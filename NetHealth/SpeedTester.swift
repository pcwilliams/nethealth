import Foundation
import Network

/// Tunables for one bandwidth test. Each direction stops at whichever comes
/// first: `duration` seconds of transfer, or its byte cap — so a fast link
/// finishes in well under a second and a test never costs more than
/// `downloadBytes + uploadBytes` of data.
struct SpeedTestConfig: Sendable {
    var host = "speed.cloudflare.com"
    /// Parallel TCP streams. One stream tops out well below a multi-gigabit
    /// link (measured ~170 Mbps single-stream on the 5 Gb/s fibre).
    var streams = 6
    var duration: TimeInterval = 3
    var downloadBytes = 40_000_000
    var uploadBytes = 15_000_000
    /// Size of each download request. Each stream fetches these back to back
    /// over one keep-alive connection until the test stops. Cloudflare starts
    /// answering HTTP 429 to single requests of ≥10 MB from an IP that has
    /// tested a lot, while a stream of small ones is still served.
    var downloadRequestBytes = 4_000_000
    /// Give up if no data has flowed this long after starting.
    var connectTimeout: TimeInterval = 4
}

/// Measures throughput against Cloudflare's speed-test endpoints
/// (`/__down?bytes=N`, `POST /__up`) over HTTPS, using `NWConnection` with
/// `requiredInterface` so each test runs over exactly one link. URLSession has
/// no public way to pin an interface, hence the hand-rolled HTTP/1.1.
enum SpeedTester {

    struct Measurement: Sendable {
        let mbps: Double?
        let bytes: Int64
        let error: String?
    }

    static func measure(_ phase: SpeedPhase,
                        interface: NWInterface?,
                        config: SpeedTestConfig = SpeedTestConfig(),
                        progress: @escaping @Sendable (Double) -> Void = { _ in }) async -> Measurement {
        let meter = TransferMeter()
        let queue = DispatchQueue(label: "nethealth.speedtest")
        // Uploads split the cap across streams (one POST each); downloads loop
        // small GETs (see `downloadRequestBytes`).
        let total = phase == .download ? config.downloadBytes : config.uploadBytes
        let perStream = phase == .download ? config.downloadRequestBytes : max(1, total / config.streams)

        let streams: [TransferStream] = (0..<config.streams).map { _ in
            let params = NWParameters(tls: NWProtocolTLS.Options(), tcp: NWProtocolTCP.Options())
            if let interface { params.requiredInterface = interface }
            let conn = NWConnection(host: NWEndpoint.Host(config.host), port: 443, using: params)
            return TransferStream(connection: conn, phase: phase, host: config.host,
                                  bytes: perStream, meter: meter)
        }
        streams.forEach { $0.start(on: queue) }

        let started = now()
        var samples: [(t: Double, bytes: Int64)] = []
        var lastProgress = started
        while true {
            try? await Task.sleep(nanoseconds: 50_000_000)
            let snap = meter.snapshot()
            let t = now()
            samples.append((t, snap.bytes))

            if t - lastProgress >= 0.25, let rate = rollingRate(samples, over: 0.5) {
                progress(rate)
                lastProgress = t
            }

            if snap.finished >= streams.count { break }               // all done
            if snap.bytes >= Int64(total) { break }                   // byte cap
            if let first = snap.firstByte, t - first >= config.duration { break }   // time cap
            if snap.firstByte == nil, t - started >= config.connectTimeout { break } // never started
            if Task.isCancelled { break }
        }
        streams.forEach { $0.cancel() }

        let snap = meter.snapshot()
        return Measurement(mbps: finalRate(samples: samples, snapshot: snap),
                           bytes: snap.bytes,
                           error: snap.bytes > 0 ? nil : (snap.error ?? "no data"))
    }

    /// Throughput (Mbps) excluding TCP slow-start: skip the first 25% (up to
    /// 0.5 s) after the first byte, then bytes ÷ time to the last byte.
    private static func finalRate(samples: [(t: Double, bytes: Int64)],
                                  snapshot: TransferMeter.Snapshot) -> Double? {
        guard let first = snapshot.firstByte, let last = snapshot.lastByte, last > first else { return nil }
        let warm = first + min(0.5, 0.25 * (last - first))
        let warmBytes = samples.last(where: { $0.t <= warm })?.bytes ?? 0
        let span = last - warm
        if span >= 0.05, snapshot.bytes > warmBytes {
            return Double(snapshot.bytes - warmBytes) * 8 / span / 1_000_000
        }
        return Double(snapshot.bytes) * 8 / (last - first) / 1_000_000
    }

    private static func rollingRate(_ samples: [(t: Double, bytes: Int64)], over window: Double) -> Double? {
        guard let last = samples.last,
              let base = samples.last(where: { last.t - $0.t >= window }),
              last.bytes > base.bytes else { return nil }
        return Double(last.bytes - base.bytes) * 8 / (last.t - base.t) / 1_000_000
    }

