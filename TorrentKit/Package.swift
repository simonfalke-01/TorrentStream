// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TorrentKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TorrentKit", targets: ["TorrentKit"]),
        .library(name: "NyaaKit", targets: ["NyaaKit"]),
    ],
    targets: [
        .target(name: "TorrentKit"),
        // Search client for nyaa.si.
        .target(name: "NyaaKit"),
        // Command line harness used to exercise the engine on Linux/macOS.
        .executableTarget(name: "tkcli", dependencies: ["TorrentKit"]),
        .testTarget(name: "TorrentKitTests", dependencies: ["TorrentKit"]),
        .testTarget(name: "NyaaKitTests", dependencies: ["NyaaKit"]),
    ]
)
