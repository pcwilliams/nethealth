import SwiftUI

/// Which probe actually produced a reading. Surfaced in the UI so you can tell
/// at a glance whether real ICMP echo is working or we've fallen back to TCP
/// connect timing (the usual case under the macOS App Sandbox).
enum ProbeMethod: String, Sendable {
    case icmp = "ICMP"
    case tcp  = "TCP"
}

/// A single latency measurement for one target.
struct PingSample: Identifiable {
    let id = UUID()
    /// Wall-clock time this sample was taken. The graph positions each point by
    /// its real age (`now − date`), so it scrolls smoothly through time.
    let date: Date
    /// Round-trip time in milliseconds, or `nil` if the ping timed out / was lost.
    let rtt: Double?
    /// How this reading was obtained (ICMP echo vs TCP connect); `nil` on loss.
    let method: ProbeMethod?

    var isLoss: Bool { rtt == nil }
}

/// Coarse health buckets that drive colour across the whole UI.
enum HealthState: Int, Comparable {
    case excellent = 0   // calm green
    case good            // teal
    case fair            // amber
    case poor            // orange
    case bad             // red
    case offline         // grey — target unreachable

    static func < (lhs: HealthState, rhs: HealthState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Classify a latency (ms) into a bucket. `nil` latency means offline.
    static func from(rtt: Double?, loss: Double) -> HealthState {
        guard let rtt else { return .offline }
        if loss >= 0.5 { return .bad }
        switch rtt {
        case ..<20:   return .excellent
        case ..<40:   return .good
        case ..<80:   return .fair
        case ..<150:  return .poor
        default:      return .bad
        }
    }

    var tint: Color {
        switch self {
        case .excellent: return Color(red: 0.30, green: 0.95, blue: 0.70)
        case .good:      return Color(red: 0.35, green: 0.85, blue: 0.95)
        case .fair:      return Color(red: 0.98, green: 0.82, blue: 0.35)
        case .poor:      return Color(red: 0.99, green: 0.58, blue: 0.30)
        case .bad:       return Color(red: 0.98, green: 0.36, blue: 0.42)
        case .offline:   return Color(white: 0.55)
        }
    }

    var label: String {
        switch self {
        case .excellent: return "Excellent"
        case .good:      return "Good"
        case .fair:      return "Fair"
        case .poor:      return "Poor"
        case .bad:       return "Bad"
        case .offline:   return "Offline"
        }
    }
}

/// One thing we monitor (router, dish, public anchor).
struct PingTarget: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let host: String
    /// Candidate TCP ports for the connect-time probe, tried in order.
    let ports: [UInt16]
    /// Accent colour for this target's ribbon (modulated by health at render time).
    let baseHue: Double
    /// Optional targets (e.g. the Starlink dish) only appear once they've been
    /// reachable at least once. On a network where they don't exist — say the
    /// dish on a plain fiber connection — they're omitted from the cards, the
    /// graph, and the overall-health tint instead of showing a dead red ribbon.
    var optional: Bool = false

    static func == (lhs: PingTarget, rhs: PingTarget) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

/// Rolling history + derived statistics for a single target.
@MainActor
final class TargetHealth: ObservableObject, Identifiable {
    let target: PingTarget
    nonisolated var id: UUID { target.id }

    /// Newest-last ring buffer of samples.
    @Published private(set) var samples: [PingSample] = []

    /// Most recent successful RTT, ms.
    @Published private(set) var current: Double?
    @Published private(set) var minRTT: Double?
    @Published private(set) var avgRTT: Double?
    @Published private(set) var maxRTT: Double?
    /// Mean absolute consecutive difference (jitter), ms.
    @Published private(set) var jitter: Double?
    /// Fraction of recent pings lost, 0...1.
    @Published private(set) var loss: Double = 0
    @Published private(set) var state: HealthState = .offline
    /// Method behind the most recent successful reading (ICMP vs TCP fallback).
    @Published private(set) var method: ProbeMethod?
    /// Latches `true` the first time this target ever answers. Used to decide
    /// whether an `optional` target exists on the current network.
    @Published private(set) var everReachable = false

    /// Whether this target should be shown at all. Required targets always show;
    /// an optional one (the dish) is only present once it has answered at least
    /// once, so on a non-Starlink network it's omitted entirely rather than
    /// rendered as a permanently-offline card and ribbon.
    var isPresent: Bool { !target.optional || everReachable }

    /// How many samples we keep (≈ visible window at 1 Hz). Exposed so the graph
    /// can map samples to a fixed horizontal step and scroll smoothly.
    let capacity: Int

    init(target: PingTarget, capacity: Int = 240) {
        self.target = target
        self.capacity = capacity
    }

    func append(_ sample: PingSample) {
        samples.append(sample)
        if sample.rtt != nil { everReachable = true }
        if samples.count > capacity {
            samples.removeFirst(samples.count - capacity)
        }
        recompute()
    }

    private func recompute() {
        let rtts = samples.compactMap { $0.rtt }
        current = samples.last?.rtt
        method = samples.last(where: { $0.rtt != nil })?.method
        minRTT = rtts.min()
        maxRTT = rtts.max()
        avgRTT = rtts.isEmpty ? nil : rtts.reduce(0, +) / Double(rtts.count)

        if rtts.count >= 2 {
            var diffs = 0.0
            for i in 1..<rtts.count { diffs += abs(rtts[i] - rtts[i - 1]) }
            jitter = diffs / Double(rtts.count - 1)
        } else {
            jitter = nil
        }

        // Loss over the recent window only.
        let window = samples.suffix(60)
        let lost = window.filter { $0.isLoss }.count
        loss = window.isEmpty ? 0 : Double(lost) / Double(window.count)

        state = HealthState.from(rtt: current, loss: loss)
    }
}
