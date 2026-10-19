import Foundation

/// Measures latency to a host, preferring ICMP echo but transparently falling
/// back to a TCP connect-time probe.
///
/// On the macOS **App Sandbox**, unprivileged ICMP datagram sockets can be
/// created and written but the kernel denies the inbound echo reply with EPERM,
/// so ICMP never completes. `ICMPPinger` surfaces that as `.socketUnavailable`;
/// the first time we see it we disable ICMP for good and use TCP connect timing
/// (one round trip — a close proxy for ICMP RTT) for every subsequent probe.
actor PingService {

    /// A successful reading: the round-trip time and which probe produced it.
    struct Reading: Sendable {
        let rtt: Double
        let method: ProbeMethod
    }

    /// Set false permanently once ICMP proves unusable (sandbox / no permission).
    private var icmpUsable = true

    /// Measure latency to `host`, trying each of `ports` in order for the TCP path.
    /// `interfaceIndex` pins the probe to one network interface (see `TCPPinger`).
    /// - Returns: a `Reading` (RTT + method), or `nil` if the host was unreachable.
    func measure(host: String, ports: [UInt16], timeout: TimeInterval = 1.0,
                 interfaceIndex: UInt32? = nil) async -> Reading? {
        if icmpUsable {
            do {
                let rtt = try await ICMPPinger.ping(host: host, timeout: timeout, interfaceIndex: interfaceIndex)
                return Reading(rtt: rtt, method: .icmp)
            } catch ICMPPinger.PingError.socketUnavailable {
                icmpUsable = false          // sandbox/permission — never retry ICMP
            } catch {
                // Transient ICMP failure (timeout/loss) — fall through to TCP so a
                // network that simply drops ICMP still yields a reading.
            }
        }

        // TCP fallback: first port that connects wins; connection-refused is
        // effectively instant, so trying a few candidates is cheap.
        for port in ports {
            if let rtt = try? await TCPPinger.ping(host: host, port: port, timeout: timeout,
                                                    interfaceIndex: interfaceIndex) {
                return Reading(rtt: rtt, method: .tcp)
            }
        }
        return nil
    }
}
