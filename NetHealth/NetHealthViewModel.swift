import SwiftUI
import Network

/// How often the automatic bandwidth test runs. Persisted in UserDefaults.
enum SpeedTestInterval: Int, CaseIterable, Identifiable {
    case off = 0, oneMinute = 60, fiveMinutes = 300, tenMinutes = 600, fifteenMinutes = 900, hourly = 3600

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .off:            return "Off"
        case .oneMinute:      return "Every minute"
        case .fiveMinutes:    return "Every 5 min"
        case .tenMinutes:     return "Every 10 min"
        case .fifteenMinutes: return "Every 15 min"
        case .hourly:         return "Hourly"
        }
    }
}

/// Drives the dashboard: discovers every live network connection, runs a ~1 Hz
/// ping loop over each (sockets pinned to that interface), and schedules
/// periodic bandwidth tests, one connection at a time.
@MainActor
final class NetHealthViewModel: ObservableObject {

    /// One entry per live link, primary first.
    @Published private(set) var connections: [NetworkConnection] = []

    /// Worst current state across all connections — drives the ambient
    /// background.
    @Published private(set) var overall: HealthState = .offline

    @Published var speedInterval: SpeedTestInterval {
        didSet {
            UserDefaults.standard.set(speedInterval.rawValue, forKey: Self.intervalKey)
            scheduleNextSpeedTest(after: 5)
        }
    }
    @Published private(set) var speedTestRunning = false
    @Published private(set) var nextSpeedTest: Date?
    /// Data consumed by bandwidth tests since launch.
    @Published private(set) var sessionBytes: Int64 = 0

    /// How often each target is pinged.
    let interval: TimeInterval = 1.0
    var speedConfig = SpeedTestConfig()

    private static let intervalKey = "speedTestInterval"
    private let service = PingService()
    private let monitor = NWPathMonitor()
    private var latestPath: NWPath?
    private var pingTask: Task<Void, Never>?
    private var speedTask: Task<Void, Never>?
    private var manualSpeedTest = false
    private var tick = 0

    init() {
        let saved = UserDefaults.standard.object(forKey: Self.intervalKey) as? Int
        speedInterval = saved.flatMap(SpeedTestInterval.init(rawValue:)) ?? .tenMinutes
        refreshConnections()
    }

    func start() {
        guard pingTask == nil else { return }
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in
                self?.latestPath = path
                self?.refreshConnections()
            }
        }
        monitor.start(queue: DispatchQueue(label: "nethealth.path"))
        pingTask = Task { [weak self] in await self?.runPingLoop() }
        scheduleNextSpeedTest(after: 5)
        speedTask = Task { [weak self] in await self?.runSpeedLoop() }
    }

    func stop() {
        pingTask?.cancel(); pingTask = nil
        speedTask?.cancel(); speedTask = nil
        monitor.cancel()
    }

    func runSpeedTestNow() {
        guard !speedTestRunning else { return }
        manualSpeedTest = true
    }

    // MARK: Connections

    /// Re-reads the routing table and reconciles `connections`: existing links
    /// keep their history, new ones appear, vanished ones are removed.
    private func refreshConnections() {
        let infos = ConnectionDiscovery.discover(path: latestPath)
        var next: [NetworkConnection] = []
        for info in infos {
            if let existing = connections.first(where: { $0.id == info.interfaceName }) {
                existing.update(info)
                next.append(existing)
            } else {
                next.append(NetworkConnection(info: info))
            }
        }
        if next.map(\.id) != connections.map(\.id) {
            connections = next
        }
    }

    // MARK: Ping loop

    private func runPingLoop() async {
        while !Task.isCancelled {
            let started = Date()
            tick += 1
            // The path monitor catches link changes; this also catches a
            // gateway change it didn't report.
            if tick % 10 == 0 { refreshConnections() }
            // Wi-Fi rate and signal drift; a few seconds is fresh enough.
            if tick % 5 == 1 { connections.forEach { $0.refreshLink() } }

            let stamp = Date()   // shared timestamp so all ribbons align in time
            let timeout = interval * 0.95
            let current = connections
            let probeTick = tick

            await withTaskGroup(of: (Int, Int, PingService.Reading?)?.self) { group in
                for (ci, connection) in current.enumerated() {
                    let index = connection.info.interfaceIndex
                    for (ti, health) in connection.healths.enumerated() {
                        guard Self.shouldProbe(health, tick: probeTick) else { continue }
                        let host = health.target.host
                        let ports = health.target.ports
                        group.addTask { [service] in
                            (ci, ti, await service.measure(host: host, ports: ports, timeout: timeout,
                                                           interfaceIndex: index))
                        }
                    }
                }
                for await result in group {
                    guard let (ci, ti, reading) = result else { continue }
                    let healths = current[ci].healths
                    guard ti < healths.count else { continue }   // rebuilt meanwhile
                    healths[ti].append(PingSample(date: stamp, rtt: reading?.rtt, method: reading?.method))
                }
            }

            current.forEach { $0.recomputeOverall() }
            overall = connections.map(\.overall).max() ?? .offline

            let remaining = interval - Date().timeIntervalSince(started)
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
        }
    }

    /// An optional target that has never answered (the dish on a link it isn't
    /// behind) is probed every second for the first 15 s, then only every 15 s,
    /// so we don't keep firing packets at an address that isn't there.
    static func shouldProbe(_ health: TargetHealth, tick: Int) -> Bool {
        guard health.target.optional, !health.everReachable else { return true }
        return health.samples.count < 15 || tick % 15 == 0
    }

    // MARK: Bandwidth tests

    private func scheduleNextSpeedTest(after delay: TimeInterval? = nil) {
        guard speedInterval != .off else { nextSpeedTest = nil; return }
        nextSpeedTest = Date().addingTimeInterval(delay ?? TimeInterval(speedInterval.rawValue))
    }

    private func runSpeedLoop() async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let due = nextSpeedTest.map { Date() >= $0 } ?? false
            guard manualSpeedTest || due else { continue }
            // Links (and their NWInterface handles, needed to pin the test)
            // arrive with the first path update; if they aren't here yet, try
            // again shortly rather than waiting a whole interval.
            if connections.isEmpty || latestPath == nil {
                if due { scheduleNextSpeedTest(after: 5) }
                continue
            }
            manualSpeedTest = false
            await runSpeedTests()
            scheduleNextSpeedTest()
        }
    }

    /// Tests each connection in turn — download then upload — so two links
    /// never compete for the Mac's CPU or a shared upstream.
    private func runSpeedTests() async {
        speedTestRunning = true
        defer { speedTestRunning = false }
        for connection in connections where !Task.isCancelled && !connection.isRateLimited {
            let iface = connection.info.nwInterface
            var mbps: [SpeedPhase: Double] = [:]
            var errors: [String] = []
            var bytes: Int64 = 0
            for phase in [SpeedPhase.download, .upload] {
                connection.beginPhase(phase)
                let m = await SpeedTester.measure(phase, interface: iface, config: speedConfig) { rate in
                    Task { @MainActor in connection.updateLive(rate) }
                }
                connection.endPhase()
                if let rate = m.mbps { mbps[phase] = rate }
                if let e = m.error { errors.append("\(phase.arrow) \(e)") }
                bytes += m.bytes
                sessionBytes += m.bytes
            }
            connection.record(SpeedResult(date: Date(), downMbps: mbps[.download], upMbps: mbps[.upload],
                                          bytesUsed: bytes, error: errors.first))
        }
    }
}
