import SwiftUI
import Network

/// A live network link the Mac can send traffic through — one per interface
/// that has its own IPv4 default route (e.g. Ethernet → Starlink and
/// Wi-Fi → fibre at the same time).
struct ConnectionInfo: Hashable, Sendable {
    enum Kind: Sendable { case wifi, ethernet, cellular, other }

    /// BSD interface name, e.g. `en0`. Stable identity for a connection.
    let interfaceName: String
    let interfaceIndex: UInt32
    let kind: Kind
    let gateway: String
    let localIP: String?
    /// `true` for the link carrying ordinary (unbound) traffic.
    let isPrimary: Bool
    /// The Network.framework handle, used to pin bandwidth tests to this link.
    let nwInterface: NWInterface?

    var displayName: String {
        switch kind {
        case .wifi:     return "Wi-Fi"
        case .ethernet: return "Ethernet"
        case .cellular: return "Cellular"
        case .other:    return interfaceName
        }
    }

    var symbol: String {
        switch kind {
        case .wifi:     return "wifi"
        case .ethernet: return "cable.connector.horizontal"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .other:    return "network"
        }
    }
}

/// Finds every connection by combining the kernel's per-interface default
/// routes (`Gateway.defaultRoutes()`) with Network.framework's interface types.
enum ConnectionDiscovery {

    /// Interfaces that carry a default route but aren't a physical link —
    /// VPN tunnels, AirDrop, bridges — are skipped.
    private static let ignoredPrefixes = ["utun", "ipsec", "ppp", "awdl", "llw", "bridge", "lo", "gif", "stf", "anpi"]

    static func discover(path: NWPath?) -> [ConnectionInfo] {
        let interfaces = path?.availableInterfaces ?? []
        return Gateway.defaultRoutes().compactMap { route in
            let name = route.interfaceName
            guard !ignoredPrefixes.contains(where: { name.hasPrefix($0) }) else { return nil }
            let nw = interfaces.first { $0.name == name }
            let kind: ConnectionInfo.Kind
            switch nw?.type {
            case .wifi?:          kind = .wifi
            case .wiredEthernet?: kind = .ethernet
            case .cellular?:      kind = .cellular
            case .other?, .loopback?: return nil          // tunnel / virtual
            default:              kind = name.hasPrefix("en") ? .ethernet : .other
            }
            return ConnectionInfo(interfaceName: name,
                                  interfaceIndex: route.interfaceIndex,
                                  kind: kind,
                                  gateway: route.gateway,
                                  localIP: Gateway.localIPv4(interface: name),
                                  isPrimary: route.isPrimary,
                                  nwInterface: nw)
        }
    }

    /// One-shot, blocking read of the current path — for the CLI modes, which
    /// run before any UI exists. Safe to call from the main thread: the
    /// monitor delivers on its own queue.
    static func currentPath(timeout: TimeInterval = 1.5) -> NWPath? {
        let monitor = NWPathMonitor()
        let sema = DispatchSemaphore(value: 0)
        let box = PathBox()
        monitor.pathUpdateHandler = { path in
            box.path = path
            sema.signal()
        }
        monitor.start(queue: DispatchQueue(label: "nethealth.path.oneshot"))
        _ = sema.wait(timeout: .now() + timeout)
        monitor.cancel()
        return box.path
    }

    private final class PathBox: @unchecked Sendable { var path: NWPath? }

    /// The targets probed over one connection: its own gateway, the Starlink
    /// dish (optional — only appears on the link it's actually behind), and a
    /// public anchor.
    static func targets(for info: ConnectionInfo) -> [PingTarget] {
        [
            PingTarget(name: "Router",     host: info.gateway,    ports: [80, 443, 9000], baseHue: 0.34),
            PingTarget(name: "Dish",       host: "192.168.100.1", ports: [80, 443],       baseHue: 0.52, optional: true),
            PingTarget(name: "Cloudflare", host: "1.1.1.1",       ports: [443, 80],       baseHue: 0.60),
        ]
    }
}

/// Which half of a bandwidth test is running.
enum SpeedPhase: String, Sendable {
    case download, upload

    var arrow: String { self == .download ? "↓" : "↑" }
    var tint: Color {
        self == .download ? Color(red: 0.45, green: 0.70, blue: 1.0) : Color(red: 0.78, green: 0.55, blue: 1.0)
    }
}

/// One completed bandwidth test on one connection.
struct SpeedResult: Identifiable, Sendable {
    let id = UUID()
    let date: Date
    let downMbps: Double?
    let upMbps: Double?
    let bytesUsed: Int64
    let error: String?
}

