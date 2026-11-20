import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A stretch of an episode the player can offer to skip.
public struct SkipSegment: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case intro, recap, credits, preview }
    public var kind: Kind
    /// Seconds from the start of the file.
    public var start: Double
    public var end: Double

    public init(kind: Kind, start: Double, end: Double) {
        self.kind = kind
        self.start = start
        self.end = end
    }
}

extension ShowCatalog {
    /// Opening, ending and recap times users submitted to AniSkip, sorted by start. `duration` is the length of the
    /// file in seconds, which AniSkip matches against the cuts it knows; pass 0 when unknown. Empty when there are none.
    public func skipSegments(malID: Int, episode: Int, duration: Double) async throws -> [SkipSegment] {
        let types = ["op", "ed", "mixed-op", "mixed-ed", "recap"].map { "types%5B%5D=\($0)" }.joined(separator: "&")
        let length = duration > 0 ? String(format: "%.3f", duration) : "0"
        guard let url = URL(string: "https://api.aniskip.com/v2/skip-times/\(malID)/\(episode)?\(types)&episodeLength=\(length)") else {
            throw CatalogError.unreadable
        }
        do {
            return Self.skipSegments(try await json(url, accept: "application/json"), duration: duration)
        } catch CatalogError.http(404) {
            return []
        }
    }

    static func skipSegments(_ root: [String: Any], duration: Double) -> [SkipSegment] {
        guard root["found"] as? Bool == true else { return [] }
        let kinds: [String: SkipSegment.Kind] = ["op": .intro, "mixed-op": .intro, "ed": .credits, "mixed-ed": .credits, "recap": .recap]
        var picked: [(segment: SkipSegment, mismatch: Double)] = []
        for r in (root["results"] as? [[String: Any]]) ?? [] {
            guard let kind = kinds[r["skipType"] as? String ?? ""], let i = r["interval"] as? [String: Any],
                  let start = number(i["startTime"]).map({ max(0, $0) }), var end = number(i["endTime"]) else { continue }
            if duration > 0 { end = min(end, duration) }
            guard end > start else { continue }
            let segment = SkipSegment(kind: kind, start: start, end: end)
            let mismatch = duration > 0 ? number(r["episodeLength"]).map { abs($0 - duration) } ?? .infinity : 0
            // Submissions for other cuts of the episode can overlap; keep the one timed against the closest length.
            if let j = picked.firstIndex(where: { $0.segment.kind == kind && $0.segment.start < end && start < $0.segment.end }) {
                if mismatch < picked[j].mismatch { picked[j] = (segment, mismatch) }
            } else {
                picked.append((segment, mismatch))
            }
        }
        return picked.map(\.segment).sorted { $0.start < $1.start }
    }
}

/// Skip segments read from the chapter names in a video file, for episodes AniSkip doesn't know.
public enum ChapterSkips {
    /// Segments for chapters named like an opening, ending, preview or recap. A chapter without an end runs to the
    /// next chapter or the end of the file. Chapters under 10 seconds or over 4 minutes (2 for previews) are ignored.
    public static func segments(_ chapters: [(name: String, start: Double, end: Double?)], duration: Double) -> [SkipSegment] {
        let sorted = chapters.sorted { $0.start < $1.start }
        var out: [SkipSegment] = []
        for (i, c) in sorted.enumerated() {
            guard let kind = kind(c.name) else { continue }
            var end = c.end.flatMap { $0 > c.start ? $0 : nil } ?? (i + 1 < sorted.count ? sorted[i + 1].start : duration)
            if duration > 0 { end = min(end, duration) }
            let length = end - c.start
            guard length >= 10, length <= (kind == .preview ? 120 : 240) else { continue }
            out.append(SkipSegment(kind: kind, start: c.start, end: end))
        }
        return out
    }

    private static let patterns: [(SkipSegment.Kind, String)] = [
        (.preview, #"\b(preview|next\s+ep(isode)?|yokoku)\b"#),
        (.recap, #"\b(recap|previously)\b"#),
        (.intro, #"\b(opening|intro|op\s*\d*)\b"#),
        (.credits, #"\b(ending|credits|ed\s*\d*)\b"#),
    ]

    static func kind(_ name: String) -> SkipSegment.Kind? {
        patterns.first { name.range(of: "(?i)" + $0.1, options: .regularExpression) != nil }?.0
    }
}
