import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A stretch of an episode the player can offer to skip.
public struct SkipSegment: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable, CaseIterable { case intro, recap, credits, preview }
    public var kind: Kind
    /// Seconds from the start of the file.
    public var start: Double
    public var end: Double
    /// Timed from neighbouring episodes rather than submitted for this one.
    public var isInferred: Bool

    public init(kind: Kind, start: Double, end: Double, isInferred: Bool = false) {
        self.kind = kind
        self.start = start
        self.end = end
        self.isInferred = isInferred
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        start = try c.decode(Double.self, forKey: .start)
        end = try c.decode(Double.self, forKey: .end)
        isInferred = try c.decodeIfPresent(Bool.self, forKey: .isInferred) ?? false
    }
}

/// One AniSkip submission: where a segment falls in the cut it was timed against.
struct SkipTime: Equatable, Sendable {
    var kind: SkipSegment.Kind
    var start: Double
    var end: Double
    /// Length of that cut in seconds, when known.
    var length: Double?
}

/// AniSkip answers by episode and cut length, shared by every lookup the catalog makes. Requests in flight are shared too.
actor SkipTimesCache {
    struct Key: Hashable {
        var malID: Int
        var episode: Int
        /// Milliseconds; 0 for any cut.
        var length: Int
    }

    private var entries: [Key: Task<[SkipTime], Error>] = [:]

    func times(_ key: Key, fetch: @escaping @Sendable () async throws -> [SkipTime]) async throws -> [SkipTime] {
        if let task = entries[key] { return try await task.value }
        if entries.count >= 1000 { entries.removeAll() }
        let task = Task { try await fetch() }
        entries[key] = task
        do {
            return try await task.value
        } catch {
            if entries[key] == task { entries[key] = nil }
            throw error
        }
    }
}

extension ShowCatalog {
    /// Opening, ending and recap times for an episode, sorted by start. Uses what users submitted to AniSkip for this
    /// episode, and fills in an intro or ending it lacks from up to four neighbouring episodes. `duration` is the length
    /// of the file in seconds, which AniSkip matches against the cuts it knows; pass 0 when unknown. Empty when there
    /// are none.
    public func skipSegments(malID: Int, episode: Int, duration: Double) async throws -> [SkipSegment] {
        let own = try await skipTimes(malID: malID, episode: episode, duration: duration)
        let segments = Self.picked(own, duration: duration)
        let found = Set(segments.map(\.kind))
        guard !found.isSuperset(of: [.intro, .credits]) else { return segments }
        let order = [episode - 1, episode + 1, episode - 2, episode + 2].filter { $0 >= 1 }
        let fetched = await withTaskGroup(of: (Int, [SkipTime]?).self) { group -> [Int: [SkipTime]] in
            for n in order { group.addTask { (n, try? await self.skipTimes(malID: malID, episode: n, duration: 0)) } }
            var all: [Int: [SkipTime]] = [:]
            for await (n, times) in group { all[n] = times }
            return all
        }
        let neighbours = order.compactMap { fetched[$0] }
        let missing = Set(SkipSegment.Kind.allCases).subtracting(found)
        return (segments + Self.inferredSegments(neighbours, missing: missing, duration: duration)).sorted { $0.start < $1.start }
    }

    /// Submissions for one episode, timed against a cut of about `duration` seconds, or any cut for 0.
    private func skipTimes(malID: Int, episode: Int, duration: Double) async throws -> [SkipTime] {
        let key = SkipTimesCache.Key(malID: malID, episode: episode, length: duration > 0 ? Int((duration * 1000).rounded()) : 0)
        return try await skipCache.times(key) {
            let types = ["op", "ed", "mixed-op", "mixed-ed", "recap"].map { "types%5B%5D=\($0)" }.joined(separator: "&")
            let length = duration > 0 ? String(format: "%.3f", duration) : "0"
            guard let url = URL(string: "https://api.aniskip.com/v2/skip-times/\(malID)/\(episode)?\(types)&episodeLength=\(length)") else {
                throw CatalogError.unreadable
            }
            do {
                return Self.skipTimes(try await self.json(url, accept: "application/json"))
            } catch CatalogError.http(404) {
                return []
            }
        }
    }

    static func skipSegments(_ root: [String: Any], duration: Double) -> [SkipSegment] {
        picked(skipTimes(root), duration: duration)
    }

    static func skipTimes(_ root: [String: Any]) -> [SkipTime] {
        guard root["found"] as? Bool == true else { return [] }
        let kinds: [String: SkipSegment.Kind] = ["op": .intro, "mixed-op": .intro, "ed": .credits, "mixed-ed": .credits,
                                                 "recap": .recap, "preview": .preview]
        return ((root["results"] as? [[String: Any]]) ?? []).compactMap { r in
            guard let kind = kinds[r["skipType"] as? String ?? ""], let i = r["interval"] as? [String: Any],
                  let start = number(i["startTime"]), let end = number(i["endTime"]), end > start else { return nil }
            return SkipTime(kind: kind, start: max(0, start), end: end, length: number(r["episodeLength"]).flatMap { $0 > 0 ? $0 : nil })
        }
    }

