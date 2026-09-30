// swift-tools-version:5.10
// IslandKit: Arnav Island's sharing protocol for Apple platforms, byte for byte as the Windows island and the Android app
// speak it. Plain Foundation, CryptoKit, Network and Darwin: the tests run it on a Mac against the island's own engine.
import PackageDescription

let package = Package(
    name: "IslandKit",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [.library(name: "IslandKit", targets: ["IslandKit"])],
    targets: [
        .target(name: "IslandKit", path: "Sources/IslandKit"),
        .testTarget(name: "IslandKitTests", dependencies: ["IslandKit"], path: "Tests/IslandKitTests"),
    ]
)
