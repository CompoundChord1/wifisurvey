import Foundation
import Observation

/// Owns every survey on the phone. Each survey is a folder in Documents/Surveys/<id>/ holding
/// survey.json, raw/*.jsonl and attachments/. The folder is also visible in the Files app.
@MainActor
@Observable
final class SurveyStore {
    private(set) var surveys: [Survey] = []
    @ObservationIgnored let root: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        root = docs.appendingPathComponent("Surveys", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        load()
    }

    func load() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        var list: [Survey] = []
        for dir in dirs {
            let file = dir.appendingPathComponent("survey.json")
            if let data = try? Data(contentsOf: file), let s = try? Self.decoder.decode(Survey.self, from: data) {
                list.append(s)
            }
        }
        surveys = list.sorted { $0.createdAt > $1.createdAt }
    }

    func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    func fileURL(_ surveyId: String, _ relative: String) -> URL {
        folder(surveyId).appendingPathComponent(relative)
    }

    func survey(_ id: String) -> Survey? { surveys.first { $0.id == id } }

    @discardableResult
    func create(name: String, notes: String, settings: SurveySettings, checklist: Checklist) -> Survey {
        let s = Survey(id: UUID().uuidString, name: name, notes: notes, createdAt: Date(), finishedAt: nil,
                       timeZone: TimeZone.current.identifier, app: .current, device: .current,
                       settings: settings, checklist: checklist)
        let fm = FileManager.default
        try? fm.createDirectory(at: folder(s.id).appendingPathComponent("raw"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: folder(s.id).appendingPathComponent("attachments"),
                                withIntermediateDirectories: true)
        surveys.insert(s, at: 0)
        persist(s)
        return s
    }

    /// Mutate a survey in place and write it to disk immediately.
    func update(_ id: String, _ body: (inout Survey) -> Void) {
        guard let i = surveys.firstIndex(where: { $0.id == id }) else { return }
        var s = surveys[i]
        body(&s)
        surveys[i] = s
        persist(s)
    }

    func delete(_ id: String) {
        surveys.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: folder(id))
    }

    func addEvent(_ surveyId: String, type: String, detail: String) {
        update(surveyId) { $0.events.append(SurveyEvent(ts: Clock.nowMs(), type: type, detail: detail)) }
    }

    private func persist(_ s: Survey) {
        do {
            let data = try Self.encoder.encode(s)
            try data.write(to: folder(s.id).appendingPathComponent("survey.json"), options: .atomic)
        } catch {
            print("persist failed: \(error)")
        }
    }

    nonisolated static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    nonisolated static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()
}
