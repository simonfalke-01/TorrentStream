import XCTest
@testable import TorrentKit

final class FileTreeTests: XCTestCase {
    private func files(_ paths: [String]) -> [TorrentFile] {
        paths.enumerated().map { i, p in
            TorrentFile(index: i, path: p.split(separator: "/").map(String.init), length: 100, offset: Int64(i * 100), isPadding: false)
        }
    }

    private func isVideo(_ f: TorrentFile) -> Bool { f.fileExtension == "mkv" }

    func testFlatTorrentListsFilesInNaturalOrder() {
        let tree = FileTree.build(files(["Ep 10.mkv", "Ep 2.mkv", "Ep 1.mkv", "readme.txt"]), include: isVideo)
        XCTAssertTrue(tree.folders.isEmpty)
        XCTAssertEqual(tree.files.map(\.fileName), ["Ep 1.mkv", "Ep 2.mkv", "Ep 10.mkv"])
    }

    func testSingleFolderChainIsCollapsed() {
        let tree = FileTree.build(files(["Show/Season 1/E02.mkv", "Show/Season 1/E01.mkv", "Show/Season 1/info.nfo"]), include: isVideo)
        XCTAssertEqual(tree.path, ["Show", "Season 1"])
        XCTAssertEqual(tree.files.map(\.fileName), ["E01.mkv", "E02.mkv"])
        XCTAssertTrue(tree.folders.isEmpty)
    }

    func testNestedSeasonsAndFoldersWithoutVideos() {
        let tree = FileTree.build(files([
            "Season 10/E01.mkv", "Season 2/E01.mkv", "Season 2/E02.mkv",
            "Season 2/Extras/Clean/NCOP.mkv", "Fonts/a.ttf", "Movie.mkv",
        ]), include: isVideo)
        XCTAssertEqual(tree.files.map(\.fileName), ["Movie.mkv"])
        XCTAssertEqual(tree.folders.map(\.name), ["Season 2", "Season 10"])
        let s2 = tree.folders[0]
        XCTAssertEqual(s2.files.count, 2)
        // "Extras" only contains "Clean", so the two merge into one folder.
        XCTAssertEqual(s2.folders.map(\.id), ["Season 2/Extras/Clean"])
        XCTAssertEqual(tree.folder(id: "Season 2/Extras/Clean")?.files.map(\.fileName), ["NCOP.mkv"])
        XCTAssertEqual(tree.allFiles.count, 5)
    }

    func testCleanTitles() {
        XCTAssertEqual(MediaTitle.clean("[SubsPlease] Sousou no Frieren - 03 (1080p) [F02B9CA3].mkv"), "Sousou no Frieren - 03 (1080p)")
        XCTAssertEqual(MediaTitle.clean("Movie.Name.2019.1080p.DDP5.1.H.264.mkv"), "Movie Name 2019 1080p DDP5.1 H.264")
        XCTAssertEqual(MediaTitle.clean("Some_Show_S01E02.mp4"), "Some Show S01E02")
        XCTAssertEqual(MediaTitle.clean("[Group].mkv"), "[Group]")
        XCTAssertEqual(MediaTitle.clean("Plain Name.mkv"), "Plain Name")
    }
}
