import SwiftUI

/// Per-view mutable animation state. A reference type so the Canvas draw closure
/// can update it each frame without tripping SwiftUI's value-state invalidation
/// (the redraw cadence comes from the enclosing TimelineView, not from this).
final class RibbonAnimator {
    var displayScale: Double = 0      // eased Y-axis upper bound (ms)
    var scaleBucket: Double = 0       // chosen "nice" bucket, with hysteresis
    var lastFrame: Date?              // for frame-delta easing
}

/// The flowing aurora latency ribbon. A fixed time window scrolls continuously
/// right-to-left: every sample is positioned by its real age (`now − date`), so
/// the whole ribbon glides smoothly and old data scrolls off the left edge. One
/// translucent gradient band per target, with a glowing stroke; lost samples
/// break the ribbon. One graph per network connection; spans when a bandwidth
/// test was saturating the link are shaded so latency-under-load stands out.
struct AuroraGraphView: View {
    @ObservedObject var connection: NetworkConnection
    @State private var anim = RibbonAnimator()

    /// How many seconds of history fill the width.
    private let window: TimeInterval = 90

    var body: some View {
        // 60 Hz clock independent of the 1 Hz data, so motion is driven by real
        // elapsed time and the ribbon scrolls continuously between samples.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { timeline in
            Canvas { context, size in
                draw(in: &context, size: size, now: timeline.date)
            }
        }
    }

    /// Target upper bound (ms) of the Y axis — auto-scales to the data with a
    /// floor. Uses hysteresis (grow immediately, shrink only with margin) so the
    /// scale can't flip-flop between buckets when latency hovers on a threshold.
    private func targetScale() -> Double {
        let observed = connection.visibleHealths.compactMap { $0.maxRTT }.max() ?? 0
        let needed = observed * 1.15
        let nice = [50.0, 100, 150, 250, 400, 600, 1000]
        let fit = nice.first(where: { $0 >= needed }) ?? max(1000, needed)

        var bucket = anim.scaleBucket
        if bucket <= 0 { bucket = fit }
        if fit > bucket { bucket = fit }                 // grow at once
        else if needed < bucket * 0.6 { bucket = fit }   // shrink only well clear
        anim.scaleBucket = bucket
        return bucket
    }

    private func draw(in context: inout GraphicsContext, size: CGSize, now: Date) {
        let dt = anim.lastFrame.map { max(0, min(0.1, now.timeIntervalSince($0))) } ?? 0
        anim.lastFrame = now

        let target = targetScale()
        if anim.displayScale <= 0 { anim.displayScale = target }
        anim.displayScale += (target - anim.displayScale) * min(1, dt * 6)
        let scale = anim.displayScale

        drawTimeGuides(in: &context, size: size, now: now)
        drawSpeedWindows(in: &context, size: size, now: now)
        drawGrid(in: &context, size: size, scale: scale)

        // Draw worst→best so calmer (greener) ribbons sit on top.
        let ordered = connection.visibleHealths.sorted { $0.state > $1.state }
        for health in ordered {
            drawRibbon(for: health, in: &context, size: size, scale: scale, now: now)
        }
    }

    /// Maps a sample's age to an X position; newest at the right edge.
    private func x(forAge age: TimeInterval, width: CGFloat) -> CGFloat {
        width - CGFloat(age / window) * width
    }

    private func drawRibbon(for health: TargetHealth, in context: inout GraphicsContext,
                            size: CGSize, scale: Double, now: Date) {
        let samples = health.samples
        guard samples.count >= 2 else { return }

        func point(_ s: PingSample, _ rtt: Double) -> CGPoint {
            let age = now.timeIntervalSince(s.date)
            let y = size.height - CGFloat(min(rtt, scale) / scale) * size.height
            return CGPoint(x: x(forAge: age, width: size.width), y: y)
        }

        let tint = health.state.tint

        // Contiguous runs separated by losses, so gaps show as breaks. Only keep
        // points within (a little past) the visible window.
        var runs: [[CGPoint]] = []
        var current: [CGPoint] = []
        for s in samples {
            let age = now.timeIntervalSince(s.date)
            guard age <= window * 1.05 else { continue }      // off the left edge
            if let rtt = s.rtt {
                current.append(point(s, rtt))
            } else if !current.isEmpty {
                runs.append(current); current = []
            }
        }
        if !current.isEmpty {
            // Pin the leading edge to the right edge (hold the latest value) so the
            // trace scrolls smoothly leftward instead of sawtoothing as each new
            // sample pops in at x = width.
            if let head = current.last, head.x < size.width {
                current.append(CGPoint(x: size.width, y: head.y))
            }
            runs.append(current)
        }

        for run in runs where run.count >= 2 {
            let line = smoothPath(run)

            var area = line
            area.addLine(to: CGPoint(x: run.last!.x, y: size.height))
            area.addLine(to: CGPoint(x: run.first!.x, y: size.height))
            area.closeSubpath()

            let fill = Gradient(colors: [tint.opacity(0.55), tint.opacity(0.06)])
            context.fill(
                area,
                with: .linearGradient(fill,
                                      startPoint: CGPoint(x: 0, y: 0),
                                      endPoint: CGPoint(x: 0, y: size.height))
            )

            var glow = context
            glow.addFilter(.blur(radius: 6))
            glow.stroke(line, with: .color(tint.opacity(0.7)), lineWidth: 4)

            context.stroke(line, with: .color(tint), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round))

            if let head = run.last {
                let dot = Path(ellipseIn: CGRect(x: head.x - 3, y: head.y - 3, width: 6, height: 6))
                context.fill(dot, with: .color(tint))
                var halo = context
                halo.addFilter(.blur(radius: 4))
                halo.fill(dot, with: .color(tint.opacity(0.8)))
            }
        }
    }

    /// Faint vertical lines + labels marking elapsed time, scrolling left with the
    /// data so the time axis is legible and the motion is obvious.
    private func drawTimeGuides(in context: inout GraphicsContext, size: CGSize, now: Date) {
        let spacing: TimeInterval = 30
        // Anchor to wall time so the lines drift continuously and recycle.
        let phase = now.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: spacing)
        var age = phase
        while age <= window {
            let px = x(forAge: age, width: size.width)
            var path = Path()
            path.move(to: CGPoint(x: px, y: 0))
            path.addLine(to: CGPoint(x: px, y: size.height))
            context.stroke(path, with: .color(.white.opacity(0.05)), lineWidth: 1)

            let secs = Int(age.rounded())
            if secs > 0, px > 90 {        // keep clear of the ms labels at the left
                let label = Text("-\(secs)s")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.32))
                context.draw(label, at: CGPoint(x: px, y: size.height - 9), anchor: .center)
            }
            age += spacing
        }
    }

    /// Shades each recent bandwidth-test span (↓ blue, ↑ violet) with a label.
    private func drawSpeedWindows(in context: inout GraphicsContext, size: CGSize, now: Date) {
        for w in connection.speedWindows {
            let x0 = max(0, x(forAge: now.timeIntervalSince(w.start), width: size.width))
            let x1 = min(size.width, x(forAge: now.timeIntervalSince(w.end ?? now), width: size.width))
            guard x1 > x0 else { continue }
            let rect = CGRect(x: x0, y: 0, width: max(2, x1 - x0), height: size.height)
            context.fill(Path(rect), with: .linearGradient(
                Gradient(colors: [w.phase.tint.opacity(0.20), w.phase.tint.opacity(0.04)]),
                startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
            var edge = Path()
            edge.move(to: CGPoint(x: x0, y: 0)); edge.addLine(to: CGPoint(x: x0, y: size.height))
            context.stroke(edge, with: .color(w.phase.tint.opacity(0.35)), lineWidth: 1)
            guard x1 - x0 >= 14 else { continue }       // too narrow to label
            let label = Text(w.phase.arrow)
                .font(.system(size: 12, weight: .bold, design: .rounded))
                .foregroundColor(w.phase.tint.opacity(0.9))
            context.draw(label, at: CGPoint(x: x0 + 4, y: 12), anchor: .leading)
        }
    }

    private func drawGrid(in context: inout GraphicsContext, size: CGSize, scale: Double) {
        // Fewer gridlines on a short (stacked) graph so labels don't collide.
        let lines = size.height < 220 ? 2 : 4
        for i in 0...lines {
            let frac = Double(i) / Double(lines)
            let y = size.height - CGFloat(frac) * size.height
            var path = Path()
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
            context.stroke(path, with: .color(.white.opacity(0.06)), lineWidth: 1)

            let ms = Int((scale * frac).rounded())
            let text = Text("\(ms) ms")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundColor(.white.opacity(0.55))
            let ly = min(size.height - 10, max(11, y - 11))
            context.draw(text, at: CGPoint(x: 8, y: ly), anchor: .leading)
        }
    }

    /// Catmull-Rom smoothing through the given points for the flowing look.
    private func smoothPath(_ pts: [CGPoint]) -> Path {
        var path = Path()
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count < 3 {
            for p in pts.dropFirst() { path.addLine(to: p) }
            return path
        }
        for i in 0..<(pts.count - 1) {
            let p0 = pts[max(i - 1, 0)]
            let p1 = pts[i]
            let p2 = pts[i + 1]
            let p3 = pts[min(i + 2, pts.count - 1)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0, y: p1.y + (p2.y - p0.y) / 6.0)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0, y: p2.y - (p3.y - p1.y) / 6.0)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        return path
    }
}