    /// One segment per stretch of the episode. Submissions for other cuts can overlap; the one timed against the
    /// length closest to `duration` wins.
    static func picked(_ times: [SkipTime], duration: Double) -> [SkipSegment] {
        var picked: [(segment: SkipSegment, mismatch: Double)] = []
        for t in times {
            let end = duration > 0 ? min(t.end, duration) : t.end
            guard end > t.start else { continue }
            let segment = SkipSegment(kind: t.kind, start: t.start, end: end)
            let mismatch = duration > 0 ? t.length.map { abs($0 - duration) } ?? .infinity : 0
            if let j = picked.firstIndex(where: { $0.segment.kind == t.kind && $0.segment.start < end && t.start < $0.segment.end }) {
                if mismatch < picked[j].mismatch { picked[j] = (segment, mismatch) }
            } else {
                picked.append((segment, mismatch))
            }
        }
        return picked.map(\.segment).sorted { $0.start < $1.start }
    }

    /// Segments of the `missing` kinds timed from neighbouring episodes, nearest first. Endings and previews keep their
    /// distance from the end of the file, and one neighbour is enough. Intros and recaps keep their time from the start,
    /// and need two neighbours that agree, or one with the segment in its first 5 seconds. Neighbours agree when they
    /// are within 5 seconds of each other; when some disagree, the largest group that agrees wins.
    static func inferredSegments(_ neighbours: [[SkipTime]], missing: Set<SkipSegment.Kind>, duration: Double) -> [SkipSegment] {
        var out: [SkipSegment] = []
        for kind in SkipSegment.Kind.allCases where missing.contains(kind) {
            let fromEnd = kind == .credits || kind == .preview
            if fromEnd && duration <= 0 { continue }
            let candidates: [(start: Double, end: Double)] = neighbours.compactMap { times in
                let ofKind = times.filter { $0.kind == kind }
                let t = duration > 0 ? ofKind.min { abs(($0.length ?? .infinity) - duration) < abs(($1.length ?? .infinity) - duration) } : ofKind.first
                guard let t else { return nil }
                guard fromEnd else { return (t.start, t.end) }
                guard let length = t.length else { return nil }
                return (duration - (length - t.start), duration - (length - t.end))
            }
            let groups = candidates.map { c in candidates.filter { abs($0.start - c.start) <= 5 && abs($0.end - c.end) <= 5 }.count }
            guard let best = groups.indices.max(by: { groups[$0] < groups[$1] || (groups[$0] == groups[$1] && $0 > $1) }) else { continue }
            let agreed = groups[best] >= 2
            let accepted = fromEnd ? (agreed || candidates.count == 1) : (agreed || (candidates.count == 1 && candidates[0].start < 5))
            guard accepted else { continue }
            let start = max(0, candidates[best].start)
            let end = duration > 0 ? min(duration, candidates[best].end) : candidates[best].end
            guard end - start >= 5 else { continue }
            out.append(SkipSegment(kind: kind, start: start, end: end, isInferred: true))
        }
        return out
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

    /// Catalog times this close to a chapter boundary are taken to mean that boundary.
    static let snapDistance: Double = 4

    /// The segments to offer for a file. Chapter names come first: they were cut for this very file, whereas a
    /// catalog time may have been submitted for another release whose cold open or logos run a different length.
    /// The catalog fills in the kinds the chapters don't name, with any time within `snapDistance` of a chapter
    /// boundary moved onto it. When the file has three or more chapters, a time inferred from neighbouring
    /// episodes is kept only if its start or end lines up with one of them; otherwise it's likely off for this
    /// episode and would show the button over the wrong scene.
    public static func merged(catalog: [SkipSegment], chapters: [(name: String, start: Double, end: Double?)],
                              duration: Double) -> [SkipSegment] {
        let named = segments(chapters, duration: duration)
        let covered = Set(named.map(\.kind))
        var bounds = chapters.map(\.start) + chapters.compactMap(\.end)
        if duration > 0 { bounds.append(duration) }
        let checkable = chapters.count >= 3

        func snapped(_ t: Double) -> Double? {
            guard let b = bounds.min(by: { abs($0 - t) < abs($1 - t) }), abs(b - t) <= snapDistance else { return nil }
            return b
        }

        var out = named
        for s in catalog where !covered.contains(s.kind) {
            let start = snapped(s.start)
            let end = snapped(s.end)
            if s.isInferred && checkable && start == nil && end == nil { continue }
            var segment = s
            segment.start = start ?? s.start
            segment.end = end ?? s.end
            if duration > 0 { segment.end = min(segment.end, duration) }
            guard segment.end - segment.start >= 5,
                  !named.contains(where: { $0.start < segment.end && segment.start < $0.end }) else { continue }
            out.append(segment)
        }
        return out.sorted { $0.start < $1.start }
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
