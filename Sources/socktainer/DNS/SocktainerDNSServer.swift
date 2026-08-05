import Darwin
import Foundation
import Logging
import Vapor

struct SocktainerDNSServerKey: StorageKey {
    typealias Value = SocktainerDNSServer
}

/// UDP DNS server that resolves container service names and forwards unknown queries to 1.1.1.1.
///
/// Runs on 0.0.0.0:2054 (covers all interfaces including vmnet gateways).
/// Port 2053 is reserved by Apple Container's own DNS handler.
/// Container names are registered after start via register(hostname:ip:) and
/// unregistered on container removal via unregister(hostname:).
///
/// A single container can be attached to more than one network (e.g. a Compose
/// service joined to several networks), and each network gets its own DNS forwarder
/// sidecar (see NetworkDNSManager) that relays queries here. Because every sidecar
/// forwards to this same process, a multi-homed hostname can have one registered
/// address per network it's attached to; `register(hostname:ip:)` keeps one entry per
/// distinct subnet rather than overwriting the hostname's single address. At query
/// time, `lookupAddress` prefers whichever registered address shares a subnet with
/// the querying client — i.e. the address on the network the query actually arrived
/// on — falling back to the first-registered address when no subnet match exists
/// (unscoped registrations, or a network we have no subnet info for).
final class SocktainerDNSServer: @unchecked Sendable {
    /// One registered address for a hostname. `subnet` is the (network address, prefix
    /// length) the address was registered with — nil for callers that register a bare
    /// IP with no CIDR prefix, which matches any querying client (legacy behavior).
    private struct AddressEntry {
        let ip: [UInt8]
        let subnet: (network: [UInt8], prefixLength: UInt8)?
    }

    private let lock = NSLock()
    private var entries: [String: [AddressEntry]] = [:]  // normalized hostname → registered addresses
    private var log = Logger(label: "socktainer.dns")

    /// Registers `ip` (optionally a CIDR like "192.168.1.5/24") for `hostname`. If an
    /// entry already exists for the same subnet (or, for unscoped addresses, any prior
    /// unscoped entry), it is replaced in place; otherwise the address is added
    /// alongside any addresses already registered for this hostname on other subnets,
    /// so a multi-homed container keeps one reachable address per network.
    func register(hostname: String, ip: String) {
        guard let (addr, subnet) = Self.parseIPv4WithSubnet(ip) else { return }
        lock.lock()
        defer { lock.unlock() }
        let key = Self.normalize(hostname)
        var routes = entries[key] ?? []
        routes.removeAll { Self.sameSubnet($0.subnet, subnet) }
        routes.append(AddressEntry(ip: addr, subnet: subnet))
        entries[key] = routes
        log.info("[dns] registered \(key) → \(ip)")
    }

    func unregister(hostname: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.normalize(hostname)
        if entries.removeValue(forKey: key) != nil {
            log.info("[dns] unregistered \(key)")
        }
    }

    /// Unregisters the address `expectedIP` from `hostname` only if that exact address is
    /// currently registered — atomically, so a concurrent re-registration between a
    /// caller's ownership check and its unregister call can't be dropped. A hostname
    /// registered to a different address, or not registered at all, is left untouched.
    /// Other addresses registered for the same (multi-homed) hostname are unaffected.
    func unregisterIfOwned(hostname: String, expectedIP: String) {
        lock.lock()
        defer { lock.unlock() }
        let key = Self.normalize(hostname)
        guard let expected = Self.parseIPv4(expectedIP), var routes = entries[key] else { return }
        let originalCount = routes.count
        routes.removeAll { $0.ip == expected }
        guard routes.count != originalCount else { return }
        if routes.isEmpty {
            entries.removeValue(forKey: key)
        } else {
            entries[key] = routes
        }
        log.info("[dns] unregistered \(key)")
    }

    /// Returns one address per registered hostname (the first-registered one for
    /// multi-homed hostnames) — used for env-var rewriting at container-create time,
    /// which isn't network-scoped.
    func listEntries() -> [String: String] {
        lock.lock()
        defer { lock.unlock() }
        var result: [String: String] = [:]
        for (host, routes) in entries {
            guard let ip = routes.first?.ip else { continue }
            result[host] = "\(ip[0]).\(ip[1]).\(ip[2]).\(ip[3])"
        }
        return result
    }

