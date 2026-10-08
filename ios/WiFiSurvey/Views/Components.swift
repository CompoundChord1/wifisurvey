import PhotosUI
import SwiftUI

enum Fmt {
    static func ms(_ v: Double?) -> String {
        guard let v else { return "–" }
        return v < 10 ? String(format: "%.1f ms", v) : String(format: "%.0f ms", v)
    }

    static func pct(_ v: Double?) -> String {
        guard let v else { return "–" }
        return String(format: "%.1f%%", v)
    }

    static func dbm(_ v: Double?) -> String {
        guard let v else { return "–" }
        return String(format: "%.0f dBm", v)
    }

    static func db(_ v: Double?) -> String {
        guard let v else { return "–" }
        return String(format: "%.0f dB", v)
    }

    static func mbps(_ v: Double?) -> String {
        guard let v else { return "–" }
        return String(format: "%.0f Mbps", v)
    }

    static func clock(_ s: Int) -> String { String(format: "%d:%02d", s / 60, s % 60) }
}

func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

func gradeColor(_ grade: String) -> Color {
    switch grade {
    case "green": return .green
    case "yellow": return .yellow
    case "red": return .red
    default: return Color.gray.opacity(0.35)
    }
}

struct GradeDot: View {
    let grade: String
    var size: CGFloat = 10

    var body: some View {
        Circle().fill(gradeColor(grade)).frame(width: size, height: size)
    }
}

/// One dot per network leg of the spot's latest measurement (2G, 5G, DUAL).
struct SpotGrades: View {
    let spot: Spot?

    var body: some View {
        HStack(spacing: 3) {
            if let legs = spot?.latest?.legs, !legs.isEmpty {
                ForEach(legs) { GradeDot(grade: $0.grade, size: 8) }
            } else {
                GradeDot(grade: "none", size: 8)
            }
        }
    }
}

struct CheckRow<Accessory: View>: View {
    let ok: Bool
    let title: String
    let detail: String
    let accessory: Accessory

    init(ok: Bool, title: String, detail: String, @ViewBuilder accessory: () -> Accessory) {
        self.ok = ok
        self.title = title
        self.detail = detail
        self.accessory = accessory()
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle")
                .foregroundStyle(ok ? Color.green : Color.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            accessory
        }
    }
}

extension CheckRow where Accessory == EmptyView {
    init(ok: Bool, title: String, detail: String) {
        self.init(ok: ok, title: title, detail: detail) { EmptyView() }
    }
}

struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            Text(value).font(.callout.monospaced()).lineLimit(2).minimumScaleFactor(0.7)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }
}

struct StatTile: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value).font(.title3.weight(.semibold)).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(.secondarySystemBackground)))
    }
}

/// Results for one network leg — used on the measurement screen and in spot details.
struct LegResultView: View {
    let leg: Leg

    var body: some View {
        Section {
            HStack {
                GradeDot(grade: leg.grade, size: 14)
                Text("\(leg.network) · \(leg.ssidTarget)").font(.headline)
                Spacer()
                Text(leg.status).font(.caption).foregroundStyle(.secondary)
            }
            if let s = leg.summary { SummaryRows(summary: s) }
            if let j = leg.join, let t = j.totalMs, j.method != "already" {
                LabeledContent("Join time (\(j.method))", value: Fmt.ms(t))
            }
            if !leg.glitchMs.isEmpty { LabeledContent("Glitches marked", value: "\(leg.glitchMs.count)") }
            ForEach(leg.errors, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
        }
    }
}

private struct SummaryRows: View {
    let summary: LegSummary

