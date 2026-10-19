import SwiftUI

/// Latest download/upload throughput for one connection, a mini history of
/// recent tests, and live progress while a test is running.
struct BandwidthCard: View {
    @ObservedObject var connection: NetworkConnection
    @ObservedObject var viewModel: NetHealthViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(SpeedPhase.download.tint)
                Text("Bandwidth")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundColor(.white.opacity(0.9))
                Spacer()
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(statusText(now: context.date))
                        .font(.system(size: 9, design: .rounded))
                        .foregroundColor(.white.opacity(0.4))
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                rate(.download, live: connection.testPhase == .download ? connection.liveMbps : nil,
                     value: connection.latestResult?.downMbps, fallback: connection.lastGoodDown)
                rate(.upload, live: connection.testPhase == .upload ? connection.liveMbps : nil,
                     value: connection.latestResult?.upMbps, fallback: connection.lastGoodUp)
                Text("Mbps")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
            }

            Sparkline(results: connection.results)
                .frame(height: 22)

            if let latest = connection.latestResult {
                HStack(spacing: 6) {
                    Text("tested \(Self.stamp(latest.date))")
                        .font(.system(size: 9, design: .rounded).monospacedDigit())
                        .foregroundColor(.white.opacity(0.4))
                    if let error = latest.error {
                        Text(error)
                            .font(.system(size: 9, design: .rounded))
                            .foregroundColor(HealthState.poor.tint)
                    }
                }
                .lineLimit(1)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.white.opacity(0.05))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke((connection.testPhase?.tint ?? .white).opacity(connection.testPhase == nil ? 0.08 : 0.5),
                                lineWidth: 1)
                )
        )
        .animation(.easeInOut(duration: 0.3), value: connection.testPhase)
    }

    /// `fallback` is the last good reading, shown dimmed when the latest test
    /// in this direction failed (e.g. rate-limited).
    private func rate(_ phase: SpeedPhase, live: Double?, value: Double?, fallback: Double?) -> some View {
        let shown = live ?? value ?? fallback
        let isLive = live != nil || (value == nil && fallback != nil)
        return HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(phase.arrow)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(phase.tint.opacity(0.8))
            Text(shown.map(Self.format) ?? "—")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundColor(isLive ? phase.tint.opacity(0.75) : phase.tint)
                .contentTransition(.numericText())
        }
    }

    static func format(_ mbps: Double) -> String {
        mbps >= 1000 ? String(format: "%.2fk", mbps / 1000)
            : String(format: mbps < 10 ? "%.1f" : "%.0f", mbps)
    }

    private func statusText(now: Date) -> String {
        if let phase = connection.testPhase { return "testing \(phase.arrow)…" }
        if viewModel.speedTestRunning { return "queued" }
        if let until = connection.rateLimitedUntil, until > now {
            return "rate-limited · retry \(Self.ago(until.timeIntervalSince(now)))"
        }
        var parts: [String] = []
        if let last = connection.latestResult {
            parts.append(Self.ago(now.timeIntervalSince(last.date)) + " ago")
        }
        if let next = viewModel.nextSpeedTest {
            let s = max(0, next.timeIntervalSince(now))
            parts.append("next \(Self.ago(s))")
        }
        return parts.isEmpty ? "manual" : parts.joined(separator: " · ")
    }

    /// Wall-clock time of a test: `14:32:07`, with the date once it's not today.
    private static func stamp(_ date: Date) -> String {
        let time = date.formatted(.dateTime.hour(.twoDigits(amPM: .omitted)).minute(.twoDigits).second(.twoDigits))
        return Calendar.current.isDateInToday(date)
            ? time : date.formatted(.dateTime.day().month(.abbreviated)) + " " + time
    }

    private static func ago(_ s: TimeInterval) -> String {
        s < 60 ? "\(Int(s))s" : s < 3600 ? "\(Int(s / 60))m" : "\(Int(s / 3600))h"
    }
}

/// Tiny two-line history of recent results (↓ blue, ↑ violet), each line
/// scaled to its own maximum so both are legible despite very different rates.
private struct Sparkline: View {
    let results: [SpeedResult]

    var body: some View {
        Canvas { context, size in
            let recent = Array(results.suffix(30))
            guard recent.count >= 2 else {
                let hint = Text(recent.isEmpty ? "no tests yet" : "history builds per test")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundColor(.white.opacity(0.25))
                context.draw(hint, at: CGPoint(x: 0, y: size.height / 2), anchor: .leading)
                return
            }
            for (phase, values) in [(SpeedPhase.download, recent.map(\.downMbps)),
                                    (.upload, recent.map(\.upMbps))] {
                let peak = values.compactMap { $0 }.max() ?? 0
                guard peak > 0 else { continue }
                var path = Path()
                var started = false
                for (i, v) in values.enumerated() {
                    guard let v else { started = false; continue }
                    let p = CGPoint(x: size.width * CGFloat(i) / CGFloat(recent.count - 1),
                                    y: size.height - 2 - (size.height - 4) * CGFloat(v / peak))
                    if started { path.addLine(to: p) } else { path.move(to: p); started = true }
                }
                context.stroke(path, with: .color(phase.tint.opacity(0.75)),
                               style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
            }
        }
    }
}
