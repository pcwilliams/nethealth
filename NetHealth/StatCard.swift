import SwiftUI

/// A single target's live readout: name, current ms (big), health dot, and the
/// supporting min/avg/max · jitter · loss line.
struct StatCard: View {
    @ObservedObject var health: TargetHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle()
                    .fill(health.state.tint)
                    .frame(width: 8, height: 8)
                    .shadow(color: health.state.tint.opacity(0.8), radius: 4)
                Text(health.target.name)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                if let method = health.method {
                    methodBadge(method)
                }
                Spacer()
                Text(health.target.host)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(.white.opacity(0.35))
            }

            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(currentText)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundColor(health.state.tint)
                    .contentTransition(.numericText())
                Text("ms")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
            }

            HStack(spacing: 10) {
                metric("min", health.minRTT)
                metric("avg", health.avgRTT)
                metric("max", health.maxRTT)
            }
            HStack(spacing: 10) {
                metric("jitter", health.jitter)
                lossMetric
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(health.state.tint.opacity(0.25), lineWidth: 1)
                )
        )
    }

    /// Tiny pill showing whether the live reading came from ICMP echo or the TCP
    /// connect-time fallback. ICMP is highlighted (it means real ping is working);
    /// TCP is muted (the usual sandboxed case).
    private func methodBadge(_ method: ProbeMethod) -> some View {
        let isICMP = method == .icmp
        return Text(method.rawValue)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .tracking(0.3)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(
                Capsule().fill((isICMP ? HealthState.excellent.tint : Color.white).opacity(isICMP ? 0.18 : 0.08))
            )
            .foregroundColor(isICMP ? HealthState.excellent.tint : .white.opacity(0.55))
    }

    private var currentText: String {
        guard let c = health.current else { return "—" }
        return String(format: c < 10 ? "%.1f" : "%.0f", c)
    }

    private func metric(_ label: String, _ value: Double?) -> some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 9, design: .rounded))
                .foregroundColor(.white.opacity(0.35))
            Text(value.map { String(format: $0 < 10 ? "%.1f" : "%.0f", $0) } ?? "—")
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.7))
        }
    }

    private var lossMetric: some View {
        HStack(spacing: 3) {
            Text("loss")
                .font(.system(size: 9, design: .rounded))
                .foregroundColor(.white.opacity(0.35))
            Text(String(format: "%.0f%%", health.loss * 100))
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundColor(health.loss > 0 ? HealthState.bad.tint : .white.opacity(0.7))
        }
    }
}