    var body: some View {
        if let u = summary.udp {
            LabeledContent("Loss (phone→AP / AP→phone)",
                           value: "\(Fmt.pct(u.lossPct)) (\(Fmt.pct(u.upLossPct)) / \(Fmt.pct(u.downLossPct)))")
            LabeledContent("Latency p50 / p95 / max",
                           value: "\(Fmt.ms(u.rtt?.p50)) / \(Fmt.ms(u.rtt?.p95)) / \(Fmt.ms(u.rtt?.max))")
        }
        if let h = summary.heartbeat { LabeledContent("App stalls (2 s timeouts)", value: "\(h.failed) of \(h.sent)") }
        if let t = summary.throughput {
            LabeledContent("Speed down / up", value: t.skipped ?? "\(Fmt.mbps(t.down?.mbps)) / \(Fmt.mbps(t.up?.mbps))")
        }
        if let r = summary.radioStats {
            LabeledContent("Phone RSSI / SNR", value: "\(Fmt.dbm(r.rssiMedian)) / \(Fmt.db(r.snrMedian))")
            LabeledContent("Channel · TX PHY",
                           value: "\(r.channels.map(String.init).joined(separator: ",")) · \(Fmt.mbps(r.txRateMedian))")
        }
        if let a = summary.apSide {
            LabeledContent("AP", value: [a.apName, a.band].compactMap { $0 }.joined(separator: " · "))
            LabeledContent("AP hears phone at", value: Fmt.dbm(a.rssiMedian))
        }
        if let w = summary.wifi, w.roams > 0 { LabeledContent("Roams during leg", value: "\(w.roams)") }
        if let p = summary.ping { LabeledContent("Gateway ping loss", value: Fmt.pct(p.lossPct)) }
        if let d = summary.dns, d.failed > 0 { LabeledContent("DNS failures", value: "\(d.failed) of \(d.sent)") }
    }
}

// MARK: - Attachments (floor plans, AirPort Utility scan screenshots)

struct AttachmentsSection: View {
    let surveyId: String
    let roomId: String?
    @Environment(SurveyStore.self) private var store
    @State private var picked: [PhotosPickerItem] = []
    @State private var busy = false

    var body: some View {
        let items = store.survey(surveyId)?.attachments.filter { $0.roomId == roomId } ?? []
        ForEach(items) { a in
            AttachmentRow(surveyId: surveyId, attachment: a)
        }
        PhotosPicker(selection: $picked, maxSelectionCount: 10, matching: .images) {
            Label(busy ? "Adding…" : (roomId == nil ? "Add floor plan / screenshots" : "Add photos / screenshots"),
                  systemImage: "photo.badge.plus")
        }
        .onChange(of: picked) { _, items in
            guard !items.isEmpty else { return }
            Task { await add(items) }
        }
    }

    private func add(_ items: [PhotosPickerItem]) async {
        busy = true
        for item in items {
            guard let data = try? await item.loadTransferable(type: Data.self) else { continue }
            let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.85) ?? data
            let id = UUID().uuidString
            let rel = "attachments/\(id).jpg"
            let url = store.fileURL(surveyId, rel)
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard (try? jpeg.write(to: url)) != nil else { continue }
            store.update(surveyId) {
                $0.attachments.append(Attachment(id: id, file: rel, caption: "", roomId: roomId, addedAt: Date()))
            }
        }
        picked = []
        busy = false
    }
}

private struct AttachmentRow: View {
    let surveyId: String
    let attachment: Attachment
    @Environment(SurveyStore.self) private var store
    @State private var caption = ""
    @State private var thumb: UIImage?

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let thumb {
                    Image(uiImage: thumb).resizable().scaledToFill()
                } else {
                    Color(.secondarySystemBackground)
                }
            }
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            TextField("Caption (e.g. Upstairs floor plan)", text: $caption)
                .onSubmit(save)
        }
        .onAppear {
            caption = attachment.caption
            let url = store.fileURL(surveyId, attachment.file)
            thumb = UIImage(contentsOfFile: url.path)?.preparingThumbnail(of: CGSize(width: 112, height: 112))
        }
        .onDisappear(perform: save)
    }

    private func save() {
        guard caption != attachment.caption else { return }
        let id = attachment.id
        let text = caption
        store.update(surveyId) { s in
            if let i = s.attachments.firstIndex(where: { $0.id == id }) { s.attachments[i].caption = text }
        }
    }
}
