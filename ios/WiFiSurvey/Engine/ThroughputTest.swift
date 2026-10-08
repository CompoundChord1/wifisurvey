import Foundation
import Network

/// TCP throughput against the helper's port 9752.
///   download: send "DOWN <sec> <leg>\n", count bytes until the server closes.
///   upload:   send "UP <sec> <leg>\n", stream for <sec>, half-close, read "OK <bytes> <seconds>".
/// All mutable state is touched only on `queue`, hence @unchecked Sendable.
final class ThroughputTest: @unchecked Sendable {
    struct Outcome {
        var result: TputResult
        var raw: [String: Any]
    }

    private let conn: NWConnection
    private let queue = DispatchQueue(label: "wifisurvey.tput")
    private let direction: String
    private let seconds: Int
    private let legId: String
    private var bytes = 0
    private var timeline: [[Double]] = []
    private var lastMark = 0.0
    private var startMono = 0.0
    private var startWall = 0.0
    private var lastByteMono = 0.0
    private var reply = Data()
    private var finished = false
    private var cont: CheckedContinuation<Outcome, Never>?
    private static let chunk = Data((0..<65536).map { _ in UInt8.random(in: 0...255) })

    private init(host: String, port: Int, direction: String, seconds: Int, legId: String) {
        conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: UInt16(port))!, using: .tcp)
        self.direction = direction
        self.seconds = seconds
        self.legId = legId
    }

    static func run(host: String, port: Int, direction: String, seconds: Int, legId: String) async -> Outcome {
        let t = ThroughputTest(host: host, port: port, direction: direction, seconds: seconds, legId: legId)
        return await t.go()
    }

    // Strong captures are deliberate: the test must outlive the call, and finish() breaks the
    // handler cycle (stateUpdateHandler = nil) once it resolves. finish() is idempotent.
    private func go() async -> Outcome {
        await withCheckedContinuation { c in
            queue.async { [self] in
                cont = c
                conn.stateUpdateHandler = { [self] st in
                    switch st {
                    case .ready: begin()
                    case .failed(let e): finish(error: "connect: \(e)")
                    case .waiting(let e): finish(error: "no path: \(e)")
                    default: break
                    }
                }
                conn.start(queue: queue)
                queue.asyncAfter(deadline: .now() + .seconds(seconds + 10)) { [self] in
                    finish(error: "timed out")
                }
            }
        }
    }

    private func begin() {
        startMono = Clock.monoMs()
        startWall = Clock.nowMs()
        lastMark = startMono
        let cmd = "\(direction == "down" ? "DOWN" : "UP") \(seconds) \(legId)\n"
        conn.send(content: cmd.data(using: .ascii), completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            if let err { self.finish(error: "send: \(err)"); return }
            if self.direction == "down" { self.receiveDown() } else { self.sendUp() }
        })
    }

    private func mark(_ now: Double) {
        if now - lastMark >= 250 {
            timeline.append([Stats.r3(now - startMono), Double(bytes)])
            lastMark = now
        }
    }

    private func receiveDown() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
            guard let self else { return }
            let now = Clock.monoMs()
            if let data, !data.isEmpty {
                self.bytes += data.count
                self.lastByteMono = now
                self.mark(now)
            }
            if done || err != nil {
                self.finish(error: (err != nil && self.bytes == 0) ? "recv: \(err!)" : nil)
            } else {
                self.receiveDown()
            }
        }
    }

    private func sendUp() {
        let now = Clock.monoMs()
        if now - startMono >= Double(seconds) * 1000 {
            conn.send(content: nil, contentContext: .finalMessage, isComplete: true,
                      completion: .contentProcessed { _ in })
            receiveReply()
            return
        }
        conn.send(content: Self.chunk, completion: .contentProcessed { [weak self] err in
            guard let self else { return }
            if let err { self.finish(error: "send: \(err)"); return }
            self.bytes += Self.chunk.count
            self.lastByteMono = Clock.monoMs()
            self.mark(self.lastByteMono)
            self.sendUp()
        })
    }

    private func receiveReply() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 256) { [weak self] data, _, done, err in
            guard let self else { return }
            if let data { self.reply.append(data) }
            if done || err != nil || self.reply.contains(0x0A) {
                self.finish(error: nil)
            } else {
                self.receiveReply()
            }
        }
    }

    private func finish(error: String?) {
        guard !finished else { return }
        finished = true
        conn.stateUpdateHandler = nil
        conn.cancel()
        let endMono = lastByteMono > 0 ? lastByteMono : Clock.monoMs()
        var secs = max((endMono - startMono) / 1000, 0.001)
        var total = bytes
        var serverBytes: Int?
        var serverSeconds: Double?
        if direction == "up", let line = String(data: reply, encoding: .ascii) {
            let parts = line.split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if parts.count >= 3, parts[0] == "OK", let b = Int(parts[1]), let s = Double(parts[2]), s > 0 {
                serverBytes = b
                serverSeconds = s
                total = b
                secs = s
            }
        }
        let mbps: Double? = total > 0 ? Stats.r1(Double(total) * 8 / secs / 1e6) : nil
        // Steady rate: skip the first second (TCP ramp-up), from the client-side timeline.
        var steady: Double?
        if let first = timeline.first(where: { $0[0] >= 1000 }), let last = timeline.last, last[0] > first[0] + 500 {
            steady = Stats.r1((last[1] - first[1]) * 8 / ((last[0] - first[0]) / 1000) / 1e6)
        }
        let err: String? = (error != nil && total == 0) ? error : nil
        let result = TputResult(mbps: mbps, mbpsSteady: steady, bytes: total, seconds: Stats.r3(secs), error: err)
        let raw: [String: Any] = ["k": "tput", "dir": direction, "startMs": Stats.r3(startWall),
                                  "endMs": Stats.r3(startWall + secs * 1000), "bytes": total,
                                  "mbps": J(mbps), "mbpsSteady": J(steady), "timeline": timeline,
                                  "serverBytes": J(serverBytes), "serverSeconds": J(serverSeconds),
                                  "error": J(err)]
        let c = cont
        cont = nil
        c?.resume(returning: Outcome(result: result, raw: raw))
    }
}
