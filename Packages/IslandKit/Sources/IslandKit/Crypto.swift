import CryptoKit
import Security
import Foundation

/// The island's cryptography, byte for byte as Arnav Island for Windows (CNG) and Android do it: static ECDH P-256 keys
/// (public keys on the wire as X then Y, 32 bytes each), the shared X coordinate hashed once with SHA-256, and AES-256-GCM
/// with a 12-byte nonce of a direction byte and a frame counter.
public enum Crypto {
    public static func random(_ n: Int) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: n)
        if SecRandomCopyBytes(kSecRandomDefault, n, &out) != errSecSuccess { var g = SystemRandomNumberGenerator(); for i in 0..<n { out[i] = UInt8.random(in: 0...255, using: &g) } }
        return out
    }
    public static func sha256(_ parts: [UInt8]...) -> [UInt8] { var h = SHA256(); for p in parts { h.update(data: p) }; return Array(h.finalize()) }
    public static func sha256(_ label: String, _ parts: [UInt8]...) -> [UInt8] { var h = SHA256(); h.update(data: Array(label.utf8)); for p in parts { h.update(data: p) }; return Array(h.finalize()) }
    /// A device's key fingerprint as its pairing QR code carries it: the first ten bytes of the SHA-256 of its public key.
    public static func keyPrint(_ pub: [UInt8]) -> [UInt8] { Array(sha256(pub).prefix(10)) }
    /// A public key (X then Y) that is a point on P-256.
    public static func validPublic(_ xy: [UInt8]) -> Bool { xy.count == 64 && (try? P256.KeyAgreement.PublicKey(rawRepresentation: xy)) != nil }
}

/// This device's identity key: in the Secure Enclave where there is one (its private half never leaves it, not even to
/// this app), else in software. Either way it agrees keys exactly as the island's CNG does.
public final class IdentityKey {
    public enum Kind: UInt8 { case software = 1, enclave = 2 }
    public let kind: Kind
    public let publicXY: [UInt8]
    /// What the store keeps: the Secure Enclave's opaque blob (usable only on this device) or the software key.
    public let stored: [UInt8]
    private let software: P256.KeyAgreement.PrivateKey?
    private let enclave: SecureEnclave.P256.KeyAgreement.PrivateKey?

    private init(kind: Kind, publicXY: [UInt8], stored: [UInt8], software: P256.KeyAgreement.PrivateKey?, enclave: SecureEnclave.P256.KeyAgreement.PrivateKey?) {
        self.kind = kind; self.publicXY = publicXY; self.stored = stored; self.software = software; self.enclave = enclave
    }
    /// A new key, in the Secure Enclave when [enclave] and there is one.
    public static func create(enclave: Bool = true) -> IdentityKey {
        if enclave, SecureEnclave.isAvailable, let k = try? SecureEnclave.P256.KeyAgreement.PrivateKey() {
            return IdentityKey(kind: .enclave, publicXY: Array(k.publicKey.rawRepresentation), stored: Array(k.dataRepresentation), software: nil, enclave: k)
        }
        let k = P256.KeyAgreement.PrivateKey()
        return IdentityKey(kind: .software, publicXY: Array(k.publicKey.rawRepresentation), stored: Array(k.rawRepresentation), software: k, enclave: nil)
    }
    public static func restore(kind: Kind, stored: [UInt8]) -> IdentityKey? {
        switch kind {
        case .enclave:
            guard SecureEnclave.isAvailable, let k = try? SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: Data(stored)) else { return nil }
            return IdentityKey(kind: .enclave, publicXY: Array(k.publicKey.rawRepresentation), stored: stored, software: nil, enclave: k)
        case .software:
            guard let k = try? P256.KeyAgreement.PrivateKey(rawRepresentation: stored) else { return nil }
            return IdentityKey(kind: .software, publicXY: Array(k.publicKey.rawRepresentation), stored: stored, software: k, enclave: nil)
        }
    }
    /// ECDH, then SHA-256 of the shared X coordinate (CNG's BCRYPT_KDF_HASH with SHA-256).
    public func agree(_ theirs: [UInt8]) -> [UInt8]? {
        guard theirs.count == 64, let pub = try? P256.KeyAgreement.PublicKey(rawRepresentation: theirs) else { return nil }
        let secret: SharedSecret?
        if let e = enclave { secret = try? e.sharedSecretFromKeyAgreement(with: pub) } else { secret = try? software?.sharedSecretFromKeyAgreement(with: pub) }
        guard let s = secret else { return nil }
        let raw = s.withUnsafeBytes { Array($0) }
        return Crypto.sha256(raw)
    }
}

/// One session's AES-256-GCM channel: the nonce is the direction (1 from the side that opened the connection, 2 back) and a
/// counter per direction, so no nonce repeats under a session key; the 16-byte tag follows the ciphertext.
public final class Channel {
    private let key: SymmetricKey
    private let sendDir: UInt8, recvDir: UInt8
    private var sent: UInt64 = 0, received: UInt64 = 0
    public init(key: [UInt8], initiator: Bool) { self.key = SymmetricKey(data: key); sendDir = initiator ? 1 : 2; recvDir = initiator ? 2 : 1 }
    private static func nonce(_ dir: UInt8, _ n: UInt64) -> [UInt8] {
        var b = [UInt8](repeating: 0, count: 12); b[0] = dir
        for i in 0..<8 { b[4 + i] = UInt8(truncatingIfNeeded: n >> UInt64(8 * i)) }
        return b
    }
    /// Callers seal in the order the frames go out (the connection holds its send lock around this and the write).
    public func seal(_ plain: [UInt8]) -> [UInt8] {
        let n = Channel.nonce(sendDir, sent); sent += 1
        guard let nonce = try? AES.GCM.Nonce(data: n), let box = try? AES.GCM.seal(plain, using: key, nonce: nonce) else { return [] }
        return Array(box.ciphertext) + Array(box.tag)
    }
    public func open(_ frame: [UInt8]) -> [UInt8]? {
        guard frame.count > 16 else { return nil }
        let n = Channel.nonce(recvDir, received); received += 1
        guard let nonce = try? AES.GCM.Nonce(data: n),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: frame[0..<(frame.count - 16)], tag: frame[(frame.count - 16)...]),
              let plain = try? AES.GCM.open(box, using: key) else { return nil }
        return Array(plain)
    }
}

/// The relay's seal: a random nonce each message, the topic as associated data (ShareRelay's Seal).
final class Seal {
    private let key: SymmetricKey
    init(_ key: [UInt8]) { self.key = SymmetricKey(data: key) }
    func seal(_ plain: [UInt8], topic: String) -> [UInt8] {
        let n = Crypto.random(12)
        guard let nonce = try? AES.GCM.Nonce(data: n), let box = try? AES.GCM.seal(plain, using: key, nonce: nonce, authenticating: Array(topic.utf8)) else { return [] }
        return n + Array(box.ciphertext) + Array(box.tag)
    }
    func open(_ sealed: [UInt8], topic: String) -> [UInt8]? {
        guard sealed.count > 12 + 16, let nonce = try? AES.GCM.Nonce(data: sealed[0..<12]),
              let box = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: sealed[12..<(sealed.count - 16)], tag: sealed[(sealed.count - 16)...]),
              let plain = try? AES.GCM.open(box, using: key, authenticating: Array(topic.utf8)) else { return nil }
        return Array(plain)
    }
}