    /// Returns the best address for `hostname` given the querying client's address:
    /// the registered address sharing a subnet with `clientIP`, or the first-registered
    /// address if none match. Not `private` so unit tests can drive the network-scoped
    /// selection logic directly, without spoofing a UDP packet's source address.
    func lookupAddress(_ hostname: String, clientIP: [UInt8]) -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }
        guard let routes = entries[hostname] else { return nil }
        if let matched = routes.first(where: { route in
            guard let subnet = route.subnet else { return false }
            return Self.networkAddress(clientIP, prefixLength: subnet.prefixLength) == subnet.network
        }) {
            return matched.ip
        }
        return routes.first?.ip
    }

    private func hasEntry(_ hostname: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return entries[hostname]?.isEmpty == false
    }

    /// Tries to bind to `preferredPort`, then `preferredPort+1`, `+2`, up to `maxAttempts`.
    /// Returns the port that was successfully bound, or nil if all attempts failed.
    /// The resolved port must be passed to NetworkDNSManager so Corefiles reference the right one.
    @discardableResult
    func start(preferredPort: Int = 2054, maxAttempts: Int = 10) -> Int? {
        for offset in 0..<maxAttempts {
            let port = preferredPort + offset
            if canBind(port: port) {
                Thread.detachNewThread { self.serverLoop(port: port) }
                return port
            }
            log.warning("[dns] port \(port) unavailable, trying \(port + 1)")
        }
        log.error("[dns] no available port in \(preferredPort)..<\(preferredPort + maxAttempts)")
        return nil
    }

    private func canBind(port: Int) -> Bool {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }

    private func serverLoop(port: Int) {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else {
            log.error("[dns] socket() failed: \(String(cString: strerror(errno)))")
            return
        }
        defer { Darwin.close(fd) }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = INADDR_ANY

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            log.error("[dns] bind() failed on port \(port): \(String(cString: strerror(errno)))")
            return
        }

        log.info("[dns] listening on 0.0.0.0:\(port)")

        var buf = [UInt8](repeating: 0, count: 512)

        // Two-tier dispatch: local lookups (in-table A/AAAA/NODATA) are answered
        // inline so the Rust DNS forwarder sidecar receives the response within
        // microseconds — before any per-task scheduling latency. Upstream queries
        // (external multi-label names that need 1.1.1.1) are still dispatched to
        // avoid blocking the recvfrom loop for the 2-second socket timeout.
        while true {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &clientAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(fd, &buf, buf.count, 0, sockPtr, &clientLen)
                }
            }
            guard n > 12 else { continue }

            let packet = Array(buf[0..<n])
            let capturedAddr = clientAddr
            let capturedLen = clientLen
            // The querying client's address — for containers this is the DNS forwarder
            // sidecar's own address on whichever network it's relaying for, which lets
            // handleLocalQuery/handleQuery prefer a multi-homed hostname's address on
            // that same network over an address registered on a different one.
            let clientIP = withUnsafeBytes(of: capturedAddr.sin_addr.s_addr) { Array($0) }

            // Fast path: local resolution — answer inline without dispatch latency.
            if let local = handleLocalQuery(packet, clientIP: clientIP) {
                var addr = capturedAddr
                _ = local.withUnsafeBytes { ptr in
                    withUnsafePointer(to: &addr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, ptr.baseAddress!, local.count, 0, $0, capturedLen)
                        }
                    }
                }
                continue
            }

            // Slow path: upstream query — dispatch so recvfrom stays responsive.
            DispatchQueue.global(qos: .userInitiated).async {
                guard let response = self.handleQuery(packet, clientIP: clientIP) else { return }
                var addr = capturedAddr
                _ = response.withUnsafeBytes { ptr in
                    withUnsafePointer(to: &addr) {
                        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                            sendto(fd, ptr.baseAddress!, response.count, 0, $0, capturedLen)
                        }
                    }
                }
            }
        }
    }

    /// Returns a local response without touching the network. Returns nil if the query
    /// needs to be forwarded upstream, letting the caller fall through to the slow path.
    /// `clientIP` is the querying client's source address, used to pick the right address
    /// for a multi-homed hostname (see `lookupAddress`).
    private func handleLocalQuery(_ packet: [UInt8], clientIP: [UInt8]) -> [UInt8]? {
        guard packet.count >= 12 else { return nil }
        let flags = (UInt16(packet[2]) << 8) | UInt16(packet[3])
        guard (flags & 0x8000) == 0, (flags & 0x7800) == 0 else { return nil }
        guard let (qname, qtype, questionEnd) = parseQuestion(packet, offset: 12) else { return nil }
        let normalized = Self.normalize(qname)
        let isSingleLabel = !normalized.contains(".")
        if qtype == 1 {
            if let ip = lookupAddress(normalized, clientIP: clientIP) {
                log.info("[dns] A \(normalized) → \(ip[0]).\(ip[1]).\(ip[2]).\(ip[3]) (local)")
                return buildAResponse(packet: packet, questionEnd: questionEnd, ip: ip)
            }
            if isSingleLabel {
                log.info("[dns] \(normalized) not in table (local NXDOMAIN)")
                return buildNxdomainResponse(packet: packet, questionEnd: questionEnd)
            }
        } else if qtype == 28 {
            if isSingleLabel { return buildNodataResponse(packet: packet, questionEnd: questionEnd) }
            if hasEntry(normalized) { return buildNodataResponse(packet: packet, questionEnd: questionEnd) }
        }
        // Any other single-label query type (HTTPS/SVCB/SRV/TXT/…) is answered NODATA
        // locally rather than forwarded: a single-label name has no public meaning, so
        // forwarding it upstream only invites an authoritative NXDOMAIN that poisons the
        // resolver's parallel A+AAAA lookups.
        if isSingleLabel { return buildNodataResponse(packet: packet, questionEnd: questionEnd) }
        return nil
    }

    private func handleQuery(_ packet: [UInt8], clientIP: [UInt8]) -> [UInt8]? {
        guard packet.count >= 12 else { return nil }

        // Only handle standard queries (QR=0, OPCODE=0)
        let flags = (UInt16(packet[2]) << 8) | UInt16(packet[3])
        guard (flags & 0x8000) == 0, (flags & 0x7800) == 0 else { return nil }

        guard let (qname, qtype, questionEnd) = parseQuestion(packet, offset: 12) else {
            return forwardToUpstream(packet)
        }

        let normalized = Self.normalize(qname)

        // Single-label names are container names, not real internet domains — never forward
        // them to 1.1.1.1, whose authoritative NXDOMAIN can poison concurrent A+AAAA resolvers.
        let isSingleLabel = !normalized.contains(".")

        if qtype == 1 {  // A record
            if let ip = lookupAddress(normalized, clientIP: clientIP) {
                log.info("[dns] A \(normalized) → \(ip[0]).\(ip[1]).\(ip[2]).\(ip[3]) (local)")
                return buildAResponse(packet: packet, questionEnd: questionEnd, ip: ip)
            }
            if isSingleLabel {
                log.info("[dns] \(normalized) not in table (local NXDOMAIN)")
                return buildNxdomainResponse(packet: packet, questionEnd: questionEnd)
            }
        } else if qtype == 28 {  // AAAA — container names are IPv4-only
            // For single-label names return NODATA unconditionally; forwarding to 1.1.1.1
            // would yield an authoritative NXDOMAIN that poisons concurrent A+AAAA resolvers.
            if isSingleLabel { return buildNodataResponse(packet: packet, questionEnd: questionEnd) }
            if hasEntry(normalized) { return buildNodataResponse(packet: packet, questionEnd: questionEnd) }
        }

        return forwardToUpstream(packet)
    }

    private func parseQuestion(_ packet: [UInt8], offset: Int) -> (String, UInt16, Int)? {
        var pos = offset
        var labels: [String] = []
        while pos < packet.count {
            let len = Int(packet[pos])
            pos += 1
            if len == 0 { break }
            if (len & 0xC0) == 0xC0 { return nil }
            guard pos + len <= packet.count else { return nil }
            labels.append(String(bytes: packet[pos..<(pos + len)], encoding: .utf8) ?? "")
            pos += len
        }
        guard pos + 4 <= packet.count else { return nil }
        let qtype = (UInt16(packet[pos]) << 8) | UInt16(packet[pos + 1])
        pos += 4
        return (labels.joined(separator: "."), qtype, pos)
    }

    /// Header + question only, with every count but QDCOUNT zeroed and `flags` applied.
    ///
    /// Truncating at the end of the question is what makes the response well-formed:
    /// echoing the whole query kept any EDNS0 OPT record the client sent in the
    /// additional section while declaring ARCOUNT=0, so a strict parser (musl's
    /// resolver, Go's) read those leftover OPT bytes as the start of the answer
    /// section and reported "answer with no data" — which is what made every
    /// container-name lookup fail for curl and traefik even though A lookups
    /// through getent worked. Dropping EDNS0 from the reply is legal: a responder
    /// that omits OPT is simply treated as not supporting it.
    private func baseResponse(packet: [UInt8], questionEnd: Int, flags: UInt16) -> [UInt8] {
        var response = Array(packet[0..<min(questionEnd, packet.count)])
        let rd = (UInt16(packet[2]) << 8 | UInt16(packet[3])) & 0x0100
        let rflags = flags | rd
        response[2] = UInt8(rflags >> 8)
        response[3] = UInt8(rflags & 0xFF)
        response[4] = 0
        response[5] = 1  // QDCOUNT=1
        response[6] = 0
        response[7] = 0
        response[8] = 0
        response[9] = 0
        response[10] = 0
        response[11] = 0
        return response
    }

    private func buildAResponse(packet: [UInt8], questionEnd: Int, ip: [UInt8]) -> [UInt8] {
        var response = baseResponse(packet: packet, questionEnd: questionEnd, flags: 0x8400)  // QR=1, AA=1
        response[7] = 1  // ANCOUNT=1
        response += [
            0xC0, 0x0C,  // NAME: pointer to offset 12
            0x00, 0x01,  // TYPE: A
            0x00, 0x01,  // CLASS: IN
            0x00, 0x00, 0x00, 0x1E,  // TTL: 30s
            0x00, 0x04,  // RDLENGTH: 4
            ip[0], ip[1], ip[2], ip[3],
        ]
        return response
    }

    private func buildNodataResponse(packet: [UInt8], questionEnd: Int) -> [UInt8] {
        baseResponse(packet: packet, questionEnd: questionEnd, flags: 0x8400)
    }

    // Non-authoritative NXDOMAIN (no AA bit) so clients retry rather than cache permanently.
    private func buildNxdomainResponse(packet: [UInt8], questionEnd: Int) -> [UInt8] {
        baseResponse(packet: packet, questionEnd: questionEnd, flags: 0x8003)  // QR=1, RD, RCODE=3
    }

    private func forwardToUpstream(_ packet: [UInt8]) -> [UInt8]? {
        let sockfd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard sockfd >= 0 else { return nil }
        defer { Darwin.close(sockfd) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(sockfd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var upstream = sockaddr_in()
        upstream.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        upstream.sin_family = sa_family_t(AF_INET)
        upstream.sin_port = UInt16(53).bigEndian
        inet_pton(AF_INET, "1.1.1.1", &upstream.sin_addr)

        let connected = withUnsafePointer(to: &upstream) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(sockfd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        let sent = packet.withUnsafeBytes { send(sockfd, $0.baseAddress!, packet.count, 0) }
        guard sent == packet.count else { return nil }

        var buf = [UInt8](repeating: 0, count: 512)
        let received = recv(sockfd, &buf, buf.count, 0)
        guard received > 0 else { return nil }
        return Array(buf[0..<received])
    }

    static func normalize(_ hostname: String) -> String {
        var s = hostname.lowercased()
        while s.hasSuffix(".") { s = String(s.dropLast()) }
        return s
    }

    private static func parseIPv4(_ ip: String) -> [UInt8]? {
        let bare = String(ip.split(separator: "/").first ?? ip[...])
        var addr = in_addr()
        guard inet_pton(AF_INET, bare, &addr) == 1 else { return nil }
        return withUnsafeBytes(of: addr.s_addr) { Array($0) }
    }

    /// Parses `ip` (optionally a CIDR like "192.168.1.5/24") into its 4-byte address and,
    /// if a valid prefix length was given, the (network address, prefix length) subnet it
    /// belongs to. A bare address or an unparsable prefix yields `subnet == nil` — the
    /// address is still registered, just without network scoping.
    private static func parseIPv4WithSubnet(_ ip: String) -> (address: [UInt8], subnet: (network: [UInt8], prefixLength: UInt8)?)? {
        let parts = ip.split(separator: "/", maxSplits: 1)
        guard let addr = parseIPv4(String(parts[0])) else { return nil }
        guard parts.count == 2, let prefixLength = UInt8(parts[1]), prefixLength <= 32 else {
            return (addr, nil)
        }
        return (addr, (network: networkAddress(addr, prefixLength: prefixLength), prefixLength: prefixLength))
    }

    /// Masks `ip` down to its network address for the given prefix length (0...32).
    private static func networkAddress(_ ip: [UInt8], prefixLength: UInt8) -> [UInt8] {
        var remaining = Int(prefixLength)
        var result = [UInt8](repeating: 0, count: 4)
        for i in 0..<4 {
            if remaining >= 8 {
                result[i] = ip[i]
            } else if remaining > 0 {
                let mask = UInt8(0xFF - (0xFF >> remaining))
                result[i] = ip[i] & mask
            }
            remaining -= 8
        }
        return result
    }

    /// True if two optional subnets refer to the same registration slot — both nil (the
    /// "unscoped" slot), or both non-nil with equal network address and prefix length.
    private static func sameSubnet(_ a: (network: [UInt8], prefixLength: UInt8)?, _ b: (network: [UInt8], prefixLength: UInt8)?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let a?, let b?): return a.network == b.network && a.prefixLength == b.prefixLength
        default: return false
        }
    }
}