    fileprivate static func now() -> Double {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

/// Thread-safe byte counter shared by a test's streams and polled by the
/// measuring loop.
private final class TransferMeter: @unchecked Sendable {
    struct Snapshot {
        let bytes: Int64
        let firstByte: Double?
        let lastByte: Double?
        let finished: Int
        let error: String?
    }

    private let lock = NSLock()
    private var bytes: Int64 = 0
    private var firstByte: Double?
    private var lastByte: Double?
    private var finished = 0
    private var error: String?

    func add(_ n: Int) {
        guard n > 0 else { return }
        let t = SpeedTester.now()
        lock.lock(); defer { lock.unlock() }
        if firstByte == nil { firstByte = t }
        lastByte = t
        bytes += Int64(n)
    }

    /// Stretch the transfer's end to now (an upload's server response).
    func markEnd() {
        let t = SpeedTester.now()
        lock.lock(); defer { lock.unlock() }
        if firstByte != nil { lastByte = t }
    }

    func finish(error message: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        finished += 1
        if let message, error == nil { error = message }
    }

    func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(bytes: bytes, firstByte: firstByte, lastByte: lastByte,
                        finished: finished, error: error)
    }
}

/// One HTTPS connection: for download, back-to-back keep-alive GETs of
/// `bytes` each until cancelled; for upload, a single POST of `bytes`. All callbacks run on the test's
/// serial queue, so the mutable state here needs no further locking.
private final class TransferStream: @unchecked Sendable {
    private let connection: NWConnection
    private let phase: SpeedPhase
    private let host: String
    private let bytes: Int
    private let meter: TransferMeter

    private var done = false
    private var header = Data()
    private var headerParsed = false
    private var bodyRemaining = 0
    private var sent = 0
    private static let chunk = Data(count: 256 * 1024)

    init(connection: NWConnection, phase: SpeedPhase, host: String, bytes: Int, meter: TransferMeter) {
        self.connection = connection
        self.phase = phase
        self.host = host
        self.bytes = bytes
        self.meter = meter
    }

    func start(on queue: DispatchQueue) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.phase == .download ? self.startDownload() : self.startUpload()
            case .waiting(let error), .failed(let error):
                // `.waiting` means the pinned interface can't reach the host
                // right now — don't sit there, treat it as a failure.
                self.finish(error: error.localizedDescription)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func cancel() {
        connection.cancel()
    }

    private func finish(error: String? = nil) {
        guard !done else { return }
        done = true
        meter.finish(error: error)
        connection.cancel()
    }

    // MARK: Download

    private func startDownload() {
        requestNext()
        receive()
    }

    /// Ask for the next piece. HTTP/1.1 without pipelining: only sent once the
    /// previous body has fully arrived, so a received chunk never spans two
    /// responses.
    private func requestNext() {
        header = Data()
        headerParsed = false
        bodyRemaining = bytes
        let request = "GET /__down?bytes=\(bytes) HTTP/1.1\r\nHost: \(host)\r\n"
            + "User-Agent: NetHealth\r\nAccept: */*\r\nConnection: keep-alive\r\n\r\n"
        connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self, !self.done else { return }
            if let data, !data.isEmpty {
                if self.headerParsed {
                    self.consumeBody(data.count)
                } else {
                    self.header.append(data)
                    if let end = self.header.range(of: Data("\r\n\r\n".utf8)) {
                        if let status = Self.status(of: self.header), status != 200 {
                            self.finish(error: "HTTP \(status)")
                            return
                        }
                        self.headerParsed = true
                        if let length = Self.contentLength(of: self.header.prefix(upTo: end.lowerBound)) {
                            self.bodyRemaining = length
                        }
                        self.consumeBody(self.header.count - end.upperBound)
                    }
                }
            }
            if let error {
                self.finish(error: error.localizedDescription)
            } else if isComplete {
                self.finish()
            } else {
                self.receive()
            }
        }
    }

    private func consumeBody(_ n: Int) {
        meter.add(n)
        bodyRemaining -= n
        if bodyRemaining <= 0 { requestNext() }
    }

    private static func contentLength(of header: Data) -> Int? {
        guard let text = String(data: header, encoding: .ascii) else { return nil }
        for line in text.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        return nil
    }

    // MARK: Upload

    private func startUpload() {
        let request = "POST /__up HTTP/1.1\r\nHost: \(host)\r\nUser-Agent: NetHealth\r\n"
            + "Content-Type: application/octet-stream\r\nContent-Length: \(bytes)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
        // Two chunks in flight keeps the socket buffer topped up.
        sendNext()
        sendNext()
    }

    private func sendNext() {
        guard !done, sent < bytes else { return }
        let size = min(Self.chunk.count, bytes - sent)
        sent += size
        let body = size == Self.chunk.count ? Self.chunk : Self.chunk.prefix(size)
        connection.send(content: body, completion: .contentProcessed { [weak self] error in
            guard let self, !self.done else { return }
            if let error {
                self.finish(error: error.localizedDescription)
                return
            }
            // Counted when the stack accepts it. The warm-up skip and final
            // response timing keep socket buffering from inflating the rate.
            self.meter.add(size)
            if self.sent < self.bytes {
                self.sendNext()
            } else {
                self.awaitResponse()
            }
        })
    }

    private func awaitResponse() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, let status = Self.status(of: data), status != 200 {
                self.finish(error: "HTTP \(status)")
            } else {
                // The server only responds once it has the whole body, so this
                // is when the upload truly completed.
                self.meter.markEnd()
                self.finish(error: error?.localizedDescription)
            }
        }
    }

    private static func status(of header: Data) -> Int? {
        guard let line = String(data: header.prefix(64), encoding: .ascii)?
            .split(separator: "\r\n").first else { return nil }
        let parts = line.split(separator: " ")
        return parts.count >= 2 ? Int(parts[1]) : nil
    }
}
