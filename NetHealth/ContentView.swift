import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = NetHealthViewModel()

    var body: some View {
        ZStack {
            AmbientBackground(state: viewModel.overall)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                header
                if viewModel.connections.isEmpty {
                    Spacer()
                    Text("No network connections")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundColor(.white.opacity(0.5))
                    Spacer()
                } else {
                    // One stacked panel per live connection, primary first.
                    ForEach(viewModel.connections) { connection in
                        ConnectionPanel(connection: connection, viewModel: viewModel)
                            .transition(.opacity.combined(with: .move(edge: .bottom)))
                    }
                }
            }
            .animation(.easeInOut(duration: 0.4), value: viewModel.connections.map(\.id))
            .padding(18)
        }
        .frame(minWidth: 780, minHeight: max(420, CGFloat(viewModel.connections.count) * 300 + 60))
        .onAppear { viewModel.start() }
        .onDisappear { viewModel.stop() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(viewModel.overall.tint)
                .shadow(color: viewModel.overall.tint.opacity(0.7), radius: 6)
            Text("NetHealth")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            Spacer()
            speedControls
            HStack(spacing: 6) {
                Circle().fill(viewModel.overall.tint).frame(width: 9, height: 9)
                    .shadow(color: viewModel.overall.tint.opacity(0.8), radius: 4)
                Text(viewModel.overall.label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.8))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Capsule().fill(.white.opacity(0.06)))
        }
    }

    /// Bandwidth-test schedule, a "test now" button, and how much data the
    /// tests have used this session (they're not free on a metered link).
    private var speedControls: some View {
        HStack(spacing: 8) {
            if viewModel.sessionBytes > 0 {
                Text(ByteCountFormatter.string(fromByteCount: viewModel.sessionBytes, countStyle: .decimal) + " tested")
                    .font(.system(size: 10, design: .rounded))
                    .foregroundColor(.white.opacity(0.4))
            }
            Picker("", selection: $viewModel.speedInterval) {
                ForEach(SpeedTestInterval.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("How often to run the bandwidth test")
            Button {
                viewModel.runSpeedTestNow()
            } label: {
                Label("Test now", systemImage: viewModel.speedTestRunning ? "hourglass" : "bolt.fill")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .buttonStyle(.bordered)
            .disabled(viewModel.speedTestRunning)
        }
    }
}

/// Deep ambient gradient that slowly tints toward the overall health colour —
/// calm and dark when healthy, warmer/redder when the connection struggles.
private struct AmbientBackground: View {
    let state: HealthState

    var body: some View {
        let tint = state.tint
        LinearGradient(
            colors: [
                Color(red: 0.04, green: 0.05, blue: 0.09),
                Color(red: 0.06, green: 0.07, blue: 0.12).blended(with: tint, amount: 0.10),
                Color.black,
            ],
            startPoint: .top, endPoint: .bottom
        )
        .overlay(
            RadialGradient(
                colors: [tint.opacity(0.18), .clear],
                center: .top, startRadius: 0, endRadius: 500
            )
        )
        .animation(.easeInOut(duration: 1.2), value: state)
    }
}

private extension Color {
    /// Simple linear blend toward another colour (macOS NSColor RGB space).
    func blended(with other: Color, amount: Double) -> Color {
        let a = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let b = NSColor(other).usingColorSpace(.sRGB) ?? .black
        let t = max(0, min(1, amount))
        return Color(
            red:   Double(a.redComponent)   * (1 - t) + Double(b.redComponent)   * t,
            green: Double(a.greenComponent) * (1 - t) + Double(b.greenComponent) * t,
            blue:  Double(a.blueComponent)  * (1 - t) + Double(b.blueComponent)  * t
        )
    }
}

#Preview {
    ContentView()
        .frame(width: 900, height: 700)
}
