#if DEBUG
import Foundation
import UIKit

/// Debug builds only. Exercises the whole engine without tapping — used by tests/fault_injection.py
/// and for checking a new iOS version:
///
///     xcrun simctl launch <udid> com.example.WiFiSurvey -selftest [helperHost]
///         [-legs 2G:25,5G:25] [-noshortcut] [-label name]
///
/// Creates a demo-mode survey, measures one spot, builds an export, and writes
/// Documents/selftest-result-<label>.json and selftest-export-<label>.zip.
enum SelfTest {
    @MainActor
    static func runIfRequested(store: SurveyStore, runner: MeasurementRunner, location: LocationHelper) async {
        let args = ProcessInfo.processInfo.arguments
        guard let i = args.firstIndex(of: "-selftest") else { return }
        func value(_ flag: String) -> String? {
            guard let j = args.firstIndex(of: flag), j + 1 < args.count else { return nil }
            return args[j + 1]
        }
        let host = args.count > i + 1 && !args[i + 1].hasPrefix("-") ? args[i + 1] : "127.0.0.1"
        let label = value("-label") ?? "default"
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        var settings = SurveySettings()
        settings.helperHost = host
        settings.gateway = "127.0.0.1"      // the Simulator has no real router; loopback keeps the ping check meaningful
        settings.demoMode = true
        settings.useShortcut = !args.contains("-noshortcut")
        settings.skipThroughputMinutes = []   // a speed-test quiet window doesn't apply to a loopback test
        var legs = [LegPlan(network: "2G", seconds: 30), LegPlan(network: "5G", seconds: 20)]
        if let spec = value("-legs") {
            let parsed = spec.split(separator: ",").compactMap { part -> LegPlan? in
                let kv = part.split(separator: ":")
                guard kv.count == 2, let secs = Int(kv[1]) else { return nil }
                return LegPlan(network: String(kv[0]), seconds: secs)
            }
            if !parsed.isEmpty { legs = parsed }
        }
        settings.presets.grid = legs
        let survey = store.create(name: "Self-test \(label)", notes: "automated self-test", settings: settings,
                                  checklist: Checklist())
        let room = Room(id: UUID().uuidString, name: "Selftest room", floor: "Main", notes: "", createdAt: Date(),
                        spots: [])
        let spot = Spot(id: UUID().uuidString, kind: .N, label: "N", problem: false, symptom: "", createdAt: Date(),
                        measurements: [])
        store.update(survey.id) { s in
            s.rooms.append(room)
            s.withRoom(room.id) { $0.spots.append(spot) }
        }
        let t0 = Date()
        await runner.run(store: store, location: location,
                         ref: SpotRef(surveyId: survey.id, roomId: room.id, spotId: spot.id))
        var result: [String: Any] = ["label": label,
                                     "system": "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)",
                                     "seconds": Int(Date().timeIntervalSince(t0))]
        if let m = store.survey(survey.id)?.spot(room.id, spot.id)?.latest {
            result["measurementStatus"] = m.status
            result["legs"] = m.legs.map { leg -> [String: Any] in
                let s = leg.summary
                let u = s?.udp
                return ["id": leg.id, "network": leg.network, "status": leg.status, "grade": leg.grade,
                        "planned": leg.plannedSeconds, "wallSeconds": J(leg.endMs.map { ($0 - leg.startMs) / 1000 }),
                        "joinMethod": J(leg.join?.method), "joinError": J(leg.join?.error),
                        "udpSent": u?.sent ?? 0, "udpReceived": u?.received ?? 0, "lossPct": J(u?.lossPct),
                        "upLossPct": J(u?.upLossPct), "downLossPct": J(u?.downLossPct),
                        "unknownLost": J(u?.unknownLost), "maxLossBurst": J(u?.maxLossBurst),
                        "lossBursts3plus": J(u?.lossBursts3plus), "reconnects": J(u?.reconnects),
                        "rttP50": J(u?.rtt?.p50), "rttP95": J(u?.rtt?.p95), "rttMax": J(u?.rtt?.max),
                        "jitterMs": J(u?.jitterMs),
                        "pingLossPct": J(s?.ping?.lossPct), "hbSent": J(s?.heartbeat?.sent),
                        "hbFailed": J(s?.heartbeat?.failed), "dnsFailed": J(s?.dns?.failed),
                        "downMbps": J(s?.throughput?.down?.mbps), "downError": J(s?.throughput?.down?.error),
                        "upMbps": J(s?.throughput?.up?.mbps), "upError": J(s?.throughput?.up?.error),
                        "tputSkipped": J(s?.throughput?.skipped), "apName": J(s?.apSide?.apName),
                        "radioSamples": leg.radio.count, "errors": leg.errors]
            }
        }
        do {
            let export = try await Exporter.build(store: store, surveyId: survey.id, includeServer: true)
            let copy = docs.appendingPathComponent("selftest-export-\(label).zip")
            try? FileManager.default.removeItem(at: copy)
            try FileManager.default.copyItem(at: export.zipURL, to: copy)
            result["exportNotes"] = export.notes
        } catch {
            result["exportError"] = error.localizedDescription
        }
        if let data = try? JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: docs.appendingPathComponent("selftest-result-\(label).json"))
        }
    }
}
#endif
