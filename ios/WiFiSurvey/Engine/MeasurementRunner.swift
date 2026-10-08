import Foundation
import Observation
import UIKit

/// Runs one measurement: for each network in the spot's preset, join → settle → measure
/// (UDP echo, gateway ping, heartbeat, DNS, BSSID, AP-side status, speed tests) → Shortcut radio sample.
/// Every leg is written to disk as soon as it finishes.
@MainActor
@Observable
final class MeasurementRunner {
    enum Phase: String {
        case idle = "Ready"
        case joining = "Switching network"
        case waitingManual = "Waiting for you to join"
        case settling = "Settling"
        case measuring = "Measuring"
        case speedDown = "Download test"
        case speedUp = "Upload test"
        case radio = "Reading phone radio (Shortcut)"
        case finishing = "Saving"
        case done = "Done"
    }

    // Live state for the UI
    var isRunning = false
    var phase: Phase = .idle
    var legIndex = 0
    var legCount = 0
    var networkKey = ""
    var targetSSID = ""
    var secondsLeft = 0
    var liveSSID: String?
    var liveBSSID: String?
    var liveIP: String?
    var liveRTT: Double?
    var liveLoss: Double = 0
    var liveSent = 0
    var liveHBFail = 0
    var apLine: String?
    var phoneRSSI: Double?
    var message: String?
    var glitchCount = 0
    var results: [Leg] = []

    @ObservationIgnored var cancelRequested = false
    @ObservationIgnored var skipRequested = false
    @ObservationIgnored private weak var store: SurveyStore?
    @ObservationIgnored private var ctx: Context?
    @ObservationIgnored private var raw: RawLog?
    @ObservationIgnored private var legGlitches: [Double] = []
    @ObservationIgnored private var apRecords: [[String: Any]] = []
    @ObservationIgnored private var downOutcome: ThroughputTest.Outcome?
    @ObservationIgnored private var upOutcome: ThroughputTest.Outcome?
    @ObservationIgnored private var legInterrupted = false

    struct JoinOutcome {
        var info: JoinInfo
        /// False when there is nothing worth measuring: never got on the network, skipped, or the
        /// helper has never answered (it probably isn't running).
        var canMeasure: Bool
    }

