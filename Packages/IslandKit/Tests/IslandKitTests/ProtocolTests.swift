import XCTest
@testable import IslandKit

/// Known answers computed by Arnav Island for iPhone (web), whose link is verified against the Windows island's own engine:
/// the same keys, seals and topics must come out byte for byte.
final class ProtocolTests: XCTestCase {
    private func seq(_ n: Int, _ start: Int) -> [UInt8] { (0..<n).map { UInt8((start + $0) & 255) } }

    func testEcdhMatchesTheIsland() throws {
        let a = try XCTUnwrap(IdentityKey.restore(kind: .software, stored: seq(32, 1)))
        let b = try XCTUnwrap(IdentityKey.restore(kind: .software, stored: seq(32, 101)))
        XCTAssertEqual(a.publicXY.hex, "515c3d6eb9e396b904d3feca7f54fdcd0cc1e997bf375dca515ad0a6c3b4035f4536be3a50f318fbf9a5475902a221502bef0d57e08c53b2cc0a56f17d9f9354")
        XCTAssertEqual(b.publicXY.hex, "254ee6d1bad1c74ce2fd28ac529a166af4950a0e3da0bc53d96bf40dce38ebe7df5937f11e869d453729a222f63e709d0740b97544e1416b1e5a401b385fb950")
        XCTAssertEqual(a.agree(b.publicXY)?.hex, "cfcc10f0512e6a30a5a4425b6839ff9242aa7d4b124e92d61f7ad0b3055c43bd")
        XCTAssertEqual(b.agree(a.publicXY)?.hex, "cfcc10f0512e6a30a5a4425b6839ff9242aa7d4b124e92d61f7ad0b3055c43bd")
        XCTAssertEqual(Crypto.keyPrint(a.publicXY).hex, "ca5f30154a8f7c61be95")
        XCTAssertNil(a.agree([UInt8](repeating: 7, count: 64)), "a point off the curve is refused")
    }

    func testChannelMatchesTheIsland() {
        let c = Channel(key: seq(32, 1), initiator: true)
        XCTAssertEqual(c.seal(Array("hello island".utf8)).hex, "07e59d4b097873c9e967c7986e23ffeaa299bb25128bc927224f7681")
        XCTAssertEqual(c.seal(Array("again".utf8)).hex, "1d5fd725a3aedc8313bd58b52e742dc87b07767273")
        let back = Channel(key: seq(32, 1), initiator: false)
        XCTAssertEqual(back.open("07e59d4b097873c9e967c7986e23ffeaa299bb25128bc927224f7681".unhex!).map { String(decoding: $0, as: UTF8.self) }, "hello island")
        XCTAssertEqual(back.open("1d5fd725a3aedc8313bd58b52e742dc87b07767273".unhex!).map { String(decoding: $0, as: UTF8.self) }, "again")
        XCTAssertNil(back.open("1d5fd725a3aedc8313bd58b52e742dc87b07767273".unhex!), "a replayed frame fails")
    }

    func testRelaySealAndTopics() {
        let seal = Seal(seq(32, 50))
        let opened = seal.open("4e21ac70a05276c25681e3aa0b46102b7cd36151869d34884678e2e8b90fa4277fa169bf6731829b3a2b2cac58ddc456".unhex!, topic: "arnavisland/r1/0011223344556677889900112233445566778899")
        XCTAssertEqual(opened.map { String(decoding: $0, as: UTF8.self) }, "sealed for the relay")
        XCTAssertNil(seal.open("4e21ac70a05276c25681e3aa0b46102b7cd36151869d34884678e2e8b90fa4277fa169bf6731829b3a2b2cac58ddc456".unhex!, topic: "arnavisland/r1/other"), "the topic is bound in")
        let round = seal.open(seal.seal([1, 2, 3], topic: "t"), topic: "t"); XCTAssertEqual(round, [1, 2, 3])
        let secret = Crypto.sha256("arnav-relay-v1", "cfcc10f0512e6a30a5a4425b6839ff9242aa7d4b124e92d61f7ad0b3055c43bd".unhex!)
        XCTAssertEqual(Relay.topic(Crypto.sha256("inbox", secret, seq(16, 7))), "arnavisland/r1/c29473d0a3d6277b28b6d8535335c7ee37d2c57f")
        XCTAssertEqual(Crypto.sha256("arnav-pair-code-v1", Array("7K2PMX4Q".utf8)).hex, "8fdbb80d37325838b1086b30b735b04fd45d524ac42d95057b6b69b388e5939a")
    }

