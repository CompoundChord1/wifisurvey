import Foundation
import Network

// MARK: - ICMP ping to the gateway (control path that doesn't depend on the server)

/// Unprivileged ICMP echo via a SOCK_DGRAM socket (the same approach as Apple's SimplePing).
final class Pinger {
    struct Record {
        var seq: Int
        var sentWall: Double
        var sentMono: Double
        var rtt: Double?
    }

    private static let magic: [UInt8] = Array("WFSURVEY".utf8)
    private let target: String
    private let interval: Double
    private let ident = UInt16.random(in: 1...0xFFFE)
    private let queue = DispatchQueue(label: "wifisurvey.ping")
    private let lock = NSLock()
    private var fd: Int32 = -1
    private var addr = sockaddr_in()
    private var timer: DispatchSourceTimer?
    private var records: [Record] = []
    private var running = false
    private(set) var error: String?

    init(target: String, pps: Int) {
        self.target = target
        self.interval = 1.0 / Double(max(pps, 1))
    }

    func start() {
        fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard fd >= 0 else {
            error = "icmp socket: \(String(cString: strerror(errno)))"
            return
        }
        var tv = timeval(tv_sec: 0, tv_usec: 250_000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        guard inet_pton(AF_INET, target, &addr.sin_addr) == 1 else {
            error = "bad gateway address \(target)"
            close(fd)
            fd = -1
            return
        }
        setRunning(true)
        let sock = fd
        Thread.detachNewThread { [weak self] in self?.receiveLoop(sock) }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(50), repeating: interval)
        t.setEventHandler { [weak self] in self?.sendOne() }
        t.resume()
        timer = t
    }