    init() {
        // If the app is backgrounded mid-measurement iOS suspends the probes; the gap would look
        // exactly like a Wi-Fi stall. Record it so the leg can be flagged and redone.
        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appStateChanged("background") }
        }
        nc.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.appStateChanged("foreground") }
        }
    }

    private func appStateChanged(_ state: String) {
        // The Shortcut hand-off (.radio) backgrounds the app on purpose; probes are already stopped.
        guard isRunning, [.joining, .waitingManual, .settling, .measuring, .speedDown, .speedUp].contains(phase) else {
            return
        }
        raw?.write(["k": "app", "ts": Stats.r3(Clock.nowMs()), "state": state])
        if state == "background" { legInterrupted = true }
    }

    private struct Context {
        var surveyId: String
        var roomId: String
        var spotId: String
        var measurementId: String
        var legId: String?
        var helper: HelperClient
        var roomName: String
        var spotLabel: String
    }

    // MARK: - Measurement

    func run(store: SurveyStore, location: LocationHelper, ref: SpotRef) async {
        guard !isRunning, let survey = store.survey(ref.surveyId), let room = survey.room(ref.roomId),
              let spot = survey.spot(ref.roomId, ref.spotId) else { return }
        self.store = store
        let settings = survey.settings
        let helper = HelperClient(settings)
        var plan = spot.problem ? settings.presets.problem
            : (spot.kind == .C ? settings.presets.center : settings.presets.grid)
        isRunning = true
        cancelRequested = false
        results = []
        message = nil
        glitchCount = 0
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            isRunning = false
            phase = .done
            ctx = nil
        }

        // First measurement of the survey: have the helper take a "survey-start" config snapshot.
        if !survey.events.contains(where: { $0.type == "survey-start" }) {
            await helper.mark(["event": "survey-start", "surveyId": survey.id, "ip": J(WiFiInfo.wifiIPv4())])
            store.addEvent(survey.id, type: "survey-start", detail: "first measurement")
        }

        // Start with the network we're already on — saves one switch per spot.
        let current = await WiFiInfo.current(demo: settings.demoMode)
        if let key = settings.key(forSSID: current.ssid), let i = plan.firstIndex(where: { $0.network == key }), i > 0 {
            plan.insert(plan.remove(at: i), at: 0)
        }

        let mId = UUID().uuidString
        let m = Measurement(id: mId, startedAt: Date(), endedAt: nil, status: "running",
                            headingDeg: location.headingDeg.map(Stats.r1),
                            headingAccuracyDeg: location.headingAccuracy.map(Stats.r1), legs: [])
        store.update(survey.id) { s in s.withSpot(room.id, spot.id) { $0.measurements.append(m) } }
        ctx = Context(surveyId: survey.id, roomId: room.id, spotId: spot.id, measurementId: mId, legId: nil,
                      helper: helper, roomName: room.name, spotLabel: spot.label)
        legCount = plan.count
        for (i, lp) in plan.enumerated() {
            if cancelRequested { break }
            legIndex = i
            skipRequested = false
            results.append(await runLeg(lp, settings: settings, helper: helper))
        }
        let status = cancelRequested ? "cancelled" : "complete"
        store.update(survey.id) { s in
            s.withMeasurement(room.id, spot.id, mId) {
                $0.status = status
                $0.endedAt = Date()
            }
        }
    }

    private func runLeg(_ lp: LegPlan, settings: SurveySettings, helper: HelperClient) async -> Leg {
        let legId = UUID().uuidString
        let rel = "raw/\(legId).jsonl"
        let target = settings.ssid(for: lp.network)
        var leg = Leg(id: legId, network: lp.network, ssidTarget: target, plannedSeconds: lp.seconds,
                      startMs: Stats.r3(Clock.nowMs()), endMs: nil, status: "running", join: nil, ip: nil,
                      rawFile: rel)
        guard let store, var c = ctx else { return leg }
        let log = RawLog(url: store.fileURL(c.surveyId, rel))
        raw = log
        c.legId = legId
        ctx = c
        networkKey = lp.network
        targetSSID = target
        liveRTT = nil
        liveLoss = 0
        liveSent = 0
        liveHBFail = 0
        apLine = nil
        phoneRSSI = nil
        legGlitches = []
        apRecords = []
        downOutcome = nil
        upOutcome = nil
        legInterrupted = false
        save(leg)
        log.write(["k": "leg", "id": legId, "network": lp.network, "ssidTarget": target,
                   "plannedSeconds": lp.seconds, "startMs": leg.startMs])

        // 1. Join
        phase = .joining
        let joined = await self.join(target: target, settings: settings, helper: helper)
        leg.join = joined.info
        log.write(Self.joinRecord(joined.info))
        if let e = joined.info.error { leg.errors.append(e) }
        if !joined.canMeasure {
            leg.status = skipRequested ? "skipped" : (cancelRequested ? "cancelled" : "failed")
            leg.grade = leg.status == "failed" ? "red" : "none"
            leg.endMs = Stats.r3(Clock.nowMs())
            return close(leg, log)
        }
        var ip = WiFiInfo.wifiIPv4()
        leg.ip = ip
        liveIP = ip
        await helper.mark(markBody("start", lp: lp, ip: ip))

        // 2. Settle
        phase = .settling
        var s = settings.settleSeconds
        while s > 0 && !cancelRequested {
            secondsLeft = s
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            s -= 1
        }

        // 3. Measure
        phase = .measuring
        let prober = UDPProber(host: settings.helperHost, port: settings.udpPort, legId: legId,
                               pps: settings.probePps, packetBytes: settings.probeBytes)
        let pinger = Pinger(target: settings.gateway, pps: settings.pingPps)
        let hb = HeartbeatProbe(host: settings.helperHost, port: settings.httpPort)
        let dns = DNSProbe.systemServer().map { DNSProbe(server: $0, name: settings.dnsName) }
        let path = PathWatcher()
        path.start { p in
            log.write(["k": "path", "ts": Stats.r3(Clock.nowMs()), "status": "\(p.status)",
                       "wifi": p.usesInterfaceType(.wifi), "cellular": p.usesInterfaceType(.cellular)])
        }
        prober.start()
        pinger.start()
        hb.start()
        dns?.start()
        if let e = pinger.error { leg.errors.append(e) }

        var wifiSamples: [WiFiSnapshot] = []
        var tputSkipped: String?
        var tputTask: Task<Void, Never>?
        var tputStarted = false
        let t0 = Clock.monoMs()
        let durMs = Double(lp.seconds) * 1000
        var nextWifi = 0.0
        var nextAP = 1000.0
        while !cancelRequested {
            let el = Clock.monoMs() - t0
            if el >= durMs { break }
            secondsLeft = max(0, Int(((durMs - el) / 1000).rounded(.up)))
            if el >= nextWifi {
                nextWifi = el + 1000
                let w = await WiFiInfo.current(demo: settings.demoMode, demoSSID: target)
                if w.timedOut {
                    log.write(["k": "wifi", "ts": Stats.r3(w.ts), "timeout": true])
                } else {
                    wifiSamples.append(w)
                    liveSSID = w.ssid
                    liveBSSID = w.bssid
                    log.write(["k": "wifi", "ts": Stats.r3(w.ts), "ssid": J(w.ssid), "bssid": J(w.bssid)])
                }
                if let nowIP = WiFiInfo.wifiIPv4(), nowIP != ip {
                    ip = nowIP
                    leg.ip = nowIP
                    liveIP = nowIP
                    await helper.mark(markBody("ip-change", lp: lp, ip: nowIP))
                }
                if Int(el / 1000) % 5 == 4 { log.flush() }   // keep partial data if the app dies mid-leg
            }
            if el >= nextAP, let ipNow = ip {
                nextAP = el + 5000
                Task { [weak self] in
                    guard let rec = await helper.status(ip: ipNow) else { return }
                    var r = rec
                    r["k"] = "ap"
                    r["ts"] = Stats.r3(Clock.nowMs())
                    log.write(r)
                    self?.apRecords.append(rec)
                    self?.apLine = Self.describeAP(rec)
                }
            }
            if !tputStarted && el >= Double(settings.downloadAt) * 1000 {
                tputStarted = true
                if lp.seconds < settings.downloadAt + settings.throughputSeconds {
                    tputSkipped = "leg too short"
                } else if settings.skipThroughputMinutes.contains(Calendar.current.component(.minute, from: Date())) {
                    tputSkipped = "quiet-window"
                } else {
                    tputTask = Task { [weak self] in
                        guard let self else { return }
                        self.phase = .speedDown
                        prober.phase = "down"
                        self.downOutcome = await ThroughputTest.run(
                            host: settings.helperHost, port: settings.tcpPort, direction: "down",
                            seconds: settings.throughputSeconds, legId: legId)
                        prober.phase = "idle"
                        self.phase = .measuring
                        guard lp.seconds >= settings.uploadAt + settings.throughputSeconds - 1 else { return }
                        while !self.cancelRequested && Clock.monoMs() - t0 < Double(settings.uploadAt) * 1000 {
                            try? await Task.sleep(nanoseconds: 200_000_000)
                        }
                        if self.cancelRequested { return }
                        self.phase = .speedUp
                        prober.phase = "up"
                        self.upOutcome = await ThroughputTest.run(
                            host: settings.helperHost, port: settings.tcpPort, direction: "up",
                            seconds: settings.throughputSeconds, legId: legId)
                        prober.phase = "idle"
                        self.phase = .measuring
                    }
                }
            }
            let l = prober.live()
            liveSent = l.sent
            liveLoss = l.lossPct
            liveRTT = l.p50
            liveHBFail = hb.failures
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        await tputTask?.value

        phase = .finishing
        secondsLeft = 0
        prober.stopSending()
        pinger.stopSending()
        hb.stopSending()
        dns?.stopSending()
        try? await Task.sleep(nanoseconds: 2_100_000_000)  // late echoes + the last heartbeat
        let udpRecs = prober.finish()
        let pingRecs = pinger.finish()
        let hbRes = hb.finish()
        let dnsRecs = dns?.finish() ?? []
        path.stop()
        leg.endMs = Stats.r3(Clock.nowMs())
        await helper.mark(markBody("end", lp: lp, ip: ip))
        let arrivals = await helper.arrivals(leg: legId)
        if arrivals == nil { leg.errors.append("could not fetch arrivals from the server (loss direction unknown)") }

        for r in udpRecs { log.write(UDPProber.rawRecord(r)) }
        for r in pingRecs { log.write(["k": "ping", "seq": r.seq, "sent": Stats.r3(r.sentWall), "rtt": J(r.rtt)]) }
        for r in hbRes.records {
            log.write(["k": "hb", "sent": Stats.r3(r.sentWall), "rtt": J(r.rtt), "err": J(r.err)])
        }
        for r in dnsRecs {
            log.write(["k": "dns", "sent": Stats.r3(r.sentWall), "rtt": J(r.rtt), "rcode": J(r.rcode),
                       "err": J(r.err), "server": dns?.server ?? ""])
        }
        if let d = downOutcome { log.write(d.raw) }
        if let u = upOutcome { log.write(u.raw) }

        var sum = LegSummary()
        sum.udp = UDPProber.summarize(udpRecs, arrivals: arrivals, reconnects: prober.reconnects)
        sum.ping = pinger.error == nil ? Pinger.summarize(pingRecs, target: settings.gateway) : nil
        sum.heartbeat = HeartbeatProbe.summarize(hbRes)
        sum.dns = dns.map { DNSProbe.summarize(dnsRecs, server: $0.server) }
        sum.wifi = Self.summarizeWiFi(wifiSamples)
        sum.throughput = ThroughputStats(down: downOutcome?.result, up: upOutcome?.result, skipped: tputSkipped)
        sum.apSide = Self.summarizeAP(apRecords)

        // 4. Phone-side radio via the Shortcut (the only way to read RSSI/noise/channel on iOS)
        if settings.useShortcut && !cancelRequested {
            phase = .radio
            let res = await ShortcutBridge.shared.run(name: settings.shortcutName)
            leg.radio = res.samples
            for sample in res.samples { log.write(ShortcutBridge.rawRecord(sample)) }
            if let e = res.error { leg.errors.append(e) }
            if !res.samples.isEmpty {
                sum.radioStats = ShortcutBridge.summarize(res.samples)
                phoneRSSI = sum.radioStats?.rssiMedian
            }
            if let mac = res.samples.compactMap({ $0.mac }).first {
                var body = markBody("phone-mac", lp: lp, ip: ip)
                body["mac"] = mac
                await helper.mark(body)
            }
        }

        leg.summary = sum
        leg.status = cancelRequested ? "cancelled" : "complete"
        leg.glitchMs = legGlitches.map(Stats.r3)
        leg.grade = Self.grade(sum)
        if legInterrupted {
            leg.interrupted = true
            leg.grade = "none"
            leg.errors.append("The app left the foreground during this measurement, so gaps in the data are not Wi-Fi stalls. Measure this spot again.")
        }
        return close(leg, log)
    }

    private func close(_ leg: Leg, _ log: RawLog) -> Leg {
        log.write(["k": "end", "endMs": leg.endMs ?? Stats.r3(Clock.nowMs()), "status": leg.status])
        log.close()
        raw = nil
        save(leg)
        return leg
    }

    private func save(_ leg: Leg) {
        guard let store, let c = ctx else { return }
        store.update(c.surveyId) { s in
            s.withMeasurement(c.roomId, c.spotId, c.measurementId) { m in
                if let i = m.legs.firstIndex(where: { $0.id == leg.id }) { m.legs[i] = leg } else { m.legs.append(leg) }
            }
        }
    }

    // MARK: - Joining a survey network

    /// Switch to `target`, wait for an IP, then for the server to answer.
    ///
    /// If the phone is on the network but the server doesn't answer within `helperWaitMs`, the leg is
    /// still measured — at a bad spot that outage *is* the finding — provided the helper answered
    /// within the last 20 minutes (otherwise it probably isn't running, and we stop with a clear error).
    /// Falls back to asking the user to join by hand in Settings if iOS won't switch.
    func join(target: String, settings: SurveySettings, helper: HelperClient) async -> JoinOutcome {
        let helperWaitMs = 10_000.0
        let t0 = Clock.nowMs()
        var info = JoinInfo(method: settings.demoMode ? "demo" : "hotspot", requestMs: Stats.r3(t0))
        if settings.demoMode {
            liveSSID = target
            info.ssidSeenMs = Stats.r3(t0)
            info.ipMs = Stats.r3(t0)
        } else {
            let cur = await WiFiInfo.current()
            liveSSID = cur.ssid
            liveBSSID = cur.bssid
            if cur.ssid == target {
                info.method = "already"
                info.ssidSeenMs = Stats.r3(Clock.nowMs())
            } else {
                message = "Joining \(target)…"
                let pass = Keychain.get(Keychain.passphraseKey) ?? ""
                if pass.isEmpty {
                    info.error = "No passphrase saved for the survey networks"
                } else if let err = await NetworkSwitcher.apply(ssid: target, passphrase: pass) {
                    info.error = err
                }
            }
        }
        let autoDeadline = Clock.monoMs() + Double(settings.joinTimeoutSeconds) * 1000
        var manualDeadline: Double?
        var helperDeadline: Double?
        var onNetwork = settings.demoMode
        while !cancelRequested && !skipRequested {
            if !settings.demoMode {
                let w = await WiFiInfo.current()
                if !w.timedOut {
                    liveSSID = w.ssid
                    liveBSSID = w.bssid
                    onNetwork = w.ssid == target
                }
                if onNetwork {
                    if info.ssidSeenMs == nil { info.ssidSeenMs = Stats.r3(Clock.nowMs()) }
                    if info.ipMs == nil, WiFiInfo.wifiIPv4() != nil { info.ipMs = Stats.r3(Clock.nowMs()) }
                }
            }
            let now = Clock.monoMs()
            if onNetwork && info.ipMs != nil {
                if helperDeadline == nil { helperDeadline = now + helperWaitMs }
                if await helper.health(timeout: 1.5) != nil {
                    info.helperOkMs = Stats.r3(Clock.nowMs())
                    break
                }
                if let hd = helperDeadline, Clock.monoMs() > hd { break }
            } else if manualDeadline == nil && now > autoDeadline {
                phase = .waitingManual
                info.method = "manual"
                message = "Couldn't switch automatically. Open Settings › Wi-Fi, join \(target), then come back here — or tap Skip."
                manualDeadline = now + 180_000
            } else if let md = manualDeadline, now > md {
                break
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
        message = nil
        if let ok = info.helperOkMs {
            info.totalMs = Stats.r3(ok - t0)
            info.error = nil
            return JoinOutcome(info: info, canMeasure: true)
        }
        if skipRequested || cancelRequested {
            info.error = skipRequested ? "skipped" : "cancelled"
            return JoinOutcome(info: info, canMeasure: false)
        }
        if onNetwork && info.ipMs != nil {
            if HelperReachability.okWithin(20 * 60) {
                info.error = "helper unreachable at the start of this leg — measured anyway"
                return JoinOutcome(info: info, canMeasure: true)
            }
            info.error = "Can't reach the helper at \(settings.helperHost):\(settings.httpPort). Is it running (server/README.md)? If it is, this spot may be out of its reach: run Pre-flight from a spot that works, then measure here again."
            return JoinOutcome(info: info, canMeasure: false)
        }
        if info.error == nil { info.error = "never joined \(target)" }
        return JoinOutcome(info: info, canMeasure: false)
    }

    // MARK: - Glitch button

    func glitch(note: String = "") {
        guard let store, let c = ctx else { return }
        let ts = Clock.nowMs()
        glitchCount += 1
        legGlitches.append(ts)
        raw?.write(["k": "glitch", "ts": Stats.r3(ts), "note": note])
        store.update(c.surveyId) {
            $0.glitches.append(Glitch(ts: Stats.r3(ts), roomId: c.roomId, spotId: c.spotId,
                                      measurementId: c.measurementId, legId: c.legId, walkId: nil, note: note))
        }
        let body: [String: Any] = ["event": "glitch", "surveyId": c.surveyId, "legId": J(c.legId), "note": note,
                                   "ip": J(liveIP)]
        let helper = c.helper
        Task { await helper.mark(body) }
    }

    // MARK: - Helpers

    private func markBody(_ event: String, lp: LegPlan, ip: String?) -> [String: Any] {
        guard let c = ctx else { return ["event": event] }
        return ["event": event, "surveyId": c.surveyId, "measurementId": c.measurementId, "legId": J(c.legId),
                "network": lp.network, "ssid": targetSSID, "bssid": J(liveBSSID), "ip": J(ip),
                "room": c.roomName, "spot": c.spotLabel]
    }

    static func joinRecord(_ j: JoinInfo) -> [String: Any] {
        ["k": "join", "method": j.method, "requestMs": j.requestMs, "ssidSeenMs": J(j.ssidSeenMs), "ipMs": J(j.ipMs),
         "helperOkMs": J(j.helperOkMs), "totalMs": J(j.totalMs), "error": J(j.error)]
    }

    /// Field grade from the *idle* probes only (those sent outside the speed tests). A 5 s upload on a
    /// slow link queues packets in the phone's own driver (bufferbloat): latency and loss rise with the
    /// load, not with any stall. Mixing those probes in would paint every weak spot red for the wrong
    /// reason. The analyzer reports idle and loaded separately.
    static func grade(_ s: LegSummary) -> String {
        guard let u = s.udp, u.sent > 0 else { return "none" }
        let idle = u.idle.sent > 0 ? u.idle : LossPart(sent: u.sent, received: u.received, lossPct: u.lossPct, rtt: u.rtt)
        let p95 = idle.rtt?.p95 ?? 9999
        let hbFail = s.heartbeat?.failed ?? 0
        if idle.lossPct >= 3 || p95 >= 100 || hbFail >= 2 { return "red" }
        if idle.lossPct < 1 && p95 < 30 && hbFail == 0 { return "green" }
        return "yellow"
    }

    static func summarizeWiFi(_ samples: [WiFiSnapshot]) -> WiFiStats {
        var ssids: [String] = []
        var seconds: [String: Double] = [:]
        var roams = 0
        var noWifi = 0.0
        var prev: String?
        for w in samples {
            if let s = w.ssid, !ssids.contains(s) { ssids.append(s) }
            if let b = w.bssid {
                seconds[b, default: 0] += 1
                if let p = prev, p != b { roams += 1 }
                prev = b
            } else {
                noWifi += 1
            }
        }
        let list = seconds.map { BSSIDTime(bssid: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }
        return WiFiStats(ssids: ssids, bssids: list, roams: roams, noWifiSeconds: noWifi)
    }

    static func summarizeAP(_ recs: [[String: Any]]) -> APSideStats? {
        guard let last = recs.last else { return nil }
        func nums(_ k: String) -> [Double] { recs.compactMap { ($0[k] as? NSNumber)?.doubleValue } }
        let names = recs.compactMap { $0["apName"] as? String }
        let apName = Dictionary(grouping: names, by: { $0 }).max { $0.value.count < $1.value.count }?.key
        return APSideStats(samples: recs.count, apName: apName, apMac: last["apMac"] as? String,
                           radioId: (last["radioId"] as? NSNumber)?.intValue, band: last["band"] as? String,
                           channel: (last["channel"] as? NSNumber)?.intValue, rssiMedian: Stats.median(nums("rssi")),
                           rssiMin: nums("rssi").min(), snrMedian: Stats.median(nums("snr")),
                           txRateMedian: Stats.median(nums("txRate")), rxRateMedian: Stats.median(nums("rxRate")))
    }

    static func describeAP(_ c: [String: Any]) -> String {
        let name = (c["apName"] as? String) ?? (c["apMac"] as? String) ?? "AP ?"
        let band = (c["band"] as? String) ?? ""
        let ch = (c["channel"] as? NSNumber).map { "ch \($0.intValue)" } ?? ""
        let rssi = (c["rssi"] as? NSNumber).map { "AP hears you at \($0.intValue) dBm" } ?? ""
        return [name, band, ch, rssi].filter { !$0.isEmpty }.joined(separator: " · ")
    }
}
