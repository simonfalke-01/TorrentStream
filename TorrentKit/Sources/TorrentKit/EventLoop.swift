import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Something with a non-blocking socket that the event loop polls.
protocol LoopHandler: AnyObject {
    /// Current descriptor, or -1 once closed (the loop then drops the handler).
    var fd: Int32 { get }
    /// Whether to poll for writability (connecting, or queued output).
    var wantsWrite: Bool { get }
    /// Called on the loop thread with the poll result for `fd`.
    func handleEvents(_ revents: Int16)
}

/// One thread multiplexing every peer socket of a client with poll(2), so a new priority (a seek) turns into
/// requests on the wire immediately instead of when some peer thread next wakes up. poll is available on both
/// Darwin and Linux, and a few hundred descriptors is well within what it handles cheaply.
final class EventLoop {
    private let lock = NSLock()
    private var tasks: [() -> Void] = []
    private var added: [LoopHandler] = []
    private var running = true
    private var wakePending = false
    private let wakeRead: Int32
    private let wakeWrite: Int32
    /// Loop-thread only.
    private var handlers: [ObjectIdentifier: LoopHandler] = [:]
    private var tickers: [(id: ObjectIdentifier, interval: TimeInterval, next: TimeInterval, body: () -> Bool)] = []
    private var thread: Thread?

    init() {
        var fds: [Int32] = [0, 0]
        _ = pipe(&fds)
        wakeRead = fds[0]
        wakeWrite = fds[1]
        Net.setNonBlocking(wakeRead)
        Net.setNonBlocking(wakeWrite)
        // The thread keeps the loop alive until `stop()`.
        let t = Thread { self.run() }
        t.name = "torrent-net"
        t.stackSize = 1 << 20
        thread = t
        t.start()
    }

    var isLoopThread: Bool { Thread.current === thread }

    /// Runs `body` on the loop thread soon.
    func post(_ body: @escaping () -> Void) {
        lock.lock()
        tasks.append(body)
        lock.unlock()
        wake()
    }

    func add(_ handler: LoopHandler) {
        lock.lock()
        added.append(handler)
        lock.unlock()
        wake()
    }

    /// Calls `body` on the loop thread about every `interval` seconds until it returns false.
    func addTicker(owner: AnyObject, interval: TimeInterval, _ body: @escaping () -> Bool) {
        let id = ObjectIdentifier(owner)
        post { [weak self] in
            self?.tickers.append((id, interval, Date.timeIntervalSinceReferenceDate + interval, body))
        }
    }

    /// Interrupts poll so posted work and changed interests are picked up.
    func wake() {
        lock.lock()
        let already = wakePending
        wakePending = true
        lock.unlock()
        if already { return }
        var b: UInt8 = 1
        _ = Glue.write(wakeWrite, &b, 1)
    }

    func stop() {
        lock.lock(); running = false; lock.unlock()
        wake()
    }

    private func run() {
        var pfds: [pollfd] = []
        var order: [LoopHandler] = []
        while true {
            lock.lock()
            let isRunning = running
            let work = tasks
            tasks.removeAll()
            let newHandlers = added
            added.removeAll()
            wakePending = false
            lock.unlock()
            if !isRunning { break }
            var drain = [UInt8](repeating: 0, count: 64)
            while Glue.read(wakeRead, &drain, 64) > 0 {}
            for h in newHandlers { handlers[ObjectIdentifier(h)] = h }
            for w in work { w() }

            let now = Date.timeIntervalSinceReferenceDate
            var i = 0
            while i < tickers.count {
                if tickers[i].next <= now {
                    tickers[i].next = now + tickers[i].interval
                    if !tickers[i].body() { tickers.remove(at: i); continue }
                }
                i += 1
            }
            let nextTick = tickers.map(\.next).min() ?? now + 0.5
            let timeout = Int32(max(0, min(0.5, nextTick - Date.timeIntervalSinceReferenceDate)) * 1000) + 1

            pfds.removeAll(keepingCapacity: true)
            order.removeAll(keepingCapacity: true)
            pfds.append(pollfd(fd: wakeRead, events: Int16(POLLIN), revents: 0))
            for (id, h) in handlers {
                let fd = h.fd
                if fd < 0 { handlers[id] = nil; continue }
                var ev = Int16(POLLIN)
                if h.wantsWrite { ev |= Int16(POLLOUT) }
                pfds.append(pollfd(fd: fd, events: ev, revents: 0))
                order.append(h)
            }
            let n = poll(&pfds, nfds_t(pfds.count), timeout)
            if n <= 0 { continue }
            for k in 1..<pfds.count where pfds[k].revents != 0 {
                let h = order[k - 1]
                if h.fd == pfds[k].fd { h.handleEvents(pfds[k].revents) }
            }
        }
        for h in handlers.values { if let closable = h as? PeerConnection { closable.close(reason: "loop stopped") } }
        handlers.removeAll()
        tickers.removeAll()
        _ = Glue.close(wakeRead)
        _ = Glue.close(wakeWrite)
    }
}
