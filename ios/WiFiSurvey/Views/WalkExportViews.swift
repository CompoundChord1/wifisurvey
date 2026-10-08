import SwiftUI

struct WalkView: View {
    let surveyId: String
    @Environment(SurveyStore.self) private var store
    @Environment(WalkRecorder.self) private var walker
    @Environment(MeasurementRunner.self) private var runner
    @State private var joinStatus: String?
    @State private var joining = false
    @State private var place = ""

    var body: some View {
        if let s = store.survey(surveyId) {
            ScrollView {
                VStack(spacing: 16) {
                    Text("Two ways to use this. Walk: move through every floor at a normal pace for about 10 minutes, pausing where things usually go wrong. Soak: stand still at one spot for 20 minutes and type where you are. Either way the phone logs which AP it's on, every roam, and whether traffic stalls. Keep the app on screen.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    if walker.isRunning {
                        running
                    } else {
                        HStack {
                            ForEach(["DUAL", "5G", "2G"], id: \.self) { key in
                                let ssid = s.settings.ssid(for: key)
                                Button(key) {
                                    Task {
                                        joining = true
                                        joinStatus = "Joining \(ssid)…"
                                        runner.cancelRequested = false
                                        runner.skipRequested = false
                                        let info = await runner.join(target: ssid, settings: s.settings, helper: HelperClient(s.settings)).info
                                        joinStatus = info.helperOkMs != nil ? "On \(ssid)" : "Join failed: \(info.error ?? "?")"
                                        joining = false
                                    }
                                }
                                .buttonStyle(.bordered)
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .disabled(joining)
                        Text(joinStatus ?? "Join a survey network first (SURVEY-DUAL is where the stalls happen).")
                            .font(.caption).foregroundStyle(.secondary)
                        TextField("Soak: where are you? (leave empty for a walk)", text: $place)
                            .textFieldStyle(.roundedBorder)
                        Button {
                            Task { await walker.run(store: store, surveyId: surveyId, place: place) }
                        } label: {
                            Label(place.trimmingCharacters(in: .whitespaces).isEmpty ? "Start walk" : "Start soak",
                                  systemImage: place.trimmingCharacters(in: .whitespaces).isEmpty ? "figure.walk" : "figure.stand")
                                .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    if !s.walks.isEmpty {
                        GroupBox("Earlier walks") {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(s.walks) { WalkRow(walk: $0) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Walk / soak")
        }
    }

    private var running: some View {
        VStack(spacing: 14) {
            Text(Fmt.clock(walker.elapsed)).font(.system(size: 60, weight: .bold, design: .rounded)).monospacedDigit()
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    InfoRow(label: "On", value: walker.liveSSID ?? "–")
                    InfoRow(label: "BSSID", value: walker.liveBSSID ?? "–")
                    InfoRow(label: "AP view", value: walker.apLine ?? "waiting for the server…")
                }
            }
            HStack(spacing: 10) {
                StatTile(label: "Latency", value: Fmt.ms(walker.liveRTT))
                StatTile(label: "Loss", value: Fmt.pct(walker.liveLoss))
                StatTile(label: "Roams", value: "\(walker.roams)")
                StatTile(label: "Stalls", value: "\(walker.hbFail)")
            }
            Button { walker.glitch() } label: {
                Text("GLITCH!").font(.title.bold()).frame(maxWidth: .infinity).padding(.vertical, 20)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            if walker.glitchCount > 0 { Text("\(walker.glitchCount) marked").font(.caption) }
            Button("Stop") { walker.stopRequested = true }.buttonStyle(.bordered)
        }
    }
}

struct ExportView: View {
    let surveyId: String
    @Environment(SurveyStore.self) private var store
    @State private var finishing = false
    @State private var confirmFinish = false
    @State private var building = false
    @State private var result: Exporter.Result?
    @State private var errorText: String?
    @State private var uploading = false
    @State private var uploadStatus: String?
    @State private var removedNetworks = false

    var body: some View {
        if let s = store.survey(surveyId) {
            List {
                Section {
                    if let done = s.finishedAt {
                        LabeledContent("Finished", value: done.formatted(date: .abbreviated, time: .shortened))
                    } else {
                        Button(finishing ? "Finishing…" : "Finish survey") { confirmFinish = true }
                            .disabled(finishing)
                    }
                } footer: {
                    Text("Finishing asks the server for a closing Omada config snapshot. You can still measure and export afterwards.")
                }
                Section {
                    Button(building ? "Building…" : "Build export") { Task { await build(s) } }
                        .disabled(building)
                    if let r = result {
                        ForEach(r.notes, id: \.self) { Text($0).font(.caption) }
                        ShareLink(item: r.zipURL) {
                            Label("Share / AirDrop to the Mac", systemImage: "square.and.arrow.up")
                        }
                        Button(uploading ? "Uploading…" : "Also upload to the server") { Task { await upload(s, r) } }
                            .disabled(uploading)
                        if let u = uploadStatus { Text(u).font(.caption) }
                    }
                    if let e = errorText { Text(e).font(.caption).foregroundStyle(.red) }
                } header: {
                    Text("Export")
                } footer: {
                    Text("AirDrop lands in ~/Downloads on the Mac. Then run analysis/analyze.py on it (docs/ANALYSIS-PLAYBOOK.md).")
                }
                Section {
                    Button("Remove survey networks from this iPhone", role: .destructive) {
                        NetworkSwitcher.remove(s.settings.networks.map { $0.ssid })
                        removedNetworks = true
                    }
                    if removedNetworks {
                        Text("Removed. Turn Auto-Join back on for your home networks in Settings › Wi-Fi.")
                            .font(.caption)
                    }
                } header: {
                    Text("When you're completely done")
                }
            }
            .navigationTitle("Finish & export")
            .confirmationDialog("Finish this survey?", isPresented: $confirmFinish, titleVisibility: .visible) {
                Button("Finish survey") { Task { await finish(s) } }
            }
        }
    }

    private func finish(_ s: Survey) async {
        finishing = true
        await HelperClient(s.settings).mark(["event": "survey-end", "surveyId": s.id, "ip": J(WiFiInfo.wifiIPv4())])
        store.update(s.id) { $0.finishedAt = Date() }
        store.addEvent(s.id, type: "survey-end", detail: "finished")
        try? await Task.sleep(nanoseconds: 8_000_000_000)  // let the closing snapshot land before exporting
        finishing = false
    }

    private func build(_ s: Survey) async {
        building = true
        errorText = nil
        result = nil
        uploadStatus = nil
        do {
            result = try await Exporter.build(store: store, surveyId: s.id, includeServer: true)
            store.addEvent(s.id, type: "export", detail: result?.zipURL.lastPathComponent ?? "")
        } catch {
            errorText = error.localizedDescription
        }
        building = false
    }

    private func upload(_ s: Survey, _ r: Exporter.Result) async {
        uploading = true
        switch await HelperClient(s.settings).upload(fileURL: r.zipURL, name: r.zipURL.lastPathComponent) {
        case .success(let path): uploadStatus = "Saved on the server: \(path)"
        case .failure(let e): uploadStatus = "Upload failed: \(e.localizedDescription)"
        }
        uploading = false
    }
}
