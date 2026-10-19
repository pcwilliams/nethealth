import Foundation
import Darwin

/// Sends one ICMP echo and measures the round-trip time using an *unprivileged*
/// datagram socket (`SOCK_DGRAM` / `IPPROTO_ICMP`). This is the same approach as
/// Apple's SimplePing sample and needs no root and no special entitlement beyond
/// `com.apple.security.network.client` — the kernel handles the ICMP id/echo
/// matching for datagram ICMP sockets.
///
/// If the host blocks ICMP (or the socket can't be created in the sandbox), the
/// caller falls back to `TCPPinger`.
enum ICMPPinger {

    enum PingError: Error { case socketUnavailable, sendFailed, timeout, badAddress }

    /// Ping `host` (IPv4 dotted-quad or resolvable name) once.
    /// - Returns: round-trip time in milliseconds.
    static func ping(host: String, timeout: TimeInterval = 1.0,
                     interfaceIndex: UInt32? = nil) async throws -> Double {
        try await withCheckedThrowingContinuation { continuation in
            // Run the blocking socket work off the main actor.
            DispatchQueue.global(qos: .utility).async {
                do {
                    let rtt = try blockingPing(host: host, timeout: timeout, interfaceIndex: interfaceIndex)
                    continuation.resume(returning: rtt)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func blockingPing(host: String, timeout: TimeInterval,
                                     interfaceIndex: UInt32?) throws -> Double {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            // Not a dotted-quad — try DNS resolution for hostnames.
            guard let resolved = resolveIPv4(host) else { throw PingError.badAddress }
            addr.sin_addr = resolved
        }

        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { throw PingError.socketUnavailable }
        defer { close(fd) }
        if let interfaceIndex {
            var idx = Int32(interfaceIndex)
            setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<Int32>.size))
        }

        // Receive timeout so recvfrom doesn't block forever.
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let identifier = UInt16.random(in: 0...UInt16.max)
        let sequence: UInt16 = 1
        let packet = makeEchoRequest(identifier: identifier, sequence: sequence)

        let start = DispatchTime.now()
        let sent = packet.withUnsafeBytes { raw -> Int in
            withUnsafePointer(to: &addr) { aptr in
                aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        if sent < 0 && (errno == EPERM || errno == EACCES) { throw PingError.socketUnavailable }
        guard sent == packet.count else { throw PingError.sendFailed }

        // Read replies until we see our echo reply or time out.
        var buffer = [UInt8](repeating: 0, count: 1024)
        let deadline = start.uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        while DispatchTime.now().uptimeNanoseconds < deadline {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 {
                // The App Sandbox permits creating/sending on an ICMP datagram
                // socket but denies the inbound reply with EPERM — treat that as
                // "ICMP unusable" so the caller falls back to TCP for good.
                if errno == EPERM || errno == EACCES { throw PingError.socketUnavailable }
                throw PingError.timeout                      // SO_RCVTIMEO fired
            }
            if isMatchingEchoReply(buffer, count: n, sequence: sequence) {
                let elapsed = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
                return Double(elapsed) / 1_000_000.0
            }
            // Not ours (or kernel stripped header differently) — keep waiting.
        }
        throw PingError.timeout
    }

    // MARK: - ICMP packet helpers

    private static func makeEchoRequest(identifier: UInt16, sequence: UInt16) -> [UInt8] {
        // ICMP header: type(8)=echo, code=0, checksum, id, seq + 16 bytes payload.
        var pkt = [UInt8](repeating: 0, count: 8 + 16)
        pkt[0] = 8                                   // type: echo request
        pkt[1] = 0                                   // code
        pkt[2] = 0; pkt[3] = 0                        // checksum (filled below)
        pkt[4] = UInt8(identifier >> 8); pkt[5] = UInt8(identifier & 0xff)
        pkt[6] = UInt8(sequence >> 8);   pkt[7] = UInt8(sequence & 0xff)
        for i in 0..<16 { pkt[8 + i] = UInt8(0x61 + (i % 26)) }   // "abc…" payload
        let sum = checksum(pkt)
        pkt[2] = UInt8(sum >> 8); pkt[3] = UInt8(sum & 0xff)
        return pkt
    }

    private static func isMatchingEchoReply(_ buffer: [UInt8], count: Int, sequence: UInt16) -> Bool {
        guard count >= 8 else { return false }
        // With unprivileged SOCK_DGRAM ICMP the kernel owns the ICMP identifier —
        // it rewrites the id field on send and demuxes replies by socket — so we
        // must NOT match the id we wrote. Match the echo-reply type (0) and our
        // sequence number, which the kernel passes through untouched. The kernel
        // may or may not include the leading IP header, so check both offsets.
        for ipHeaderLen in [0, 20] {
            guard count >= ipHeaderLen + 8 else { continue }
            let type = buffer[ipHeaderLen]
            let seq = UInt16(buffer[ipHeaderLen + 6]) << 8 | UInt16(buffer[ipHeaderLen + 7])
            if type == 0 && seq == sequence { return true }
        }
        return false
    }

    private static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < data.count {
            sum += UInt32(data[i]) << 8 | UInt32(data[i + 1])
            i += 2
        }
        if i < data.count { sum += UInt32(data[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return UInt16(~sum & 0xffff)
    }

    private static func resolveIPv4(_ host: String) -> in_addr? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_DGRAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        return first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    }
}
