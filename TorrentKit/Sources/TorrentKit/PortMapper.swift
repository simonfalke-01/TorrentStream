import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

#if canImport(Glibc)
private let MAP_SOCK_DGRAM = Int32(SOCK_DGRAM.rawValue)
#else
private let MAP_SOCK_DGRAM = SOCK_DGRAM
#endif

/// Asks the home router to forward a public port to our listener, so peers on the internet can connect to us:
/// NAT-PMP (Apple and many other routers) first, then UPnP, whose discovery is sent straight to the router (iOS
/// only lets entitled apps multicast). On cellular there's no router to ask; nothing is mapped.
final class PortMapper {
    private let internalPort: UInt16
    private let onChange: (UInt16?) -> Void
    private let queue = DispatchQueue(label: "port-mapper", qos: .utility)
    private let lock = NSLock()
    private var mapped: UInt16?
    private var running = false
    private var lastAttempt: Date?
    /// How long a mapping is asked for; it's renewed at half that.
    static let lifetime: UInt32 = 3600

    init(internalPort: UInt16, onChange: @escaping (UInt16?) -> Void) {
        self.internalPort = internalPort
        self.onChange = onChange
    }

    var externalPort: UInt16? { lock.lock(); defer { lock.unlock() }; return mapped }

    /// Maps the port now (on a background queue), unless a mapping was made recently.
    func refresh(force: Bool = false) {
        lock.lock()
        if running || (!force && lastAttempt.map { Date().timeIntervalSince($0) < Double(Self.lifetime) / 2 } == true && mapped != nil) {
            lock.unlock(); return
        }
        running = true
        lastAttempt = Date()
        lock.unlock()
        queue.async { [weak self] in
            guard let self else { return }
            let port = self.map()
            self.lock.lock()
            let changed = port != self.mapped
            self.mapped = port
            self.running = false
            self.lock.unlock()
            if let port { log("port mapper: public port \(port) forwards to \(self.internalPort)") }
            if changed { self.onChange(port) }
            // Renewed before the lease runs out.
            self.queue.asyncAfter(deadline: .now() + .seconds(Int(Self.lifetime / 2))) { [weak self] in self?.refresh(force: true) }
        }
    }

    private func map() -> UInt16? {
        guard let lan = Self.lanAddress() else { return nil }
        let gateway = (lan.ip & lan.mask) | 1
        if let p = natPMP(gateway: gateway) { return p }
        return upnp(gateway: gateway, local: lan.ip)
    }

    // MARK: local network

