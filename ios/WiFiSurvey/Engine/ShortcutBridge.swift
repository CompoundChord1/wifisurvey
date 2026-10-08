import Foundation
import UIKit

/// Runs the user's "WiFiSurvey Radio" Shortcut via x-callback-url and waits for it to call back.
/// Only Shortcuts' "Get Network Details" can read the iPhone's own RSSI / noise / channel / PHY rates;
/// apps can't. The Shortcut returns lines of:  ISO-date|RSSI|Noise|Channel|TX|RX|BSSID|Standard[|MAC]
/// (docs/SHORTCUT.md). Callbacks: wifisurvey://radio?token=…&result=… (or ?data=… from the fallback).
@MainActor
final class ShortcutBridge {
    static let shared = ShortcutBridge()

    struct Outcome {
        var samples: [RadioSample]
        var error: String?
        var rawText: String?
    }

    private var cont: CheckedContinuation<Outcome, Never>?
    private var token: String?
    private var startedAt: Date?
    private var timeout: TimeInterval = 90
    private(set) var isWaiting = false

    func run(name: String, timeout: TimeInterval = 90) async -> Outcome {
        if cont != nil { finish(Outcome(samples: [], error: "superseded", rawText: nil)) }
        let token = UUID().uuidString
        self.token = token
        self.timeout = timeout
        startedAt = Date()
        let enc: (String) -> String = {
            $0.addingPercentEncoding(withAllowedCharacters: CharacterSet(
                charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? $0
        }
        let success = "wifisurvey://radio?token=\(token)"
        let failure = "wifisurvey://radio-error?token=\(token)"
        let cancel = "wifisurvey://radio-cancel?token=\(token)"
        let link = "shortcuts://x-callback-url/run-shortcut?name=\(enc(name))&x-success=\(enc(success))"
            + "&x-error=\(enc(failure))&x-cancel=\(enc(cancel))"
        return await withCheckedContinuation { c in
            cont = c
            isWaiting = true
            guard let url = URL(string: link) else {
                finish(Outcome(samples: [], error: "bad Shortcut name", rawText: nil))
                return
            }
            UIApplication.shared.open(url, options: [:]) { [weak self] ok in
                if !ok {
                    Task { @MainActor in
                        self?.finish(Outcome(samples: [], error: "Could not open the Shortcuts app", rawText: nil))
                    }
                }
            }
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if self?.token == token {
                    self?.finish(Outcome(samples: [], error: "Timed out waiting for the Shortcut", rawText: nil))
                }
            }
        }
    }

    /// Called from onOpenURL. Returns true when the URL was a Shortcut callback.
    @discardableResult
    func handle(url: URL) -> Bool {
        guard url.scheme == "wifisurvey", let host = url.host, host.hasPrefix("radio") else { return false }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        var q: [String: String] = [:]
        for item in items where q[item.name] == nil { q[item.name] = item.value ?? "" }
        if let t = q["token"], t != token { return true }  // stale callback from an earlier run
        guard cont != nil else { return true }
        switch host {
        case "radio":
            let text = q["result"] ?? q["data"] ?? ""
            let samples = Self.parse(text, endMs: Clock.nowMs())
            finish(Outcome(samples: samples, error: samples.isEmpty ? "Shortcut returned no samples" : nil,
                           rawText: text))
        case "radio-error":
            finish(Outcome(samples: [], error: "Shortcut error: \(q["errorMessage"] ?? "unknown")", rawText: nil))
        default:
            finish(Outcome(samples: [], error: "Shortcut cancelled", rawText: nil))
        }
        return true
    }

    /// If the user comes back by hand after the timeout, don't leave the measurement hanging.
    func appBecameActive() {
        if let s = startedAt, cont != nil, Date().timeIntervalSince(s) > timeout {
            finish(Outcome(samples: [], error: "Timed out waiting for the Shortcut", rawText: nil))
        }
    }

    func skip() {
        finish(Outcome(samples: [], error: "skipped", rawText: nil))
    }

    private func finish(_ o: Outcome) {
        let c = cont
        cont = nil
        token = nil
        startedAt = nil
        isWaiting = false
        c?.resume(returning: o)
    }

    // MARK: parsing

    static func parse(_ text: String, endMs: Double) -> [RadioSample] {
        let lines = text.replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.contains("|") }
        var out: [RadioSample] = []
        for (i, line) in lines.enumerated() {
            let f = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard f.count >= 7 else { continue }
            let reconstructed = endMs - Double(lines.count - 1 - i) * 1000
            out.append(RadioSample(ts: parseDate(f[0]) ?? reconstructed, rssi: number(f[1]), noise: number(f[2]),
                                   channel: number(f[3]).map { Int($0) }, txRate: number(f[4]),
                                   rxRate: number(f[5]), bssid: WiFiInfo.normalizeBSSID(f[6]),
                                   standard: f.count > 7 && !f[7].isEmpty ? f[7] : nil,
                                   mac: f.count > 8 && !f[8].isEmpty ? WiFiInfo.normalizeBSSID(f[8]) : nil, raw: line))
        }
        return out
    }

    static func number(_ s: String) -> Double? {
        guard let r = s.range(of: #"-?\d+([.,]\d+)?"#, options: .regularExpression) else { return nil }
        return Double(s[r].replacingOccurrences(of: ",", with: "."))
    }

    static func parseDate(_ s: String) -> Double? {
        let iso = ISO8601DateFormatter()
        if let d = iso.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d.timeIntervalSince1970 * 1000 }
        return nil
    }

    static func summarize(_ samples: [RadioSample]) -> RadioStats {
        let rssi = samples.compactMap { $0.rssi }
        let noise = samples.compactMap { $0.noise }
        let snr = samples.compactMap { s -> Double? in
            guard let r = s.rssi, let n = s.noise else { return nil }
            return r - n
        }
        return RadioStats(samples: samples.count, rssiMedian: Stats.median(rssi), rssiMin: rssi.min(),
                          rssiMax: rssi.max(), noiseMedian: Stats.median(noise), snrMedian: Stats.median(snr),
                          channels: Array(Set(samples.compactMap { $0.channel })).sorted(),
                          standards: Array(Set(samples.compactMap { $0.standard })).sorted(),
                          txRateMedian: Stats.median(samples.compactMap { $0.txRate }),
                          rxRateMedian: Stats.median(samples.compactMap { $0.rxRate }),
                          bssids: Array(Set(samples.compactMap { $0.bssid })).sorted())
    }

    static func rawRecord(_ s: RadioSample) -> [String: Any] {
        ["k": "radio", "ts": Stats.r3(s.ts), "rssi": J(s.rssi), "noise": J(s.noise), "channel": J(s.channel),
         "txRate": J(s.txRate), "rxRate": J(s.rxRate), "bssid": J(s.bssid), "standard": J(s.standard),
         "mac": J(s.mac), "raw": s.raw]
    }
}
