import SwiftUI

struct RoomView: View {
    let ref: RoomRef
    @Environment(SurveyStore.self) private var store
    @State private var measuring: SpotRef?
    @State private var addingSpot = false
    @State private var addAsProblem = false

    var body: some View {
        if let room = store.survey(ref.surveyId)?.room(ref.roomId) {
            ScrollView {
                VStack(spacing: 20) {
                    Text("Stand about 3 ft in from the middle of each wall, face the room's center, phone at chest height. Tap a point to measure it.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.horizontal)
                    compass(room)
                    extraSpots(room)
                    HStack(spacing: 12) {
                        Button {
                            addAsProblem = false
                            addingSpot = true
                        } label: { Label("Spot", systemImage: "plus") }
                            .buttonStyle(.bordered)
                        Button {
                            addAsProblem = true
                            addingSpot = true
                        } label: { Label("Problem spot", systemImage: "exclamationmark.triangle") }
                            .buttonStyle(.bordered).tint(.orange)
                    }
                    if !room.notes.isEmpty {
                        Text(room.notes).font(.callout).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Photos & screenshots").font(.headline)
                        AttachmentsSection(surveyId: ref.surveyId, roomId: room.id)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                }
                .padding(.vertical)
            }
            .navigationTitle("\(room.name) · \(room.floor)")
            .navigationBarTitleDisplayMode(.inline)
            .fullScreenCover(item: $measuring) { MeasureView(ref: $0) }
            .sheet(isPresented: $addingSpot) {
                NavigationStack { AddSpotView(ref: ref, problem: addAsProblem) }
            }
        } else {
            ContentUnavailableView("Room not found", systemImage: "questionmark")
        }
    }

    private func compass(_ room: Room) -> some View {
        VStack(spacing: 12) {
            point(.N, room)
            HStack(spacing: 12) {
                point(.W, room)
                point(.C, room)
                point(.E, room)
            }
            point(.S, room)
        }
    }

    @ViewBuilder
    private func point(_ kind: SpotKind, _ room: Room) -> some View {
        let spot = room.spots.first { $0.kind == kind }
        if let spot, spot.latest != nil {
            NavigationLink(value: SpotRef(surveyId: ref.surveyId, roomId: ref.roomId, spotId: spot.id)) {
                PointTile(kind: kind, spot: spot)
            }
            .buttonStyle(.plain)
        } else {
            Button { start(kind, room) } label: { PointTile(kind: kind, spot: spot) }
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private func extraSpots(_ room: Room) -> some View {
        let extras = room.spots.filter { $0.kind == .custom }
        if !extras.isEmpty {
            VStack(spacing: 8) {
                ForEach(extras) { spot in
                    HStack {
                        if spot.problem {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                        VStack(alignment: .leading) {
                            Text(spot.label).font(.body.weight(.medium))
                            if !spot.symptom.isEmpty {
                                Text(spot.symptom).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        SpotGrades(spot: spot)
                        if spot.latest != nil {
                            NavigationLink("Results", value: SpotRef(surveyId: ref.surveyId, roomId: ref.roomId,
                                                                     spotId: spot.id))
                                .font(.callout)
                        } else {
                            Button("Measure") {
                                measuring = SpotRef(surveyId: ref.surveyId, roomId: ref.roomId, spotId: spot.id)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
                }
            }
            .padding(.horizontal)
        }
    }

    private func start(_ kind: SpotKind, _ room: Room) {
        var spotId = room.spots.first { $0.kind == kind }?.id
        if spotId == nil {
            let s = Spot(id: UUID().uuidString, kind: kind, label: kind.rawValue, problem: false, symptom: "",
                         createdAt: Date(), measurements: [])
            store.update(ref.surveyId) { $0.withRoom(ref.roomId) { $0.spots.append(s) } }
            spotId = s.id
        }
        if let spotId { measuring = SpotRef(surveyId: ref.surveyId, roomId: ref.roomId, spotId: spotId) }
    }
}

struct PointTile: View {
    let kind: SpotKind
    let spot: Spot?

    var body: some View {
        let done = spot?.latest != nil
        VStack(spacing: 6) {
            Text(kind.rawValue).font(.system(size: 30, weight: .bold, design: .rounded))
            Text(kind.title).font(.caption)
            SpotGrades(spot: spot).frame(height: 10)
        }
        .frame(width: 96, height: 96)
        .background(RoundedRectangle(cornerRadius: 16)
            .fill(done ? Color.accentColor.opacity(0.15) : Color(.secondarySystemBackground)))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.accentColor.opacity(0.45), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 16))
    }
}

struct AddSpotView: View {
    let ref: RoomRef
    let problem: Bool
    @Environment(SurveyStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var label = ""
    @State private var symptom = ""
    @State private var isProblem = false

    var body: some View {
        Form {
            TextField(isProblem ? "Where (e.g. Couch, left end)" : "Label (e.g. Desk, Bed)", text: $label)
            Toggle("Problem spot", isOn: $isProblem)
            if isProblem {
                TextField("What goes wrong here?", text: $symptom, axis: .vertical)
            }
            Section {
                Text(isProblem
                     ? "Problem spots run longer on each band plus a 3-minute dual-band leg, to catch intermittent stalls."
                     : "Extra spots run the same bands as the N/S/E/W points.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(isProblem ? "Problem spot" : "Add spot")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { isProblem = problem }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Add") {
                    let s = Spot(id: UUID().uuidString, kind: .custom, label: label.trimmingCharacters(in: .whitespaces),
                                 problem: isProblem, symptom: symptom, createdAt: Date(), measurements: [])
                    store.update(ref.surveyId) { $0.withRoom(ref.roomId) { $0.spots.append(s) } }
                    dismiss()
                }
                .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }
}
