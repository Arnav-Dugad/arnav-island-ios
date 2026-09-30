import Foundation
import IslandKit
import Security

/// This iPhone's identity and its paired PCs, in the keychain (this device only, readable after the first unlock), in the
/// app group's keychain so the share sheet and widgets can reach your PCs too. The identity's private key is itself in the
/// Secure Enclave: what's kept here is only the Secure Enclave's handle to it, useless on any other device.
final class KeychainStore: LinkStore {
    static let shared = KeychainStore()
    private let service = "io.github.arnavdugad.arnavisland"

    private func query(_ account: String, group: Bool) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
        if group { q[kSecAttrAccessGroup as String] = AppGroup.id }
        return q
    }
    private func read(_ account: String) -> Data? {
        for group in [true, false] {
            var q = query(account, group: group); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
            var out: CFTypeRef?
            if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data { return d }
        }
        return nil
    }
    @discardableResult private func write(_ account: String, _ data: Data) -> Bool {
        for group in [true, false] {
            let q = query(account, group: group)
            let attrs: [String: Any] = [kSecValueData as String: data, kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
            var status = SecItemUpdate(q as CFDictionary, attrs as CFDictionary)
            if status == errSecItemNotFound { var add = q; add.merge(attrs) { $1 }; status = SecItemAdd(add as CFDictionary, nil) }
            if status == errSecSuccess { return true }
            // Without the group's entitlement (a build signed without it), the app keeps it to itself.
            if status != errSecMissingEntitlement && status != errSecNoAccessForItem { return false }
        }
        return false
    }
    func erase() { for account in ["identity", "peers"] { for g in [true, false] { SecItemDelete(query(account, group: g) as CFDictionary) } } }

    func loadIdentity() -> StoredIdentity? {
        guard let d = read("identity"), d.count > 17, let kind = IdentityKey.Kind(rawValue: d[d.startIndex]) else { return nil }
        let b = [UInt8](d); guard let key = IdentityKey.restore(kind: kind, stored: Array(b[17...])) else { return nil }
        return StoredIdentity(id: Array(b[1..<17]), key: key)
    }
    func saveIdentity(_ identity: StoredIdentity) -> Bool { write("identity", Data([identity.key.kind.rawValue] + identity.id + identity.key.stored)) }
    func loadPeers() -> [StoredPeer] { read("peers").flatMap { try? JSONDecoder().decode([StoredPeer].self, from: $0) } ?? [] }
    func savePeers(_ peers: [StoredPeer]) { if let d = try? JSONEncoder().encode(peers) { write("peers", d) } }
    var hasIdentity: Bool { read("identity") != nil }
}
