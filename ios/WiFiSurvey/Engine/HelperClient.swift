import Foundation

struct HelperHealth: Decodable {
    struct Collector: Decodable {
        var state: String?
        var error: String?
        var lastPollMs: Double?
        var site: String?
        var controller: String?
        var snapshots: Int?
    }

    var ok: Bool
    var version: String?
    var serverMs: Double?
    var run: String?
    var collector: Collector?
}

/// When the server last answered. A leg at a dead spot uses it to tell "the helper isn't running"
/// (stop and say so) from "this spot can't reach it" (measure anyway — that outage is the finding).
enum HelperReachability {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var lastOK: Date?

    static func noteOK() {
        lock.lock()
        lastOK = Date()
        lock.unlock()
    }

    /// True if the server answered within the last `seconds`. Recent contact is the evidence that the
    /// helper is running; an answer from hours ago proves nothing.
    static func okWithin(_ seconds: TimeInterval) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let t = lastOK else { return false }
        return Date().timeIntervalSince(t) <= seconds
    }
}

/// Delivers marks (leg start/end, the phone's IP and MAC, glitches) in order, retrying for up to two
/// minutes. On a bad link a mark must neither block the measurement nor get lost: without the
/// "start" mark the server doesn't know which client to record.
actor MarkQueue {
    static let shared = MarkQueue()
    private var pending: [(url: String, body: Data, deadline: Date)] = []
    private var draining = false

    func enqueue(url: String, body: Data) {
        pending.append((url, body, Date().addingTimeInterval(120)))
        if !draining {
            draining = true
            Task { await drain() }
        }
    }

    private func drain() async {
        while let item = pending.first {
            if await HelperClient.post(item.url, body: item.body, timeout: 3) != nil || Date() > item.deadline {
                pending.removeFirst()
            } else {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        draining = false
    }
}

/// Talks to the helper's HTTP API on the server (docs/SCHEMA.md, server/wifisurvey_helper.py).
struct HelperClient: Sendable {
    let host: String
    let port: Int

    init(_ s: SurveySettings) {
        host = s.helperHost
        port = s.httpPort
    }

    private var base: String { "http://\(host):\(port)" }

    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 5
        c.waitsForConnectivity = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()

    func health(timeout: TimeInterval = 2) async -> HelperHealth? {
        guard let url = URL(string: base + "/health") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        guard let (data, resp) = try? await Self.session.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let h = try? JSONDecoder().decode(HelperHealth.self, from: data) else { return nil }
        HelperReachability.noteOK()
        return h
    }

    func getJSON(_ path: String, timeout: TimeInterval = 5) async -> [String: Any]? {
        guard let url = URL(string: base + path) else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        guard let (data, _) = try? await Self.session.data(for: req) else { return nil }
        HelperReachability.noteOK()
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    /// POST a JSON body. Returns the reply, or nil if the server didn't answer.
    static func post(_ urlString: String, body: Data, timeout: TimeInterval) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        guard let (data, resp) = try? await session.data(for: req), resp is HTTPURLResponse else { return nil }
        HelperReachability.noteOK()
        return data
    }

    /// Queue a mark for reliable, ordered delivery. Returns at once — never waits on the network.
    func mark(_ body: [String: Any]) async {
        var b = body
        b["phoneMs"] = Stats.r3(Clock.nowMs())
        guard JSONSerialization.isValidJSONObject(b), let data = try? JSONSerialization.data(withJSONObject: b) else {
            return
        }
        await MarkQueue.shared.enqueue(url: base + "/mark", body: data)
    }

    /// Latest AP-side record the collector has for this phone IP.
    func status(ip: String) async -> [String: Any]? {
        guard let j = await getJSON("/status?ip=\(ip)", timeout: 3), (j["ok"] as? Bool) == true else { return nil }
        return j["c"] as? [String: Any]
    }

    /// Which probe sequence numbers reached the server for this leg. A few quick retries: the leg may end
    /// on a weak link. If it still fails the analysis recomputes the split from the server's own log.
    func arrivals(leg: String) async -> Set<Int>? {
        for attempt in 0..<3 {
            if let j = await getJSON("/arrivals?leg=\(leg)", timeout: 3), (j["ok"] as? Bool) == true,
               let ranges = j["ranges"] as? [[Int]] {
                var s = Set<Int>()
                for r in ranges where r.count == 2 && r[0] <= r[1] { s.formUnion(r[0]...r[1]) }
                return s
            }
            if attempt < 2 { try? await Task.sleep(nanoseconds: 700_000_000) }
        }
        return nil
    }

    func export(surveyId: String, fromMs: Double, toMs: Double, legs: [String]) async -> Data? {
        guard let url = URL(string: base + "/export") else { return nil }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 180
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "surveyId": surveyId, "fromMs": fromMs, "toMs": toMs, "legs": legs])
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return data
    }

    /// Upload the finished export zip to ~/wifisurvey/surveys/ on the server. Returns the saved path.
    func upload(fileURL: URL, name: String) async -> Result<String, Error> {
        let q = name.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "survey.zip"
        guard let url = URL(string: base + "/survey-upload?name=\(q)") else {
            return .failure(URLError(.badURL))
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.setValue("application/zip", forHTTPHeaderField: "Content-Type")
        do {
            let (data, _) = try await URLSession.shared.upload(for: req, fromFile: fileURL)
            let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if (j?["ok"] as? Bool) == true { return .success(j?["path"] as? String ?? "saved") }
            return .failure(NSError(domain: "helper", code: 1, userInfo: [
                NSLocalizedDescriptionKey: j?["error"] as? String ?? "upload rejected"]))
        } catch {
            return .failure(error)
        }
    }
}
