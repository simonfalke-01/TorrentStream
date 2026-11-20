// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TorrentKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TorrentKit", targets: ["TorrentKit"]),
        .library(name: "NyaaKit", targets: ["NyaaKit"]),
        .library(name: "CatalogKit", targets: ["CatalogKit"]),
    ],
    targets: [
        .target(name: "TorrentKit"),
        // Search client for nyaa.si.
        .target(name: "NyaaKit"),
        // Release-name parsing and poster/synopsis lookup (AniList, Cinemeta).
        .target(name: "CatalogKit"),
        // Command line harness used to exercise the engine on Linux/macOS.
        .executableTarget(name: "tkcli", dependencies: ["TorrentKit"]),
        .testTarget(name: "TorrentKitTests", dependencies: ["TorrentKit"]),
        .testTarget(name: "NyaaKitTests", dependencies: ["NyaaKit"]),
        .testTarget(name: "CatalogKitTests", dependencies: ["CatalogKit"]),
    ]
)
