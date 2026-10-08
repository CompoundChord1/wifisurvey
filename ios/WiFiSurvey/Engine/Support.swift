import Foundation

enum Clock {
    /// Wall clock, Unix epoch milliseconds. Used for every recorded timestamp.
    static func nowMs() -> Double { Date().timeIntervalSince1970 * 1000 }
    /// Monotonic milliseconds. Used for measuring intervals (RTTs, durations).
    static func monoMs() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000 }
}

/// Appends JSON lines to a raw/*.jsonl file on a background queue.
final class RawLog {
    private let queue = DispatchQueue(label: "wifisurvey.rawlog")
    private var buffer = Data()
    private var handle: FileHandle?

    init(url: URL) {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func write(_ obj: [String: Any]) {
        queue.async { [weak self] in
            guard let self, JSONSerialization.isValidJSONObject(obj),
                  let data = try? JSONSerialization.data(withJSONObject: obj, options: []) else { return }
            self.buffer.append(data)
            self.buffer.append(0x0A)
            if self.buffer.count > 32_768 { self.flushLocked() }
        }
    }

    func flush() { queue.sync { flushLocked() } }

    func close() {
        queue.sync {
            flushLocked()
            try? handle?.close()
            handle = nil
        }
    }

    private func flushLocked() {
        guard !buffer.isEmpty, let h = handle else { return }
        try? h.write(contentsOf: buffer)
        buffer.removeAll(keepingCapacity: true)
    }
}

/// Lets exactly one of several racing callbacks through (e.g. a result vs. its timeout).
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func pass() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// JSON-safe optional: nil and non-finite numbers become NSNull.
func J(_ v: Double?) -> Any {
    guard let v, v.isFinite else { return NSNull() }
    return Stats.r3(v)
}

func J(_ v: Int?) -> Any { v.map { $0 as Any } ?? NSNull() }
func J(_ v: String?) -> Any { v.map { $0 as Any } ?? NSNull() }

enum Stats {
    static func rtt(_ values: [Double]) -> RTTStats? {
        let s = values.filter { $0.isFinite }.sorted()
        guard !s.isEmpty else { return nil }
        func p(_ q: Double) -> Double {
            let pos = q * Double(s.count - 1)
            let lo = Int(pos.rounded(.down))
            let hi = min(lo + 1, s.count - 1)
            return r3(s[lo] + (s[hi] - s[lo]) * (pos - Double(lo)))
        }
        return RTTStats(p50: p(0.5), p90: p(0.9), p95: p(0.95), p99: p(0.99), max: r3(s[s.count - 1]),
                        mean: r3(s.reduce(0, +) / Double(s.count)))
    }

    static func median(_ values: [Double]) -> Double? {
        let s = values.filter { $0.isFinite }.sorted()
        guard !s.isEmpty else { return nil }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func r3(_ x: Double) -> Double { (x * 1000).rounded() / 1000 }
    static func r1(_ x: Double) -> Double { (x * 10).rounded() / 10 }

    static func pct(_ part: Int, _ whole: Int) -> Double {
        whole > 0 ? r3(Double(part) * 100 / Double(whole)) : 0
    }
}