/// A span of time during which a test was saturating the link — shaded on the
/// latency graph so you can see how much latency rises under load.
struct SpeedWindow: Identifiable {
    let id = UUID()
    let phase: SpeedPhase
    let start: Date
    var end: Date?
}

/// Live state for one connection: its probe targets' health, plus bandwidth.
@MainActor
final class NetworkConnection: ObservableObject, Identifiable {
    @Published private(set) var info: ConnectionInfo
    nonisolated let id: String
    @Published private(set) var healths: [TargetHealth]
    @Published private(set) var overall: HealthState = .offline
    /// The local hop's own rate (Wi-Fi transmit rate / Ethernet link speed).
    @Published private(set) var link: LinkStatus?

    // Bandwidth
    @Published private(set) var testPhase: SpeedPhase?
    @Published private(set) var liveMbps: Double?
    @Published private(set) var latestResult: SpeedResult?
    @Published private(set) var results: [SpeedResult] = []
    @Published private(set) var speedWindows: [SpeedWindow] = []
    /// Set when Cloudflare answers HTTP 429: tests on this link are skipped
    /// until then. Backs off 5 → 10 → 20 → 30 min; a clean test resets it.
    @Published private(set) var rateLimitedUntil: Date?
    private var backoff: TimeInterval = 0

    init(info: ConnectionInfo) {
        self.info = info
        self.id = info.interfaceName
        self.healths = ConnectionDiscovery.targets(for: info).map { TargetHealth(target: $0) }
        self.link = LinkReader.read(interfaceName: info.interfaceName, kind: info.kind)
    }

    /// Required targets plus optional ones that have answered at least once.
    var visibleHealths: [TargetHealth] { healths.filter(\.isPresent) }

    /// The Starlink dish answers only over the link that's behind it.
    var isStarlink: Bool { healths.contains { $0.target.optional && $0.everReachable } }

    /// Refresh addressing/primary flag. A changed gateway means a different
    /// network on the same interface, so the history starts afresh.
    func update(_ newInfo: ConnectionInfo) {
        if newInfo.gateway != info.gateway {
            healths = ConnectionDiscovery.targets(for: newInfo).map { TargetHealth(target: $0) }
        }
        if newInfo != info {
            info = newInfo
            refreshLink()
        }
    }

    func refreshLink() {
        let status = LinkReader.read(interfaceName: info.interfaceName, kind: info.kind)
        if status != link { link = status }
    }

    /// The last download got within reach of the local link's own rate, so
    /// the link (not the ISP) is the likely bottleneck. Wi-Fi rarely delivers
    /// more than ~60–70 % of its PHY rate, hence the margin.
    var isLinkLimited: Bool {
        guard let rate = link?.rateMbps, let down = lastGoodDown else { return false }
        return down >= rate * 0.6
    }

    func recomputeOverall() {
        overall = visibleHealths.map(\.state).max() ?? .offline
    }

    func beginPhase(_ phase: SpeedPhase) {
        testPhase = phase
        liveMbps = nil
        speedWindows.append(SpeedWindow(phase: phase, start: Date()))
        // Only windows still on (or near) the graph are worth keeping.
        let cutoff = Date().addingTimeInterval(-300)
        speedWindows.removeAll { ($0.end ?? .distantFuture) < cutoff }
    }

    func updateLive(_ mbps: Double) {
        if testPhase != nil { liveMbps = mbps }   // ignore stragglers after the phase ends
    }

    func endPhase() {
        if let i = speedWindows.indices.last { speedWindows[i].end = Date() }
        testPhase = nil
        liveMbps = nil
    }

    var isRateLimited: Bool { rateLimitedUntil.map { Date() < $0 } ?? false }

    /// Most recent successful reading per direction, so a failed or
    /// rate-limited test still shows the last known throughput (dimmed).
    var lastGoodDown: Double? { results.last(where: { $0.downMbps != nil })?.downMbps }
    var lastGoodUp: Double? { results.last(where: { $0.upMbps != nil })?.upMbps }

    func record(_ result: SpeedResult) {
        if result.error?.contains("HTTP 429") == true {
            backoff = min(1800, max(300, backoff * 2))
            rateLimitedUntil = Date().addingTimeInterval(backoff)
        } else if result.error == nil {
            backoff = 0
            rateLimitedUntil = nil
        }
        latestResult = result
        results.append(result)
        if results.count > 60 { results.removeFirst(results.count - 60) }
    }
}