    func testPairingCodesAndLinks() {
        XCTAssertEqual(Pairing.code("7k2p mx4q"), "7K2PMX4Q")
        XCTAssertEqual(Pairing.code("7K2P-MX4Q"), "7K2PMX4Q")
        XCTAssertNil(Pairing.code("7K2PMX4"), "seven characters")
        XCTAssertNil(Pairing.code("7K2PMX40"), "0 isn't in the alphabet")
        XCTAssertNil(Pairing.code("straße12"), "letters that turn into two")
        let l = Pairing.link("arnavisland://pair/7K2PMX4Q?k=ca5f30154a8f7c61be95")
        XCTAssertEqual(l?.code, "7K2PMX4Q"); XCTAssertEqual(l?.key?.hex, "ca5f30154a8f7c61be95")
        XCTAssertEqual(Pairing.link("https://arnav-island.pages.dev/pair/7K2PMX4Q?k=ca5f30154a8f7c61be95")?.key?.hex, "ca5f30154a8f7c61be95")
        XCTAssertEqual(Pairing.link("ARNAVISLAND://pair/7k2pmx4q/"), PairLink(code: "7K2PMX4Q", key: nil))
        XCTAssertNil(Pairing.link("arnavisland://pair/7K2PMX4Q?k=zz")?.key)
        XCTAssertNil(Pairing.link("https://example.com/7K2PMX4Q"))
    }

    func testWireAndReader() {
        let b = Wire().u8(0xAB).u16(0x1234).u32(0xDEADBEEF).u64(0x0102030405060708).f64(1.5).string("é").build()
        let r = Reader(b)
        XCTAssertEqual(r.u8(), 0xAB); XCTAssertEqual(r.u16(), 0x1234); XCTAssertEqual(r.u32(), 0xDEADBEEF); XCTAssertEqual(r.u64(), 0x0102030405060708)
        XCTAssertEqual(r.f64(), 1.5); XCTAssertEqual(r.string(), "é"); XCTAssertNil(r.u8(), "nothing overruns")
        XCTAssertEqual(Reader([0xFF]).i8(), -1)
        XCTAssertEqual(Relay.packet(0x30, [UInt8](repeating: 1, count: 200)).prefix(3), [0x30, 0xC8, 0x01])
        XCTAssertEqual(Relay.connectPacket("ai01").hex, "101000044d5154540402003c00046169303 1".replacingOccurrences(of: " ", with: ""))
    }

    func testNamesAndPaths() {
        XCTAssertEqual(safeName("../a<b>.txt"), "a_b_.txt")
        XCTAssertEqual(safeName("CON.txt"), "_CON.txt")
        XCTAssertEqual(safePath("Photos/../x/./y.jpg"), ["Photos", "x", "y.jpg"])
        XCTAssertEqual(cleanName("\u{1}PC\u{7f}"), "PC"); XCTAssertEqual(cleanName(""), "A PC")
    }

    func testCandidates() {
        let w = Wire(); w.u8(2)
        Relay.putCandidate(w, SocketAddress(ip: [192, 168, 1, 20], port: 50000), 0)
        Relay.putCandidate(w, SocketAddress(ip: [UInt8](repeating: 0x20, count: 16), port: 1), 1)
        let got = Relay.readCandidates(w.build(), 0)
        XCTAssertEqual(got, [SocketAddress(ip: [192, 168, 1, 20], port: 50000), SocketAddress(ip: [UInt8](repeating: 0x20, count: 16), port: 1)])
        XCTAssertTrue(got[0].local); XCTAssertFalse(got[1].local)
    }

    func testStatusParse() {
        let p = Wire().u16(1 | 2 | 16 | 1 << 9).f64(61.5).f64(200).u8(42).u8(77).u8(13).u8(0).string("Song\nArtist\nSpotify\nStudio PC\n14° Rain").build()
        let s = IslandWire.status(p, previous: nil)
        XCTAssertEqual(s?.title, "Song"); XCTAssertEqual(s?.weather, "14° Rain"); XCTAssertEqual(s?.volume, 42); XCTAssertEqual(s?.playing, true); XCTAssertEqual(s?.clipboard, true)
    }

    func testStreams() throws {
        let q = ByteQueue(); q.write([1, 2]); q.write([3])
        XCTAssertEqual(try q.readExactly(3, timeout: 1), [1, 2, 3])
        XCTAssertThrowsError(try q.readExactly(1, timeout: 0.05)) { XCTAssertTrue($0 is StreamTimedOut) }
        q.close(); XCTAssertEqual(q.read(max: 10, timeout: 1), [])
    }
}
