import Foundation
import Darwin

/// Fallback latency probe: measures the time to complete a TCP connect to a
/// host:port. Used when ICMP is unavailable (some networks/firewalls drop it,
/// or the datagram-ICMP socket can't be created). A connect time is a fine proxy
/// for "is this host reachable and how snappy is it".
enum TCPPinger {

    enum TCPError: Error { case badAddress, unreachable, timeout }

    /// - Parameter interfaceIndex: when set, the socket is pinned to that
    ///   interface (`IP_BOUND_IF`) so the probe leaves through it — and its
    ///   scoped default route — rather than whichever link macOS prefers. That's
    ///   what lets NetHealth measure Wi-Fi and Ethernet side by side.
    static func ping(host: String, port: UInt16, timeout: TimeInterval = 1.0,
                     interfaceIndex: UInt32? = nil) async throws -> Double {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                do {
                    let rtt = try blockingConnect(host: host, port: port, timeout: timeout,
                                                  interfaceIndex: interfaceIndex)
                    continuation.resume(returning: rtt)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    private static func blockingConnect(host: String, port: UInt16, timeout: TimeInterval,
                                        interfaceIndex: UInt32?) throws -> Double {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &addr.sin_addr) != 1 {
            guard let resolved = resolveIPv4(host) else { throw TCPError.badAddress }
            addr.sin_addr = resolved
        }

        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw TCPError.unreachable }
        defer { close(fd) }
        if let interfaceIndex { try bind(fd, toInterface: interfaceIndex) }

        // Non-blocking connect + select so we can enforce a timeout.
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let start = DispatchTime.now()
        let rc = withUnsafePointer(to: &addr) { aptr in
            aptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                connect(fd, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if rc == 0 {
            return elapsedMS(since: start)            // connected immediately
        }
        // A RST (connection refused) is a *complete* round trip from a host that
        // is up — it just has nothing listening on this port. That's a perfectly
        // good latency sample, and it's what lets a bare gateway with no open web
        // port (common on fiber routers) still read as a healthy local hop.
        if errno == ECONNREFUSED {
            return elapsedMS(since: start)
        }
        guard errno == EINPROGRESS else { throw TCPError.unreachable }

        var writeSet = fd_set()
        fdZero(&writeSet); fdSet(fd, &writeSet)
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - floor(timeout)) * 1_000_000))
        let sel = select(fd + 1, nil, &writeSet, nil, &tv)
        guard sel > 0 else { throw TCPError.timeout }

        // Confirm the connect actually succeeded.
        var soError: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &soError, &len)
        // 0 = connected; ECONNREFUSED = host answered with a RST (up, port closed).
        // Anything else (EHOSTUNREACH, ETIMEDOUT, …) means genuinely unreachable —
        // which is exactly how an absent dish stays absent.
        guard soError == 0 || soError == ECONNREFUSED else { throw TCPError.unreachable }
        return elapsedMS(since: start)
    }

    /// Pin a socket to one interface. Works under the App Sandbox.
    static func bind(_ fd: Int32, toInterface index: UInt32) throws {
        var idx = Int32(index)
        guard setsockopt(fd, IPPROTO_IP, IP_BOUND_IF, &idx, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw TCPError.unreachable
        }
    }

    private static func elapsedMS(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000.0
    }

    private static func resolveIPv4(_ host: String) -> in_addr? {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(result) }
        return first.pointee.ai_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
    }
}

// MARK: - fd_set helpers (Swift can't use the C FD_* macros directly)

private func fdZero(_ set: inout fd_set) {
    set.fds_bits = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

private func fdSet(_ fd: Int32, _ set: inout fd_set) {
    let intOffset = Int(fd) / 32
    let bitOffset = Int(fd) % 32
    let mask: Int32 = 1 << bitOffset
    withUnsafeMutablePointer(to: &set.fds_bits) { ptr in
        ptr.withMemoryRebound(to: Int32.self, capacity: 32) { bits in
            bits[intOffset] |= mask
        }
    }
}
