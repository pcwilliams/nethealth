import Foundation
import CoreWLAN

/// What the OS says about the local hop itself — the Wi-Fi radio's current
/// transmit rate / band / signal, or the Ethernet negotiated speed. No traffic
/// is sent; this is the ceiling the bandwidth test can't exceed.
struct LinkStatus: Equatable, Sendable {
    enum Band: Sendable { case ghz2_4, ghz5, ghz6 }

    /// Current PHY rate (Wi-Fi, varies with signal) or negotiated speed (Ethernet).
    var rateMbps: Double?
    // Wi-Fi only
    var band: Band?
    var channel: Int?
    var widthMHz: Int?
    var rssi: Int?
    var noise: Int?
    var phyMode: String?

    var isWiFi: Bool { band != nil || rssi != nil }

    var bandLabel: String? {
        switch band {
        case .ghz2_4?: return "2.4 GHz"
        case .ghz5?:   return "5 GHz"
        case .ghz6?:   return "6 GHz"
        case nil:      return nil
        }
    }

    /// Short header text: `137 Mbps · 2.4 GHz ch 11 · −66 dBm` or `1 Gb/s`.
    var summary: String {
        var parts = [rateMbps.map(Self.formatRate) ?? "link —"]
        if let bandLabel { parts.append(channel.map { "\(bandLabel) ch \($0)" } ?? bandLabel) }
        if let rssi { parts.append("\(rssi) dBm".replacingOccurrences(of: "-", with: "−")) }
        return parts.joined(separator: " · ")
    }

    /// Hover text with everything we know.
    var details: String {
        var lines: [String] = []
        if let rateMbps { lines.append((isWiFi ? "Transmit rate: " : "Link speed: ") + Self.formatRate(rateMbps)) }
        if let phyMode { lines.append("Mode: \(phyMode)") }
        if let bandLabel {
            lines.append("Band: \(bandLabel)" + (channel.map { ", channel \($0)" } ?? "")
                         + (widthMHz.map { ", \($0) MHz wide" } ?? ""))
        }
        if let rssi {
            lines.append("Signal: \(rssi) dBm" + (noise.map { " · noise \($0) dBm · SNR \(rssi - $0) dB" } ?? ""))
        }
        if band == .ghz2_4 {
            lines.append("On 2.4 GHz — joining the router's 5/6 GHz band is usually much faster.")
        }
        return lines.joined(separator: "\n")
    }

    static func formatRate(_ mbps: Double) -> String {
        mbps >= 1000 ? String(format: mbps.truncatingRemainder(dividingBy: 1000) == 0 ? "%.0f Gb/s" : "%.1f Gb/s", mbps / 1000)
            : String(format: "%.0f Mbps", mbps)
    }
}

/// Reads `LinkStatus` for an interface. Cheap (no I/O beyond the kernel /
/// CoreWLAN), and works under the App Sandbox — only the SSID would need
/// Location permission, and we don't ask for it.
enum LinkReader {

    static func read(interfaceName: String, kind: ConnectionInfo.Kind) -> LinkStatus? {
        if kind == .wifi, let wifi = CWWiFiClient.shared().interface(withName: interfaceName) {
            return wifiStatus(wifi)
        }
        return baudRate(interfaceName).map { LinkStatus(rateMbps: Double($0) / 1_000_000) }
    }

    private static func wifiStatus(_ wifi: CWInterface) -> LinkStatus? {
        // A powered-off or disassociated radio reports zeros.
        let rate = wifi.transmitRate()
        guard rate > 0 || wifi.rssiValue() != 0 else { return nil }
        var status = LinkStatus(rateMbps: rate > 0 ? rate : nil)
        if let ch = wifi.wlanChannel() {
            status.channel = ch.channelNumber
            switch ch.channelBand {
            case .band2GHz: status.band = .ghz2_4
            case .band5GHz: status.band = .ghz5
            case .band6GHz: status.band = .ghz6
            default:        break
            }
            switch ch.channelWidth {
            case .width20MHz:  status.widthMHz = 20
            case .width40MHz:  status.widthMHz = 40
            case .width80MHz:  status.widthMHz = 80
            case .width160MHz: status.widthMHz = 160
            default:           break
            }
        }
        let rssi = wifi.rssiValue()
        if rssi != 0 { status.rssi = rssi }
        let noise = wifi.noiseMeasurement()
        if noise != 0 { status.noise = noise }
        switch wifi.activePHYMode() {
        case .mode11a:  status.phyMode = "802.11a"
        case .mode11b:  status.phyMode = "802.11b"
        case .mode11g:  status.phyMode = "802.11g"
        case .mode11n:  status.phyMode = "802.11n (Wi-Fi 4)"
        case .mode11ac: status.phyMode = "802.11ac (Wi-Fi 5)"
        case .mode11ax: status.phyMode = "802.11ax (Wi-Fi 6)"
        default:        break
        }
        return status
    }

    /// Negotiated speed from the interface's `if_data` (e.g. 1 000 000 000 for
    /// 1000baseT). Meaningless for Wi-Fi, hence CoreWLAN above.
    private static func baudRate(_ name: String) -> UInt64? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }
        var cursor = head
        while let entry = cursor {
            defer { cursor = entry.pointee.ifa_next }
            guard let addr = entry.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  String(cString: entry.pointee.ifa_name) == name,
                  let data = entry.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) else { continue }
            let baud = UInt64(data.pointee.ifi_baudrate)
            return baud > 0 ? baud : nil
        }
        return nil
    }
}
