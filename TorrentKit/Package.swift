// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TorrentKit",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "TorrentKit", targets: ["TorrentKit"]),
        .library(name: "NyaaKit", targets: ["NyaaKit"]),
        .library(name: "CatalogKit", targets: ["CatalogKit"]),
        .library(name: "SourceKit", targets: ["SourceKit"]),
        .library(name: "SubtitleKit", targets: ["SubtitleKit"]),
        .library(name: "MediaKit", targets: ["MediaKit"]),
        .library(name: "SkipKit", targets: ["SkipKit"]),
    ],
    targets: [
        .target(name: "TorrentKit"),
        // Search client for nyaa.si.
        .target(name: "NyaaKit"),
        // Release-name parsing and poster/synopsis lookup (AniList, Cinemeta).
        .target(name: "CatalogKit"),
        // Finds the Nyaa release and file that play a catalog episode.
        .target(name: "SourceKit", dependencies: ["CatalogKit", "NyaaKit"]),
        // SRT/WebVTT/ASS parsing and text subtitle tracks of (partly downloaded) Matroska files.
        .target(name: "SubtitleKit"),
        // Keyframe index of (partly downloaded) Matroska and MP4 files, for seek previews.
        .target(name: "MediaKit"),
        // Finds an episode's opening and ending by matching its audio against other episodes of the show, and merges
        // that with chapter names and catalog times.
        .target(name: "SkipKit", dependencies: ["CatalogKit"]),
        // Command line harness used to exercise the engine on Linux/macOS.
        .executableTarget(name: "tkcli", dependencies: ["TorrentKit"]),
        // Runs SkipKit over Matroska files and decoded audio, to measure skip times against real episodes.
        .executableTarget(name: "skipcli", dependencies: ["SkipKit", "CatalogKit"]),
        .testTarget(name: "TorrentKitTests", dependencies: ["TorrentKit"]),
        .testTarget(name: "NyaaKitTests", dependencies: ["NyaaKit"]),
        .testTarget(name: "CatalogKitTests", dependencies: ["CatalogKit"]),
        .testTarget(name: "SourceKitTests", dependencies: ["SourceKit"]),
        .testTarget(name: "SubtitleKitTests", dependencies: ["SubtitleKit"]),
        .testTarget(name: "MediaKitTests", dependencies: ["MediaKit"], exclude: ["Fixtures"]),
        .testTarget(name: "SkipKitTests", dependencies: ["SkipKit", "CatalogKit"]),
    ]
)
