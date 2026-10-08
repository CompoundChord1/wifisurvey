import Foundation

/// Builds the export package (docs/SCHEMA.md):
///   WiFiSurvey_<name>_<stamp>/{survey.json, raw/, attachments/, server-data.zip, SCHEMA.md} → .zip
enum Exporter {
    struct Result {
        var zipURL: URL
        var notes: [String]
    }

    @MainActor
    static func build(store: SurveyStore, surveyId: String, includeServer: Bool) async throws -> Result {
        guard let s = store.survey(surveyId) else { throw err("survey not found") }
        let fm = FileManager.default
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyyMMdd-HHmm"
        let name = "WiFiSurvey_\(slug(s.name))_\(stamp.string(from: Date()))"
        let work = fm.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? fm.removeItem(at: work)
        let dir = work.appendingPathComponent(name, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var notes: [String] = []

        let src = store.folder(surveyId)
        try fm.copyItem(at: src.appendingPathComponent("survey.json"), to: dir.appendingPathComponent("survey.json"))
        for sub in ["raw", "attachments"] {
            let from = src.appendingPathComponent(sub)
            if fm.fileExists(atPath: from.path) { try fm.copyItem(at: from, to: dir.appendingPathComponent(sub)) }
        }
        if let schema = Bundle.main.url(forResource: "SCHEMA", withExtension: "md") {
            try? fm.copyItem(at: schema, to: dir.appendingPathComponent("SCHEMA.md"))
        }

        if includeServer {
            let legs = s.allLegs
            let ids = legs.map { $0.id } + s.walks.map { $0.id }
            let from = (legs.map { $0.startMs } + s.walks.map { $0.startMs }).min() ?? s.createdAt.timeIntervalSince1970 * 1000
            let to = (legs.compactMap { $0.endMs } + s.walks.compactMap { $0.endMs }).max() ?? Clock.nowMs()
            if let data = await HelperClient(s.settings).export(surveyId: s.id, fromMs: from, toMs: to, legs: ids) {
                try data.write(to: dir.appendingPathComponent("server-data.zip"))
                notes.append("Included server data (\(ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file))).")
            } else {
                notes.append("helper unreachable — export has phone data only. Pull the helper's runs/ folder separately.")
            }
        }

        let zip = try zipFolder(dir, into: work)
        let size = (try? fm.attributesOfItem(atPath: zip.path)[.size] as? Int) ?? 0
        notes.append("\(zip.lastPathComponent) — \(ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file))")
        return Result(zipURL: zip, notes: notes)
    }

    /// NSFileCoordinator's .forUploading hands back a zip of a directory — no zip library needed.
    static func zipFolder(_ dir: URL, into out: URL) throws -> URL {
        var coordError: NSError?
        var copyError: Error?
        var result: URL?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: [.forUploading], error: &coordError) { zipURL in
            let dest = out.appendingPathComponent(dir.lastPathComponent + ".zip")
            try? FileManager.default.removeItem(at: dest)
            do {
                try FileManager.default.copyItem(at: zipURL, to: dest)
                result = dest
            } catch {
                copyError = error
            }
        }
        if let e = coordError ?? (copyError as NSError?) { throw e }
        guard let result else { throw err("zip failed") }
        return result
    }

    static func slug(_ s: String) -> String {
        let cleaned = s.map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(cleaned).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "survey" : String(collapsed.prefix(40))
    }

    private static func err(_ msg: String) -> NSError {
        NSError(domain: "Exporter", code: 1, userInfo: [NSLocalizedDescriptionKey: msg])
    }
}
