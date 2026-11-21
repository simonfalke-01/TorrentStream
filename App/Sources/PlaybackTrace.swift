import Foundation

/// A timeline of what happened while starting and seeking, kept on disk so a slow start can be explained after the
/// fact: when Play was pressed, when the release was found, when the player asked for data, when the first frame
/// showed, how long each seek took, and how the swarm looked meanwhile. Shared from Settings.
final class PlaybackTrace: @unchecked Sendable {
    static let shared = PlaybackTrace()

    let fileURL: URL
    private let queue = DispatchQueue(label: "PlaybackTrace")
    private var lines: [String] = []
    private var origin = Date()
    private let maxLines = 4000

    private init() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("playback-trace.log")
        if let old = try? String(contentsOf: fileURL, encoding: .utf8) {
            lines = old.split(separator: "\n", omittingEmptySubsequences: true).suffix(maxLines / 2).map(String.init)
        }
    }

    /// Starts a new section with its own clock, e.g. when Play is pressed.
    func begin(_ title: String) {
        let now = Date()
        queue.async {
            self.origin = now
            self.append("")
            self.append("=== \(title) — \(now.formatted(date: .abbreviated, time: .standard))")
        }
    }

    func mark(_ event: String) {
        let now = Date()
        queue.async {
            self.append(String(format: "%8.2fs  ", now.timeIntervalSince(self.origin)) + event)
        }
    }

    private func append(_ line: String) {
        lines.append(line)
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
        pendingWrite = true
        guard !writeScheduled else { return }
        writeScheduled = true
        queue.asyncAfter(deadline: .now() + 1) {
            self.writeScheduled = false
            guard self.pendingWrite else { return }
            self.pendingWrite = false
            try? self.lines.joined(separator: "\n").write(to: self.fileURL, atomically: true, encoding: .utf8)
        }
    }

    private var pendingWrite = false
    private var writeScheduled = false

    /// Writes everything so far, for sharing.
    func flush() -> URL {
        queue.sync {
            pendingWrite = false
            try? lines.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
        }
        return fileURL
    }
}
