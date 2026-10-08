import Foundation
import Network

/// Sends small JSON probes to the helper's UDP echo at a fixed rate and times the echoes.
/// The helper logs every arrival, so after the leg `summarize` can split loss into
/// phone→AP ("up": never reached the server) and AP→phone ("down": reached the server, echo lost).
///
/// The socket must never be the reason a probe looks lost. After a Wi-Fi drop, a roam or an ICMP
/// error a UDP socket can stop delivering replies, so:
///   - a receive error does not end listening (it retries, and rebuilds the socket if it failed);
///   - a watchdog opens a new socket when no echo has arrived for `watchdogMs`.
/// The replaced socket is NOT closed: it keeps listening until the leg ends. A new socket has a new
/// source port, so an echo for a probe sent on the old socket can only arrive on the old socket. Closing
/// it would turn every probe that was merely *delayed* past the watchdog (queued in the phone's driver
/// during a stall or roam, then delivered) into an AP→phone loss — misattributing the direction.
/// `reconnects` counts rebuilds; probes keep their sequence numbers throughout.
final class UDPProber: @unchecked Sendable {
    struct Record {
        var seq: Int
        var sentWall: Double
        var sentMono: Double
        var rtt: Double?
        var sr: Double?
        var phase: String
        var dup = 0
        /// The local send failed (no route / interface gone). Still counted as lost, but it tells the
        /// analysis the probe never left the phone.
        var sendError = false
    }

    /// One UDP socket. After a rebuild the old one is kept in `retired` so late echoes still count.
    private final class Sock {
        let conn: NWConnection
        var receiving = false
        init(_ c: NWConnection) { conn = c }
    }

    private static let watchdogMs = 3000.0
    private static let maxRetired = 4

    private let host: String
    private let port: UInt16
    private let legId: String
    private let interval: Double
    private let packetBytes: Int
    private let queue = DispatchQueue(label: "wifisurvey.udp")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    // Guarded by `lock` (read from the main actor for the live display):
    private var records: [Record] = []
    private var drained = 0
    private var _phase = "idle"
    private var _reconnects = 0
    // Touched only on `queue`:
    private var current: Sock?
    private var retired: [Sock] = []
    private var stopped = false
    private var reconnectPending = false
    private var lastReplyMono = 0.0
    private var lastConnectMono = 0.0

    /// "idle", "down" or "up" — tagged onto each probe so latency under load can be separated.
    var phase: String {
        get { lock.lock(); defer { lock.unlock() }; return _phase }
        set { lock.lock(); _phase = newValue; lock.unlock() }
    }

    var reconnects: Int {
        lock.lock()
        defer { lock.unlock() }
        return _reconnects
    }

    init(host: String, port: Int, legId: String, pps: Int, packetBytes: Int) {
        self.host = host
        self.port = UInt16(port)
        self.legId = legId
        self.interval = 1.0 / Double(max(pps, 1))
        self.packetBytes = packetBytes
    }

