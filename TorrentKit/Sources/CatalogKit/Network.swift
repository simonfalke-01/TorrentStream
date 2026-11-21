import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Whether catalog requests made from the current task are for something on screen or ahead-of-time work.
public enum CatalogPriority {
    /// Set for prefetching and background refreshes. Such AniList requests give way when the request budget runs
    /// low, so what the viewer is waiting on never sits behind a rate limit.
    @TaskLocal public static var isBackground = false
}

/// AniList allows a fixed number of requests a minute (30 while it's degraded, normally 90) and answers a burst past
/// that with a 429 and a minute's wait. This keeps track of what's left from the response headers, counting requests
/// still in flight, and holds a reserve back for requests the viewer is waiting on.
public final class AniListBudget: @unchecked Sendable {
    public static let shared = AniListBudget()

    private let lock = NSLock()
    private var remaining: Int?
    private var updatedAt = Date.distantPast
    private var inFlight = 0
    private var blockedUntil = Date.distantPast
    /// Requests kept for the viewer.
    public static let reserve = 8

    init() {}

    /// Requests that can still be made this minute without eating into the reserve, or nil when unknown.
    public var spare: Int? {
        lock.lock(); defer { lock.unlock() }
        return spareLocked(Date())
    }

    private func spareLocked(_ now: Date) -> Int? {
        if now < blockedUntil { return 0 }
        // The window is a minute; past that the count has refilled.
        guard let r = remaining, now.timeIntervalSince(updatedAt) < 60 else { return nil }
        return r - inFlight - Self.reserve
    }

    /// Waits out a rate limit for the viewer's requests; background requests fail instead of waiting or spending the
    /// reserve.
    func admit(background: Bool) async throws {
        let now = Date()
        guard let wait = try ticket(background: background, now: now) else { return }
        try await Task.sleep(nanoseconds: UInt64(min(wait, 30) * 1_000_000_000))
        started()
    }

    /// Counts the request as started and returns nil, or returns how long it must wait first.
    private func ticket(background: Bool, now: Date) throws -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        if background, let spare = spareLocked(now), spare <= 0 { throw CatalogError.rateLimited }
        guard now < blockedUntil else {
            inFlight += 1
            return nil
        }
        return blockedUntil.timeIntervalSince(now)
    }

    private func started() {
        lock.lock(); defer { lock.unlock() }
        inFlight += 1
    }

    func finished(_ response: URLResponse?) {
        let now = Date()
        lock.lock(); defer { lock.unlock() }
        inFlight = max(0, inFlight - 1)
        guard let http = response as? HTTPURLResponse else { return }
        if let r = http.value(forHTTPHeaderField: "X-RateLimit-Remaining").flatMap({ Int($0) }) {
            remaining = r
            updatedAt = now
        }
        if http.statusCode == 429 {
            let wait = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) } ?? 30
            blockedUntil = now.addingTimeInterval(min(max(wait, 1), 90))
            remaining = 0
            updatedAt = now
        }
    }

    /// For tests.
    func record(remaining: Int?, at date: Date = Date(), blockedUntil: Date = .distantPast) {
        lock.lock(); defer { lock.unlock() }
        self.remaining = remaining
        updatedAt = date
        self.blockedUntil = blockedUntil
        inFlight = 0
    }
}

public enum HTTP {
    /// A data task that is cancelled with the Swift task that awaits it, so a superseded request (a search for what
    /// the viewer typed a moment ago) stops using the connection.
    public static func data(_ session: URLSession, for request: URLRequest,
                            priority: Float = URLSessionTask.defaultPriority) async throws -> (Data, URLResponse?) {
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(Data, URLResponse?), Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error { cont.resume(throwing: error); return }
                    cont.resume(returning: (data ?? Data(), response))
                }
                task.priority = priority
                if box.set(task) { task.cancel() }
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// Opens connections (DNS, TCP, TLS, HTTP/2) to hosts the app is about to use, so the first real request
    /// doesn't pay three round trips for them. Connections are pooled per session, so warm the session that will be
    /// used.
    public static func preconnect(_ urls: [URL], session: URLSession = .shared) {
        for url in urls {
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.httpMethod = "HEAD"
            request.setValue("TorrentStream/4 (iOS)", forHTTPHeaderField: "User-Agent")
            let task = session.dataTask(with: request) { _, _, _ in }
            task.priority = URLSessionTask.lowPriority
            task.resume()
        }
    }
}

/// Something that happens once, from whichever task gets there first.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false

    /// True for the first caller only.
    func setOnce() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if set { return false }
        set = true
        return true
    }
}

private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    /// Returns true when cancellation came first.
    func set(_ t: URLSessionDataTask) -> Bool {
        lock.lock(); defer { lock.unlock() }
        task = t
        return cancelled
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let t = task
        lock.unlock()
        t?.cancel()
    }
}
