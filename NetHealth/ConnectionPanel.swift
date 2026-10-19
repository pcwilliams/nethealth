import SwiftUI

/// Everything for one network connection: a header naming the link, its own
/// aurora latency graph, and a row of stat cards plus the bandwidth card.
/// ContentView stacks one of these per connection.
struct ConnectionPanel: View {
    @ObservedObject var connection: NetworkConnection
    @ObservedObject var viewModel: NetHealthViewModel

    var body: some View {
        VStack(spacing: 10) {
            header
            AuroraGraphView(connection: connection)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .frame(minHeight: 110)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(.black.opacity(0.25))
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))

            HStack(spacing: 10) {
                // Fixed slots (Router · Dish · Cloudflare · Bandwidth) so cards
                // line up across stacked panels; an absent dish leaves a gap.
                ForEach(connection.healths) { health in
                    CardSlot(health: health)
                }
                BandwidthCard(connection: connection, viewModel: viewModel)
            }
            .fixedSize(horizontal: false, vertical: true)   // cards share the tallest height
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.025))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(connection.overall.tint.opacity(0.18), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.8), value: connection.overall)
    }

    private var header: some View {
        let info = connection.info
        return HStack(spacing: 8) {
            Image(systemName: info.symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(connection.overall.tint)
            Text(info.displayName)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundColor(.white)
            if connection.isStarlink {
                badge("STARLINK", tint: HealthState.good.tint)
            }
            if info.isPrimary {
                badge("PRIMARY", tint: .white)
            }
            Text([info.interfaceName, info.localIP, "gw \(info.gateway)"].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.white.opacity(0.4))
            if let link = connection.link {
                linkChip(link)
            }
            Spacer()
            Circle().fill(connection.overall.tint).frame(width: 7, height: 7)
                .shadow(color: connection.overall.tint.opacity(0.8), radius: 3)
            Text(connection.overall.label)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundColor(.white.opacity(0.75))
        }
        .padding(.horizontal, 4)
    }

    /// The local hop's own rate. Turns amber when it's probably holding the
    /// connection back: Wi-Fi on 2.4 GHz, or the last download got close to it.
    private func linkChip(_ link: LinkStatus) -> some View {
        let limited = connection.isLinkLimited
        let warn = limited || link.band == .ghz2_4
        var help = link.details
        if limited {
            help += "\nThe last download reached ≥60 % of this rate, so the local link is likely the bottleneck."
        }
        return HStack(spacing: 4) {
            Image(systemName: warn ? "exclamationmark.triangle.fill" : "link")
                .font(.system(size: 8, weight: .bold))
            Text(link.summary)
                .font(.system(size: 10, weight: .medium, design: .rounded).monospacedDigit())
        }
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(Capsule().fill((warn ? HealthState.fair.tint : .white).opacity(warn ? 0.15 : 0.06)))
        .foregroundColor(warn ? HealthState.fair.tint : .white.opacity(0.6))
        .help(help)
    }

    private func badge(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .bold, design: .rounded))
            .tracking(0.4)
            .padding(.horizontal, 5).padding(.vertical, 1.5)
            .background(Capsule().fill(tint.opacity(0.14)))
            .foregroundColor(tint.opacity(0.9))
    }
}

/// One fixed card position. Observes its own target so an optional one (the
/// dish) pops in the moment it first answers — the panel itself doesn't
/// republish when a target's `everReachable` flips.
private struct CardSlot: View {
    @ObservedObject var health: TargetHealth

    var body: some View {
        ZStack {
            if health.isPresent {
                StatCard(health: health)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.4), value: health.isPresent)
    }
}
