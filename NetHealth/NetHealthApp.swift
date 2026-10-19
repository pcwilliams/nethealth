import SwiftUI
import Darwin

@main
struct NetHealthApp: App {
    init() {
        // Headless self-test: `NetHealth --selftest` measures every default
        // target once, prints the result, and exits non-zero if all are down.
        if CommandLine.arguments.contains("--selftest") {
            SelfTest.run()
        }
        // Low-level socket diagnostics: `NetHealth --netdiag` reports the raw
        // result + errno of each socket step (ICMP create/send/recv, TCP connect)
        // to distinguish a code bug from a sandbox / connectivity issue.
        if CommandLine.arguments.contains("--netdiag") {
            NetDiag.run()
        }
        // Headless bandwidth test: `NetHealth --speedtest` runs a download +
        // upload over every connection (pinned per interface) and prints Mbps.
        if CommandLine.arguments.contains("--speedtest") {
            SpeedTestCLI.run()
        }
        // Live probe log: `NetHealth --watch [seconds]` runs the same concurrent
        // 1 Hz probe pattern as the GUI and prints one line per tick.
        if let i = CommandLine.arguments.firstIndex(of: "--watch") {
            let next = CommandLine.arguments.indices.contains(i + 1) ? Int(CommandLine.arguments[i + 1]) : nil
            WatchCLI.run(seconds: next ?? 15)
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

private func emitLine(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}

/// Command-line self-test for the ping pipeline. Output goes through an
/// unbuffered `FileHandle` (a GUI app's buffered `print` to a redirected stdout
/// isn't reliably flushed) and the probes run on a *detached* task — a plain
/// `Task {}` would inherit `App.init()`'s MainActor and deadlock the semaphore.
enum SelfTest {
    static func run() {
        let service = PingService()
        let connections = ConnectionDiscovery.discover(path: ConnectionDiscovery.currentPath())
        let sema = DispatchSemaphore(value: 0)
        let reachable = NSMutableArray()
        let required = connections.count * 2      // router + Cloudflare per link

        emitLine("NetHealth self-test — \(connections.count) connection(s)")
        Task.detached {
            for c in connections {
                emitLine("  \(c.displayName)  \(c.interfaceName)  \(c.localIP ?? "?")  gw \(c.gateway)\(c.isPrimary ? "  (primary)" : "")")
                if let link = LinkReader.read(interfaceName: c.interfaceName, kind: c.kind) {
                    emitLine("    link  \(link.summary)" + (link.phyMode.map { "  \($0)" } ?? "")
                             + (link.widthMHz.map { "  \($0) MHz" } ?? "") + (link.noise.map { "  noise \($0) dBm" } ?? ""))
                } else {
                    emitLine("    link  unknown")
                }
                for t in ConnectionDiscovery.targets(for: c) {
                    let reading = await service.measure(host: t.host, ports: t.ports, timeout: 1.5,
                                                        interfaceIndex: c.interfaceIndex)
                    let name = t.name.padding(toLength: 11, withPad: " ", startingAt: 0)
                    let host = t.host.padding(toLength: 16, withPad: " ", startingAt: 0)
                    if let reading {
                        reachable.add("\(c.interfaceName)/\(t.name)")
                        emitLine(String(format: "    [OK]   %@ %@ %7.1f ms  via %@", name, host, reading.rtt, reading.method.rawValue))
                    } else if t.optional {
                        // Optional targets (the dish) only exist behind one link —
                        // not a failure, just omitted in the UI.
                        emitLine("    [--]   \(name) \(host) not present (optional)")
                    } else {
                        emitLine("    [FAIL] \(name) \(host) unreachable")
                    }
                }
            }
            sema.signal()
        }
        if sema.wait(timeout: .now() + Double(connections.count) * 9.0 + 2.0) == .timedOut {
            emitLine("  [FAIL] self-test timed out")
        }
        emitLine("\(reachable.count) targets reachable (\(required) required across \(connections.count) connection(s))")
        exit(reachable.count > 0 ? 0 : 1)
    }
}

/// Command-line bandwidth test over every connection, one at a time.
enum SpeedTestCLI {
    static func run() {
        let connections = ConnectionDiscovery.discover(path: ConnectionDiscovery.currentPath())
        let config = SpeedTestConfig()
        let sema = DispatchSemaphore(value: 0)
        let ok = NSMutableArray()

        emitLine("NetHealth speed test — \(connections.count) connection(s), \(config.streams) streams, "
                 + "≤\(Int(config.duration))s / ≤\(config.downloadBytes / 1_000_000) MB down, ≤\(config.uploadBytes / 1_000_000) MB up")
        Task.detached {
            for c in connections {
                emitLine("  \(c.displayName)  \(c.interfaceName)  gw \(c.gateway)\(c.isPrimary ? "  (primary)" : "")")
                for phase in [SpeedPhase.download, .upload] {
                    let t0 = Date()
                    let m = await SpeedTester.measure(phase, interface: c.nwInterface, config: config)
                    let secs = Date().timeIntervalSince(t0)
                    let mb = Double(m.bytes) / 1_000_000
                    if let mbps = m.mbps {
                        ok.add(phase.rawValue)
                        emitLine(String(format: "    %@ %@  %8.1f Mbps   %6.1f MB in %.1fs%@", phase.arrow,
                                        phase.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0),
                                        mbps, mb, secs, m.error.map { "  (\($0))" } ?? ""))
                    } else {
                        emitLine("    \(phase.arrow) \(phase.rawValue)  FAILED: \(m.error ?? "unknown")")
                    }
                }
            }
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + Double(connections.count) * 25.0 + 5.0)
        emitLine("\(ok.count)/\(connections.count * 2) measurements succeeded")
        exit(ok.count > 0 ? 0 : 1)
    }
}

/// Concurrent 1 Hz probe loop across every connection × target, as the GUI
/// does, logging each tick: `en1/Router 3.1  en1/Cloudflare 9.8  …` (`--` = lost).
enum WatchCLI {
    static func run(seconds: Int) {
        let service = PingService()
        let connections = ConnectionDiscovery.discover(path: ConnectionDiscovery.currentPath())
        let probes = connections.flatMap { c in
            ConnectionDiscovery.targets(for: c).map { (c.interfaceName, c.interfaceIndex, $0) }
        }
        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            for tick in 1...max(1, seconds) {
                let started = Date()
                let results = await withTaskGroup(of: (Int, Double?).self) { group -> [Int: Double?] in
                    for (i, p) in probes.enumerated() {
                        group.addTask {
                            (i, await service.measure(host: p.2.host, ports: p.2.ports, timeout: 0.95,
                                                      interfaceIndex: p.1)?.rtt)
                        }
                    }
                    var out: [Int: Double?] = [:]
                    for await (i, rtt) in group { out[i] = rtt }
                    return out
                }
                let line = probes.indices.map { i -> String in
                    let label = "\(probes[i].0)/\(probes[i].2.name)"
                    return label + " " + ((results[i] ?? nil).map { String(format: "%.1f", $0) } ?? "--")
                }.joined(separator: "  ")
                emitLine(String(format: "%3d  ", tick) + line)
                let remaining = 1 - Date().timeIntervalSince(started)
                if remaining > 0 { try? await Task.sleep(nanoseconds: UInt64(remaining * 1e9)) }
            }
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + Double(seconds) * 3 + 5)
        exit(0)
    }
}

/// Raw socket diagnostics — reports the exact errno of each operation.
enum NetDiag {
    static func run() {
        let icmpFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        if icmpFD < 0 {
            emitLine("ICMP socket(): FAILED errno=\(errno) (\(String(cString: strerror(errno))))")
        } else {
            emitLine("ICMP socket(): ok fd=\(icmpFD)")
            close(icmpFD)
        }
        rawIcmpProbe(host: "127.0.0.1")
        tcpProbe(host: "1.1.1.1", port: 443)
        tcpProbe(host: "192.168.1.1", port: 80)
        tcpProbe(host: "192.168.100.1", port: 80)

        let sema = DispatchSemaphore(value: 0)
        Task.detached {
            for host in ["127.0.0.1", "1.1.1.1"] {
                do {
                    let ms = try await ICMPPinger.ping(host: host, timeout: 1.5)
                    emitLine("ICMPPinger.ping(\(host)): \(String(format: "%.2f", ms)) ms")
                } catch {
                    emitLine("ICMPPinger.ping(\(host)): error \(error)")
                }
            }
            do {
                let ms = try await TCPPinger.ping(host: "1.1.1.1", port: 443, timeout: 1.5)
                emitLine("TCPPinger.ping(1.1.1.1:443): \(String(format: "%.2f", ms)) ms")
            } catch {
                emitLine("TCPPinger.ping(1.1.1.1:443): error \(error)")
            }
            sema.signal()
        }
        _ = sema.wait(timeout: .now() + 12)
        exit(0)
    }

