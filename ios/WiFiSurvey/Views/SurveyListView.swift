import SwiftUI

struct SurveyListView: View {
    @Environment(SurveyStore.self) private var store
    @State private var showNew = false
    @State private var pendingDelete: Survey?

    var body: some View {
        List {
            if store.surveys.isEmpty {
                ContentUnavailableView("No surveys yet", systemImage: "wifi",
                                       description: Text("Tap + to set up a survey, then run the pre-flight check."))
            }
            ForEach(store.surveys) { s in
                NavigationLink(value: s.id) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(s.name).font(.headline)
                        Text("\(plural(s.rooms.count, "room")) · \(plural(s.measuredSpotCount, "spot")) measured")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(s.createdAt.formatted(date: .abbreviated, time: .shortened)
                             + (s.finishedAt != nil ? " · finished" : ""))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .swipeActions {
                    Button("Delete", role: .destructive) { pendingDelete = s }
                }
            }
        }
        .navigationTitle("WiFi Survey")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showNew = true } label: { Image(systemName: "plus") }
            }
        }
        .sheet(isPresented: $showNew) {
            NavigationStack { NewSurveyView() }
        }
        .confirmationDialog("Delete “\(pendingDelete?.name ?? "")” and all its data from this iPhone?",
                            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                            titleVisibility: .visible) {
            Button("Delete survey", role: .destructive) {
                if let s = pendingDelete { store.delete(s.id) }
                pendingDelete = nil
            }
        }
        .navigationDestination(for: String.self) { SurveyView(surveyId: $0) }
        .navigationDestination(for: RoomRef.self) { RoomView(ref: $0) }
        .navigationDestination(for: SpotRef.self) { SpotDetailView(ref: $0) }
        .navigationDestination(for: SurveyRoute.self) { route in
            switch route {
            case .preflight(let id): PreflightView(surveyId: id)
            case .walk(let id): WalkView(surveyId: id)
            case .export(let id): ExportView(surveyId: id)
            }
        }
    }
}

struct NewSurveyView: View {
    @Environment(SurveyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = "Whole house"
    @State private var notes = ""
    @State private var settings = SurveySettings()
    @State private var checklist = Checklist()
    @State private var passphrase = Keychain.get(Keychain.passphraseKey) ?? ""
    @State private var gridSeconds = 45
    @State private var centerDual = 30
    @State private var problemBand = 60
    @State private var problemDual = 180

    init() {
        #if targetEnvironment(simulator)
        // The Simulator has no Wi-Fi APIs: default to demo mode against a helper on this Mac.
        var s = SurveySettings()
        s.helperHost = "127.0.0.1"
        s.gateway = "127.0.0.1"
        s.demoMode = true
        _settings = State(initialValue: s)
        _name = State(initialValue: "Simulator demo")
        #endif
    }

    var body: some View {
        Form {
            Section("Survey") {
                TextField("Name", text: $name)
                TextField("Notes (time of day, household activity…)", text: $notes, axis: .vertical)
            }
            Section {
                TextField("Helper address (e.g. 192.168.1.10)", text: $settings.helperHost)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("Gateway to ping (e.g. 192.168.1.1)", text: $settings.gateway)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            } header: {
                Text("Survey helper")
            } footer: {
                Text("Uses UDP \(String(settings.udpPort)) and TCP \(String(settings.httpPort))/\(String(settings.tcpPort)).")
            }
            Section {
                ForEach($settings.networks) { $n in
                    HStack {
                        Text(n.key).foregroundStyle(.secondary).frame(width: 52, alignment: .leading)
                        TextField("SSID", text: $n.ssid)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                }
                SecureField("Passphrase (shared by all three)", text: $passphrase)
            } header: {
                Text("Survey networks")
            } footer: {
                Text("The passphrase is kept in this iPhone's Keychain only — never in the survey or its export.")
            }
            Section {
                Stepper("N/S/E/W: \(gridSeconds) s per band", value: $gridSeconds, in: 20...120, step: 5)
                Stepper("Center dual-band leg: \(centerDual) s", value: $centerDual, in: 20...120, step: 5)
                Stepper("Problem spot: \(problemBand) s per band", value: $problemBand, in: 30...300, step: 15)
                Stepper("Problem spot dual-band: \(problemDual) s", value: $problemDual, in: 30...600, step: 30)
            } header: {
                Text("Timing")
            } footer: {
                Text("Recommended: 45 s per band. Center adds a dual-band leg; problem spots run longer because stalls come and go.")
            }
            Section {
                Toggle("Phone radio via Shortcut", isOn: $settings.useShortcut)
                if settings.useShortcut {
                    TextField("Shortcut name", text: $settings.shortcutName)
                        .autocorrectionDisabled()
                }
                Toggle("Demo mode (Simulator testing)", isOn: $settings.demoMode)
            } header: {
                Text("Options")
            } footer: {
                Text("Demo mode skips Wi-Fi switching and fakes the network name so the flow can be tried in the Simulator.")
            }
            Section("Phone prep — confirm before you start") {
                Toggle("Airplane Mode on, then Wi-Fi back on", isOn: $checklist.airplaneWifiOn)
                Toggle("Bluetooth off", isOn: $checklist.bluetoothOff)
                Toggle("Auto-Join off for your home networks", isOn: $checklist.autoJoinOff)
                Toggle("Private Wi-Fi Address: Fixed on SURVEY networks", isOn: $checklist.privateAddressFixed)
                Toggle("Low Power Mode off", isOn: $checklist.lowPowerOff)
            }
        }
        .navigationTitle("New survey")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create", action: create)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty
                              || settings.helperHost.trimmingCharacters(in: .whitespaces).isEmpty
                              || settings.gateway.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func create() {
        var s = settings
        s.presets = Presets(
            grid: [LegPlan(network: "2G", seconds: gridSeconds), LegPlan(network: "5G", seconds: gridSeconds)],
            center: [LegPlan(network: "2G", seconds: gridSeconds), LegPlan(network: "5G", seconds: gridSeconds),
                     LegPlan(network: "DUAL", seconds: centerDual)],
            problem: [LegPlan(network: "2G", seconds: problemBand), LegPlan(network: "5G", seconds: problemBand),
                      LegPlan(network: "DUAL", seconds: problemDual)])
        Keychain.set(passphrase, for: Keychain.passphraseKey)
        store.create(name: name.trimmingCharacters(in: .whitespaces), notes: notes, settings: s, checklist: checklist)
        dismiss()
    }
}
