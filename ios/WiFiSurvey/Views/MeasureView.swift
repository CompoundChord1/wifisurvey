import SwiftUI

/// Full-screen while a spot is being measured: countdown, what the phone is connected to,
/// live latency/loss, the Glitch! button; then the per-network results.
struct MeasureView: View {
    let ref: SpotRef
    @Environment(SurveyStore.self) private var store
    @Environment(MeasurementRunner.self) private var runner
    @Environment(LocationHelper.self) private var location
    @Environment(\.dismiss) private var dismiss
    @State private var started = false
    @State private var finished = false
    @State private var confirmCancel = false

    var body: some View {
        let survey = store.survey(ref.surveyId)
        let room = survey?.room(ref.roomId)
        let spot = survey?.spot(ref.roomId, ref.spotId)
        NavigationStack {
            Group {
                if finished { results } else { live }
            }
            .navigationTitle("\(room?.name ?? "") · \(spot.map { $0.kind == .custom ? $0.label : $0.kind.title } ?? "")")
            .navigationBarTitleDisplayMode(.inline)
        }
        .interactiveDismissDisabled(!finished)
        .onAppear {
            guard !started else { return }
            started = true
            Task {
                await runner.run(store: store, location: location, ref: ref)
                finished = true
            }
        }
    }

    private var countingDown: Bool {
        [.settling, .measuring, .speedDown, .speedUp].contains(runner.phase)
    }

    private var live: some View {
        ScrollView {
            VStack(spacing: 14) {
                Text(runner.legCount > 0
                     ? "Network \(runner.legIndex + 1) of \(runner.legCount): \(runner.networkKey)"
                     : "Starting…")
                    .font(.headline)
                Text(runner.phase.rawValue).font(.subheadline).foregroundStyle(.secondary)
                Text("\(runner.secondsLeft)")
                    .font(.system(size: 76, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .opacity(countingDown ? 1 : 0.2)
                if let m = runner.message {
                    Text(m).font(.callout).multilineTextAlignment(.center).padding()
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.15)))
                }
                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        InfoRow(label: "Target", value: runner.targetSSID)
                        InfoRow(label: "On", value: runner.liveSSID ?? "–")
                        InfoRow(label: "BSSID", value: runner.liveBSSID ?? "–")
                        InfoRow(label: "AP view", value: runner.apLine ?? "waiting for the server…")
                        InfoRow(label: "Phone RSSI", value: Fmt.dbm(runner.phoneRSSI))
                    }
                }
                HStack(spacing: 10) {
                    StatTile(label: "Latency", value: Fmt.ms(runner.liveRTT))
                    StatTile(label: "Loss", value: Fmt.pct(runner.liveLoss))
                    StatTile(label: "Stalls", value: "\(runner.liveHBFail)")
                }
                if runner.phase == .waitingManual || runner.phase == .joining {
                    Button("Skip this network") { runner.skipRequested = true }.buttonStyle(.bordered)
                }
                if runner.phase == .radio {
                    Button("Skip phone radio sample") { ShortcutBridge.shared.skip() }.buttonStyle(.bordered)
                }
                Button { runner.glitch() } label: {
                    Text("GLITCH!").font(.title.bold()).frame(maxWidth: .infinity).padding(.vertical, 20)
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                Text(runner.glitchCount > 0 ? "\(runner.glitchCount) marked" : "Tap whenever things feel stuck.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Cancel measurement", role: .destructive) { confirmCancel = true }
                    .padding(.top, 8)
            }
            .padding()
        }
        .confirmationDialog("Stop this measurement?", isPresented: $confirmCancel, titleVisibility: .visible) {
            Button("Stop measurement", role: .destructive) { runner.cancelRequested = true }
        }
    }

    private var results: some View {
        List {
            ForEach(runner.results) { LegResultView(leg: $0) }
            Section {
                Button {
                    dismiss()
                } label: {
                    Text("Done").font(.headline).frame(maxWidth: .infinity)
                }
            }
        }
    }
}

struct SpotDetailView: View {
    let ref: SpotRef
    @Environment(SurveyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var measuring: SpotRef?
    @State private var confirmDelete = false
    @State private var symptom = ""

    var body: some View {
        if let spot = store.survey(ref.surveyId)?.spot(ref.roomId, ref.spotId) {
            List {
                Section {
                    Button { measuring = ref } label: {
                        Label(spot.latest == nil ? "Measure" : "Measure again", systemImage: "play.circle.fill")
                    }
                    Toggle("Problem spot", isOn: Binding(
                        get: { spot.problem },
                        set: { v in store.update(ref.surveyId) { $0.withSpot(ref.roomId, ref.spotId) { $0.problem = v } } }))
                    if spot.problem {
                        TextField("What goes wrong here?", text: $symptom)
                            .onSubmit(saveSymptom)
                    }
                }
                ForEach(Array(spot.measurements.reversed())) { m in
                    Section {
                        Text(header(m)).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(m.legs) { LegResultView(leg: $0) }
                }
                Section {
                    Button("Delete this spot", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle(spot.kind == .custom ? spot.label : spot.kind.title)
            .onAppear { symptom = spot.symptom }
            .onDisappear(perform: saveSymptom)
            .fullScreenCover(item: $measuring) { MeasureView(ref: $0) }
            .confirmationDialog("Delete this spot and its measurements?", isPresented: $confirmDelete,
                                titleVisibility: .visible) {
                Button("Delete spot", role: .destructive) {
                    store.update(ref.surveyId) { $0.withRoom(ref.roomId) { $0.spots.removeAll { $0.id == ref.spotId } } }
                    dismiss()
                }
            }
        } else {
            ContentUnavailableView("Spot not found", systemImage: "questionmark")
        }
    }

    private func header(_ m: Measurement) -> String {
        var s = "\(m.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(m.status)"
        if let h = m.headingDeg { s += String(format: " · facing %.0f°", h) }
        return s
    }

    private func saveSymptom() {
        let text = symptom
        guard store.survey(ref.surveyId)?.spot(ref.roomId, ref.spotId)?.symptom != text else { return }
        store.update(ref.surveyId) { $0.withSpot(ref.roomId, ref.spotId) { $0.symptom = text } }
    }
}