    private func setRunning(_ v: Bool) {
        lock.lock()
        running = v
        lock.unlock()
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func sendOne() {
        lock.lock()
        let seq = records.count
        records.append(Record(seq: seq, sentWall: Clock.nowMs(), sentMono: Clock.monoMs(), rtt: nil))
        lock.unlock()
        var pkt = [UInt8](repeating: 0, count: 24)
        pkt[0] = 8  // echo request
        pkt[4] = UInt8(ident >> 8)
        pkt[5] = UInt8(ident & 0xff)
        pkt[6] = UInt8((seq >> 8) & 0xff)
        pkt[7] = UInt8(seq & 0xff)
        for i in 0..<8 { pkt[8 + i] = Pinger.magic[i] }
        let s32 = UInt32(seq)
        pkt[16] = UInt8(s32 >> 24)
        pkt[17] = UInt8((s32 >> 16) & 0xff)
        pkt[18] = UInt8((s32 >> 8) & 0xff)
        pkt[19] = UInt8(s32 & 0xff)
        let ck = Pinger.checksum(pkt)
        pkt[2] = UInt8(ck >> 8)
        pkt[3] = UInt8(ck & 0xff)
        var a = addr
        _ = pkt.withUnsafeBytes { buf in
            withUnsafePointer(to: &a) { ap in
                ap.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, buf.baseAddress, buf.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
    }

    private func receiveLoop(_ sock: Int32) {
        var buf = [UInt8](repeating: 0, count: 2048)
        while isRunning() {
            let n = recv(sock, &buf, buf.count, 0)
            guard n > 0 else { continue }
            // Darwin delivers the IPv4 header on ICMP datagram sockets; skip it if present.
            let off = (buf[0] >> 4) == 4 ? Int(buf[0] & 0x0f) * 4 : 0
            guard n >= off + 20, buf[off] == 0, Array(buf[(off + 8)..<(off + 16)]) == Pinger.magic else { continue }
            let seq = Int(UInt32(buf[off + 16]) << 24 | UInt32(buf[off + 17]) << 16 |
                          UInt32(buf[off + 18]) << 8 | UInt32(buf[off + 19]))
            let mono = Clock.monoMs()
            lock.lock()
            if seq < records.count, records[seq].rtt == nil { records[seq].rtt = mono - records[seq].sentMono }
            lock.unlock()
        }
        close(sock)
    }

    func stopSending() {
        timer?.cancel()
        timer = nil
    }

    func finish() -> [Record] {
        stopSending()
        setRunning(false)  // the receive thread closes the socket within 250 ms
        fd = -1
        lock.lock()
        defer { lock.unlock() }
        return records
    }

    static func checksum(_ data: [UInt8]) -> UInt16 {
        var sum: UInt32 = 0
        var i = 0
        while i + 1 < data.count {
            sum += UInt32(data[i]) << 8 | UInt32(data[i + 1])
            i += 2
        }
        if i < data.count { sum += UInt32(data[i]) << 8 }
        while sum >> 16 != 0 { sum = (sum & 0xffff) + (sum >> 16) }
        return ~UInt16(sum)
    }

    static func summarize(_ recs: [Record], target: String) -> PingStats {
        let rtts = recs.compactMap { $0.rtt }
        return PingStats(target: target, sent: recs.count, received: rtts.count,
                         lossPct: Stats.pct(recs.count - rtts.count, recs.count), rtt: Stats.rtt(rtts))
    }
}

// MARK: - HTTP heartbeat (what "connected but stalls" feels like to an app)

final class HeartbeatProbe {
    struct Record {
        var sentWall: Double
        var rtt: Double?
        var err: String?
    }

    private let url: URL
    private let session: URLSession
    private let queue = DispatchQueue(label: "wifisurvey.hb")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var records: [Record] = []
    private var inFlight = false
    private var skipped = 0

    init(host: String, port: Int) {
        url = URL(string: "http://\(host):\(port)/health?hb=1")!
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 2
        cfg.timeoutIntervalForResource = 3
        cfg.httpMaximumConnectionsPerHost = 1
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(200), repeating: 1.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    private func tick() {
        lock.lock()
        if inFlight {
            skipped += 1
            lock.unlock()
            return
        }
        inFlight = true
        let idx = records.count
        records.append(Record(sentWall: Clock.nowMs(), rtt: nil, err: nil))
        lock.unlock()
        let t0 = Clock.monoMs()
        session.dataTask(with: url) { [weak self] _, resp, err in
            guard let self else { return }
            let rtt = Clock.monoMs() - t0
            self.lock.lock()
            if let err = err as NSError? {
                self.records[idx].err = err.code == NSURLErrorTimedOut ? "timeout" : "err \(err.code)"
            } else if (resp as? HTTPURLResponse)?.statusCode == 200 {
                self.records[idx].rtt = rtt
            } else {
                self.records[idx].err = "http \((resp as? HTTPURLResponse)?.statusCode ?? 0)"
            }
            self.inFlight = false
            self.lock.unlock()
        }.resume()
    }

    var failures: Int {
        lock.lock()
        defer { lock.unlock() }
        return records.filter { $0.err != nil }.count
    }

    func stopSending() {
        timer?.cancel()
        timer = nil
    }

    /// Call after ≥2 s grace so the last request can finish or time out.
    func finish() -> (records: [Record], skipped: Int) {
        stopSending()
        session.invalidateAndCancel()
        lock.lock()
        defer { lock.unlock() }
        // A request still pending at this point was cut off by us, not by the network.
        return (records.filter { $0.rtt != nil || $0.err != nil }, skipped)
    }

    static func summarize(_ r: (records: [Record], skipped: Int)) -> HeartbeatStats {
        let ok = r.records.compactMap { $0.rtt }
        return HeartbeatStats(sent: r.records.count, ok: ok.count, failed: r.records.count - ok.count,
                              skipped: r.skipped, rtt: Stats.rtt(ok))
    }
}

// MARK: - DNS responsiveness (rules the local DNS resolver in or out)

final class DNSProbe: @unchecked Sendable {
    struct Record {
        var sentWall: Double
        var rtt: Double?
        var rcode: Int?
        var err: String?
    }

    let server: String
    private let name: String
    private let queue = DispatchQueue(label: "wifisurvey.dns")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var pending: [UInt16: (idx: Int, mono: Double)] = [:]
    private var records: [Record] = []
    // Touched only on `queue`:
    private var conn: NWConnection?
    private var generation = 0
    private var stopped = false
    private var timeoutsInARow = 0

    init(server: String, name: String) {
        self.server = server
        self.name = name
    }

    /// The resolver iOS got from DHCP (IPv4 preferred).
    static func systemServer() -> String? {
        var buf = [CChar](repeating: 0, count: 512)
        guard wfs_dns_servers(&buf, Int32(buf.count)) > 0 else { return nil }
        let all = String(cString: buf).split(separator: ",").map(String.init)
        return all.first { $0.contains(".") } ?? all.first
    }

    func start() {
        queue.async { [self] in connect() }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(300), repeating: 2.0)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    /// A fresh socket: used at start, after a receive error, and after repeated timeouts, so a socket
    /// that went deaf (Wi-Fi drop, roam, ICMP error) is never mistaken for a resolver outage.
    private func connect() {
        generation += 1
        let gen = generation
        conn?.cancel()
        let c = NWConnection(host: NWEndpoint.Host(server), port: 53, using: .udp)
        conn = c
        c.stateUpdateHandler = { [weak self] st in
            guard let self, gen == self.generation, !self.stopped else { return }
            if case .ready = st { self.receiveLoop(c, gen) }
        }
        c.start(queue: queue)
    }

    private func tick() {
        let now = Clock.monoMs()
        lock.lock()
        for (id, p) in pending where now - p.mono > 1500 {
            records[p.idx].err = "timeout"
            pending[id] = nil
            timeoutsInARow += 1
        }
        let id = UInt16.random(in: 1...0xFFFE)
        pending[id] = (records.count, now)
        records.append(Record(sentWall: Clock.nowMs(), rtt: nil, rcode: nil, err: nil))
        lock.unlock()
        if timeoutsInARow >= 2 {
            timeoutsInARow = 0
            connect()
        }
        conn?.send(content: query(id: id), completion: .contentProcessed { _ in })
    }

    private func query(id: UInt16) -> Data {
        var d = Data([UInt8(id >> 8), UInt8(id & 0xff), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0])
        for label in name.split(separator: ".") {
            d.append(UInt8(label.utf8.count))
            d.append(contentsOf: Array(label.utf8))
        }
        d.append(contentsOf: [0, 0, 1, 0, 1])  // root, QTYPE A, QCLASS IN
        return d
    }

    private func receiveLoop(_ c: NWConnection, _ gen: Int) {
        c.receiveMessage { [weak self] data, _, _, error in
            guard let self, gen == self.generation, !self.stopped else { return }
            if let data, data.count >= 4 {
                let id = UInt16(data[data.startIndex]) << 8 | UInt16(data[data.startIndex + 1])
                let rcode = Int(data[data.startIndex + 3] & 0x0f)
                let mono = Clock.monoMs()
                self.timeoutsInARow = 0
                self.lock.lock()
                if let p = self.pending.removeValue(forKey: id) {
                    self.records[p.idx].rtt = mono - p.mono
                    self.records[p.idx].rcode = rcode
                }
                self.lock.unlock()
            }
            if error == nil {
                self.receiveLoop(c, gen)
            } else {
                self.queue.asyncAfter(deadline: .now() + .milliseconds(300)) { [weak self] in
                    guard let self, gen == self.generation, !self.stopped else { return }
                    self.connect()
                }
            }
        }
    }

    func stopSending() {
        timer?.cancel()
        timer = nil
    }

    func finish() -> [Record] {
        stopSending()
        queue.sync {
            stopped = true
            conn?.cancel()
            conn = nil
        }
        lock.lock()
        defer { lock.unlock() }
        for (_, p) in pending { records[p.idx].err = "timeout" }
        pending.removeAll()
        return records
    }

    static func summarize(_ recs: [Record], server: String) -> DNSStats {
        let ok = recs.compactMap { $0.rtt }
        return DNSStats(server: server, sent: recs.count, ok: ok.count, failed: recs.count - ok.count,
                        rtt: Stats.rtt(ok))
    }
}
