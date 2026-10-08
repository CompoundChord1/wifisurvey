import SwiftUI

/// Everything that must work before walking the house: permissions, helper + Omada collector,
/// DNS/gateway, joining each survey network, and the phone-radio Shortcut.
struct PreflightView: View {
    let surveyId: String
    @Environment(SurveyStore.self) private var store
    @Environment(LocationHelper.self) private var location
    @Environment(MeasurementRunner.self) private var runner
    @State private var wifi: WiFiSnapshot?
    @State private var health: HelperHealth?
    @State private var checked = false
    @State private var dnsServer: String?
    @State private var ping: (ok: Int, sent: Int, median: Double?)?
    @State private var joinResults: [String: (ok: Bool, text: String)] = [:]
    @State private var joining = false
    @State private var shortcut: (ok: Bool, text: String)?
    @State private var runningShortcut = false

    var body: some View {
        if let s = store.survey(surveyId) {
            List {
                permissions(s)
                helperSection(s)
                networksSection(s)
                shortcutSection(s)
                Section {
                    Button("Re-check") { Task { await refresh(s) } }
                }
            }
            .navigationTitle("Pre-flight")
            .task { await refresh(s) }
        }
    }

    private func permissions(_ s: Survey) -> some View {
        Section("1 · This iPhone") {
            CheckRow(ok: location.authorized && location.precise, title: "Location (precise)",
                     detail: location.authorized ? (location.precise ? "Allowed" : "Turn on Precise Location in Settings")
                         : "iOS needs it to show the network name / BSSID") {
                if !location.authorized { Button("Allow") { location.request() }.buttonStyle(.bordered) }
            }
            CheckRow(ok: wifi?.ssid != nil, title: "Wi-Fi info readable",
                     detail: wifi.map { "\($0.ssid ?? "no network name") · \($0.bssid ?? "no BSSID")" } ?? "…")
            CheckRow(ok: !(Keychain.get(Keychain.passphraseKey) ?? "").isEmpty, title: "Survey passphrase saved",
                     detail: "Kept in the Keychain")
        }
    }

    private func helperSection(_ s: Survey) -> some View {
        Section {
            CheckRow(ok: health?.ok == true, title: "Helper reachable",
                     detail: health.map { "v\($0.version ?? "?") at \(s.settings.helperHost)" }
                         ?? (checked ? "No answer from \(s.settings.helperHost):\(String(s.settings.httpPort))" : "Checking…"))
            CheckRow(ok: health?.collector?.state == "ok", title: "Omada collector", detail: collectorDetail)
            CheckRow(ok: dnsServer != nil, title: "DNS server", detail: dnsServer ?? (checked ? "not found" : "…"))
            CheckRow(ok: ping.map { $0.sent > 0 && $0.ok == $0.sent } ?? false, title: "Gateway ping \(s.settings.gateway)",
                     detail: ping.map { "\($0.ok)/\($0.sent) replies · median \(Fmt.ms($0.median))" } ?? "…")
        } header: {
            Text("2 · Helper & network")
        } footer: {
            if health == nil && checked {
                Text("Start the helper on your server (server/README.md) and allow Local Network access if iOS asked.")
            }
        }
    }

    private func networksSection(_ s: Survey) -> some View {
        Section {
            ForEach(s.settings.networks) { n in
                CheckRow(ok: joinResults[n.key]?.ok ?? false, title: n.ssid,
                         detail: joinResults[n.key]?.text ?? "not tested")
            }
            if joining, let m = runner.message {
                Text(m).font(.caption).foregroundStyle(.orange)
                Button("Skip this one") { runner.skipRequested = true }
            }
            Button(joining ? "Testing…" : "Test joining each network") { Task { await testJoins(s) } }
                .disabled(joining)
        } header: {
            Text("3 · Survey networks")
        } footer: {
            Text("iOS may ask you to confirm each join. This also tells us how long a switch takes.")
        }
    }

    private func shortcutSection(_ s: Survey) -> some View {
        Section {
            CheckRow(ok: shortcut?.ok ?? false, title: s.settings.shortcutName,
                     detail: shortcut?.text ?? (s.settings.useShortcut ? "not tested" : "turned off for this survey"))
            Button(runningShortcut ? "Running…" : "Run the Shortcut once") { Task { await testShortcut(s) } }
                .disabled(runningShortcut || !s.settings.useShortcut)
        } header: {
            Text("4 · Phone radio Shortcut")
        } footer: {
            Text("Build it first (docs/SHORTCUT.md). The Shortcuts app opens, takes ~10 readings, and comes back here.")
        }
    }

    private var collectorDetail: String {
        guard let c = health?.collector else { return checked ? "unknown" : "…" }
        switch c.state {
        case "ok": return "Logged in\(c.site.map { " · site \($0)" } ?? "") · \(c.snapshots ?? 0) config snapshots"
        case "disabled": return "Off: \(c.error ?? "")"
        default: return "\(c.state ?? "?"): \(c.error ?? "")"
        }
    }

    private func refresh(_ s: Survey) async {
        if location.status == .notDetermined { location.request() }
        wifi = await WiFiInfo.current(demo: s.settings.demoMode, demoSSID: "demo")
        health = await HelperClient(s.settings).health(timeout: 3)
        checked = true
        dnsServer = DNSProbe.systemServer()
        let p = Pinger(target: s.settings.gateway, pps: 5)
        p.start()
        try? await Task.sleep(nanoseconds: 1_100_000_000)
        p.stopSending()
        try? await Task.sleep(nanoseconds: 600_000_000)
        let recs = p.finish()
        let rtts = recs.compactMap { $0.rtt }
        ping = (rtts.count, recs.count, Stats.median(rtts))
        let summary = "helper=\(health?.ok == true) collector=\(health?.collector?.state ?? "-") ssid=\(wifi?.ssid ?? "-") dns=\(dnsServer ?? "-") ping=\(rtts.count)/\(recs.count)"
        store.addEvent(surveyId, type: "preflight", detail: summary)
    }

    private func testJoins(_ s: Survey) async {
        joining = true
        runner.cancelRequested = false
        let helper = HelperClient(s.settings)
        for n in s.settings.networks {
            runner.skipRequested = false
            joinResults[n.key] = (false, "joining…")
            let info = await runner.join(target: n.ssid, settings: s.settings, helper: helper).info
            if info.helperOkMs != nil {
                joinResults[n.key] = (true, "OK · \(Fmt.ms(info.totalMs)) (\(info.method))")
            } else {
                joinResults[n.key] = (false, "Failed: \(info.error ?? "unknown")")
            }
        }
        let detail = s.settings.networks.map { "\($0.key)=\(joinResults[$0.key]?.text ?? "-")" }.joined(separator: "; ")
        store.addEvent(surveyId, type: "preflight", detail: "joins: \(detail)")
        joining = false
    }

    private func testShortcut(_ s: Survey) async {
        runningShortcut = true
        let r = await ShortcutBridge.shared.run(name: s.settings.shortcutName)
        if r.samples.isEmpty {
            shortcut = (false, r.error ?? "no samples")
        } else {
            let st = ShortcutBridge.summarize(r.samples)
            shortcut = (true, "OK · \(r.samples.count) samples · RSSI \(Fmt.dbm(st.rssiMedian)) · noise \(Fmt.dbm(st.noiseMedian)) · ch \(st.channels.map(String.init).joined(separator: ","))")
        }
        store.addEvent(surveyId, type: "preflight", detail: "shortcut: \(shortcut?.text ?? "-")")
        runningShortcut = false
    }
}
