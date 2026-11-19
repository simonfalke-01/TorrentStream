// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TorrentKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TorrentKit", targets: ["TorrentKit"]),
    ],
    targets: [
        .target(name: "TorrentKit"),
        // Command line harness used to exercise the engine on Linux/macOS.
        .executableTarget(name: "tkcli", dependencies: ["TorrentKit"]),
        .testTarget(name: "TorrentKitTests", dependencies: ["TorrentKit"]),
    ]
)