    private static func rawIcmpProbe(host: String) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        inet_pton(AF_INET, host, &addr.sin_addr)
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else { emitLine("raw: socket fail errno=\(errno)"); return }
        defer { close(fd) }
        var tv = timeval(tv_sec: 1, tv_usec: 500000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var pkt = [UInt8](repeating: 0, count: 16)
        pkt[0] = 8; pkt[6] = 0; pkt[7] = 1
        for i in 0..<8 { pkt[8 + i] = UInt8(0x61 + i) }
        let sent = pkt.withUnsafeBytes { raw in
            withUnsafePointer(to: &addr) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    sendto(fd, raw.baseAddress, raw.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        emitLine("raw: sendto -> \(sent)")
        var buf = [UInt8](repeating: 0, count: 256)
        let n = recv(fd, &buf, buf.count, 0)
        if n < 0 {
            emitLine("raw: recv -> -1 errno=\(errno) (\(String(cString: strerror(errno))))")
        } else {
            let hex = buf.prefix(min(n, 12)).map { String(format: "%02x", $0) }.joined(separator: " ")
            emitLine("raw: recv -> \(n) bytes  head=[\(hex)]")
        }
    }

    private static func tcpProbe(host: String, port: UInt16) {
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        inet_pton(AF_INET, host, &addr.sin_addr)
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        if fd < 0 { emitLine("TCP socket(\(host):\(port)): FAILED errno=\(errno)"); return }
        defer { close(fd) }
        let rc = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 {
            emitLine("TCP connect(\(host):\(port)): ok")
        } else {
            emitLine("TCP connect(\(host):\(port)): FAILED errno=\(errno) (\(String(cString: strerror(errno))))")
        }
    }
}