    /// The Wi-Fi (or Ethernet) IPv4 address and netmask, if on a private network.
    static func lanAddress() -> (ip: UInt32, mask: UInt32)? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var best: (ip: UInt32, mask: UInt32)?
        var cur: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = cur {
            defer { cur = ifa.pointee.ifa_next }
            guard let addr = ifa.pointee.ifa_addr, addr.pointee.sa_family == sa_family_t(AF_INET),
                  let maskPtr = ifa.pointee.ifa_netmask else { continue }
            let name = String(cString: ifa.pointee.ifa_name)
            guard name.hasPrefix("en") || name.hasPrefix("eth") || name.hasPrefix("wl") else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let mask = maskPtr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            guard isPrivate(ip), mask != 0, mask != .max else { continue }
            if best == nil || name == "en0" { best = (ip, mask) }
        }
        return best
    }

    static func isPrivate(_ ip: UInt32) -> Bool {
        ip >> 24 == 10 || ip >> 20 == 0xAC1 || ip >> 16 == 0xC0A8
    }

    private static func dotted(_ ip: UInt32) -> String {
        "\(ip >> 24).\((ip >> 16) & 0xff).\((ip >> 8) & 0xff).\(ip & 0xff)"
    }

    // MARK: NAT-PMP (RFC 6886)

    private func natPMP(gateway: UInt32) -> UInt16? {
        var req = Data([0, 2, 0, 0])
        req.appendBE(internalPort)
        req.appendBE(internalPort)
        req.appendBE(Self.lifetime)
        for timeout in [0.25, 0.5, 1.0] {
            guard let reply = Self.udpExchange(req, to: PeerAddress(ip: gateway, port: 5351), timeout: timeout) else { continue }
            guard reply.count >= 16, reply[reply.startIndex + 1] == 130 else { return nil }
            guard reply.readUInt16BE(at: 2) == 0 else { return nil }
            let external = reply.readUInt16BE(at: 10)
            return external == 0 ? nil : external
        }
        return nil
    }

    // MARK: UPnP IGD

    private func upnp(gateway: UInt32, local: UInt32) -> UInt16? {
        let search = "M-SEARCH * HTTP/1.1\r\nHOST: 239.255.255.250:1900\r\nMAN: \"ssdp:discover\"\r\nMX: 1\r\n"
            + "ST: urn:schemas-upnp-org:device:InternetGatewayDevice:1\r\n\r\n"
        var location: URL?
        for timeout in [0.5, 1.0] {
            guard let reply = Self.udpExchange(Data(search.utf8), to: PeerAddress(ip: gateway, port: 1900), timeout: timeout),
                  let text = String(data: reply, encoding: .utf8) else { continue }
            for line in text.components(separatedBy: "\r\n") where line.lowercased().hasPrefix("location:") {
                location = URL(string: line.dropFirst("location:".count).trimmingCharacters(in: .whitespaces))
            }
            if location != nil { break }
        }
        guard let location, let xml = Self.http(location, body: nil, headers: [:]).flatMap({ String(data: $0.1, encoding: .utf8) }),
              let (service, control) = Self.wanService(xml, base: location) else { return nil }
        var external = internalPort
        for attempt in 0..<4 {
            for lease in [Self.lifetime, 0] {
                let body = """
                <?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" \
                s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:AddPortMapping xmlns:u="\(service)">\
                <NewRemoteHost></NewRemoteHost><NewExternalPort>\(external)</NewExternalPort><NewProtocol>TCP</NewProtocol>\
                <NewInternalPort>\(internalPort)</NewInternalPort><NewInternalClient>\(Self.dotted(local))</NewInternalClient>\
                <NewEnabled>1</NewEnabled><NewPortMappingDescription>TorrentStream</NewPortMappingDescription>\
                <NewLeaseDuration>\(lease)</NewLeaseDuration></u:AddPortMapping></s:Body></s:Envelope>
                """
                guard let (status, reply) = Self.http(control, body: Data(body.utf8), headers: [
                    "Content-Type": "text/xml; charset=\"utf-8\"",
                    "SOAPAction": "\"\(service)#AddPortMapping\"",
                ]) else { return nil }
                if status == 200 { return external }
                let text = String(data: reply, encoding: .utf8) ?? ""
                // 725: the router only takes permanent mappings.
                if text.contains("<errorCode>725</errorCode>") { continue }
                // 718: the port is mapped to someone else; another is tried.
                if text.contains("<errorCode>718</errorCode>") { break }
                return nil
            }
            external = UInt16.random(in: 20000...60000)
            _ = attempt
        }
        return nil
    }

    /// The WAN connection service of a device description, and its control URL.
    static func wanService(_ xml: String, base: URL) -> (String, URL)? {
        let blocks = xml.components(separatedBy: "<service>").dropFirst()
        for kind in ["WANIPConnection:2", "WANIPConnection:1", "WANPPPConnection:1"] {
            for block in blocks {
                guard let type = tag("serviceType", in: block), type.hasSuffix(kind),
                      let control = tag("controlURL", in: block),
                      let url = URL(string: control, relativeTo: base)?.absoluteURL else { continue }
                return (type, url)
            }
        }
        return nil
    }

    private static func tag(_ name: String, in text: String) -> String? {
        guard let a = text.range(of: "<\(name)>"), let b = text.range(of: "</\(name)>", range: a.upperBound..<text.endIndex)
        else { return nil }
        return text[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: transport

    /// Sends one datagram and waits for the first reply.
    static func udpExchange(_ data: Data, to address: PeerAddress, timeout: Double) -> Data? {
        let fd = socket(AF_INET, MAP_SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { _ = Glue.close(fd) }
        Net.setTimeout(fd, option: SO_RCVTIMEO, seconds: timeout)
        var sa = address.sockaddr
        let sent = data.withUnsafeBytes { raw in
            withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, raw.baseAddress, raw.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == data.count else { return nil }
        var buf = [UInt8](repeating: 0, count: 2048)
        let n = buf.withUnsafeMutableBytes { Glue.recv(fd, $0.baseAddress!, 2048, 0) }
        return n > 0 ? Data(buf[0..<n]) : nil
    }

    /// A blocking HTTP request to the router (GET, or POST with a body).
    static func http(_ url: URL, body: Data?, headers: [String: String]) -> (Int, Data)? {
        var req = URLRequest(url: url, timeoutInterval: 3)
        req.httpMethod = body == nil ? "GET" : "POST"
        req.httpBody = body
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        let done = DispatchSemaphore(value: 0)
        var result: (Int, Data)?
        URLSession.shared.dataTask(with: req) { data, response, _ in
            if let http = response as? HTTPURLResponse { result = (http.statusCode, data ?? Data()) }
            done.signal()
        }.resume()
        _ = done.wait(timeout: .now() + 4)
        return result
    }
}