    func start() {
        queue.async { [self] in
            lastReplyMono = Clock.monoMs()
            connect()
        }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(100), repeating: interval, leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.sendOne() }
        t.resume()
        timer = t
    }

    // MARK: connection lifecycle (all on `queue`)

    private func connect() {
        if let old = current {
            retired.append(old)
            while retired.count > Self.maxRetired { retired.removeFirst().conn.cancel() }
        }
        let s = Sock(NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: .udp))
        current = s
        reconnectPending = false
        lastConnectMono = Clock.monoMs()
        s.conn.stateUpdateHandler = { [weak self] st in
            guard let self, !self.stopped, self.isAlive(s) else { return }
            switch st {
            case .ready: self.receiveLoop(s)
            case .failed: self.socketFailed(s)
            default: break
            }
        }
        s.conn.start(queue: queue)
    }

    private func isAlive(_ s: Sock) -> Bool {
        s === current || retired.contains { $0 === s }
    }

    /// A dead current socket is replaced; a dead retired one is simply dropped.
    private func socketFailed(_ s: Sock) {
        if s === current {
            reconnect(afterMs: 300)
        } else {
            retired.removeAll { $0 === s }
            s.conn.cancel()
        }
    }

    private func reconnect(afterMs: Int) {
        guard !stopped, !reconnectPending else { return }
        reconnectPending = true
        queue.asyncAfter(deadline: .now() + .milliseconds(afterMs)) { [weak self] in
            guard let self, !self.stopped else { return }
            self.lock.lock()
            self._reconnects += 1
            self.lock.unlock()
            self.connect()
        }
    }

    private func receiveLoop(_ s: Sock) {
        guard !s.receiving, isAlive(s) else { return }
        s.receiving = true
        s.conn.receiveMessage { [weak self] data, _, _, error in
            guard let self, !self.stopped, self.isAlive(s) else { return }
            s.receiving = false
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let seq = obj["s"] as? Int {
                let mono = Clock.monoMs()
                self.lastReplyMono = mono
                self.lock.lock()
                if seq >= 0, seq < self.records.count {
                    if self.records[seq].rtt == nil {
                        self.records[seq].rtt = mono - self.records[seq].sentMono
                        self.records[seq].sr = obj["sr"] as? Double
                    } else {
                        self.records[seq].dup += 1
                    }
                }
                self.lock.unlock()
            }
            if error == nil {
                self.receiveLoop(s)
            } else {
                // A transient error (e.g. ICMP port-unreachable) must not end listening. Keep reading on
                // this socket; if it has actually failed, the state handler or the watchdog replaces it.
                self.queue.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
                    guard let self, !self.stopped, self.isAlive(s) else { return }
                    if case .failed = s.conn.state { self.socketFailed(s) } else { self.receiveLoop(s) }
                }
            }
        }
    }

    private func sendOne() {
        let mono = Clock.monoMs()
        if mono - lastReplyMono > Self.watchdogMs, mono - lastConnectMono > Self.watchdogMs {
            reconnect(afterMs: 0)
        }
        lock.lock()
        let seq = records.count
        let wall = Clock.nowMs()
        records.append(Record(seq: seq, sentWall: wall, sentMono: mono, rtt: nil, sr: nil, phase: _phase))
        lock.unlock()
        var obj: [String: Any] = ["l": legId, "s": seq, "t": Stats.r3(wall)]
        let base = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data()
        obj["p"] = String(repeating: "x", count: max(0, packetBytes - base.count - 8))
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        current?.conn.send(content: data, completion: .contentProcessed { [weak self] err in
            guard err != nil, let self else { return }
            self.lock.lock()
            if seq < self.records.count { self.records[seq].sendError = true }
            self.lock.unlock()
        })
    }

    // MARK: reading results

    /// Live view for the UI: probes older than 1 s count as final.
    func live() -> (sent: Int, lossPct: Double, p50: Double?) {
        lock.lock()
        defer { lock.unlock() }
        let now = Clock.monoMs()
        var final = 0, lost = 0
        var recent: [Double] = []
        for r in records where now - r.sentMono > 1000 {
            final += 1
            if let rtt = r.rtt { recent.append(rtt) } else { lost += 1 }
        }
        return (final, Stats.pct(lost, final), Stats.median(Array(recent.suffix(50))))
    }

    /// Walk mode: hand back probes older than `ms` that haven't been written yet.
    func drain(olderThan ms: Double) -> [Record] {
        lock.lock()
        defer { lock.unlock() }
        let now = Clock.monoMs()
        var end = drained
        while end < records.count, now - records[end].sentMono > ms { end += 1 }
        let out = Array(records[drained..<end])
        drained = end
        return out
    }

    func stopSending() {
        timer?.cancel()
        timer = nil
    }

    /// Call after a grace period for late echoes. Returns every probe not yet drained.
    func finish() -> [Record] {
        stopSending()
        queue.sync {
            stopped = true
            current?.conn.cancel()
            current = nil
            for s in retired { s.conn.cancel() }
            retired = []
        }
        lock.lock()
        defer { lock.unlock() }
        let out = Array(records[drained...])
        drained = records.count
        return out
    }

    static func rawRecord(_ r: Record) -> [String: Any] {
        var o: [String: Any] = ["k": "udp", "seq": r.seq, "sent": Stats.r3(r.sentWall), "rtt": J(r.rtt), "sr": J(r.sr),
                                "ph": r.phase]
        if r.sendError { o["se"] = true }   // the send itself failed: the probe never left the phone
        return o
    }

    static func summarize(_ recs: [Record], arrivals: Set<Int>?, reconnects: Int = 0) -> UDPStats {
        let sent = recs.count
        let lostSeqs = recs.filter { $0.rtt == nil }.map { $0.seq }
        let sendErrors = recs.filter { $0.sendError }.count
        let received = sent - lostSeqs.count
        var up: Int?, down: Int?
        var unknown = 0
        if let arrivals {
            let u = lostSeqs.filter { !arrivals.contains($0) }.count
            up = u
            down = lostSeqs.count - u
        } else {
            unknown = lostSeqs.count
        }
        let rtts = recs.compactMap { $0.rtt }
        var diffs: [Double] = []
        var prev: Double?
        for r in recs {
            guard let rt = r.rtt else { continue }
            if let p = prev { diffs.append(abs(rt - p)) }
            prev = rt
        }
        var maxBurst = 0, bursts3 = 0, cur = 0
        for r in recs {
            if r.rtt == nil {
                cur += 1
                maxBurst = max(maxBurst, cur)
            } else {
                if cur >= 3 { bursts3 += 1 }
                cur = 0
            }
        }
        if cur >= 3 { bursts3 += 1 }
        let withSr = recs.filter { $0.rtt != nil && $0.sr != nil }.sorted { $0.rtt! < $1.rtt! }
        let offsets = withSr.prefix(max(1, withSr.count / 10)).map { $0.sr! - ($0.sentWall + $0.rtt! / 2) }

        func part(_ include: (Record) -> Bool) -> LossPart {
            let rs = recs.filter(include)
            let rv = rs.compactMap { $0.rtt }
            return LossPart(sent: rs.count, received: rv.count, lossPct: Stats.pct(rs.count - rv.count, rs.count),
                            rtt: Stats.rtt(rv))
        }

        return UDPStats(
            sent: sent, received: received, lossPct: Stats.pct(sent - received, sent),
            upLost: up, downLost: down, unknownLost: unknown,
            upLossPct: up.map { Stats.pct($0, sent) }, downLossPct: down.map { Stats.pct($0, sent) },
            late: rtts.filter { $0 > 1000 }.count, dup: recs.reduce(0) { $0 + $1.dup },
            rtt: Stats.rtt(rtts),
            jitterMs: diffs.isEmpty ? nil : Stats.r3(diffs.reduce(0, +) / Double(diffs.count)),
            maxLossBurst: maxBurst, lossBursts3plus: bursts3,
            clockOffsetMs: Stats.median(offsets).map(Stats.r3),
            idle: part { $0.phase == "idle" }, loaded: part { $0.phase != "idle" },
            reconnects: reconnects, sendErrors: sendErrors)
    }
}
