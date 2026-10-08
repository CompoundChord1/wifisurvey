import SwiftUI

struct SurveyView: View {
    let surveyId: String
    @Environment(SurveyStore.self) private var store
    @State private var showAddRoom = false

    var body: some View {
        if let s = store.survey(surveyId) {
            List {
                Section {
                    NavigationLink(value: SurveyRoute.preflight(surveyId)) {
                        Label("Pre-flight check", systemImage: "checklist")
                    }
                    NavigationLink(value: SurveyRoute.walk(surveyId)) {
                        Label("Walk / soak", systemImage: "figure.walk")
                    }
                    NavigationLink(value: SurveyRoute.export(surveyId)) {
                        Label(s.finishedAt == nil ? "Finish & export" : "Export", systemImage: "square.and.arrow.up")
                    }
                }
                ForEach(floors(s), id: \.self) { floor in
                    Section(floor) {
                        ForEach(s.rooms.filter { $0.floor == floor }) { room in
                            NavigationLink(value: RoomRef(surveyId: surveyId, roomId: room.id)) {
                                RoomRow(room: room)
                            }
                        }
                    }
                }
                Section {
                    Button { showAddRoom = true } label: {
                        Label("Add room", systemImage: "plus.circle.fill")
                    }
                }
                Section("Floor plans & screenshots") {
                    AttachmentsSection(surveyId: surveyId, roomId: nil)
                }
                if !s.walks.isEmpty {
                    Section("Walks") {
                        ForEach(s.walks) { WalkRow(walk: $0) }
                    }
                }
                Section("Summary") {
                    LabeledContent("Rooms", value: "\(s.rooms.count)")
                    LabeledContent("Spots measured", value: "\(s.measuredSpotCount)")
                    LabeledContent("Glitches marked", value: "\(s.glitches.count)")
                    if !s.notes.isEmpty { Text(s.notes).font(.callout) }
                }
            }
            .navigationTitle(s.name)
            .sheet(isPresented: $showAddRoom) {
                NavigationStack { AddRoomView(surveyId: surveyId, knownFloors: floors(s)) }
            }
        } else {
            ContentUnavailableView("Survey not found", systemImage: "questionmark")
        }
    }

    private func floors(_ s: Survey) -> [String] {
        var seen: [String] = []
        for r in s.rooms where !seen.contains(r.floor) { seen.append(r.floor) }
        return seen
    }
}

struct RoomRow: View {
    let room: Room

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(room.name).font(.body.weight(.medium))
                Text("\(plural(room.spots.filter { $0.latest != nil }.count, "spot")) measured")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                ForEach(room.spots) { SpotGrades(spot: $0) }
            }
        }
    }
}

struct WalkRow: View {
    let walk: Walk

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            let mins = ((walk.endMs ?? walk.startMs) - walk.startMs) / 60000
            Text("\(walk.place.map { "Soak · \($0)" } ?? "Walk") · \(walk.network ?? "?") · \(String(format: "%.1f", mins)) min")
            if let u = walk.summary?.udp {
                Text("loss \(Fmt.pct(u.lossPct)) · p95 \(Fmt.ms(u.rtt?.p95)) · roams \(walk.summary?.wifi?.roams ?? 0) · stalls \(walk.summary?.heartbeat?.failed ?? 0)")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct AddRoomView: View {
    let surveyId: String
    let knownFloors: [String]
    @Environment(SurveyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var floor = "Main"
    @State private var notes = ""

    private var floorChoices: [String] {
        var out = ["Basement", "Main", "Upper"]
        for f in knownFloors where !out.contains(f) { out.append(f) }
        return out
    }

    var body: some View {
        Form {
            TextField("Room name (e.g. Kitchen)", text: $name)
            Section("Floor") {
                Picker("Floor", selection: $floor) {
                    ForEach(floorChoices, id: \.self) { Text($0) }
                }
                .pickerStyle(.menu)
                TextField("…or type one", text: $floor)
            }
            Section("Notes") {
                TextField("Walls, appliances, where the AP is…", text: $notes, axis: .vertical)
            }
        }
        .navigationTitle("Add room")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    let room = Room(id: UUID().uuidString, name: name.trimmingCharacters(in: .whitespaces),
                                    floor: floor.trimmingCharacters(in: .whitespaces), notes: notes,
                                    createdAt: Date(), spots: [])
                    store.update(surveyId) { $0.rooms.append(room) }
                    dismiss()
                }
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || floor.isEmpty)
            }
        }
    }
}
