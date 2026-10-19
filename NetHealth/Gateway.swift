import Foundation
import Darwin

/// Discovers the LAN default gateway (the router) by reading the kernel routing
/// table via `sysctl(NET_RT_DUMP)` — the in-process equivalent of
/// `route -n get default`. Works under the macOS App Sandbox: this reads the
/// routing table, it doesn't open a network connection, so it needs no special
/// entitlement.
///
/// This lets NetHealth point its "Router" target at whatever gateway the machine
/// is actually behind (192.168.1.1 on a Starlink LAN, 192.168.0.1 / 10.0.0.1 /
/// etc. on other routers) instead of a hard-coded address.
enum Gateway {

    /// One default route: which interface it leaves through and the gateway it
    /// points at. On a Mac with several live links (say Ethernet → Starlink and
    /// Wi-Fi → fibre) the routing table holds one default route per interface:
    /// the *primary* one is unscoped, the others carry `RTF_IFSCOPE` and are only
    /// used by sockets bound to that interface (`IP_BOUND_IF`).
    struct DefaultRoute: Hashable, Sendable {
        let interfaceIndex: UInt32
        let interfaceName: String
        let gateway: String
        /// `true` for the unscoped default route — the one macOS actually uses
        /// for ordinary traffic.
        let isPrimary: Bool
    }

    /// `RTF_IFSCOPE` from `<net/route.h>` (not bridged into Swift).
    private static let rtfIfScope: Int32 = 0x1000000

    /// The IPv4 address of the current (primary) default gateway, e.g.
    /// `"192.168.1.1"`. Returns `nil` if there's no default route.
    static func defaultIPv4() -> String? {
        let routes = defaultRoutes()
        return (routes.first(where: \.isPrimary) ?? routes.first)?.gateway
    }

    /// Every IPv4 default route, one per interface, primary first.
    static func defaultRoutes() -> [DefaultRoute] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, AF_INET, NET_RT_DUMP, 0]
        var len = 0
        guard sysctl(&mib, 6, nil, &len, nil, 0) == 0, len > 0 else { return [] }

        var buf = [UInt8](repeating: 0, count: len)
        guard sysctl(&mib, 6, &buf, &len, nil, 0) == 0 else { return [] }

        var routes: [DefaultRoute] = []
        buf.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset + MemoryLayout<rt_msghdr>.size <= len {
                let hdr = base.advanced(by: offset)
                    .assumingMemoryBound(to: rt_msghdr.self).pointee
                let msgLen = Int(hdr.rtm_msglen)
                if msgLen == 0 { break }

                let flags = Int32(hdr.rtm_flags)
                if (flags & RTF_GATEWAY) != 0, (flags & RTF_UP) != 0,
                   let gw = gateway(inMessageAt: base.advanced(by: offset), header: hdr) {
                    let index = UInt32(hdr.rtm_index)
                    // Keep the first default route seen for each interface.
                    if !routes.contains(where: { $0.interfaceIndex == index }) {
                        routes.append(DefaultRoute(interfaceIndex: index,
                                                   interfaceName: interfaceName(index) ?? "if\(index)",
                                                   gateway: gw,
                                                   isPrimary: (flags & rtfIfScope) == 0))
                    }
                }
                offset += msgLen
            }
        }
        return routes.sorted { $0.isPrimary && !$1.isPrimary }
    }

    /// The local IPv4 address assigned to a BSD interface (e.g. `en0`).
    static func localIPv4(interface name: String) -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let ifa = ptr {
            if let sa = ifa.pointee.ifa_addr, sa.pointee.sa_family == sa_family_t(AF_INET),
               String(cString: ifa.pointee.ifa_name) == name {
                var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var cbuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sin.sin_addr, &cbuf, socklen_t(INET_ADDRSTRLEN))
                return String(cString: cbuf)
            }
            ptr = ifa.pointee.ifa_next
        }
        return nil
    }

    private static func interfaceName(_ index: UInt32) -> String? {
        var cbuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        guard if_indextoname(index, &cbuf) != nil else { return nil }
        return String(cString: cbuf)
    }

    /// Walks the sockaddr list that follows a routing message and returns the
    /// gateway address — but only if this message is the *default* route
    /// (destination `0.0.0.0`), so we don't pick up some unrelated gateway route.
    private static func gateway(inMessageAt msg: UnsafeRawPointer, header: rt_msghdr) -> String? {
        var ptr = msg.advanced(by: MemoryLayout<rt_msghdr>.size)   // first sockaddr
        let addrs = Int32(header.rtm_addrs)
        var dstIsDefault = false
        var gatewayIP: String?

        for axis in 0..<Int(RTAX_MAX) {
            guard (addrs & (1 << Int32(axis))) != 0 else { continue }
            let sa = ptr.assumingMemoryBound(to: sockaddr.self).pointee
            let saLen = Int(sa.sa_len)

            if axis == Int(RTAX_DST) {
                // The default route's destination is sockaddr_in 0.0.0.0 (often a
                // zero-length / unspecified sockaddr).
                if saLen == 0 {
                    dstIsDefault = true
                } else if sa.sa_family == sa_family_t(AF_INET) {
                    let sin = ptr.assumingMemoryBound(to: sockaddr_in.self).pointee
                    if sin.sin_addr.s_addr == 0 { dstIsDefault = true }
                }
            } else if axis == Int(RTAX_GATEWAY), sa.sa_family == sa_family_t(AF_INET) {
                var sin = ptr.assumingMemoryBound(to: sockaddr_in.self).pointee
                var cbuf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                inet_ntop(AF_INET, &sin.sin_addr, &cbuf, socklen_t(INET_ADDRSTRLEN))
                gatewayIP = String(cString: cbuf)
            }

            ptr = ptr.advanced(by: roundup(saLen))
        }
        return dstIsDefault ? gatewayIP : nil
    }

    /// sockaddrs in routing messages are padded to 4-byte (sizeof `uint32_t`)
    /// boundaries; a zero-length sockaddr still advances one word.
    private static func roundup(_ a: Int) -> Int {
        let word = MemoryLayout<UInt32>.size
        return a > 0 ? (1 + ((a - 1) | (word - 1))) : word
    }
}
