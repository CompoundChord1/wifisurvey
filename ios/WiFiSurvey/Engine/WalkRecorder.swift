import Foundation
import Observation
import UIKit

/// Walk mode: light continuous logging on whatever network the phone is on — either moving through the
/// house (catches roams, drops and stalls in motion) or standing at one spot as a soak (`place` set),
/// which measures how often stalls happen there.
@MainActor
@Observable
final class WalkRecorder {
    var isRunning = false
    var elapsed = 0
    var liveSSID: String?
    var liveBSSID: String?
    var liveLoss = 0.0
    var liveRTT: Double?
    var roams = 0
    var hbFail = 0
    var apLine: String?
    var glitchCount = 0

    @ObservationIgnored var stopRequested = false
    @ObservationIgnored private weak var store: SurveyStore?
    @ObservationIgnored private var surveyId: String?
    @ObservationIgnored private var walkId: String?
    @ObservationIgnored private var helper: HelperClient?
    @ObservationIgnored private var raw: RawLog?

    func run(store: SurveyStore, surveyId: String, place: String? = nil) async {
        guard !isRunning, let survey = store.survey(surveyId) else { return }
        let settings = survey.settings
        let helper = HelperClient(settings)
        let walkId = UUID().uuidString
        let rel = "raw/walk-\(walkId).jsonl"
        let log = RawLog(url: store.fileURL(surveyId, rel))
        self.store = store
        self.surveyId = surveyId
        self.walkId = walkId
        self.helper = helper
        raw = log
        isRunning = true
        stopRequested = false
        elapsed = 0
        roams = 0
        glitchCount = 0
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            isRunning = false
            raw = nil
            self.walkId = nil
        }

        let startMs = Stats.r3(Clock.nowMs())
        let w0 = await WiFiInfo.current(demo: settings.demoMode, demoSSID: settings.ssid(for: "DUAL"))
        let netKey = settings.key(forSSID: w0.ssid)
        let place = place.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        store.update(surveyId) {
            $0.walks.append(Walk(id: walkId, network: netKey, startMs: startMs, endMs: nil, rawFile: rel, summary: nil,
                                 place: place))
        }
        log.write(["k": "leg", "id": walkId, "network": J(netKey), "ssidTarget": J(w0.ssid), "plannedSeconds": 0,
                   "startMs": startMs, "walk": true, "place": J(place)])
        var ip = WiFiInfo.wifiIPv4()
        await helper.mark(["event": "start", "surveyId": surveyId, "legId": walkId, "network": J(netKey),
                           "ssid": J(w0.ssid), "ip": J(ip), "room": place == nil ? "walk" : "soak", "spot": place ?? "walk"])

        let prober = UDPProber(host: settings.helperHost, port: settings.udpPort, legId: walkId, pps: 10,
                               packetBytes: settings.probeBytes)
        let hb = HeartbeatProbe(host: settings.helperHost, port: settings.httpPort)
        let path = PathWatcher()
        path.start { p in
            log.write(["k": "path", "ts": Stats.r3(Clock.nowMs()), "status": "\(p.status)",
                       "wifi": p.usesInterfaceType(.wifi), "cellular": p.usesInterfaceType(.cellular)])
        }
        prober.start()
        hb.start()

        var samples: [WiFiSnapshot] = []
        var udp: [UDPProber.Record] = []
        var prevBSSID: String?
        let t0 = Clock.monoMs()
        var nextWifi = 0.0
        var nextAP = 1000.0
        var nextDrain = 5000.0
        while !stopRequested {
            let el = Clock.monoMs() - t0
            elapsed = Int(el / 1000)
            if el >= nextWifi {
                nextWifi = el + 1000
                let w = await WiFiInfo.current(demo: settings.demoMode, demoSSID: w0.ssid)
                if w.timedOut {
                    log.write(["k": "wifi", "ts": Stats.r3(w.ts), "timeout": true])
                } else {
                    samples.append(w)
                    liveSSID = w.ssid
                    liveBSSID = w.bssid
                    if let b = w.bssid {
                        if let p = prevBSSID, p != b { roams += 1 }
                        prevBSSID = b
                    }
                    log.write(["k": "wifi", "ts": Stats.r3(w.ts), "ssid": J(w.ssid), "bssid": J(w.bssid)])
                }
                if let nowIP = WiFiInfo.wifiIPv4(), nowIP != ip {
                    ip = nowIP
                    await helper.mark(["event": "ip-change", "surveyId": surveyId, "legId": walkId, "ip": nowIP])
                }
            }
            if el >= nextAP, let ipNow = ip {
                nextAP = el + 5000
                Task { [weak self] in
                    guard let rec = await helper.status(ip: ipNow) else { return }
                    var r = rec
                    r["k"] = "ap"
                    r["ts"] = Stats.r3(Clock.nowMs())
                    log.write(r)
                    self?.apLine = MeasurementRunner.describeAP(rec)
                }
            }
            if el >= nextDrain {
                nextDrain = el + 5000
                let d = prober.drain(olderThan: 3000)
                udp += d
                for r in d { log.write(UDPProber.rawRecord(r)) }
                log.flush()
            }
            let l = prober.live()
            liveLoss = l.lossPct
            liveRTT = l.p50
            hbFail = hb.failures
            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        prober.stopSending()
        hb.stopSending()
        try? await Task.sleep(nanoseconds: 2_100_000_000)
        let rest = prober.finish()
        udp += rest
        for r in rest { log.write(UDPProber.rawRecord(r)) }
        let hbRes = hb.finish()
        for r in hbRes.records {
            log.write(["k": "hb", "sent": Stats.r3(r.sentWall), "rtt": J(r.rtt), "err": J(r.err)])
        }
        path.stop()
        let endMs = Stats.r3(Clock.nowMs())
        await helper.mark(["event": "end", "surveyId": surveyId, "legId": walkId, "ip": J(ip)])
        let arrivals = await helper.arrivals(leg: walkId)
        let summary = WalkSummary(udp: UDPProber.summarize(udp, arrivals: arrivals, reconnects: prober.reconnects),
                                  wifi: MeasurementRunner.summarizeWiFi(samples),
                                  heartbeat: HeartbeatProbe.summarize(hbRes))
        log.write(["k": "end", "endMs": endMs, "status": "complete"])
        log.close()
        store.update(surveyId) { s in
            if let i = s.walks.firstIndex(where: { $0.id == walkId }) {
                s.walks[i].endMs = endMs
                s.walks[i].summary = summary
            }
        }
    }

    func glitch() {
        guard let store, let surveyId, let walkId else { return }
        let ts = Stats.r3(Clock.nowMs())
        glitchCount += 1
        raw?.write(["k": "glitch", "ts": ts, "note": ""])
        store.update(surveyId) {
            $0.glitches.append(Glitch(ts: ts, roomId: nil, spotId: nil, measurementId: nil, legId: nil,
                                      walkId: walkId, note: ""))
        }
        if let helper {
            let body: [String: Any] = ["event": "glitch", "surveyId": surveyId, "legId": walkId]
            Task { await helper.mark(body) }
        }
    }
}
