import Foundation
import UIKit

// The survey document. Field names match docs/SCHEMA.md ("wifisurvey/1").

struct NetworkTarget: Codable, Hashable, Identifiable {
    var key: String      // "2G", "5G", "DUAL"
    var ssid: String
    var id: String { key }
}

struct LegPlan: Codable, Hashable {
    var network: String
    var seconds: Int
}

struct Presets: Codable, Hashable {
    var grid: [LegPlan]
    var center: [LegPlan]
    var problem: [LegPlan]

    static let standard = Presets(
        grid: [LegPlan(network: "2G", seconds: 45), LegPlan(network: "5G", seconds: 45)],
        center: [LegPlan(network: "2G", seconds: 45), LegPlan(network: "5G", seconds: 45),
                 LegPlan(network: "DUAL", seconds: 30)],
        problem: [LegPlan(network: "2G", seconds: 60), LegPlan(network: "5G", seconds: 60),
                  LegPlan(network: "DUAL", seconds: 180)])
}

struct SurveySettings: Codable, Hashable {
    var helperHost = ""          // set per survey: the machine running server/wifisurvey_helper.py
    var udpPort = 9750
    var httpPort = 9751
    var tcpPort = 9752
    var gateway = ""             // set per survey: your router
    var dnsName = "apple.com"
    var networks: [NetworkTarget] = [NetworkTarget(key: "2G", ssid: "SURVEY-2G"),
                                     NetworkTarget(key: "5G", ssid: "SURVEY-5G"),
                                     NetworkTarget(key: "DUAL", ssid: "SURVEY-DUAL")]
    var presets = Presets.standard
    var probePps = 25
    var probeBytes = 200
    var pingPps = 5
    var useShortcut = true
    var shortcutName = "WiFiSurvey Radio"
    var throughputSeconds = 5
    var downloadAt = 15
    var uploadAt = 25
    var skipThroughputMinutes: [Int] = []   // minutes of the hour to skip speed tests (e.g. another monitor runs then)
    var settleSeconds = 3
    var joinTimeoutSeconds = 30
    var demoMode = false

    func ssid(for key: String) -> String { networks.first { $0.key == key }?.ssid ?? key }
    func key(forSSID ssid: String?) -> String? { networks.first { $0.ssid == ssid }?.key }
}

struct Checklist: Codable, Hashable {
    var airplaneWifiOn = false
    var bluetoothOff = false
    var autoJoinOff = false
    var privateAddressFixed = false
    var lowPowerOff = false
}

struct AppInfo: Codable, Hashable {
    var version: String
    var build: String

    static var current: AppInfo {
        let info = Bundle.main.infoDictionary ?? [:]
        return AppInfo(version: info["CFBundleShortVersionString"] as? String ?? "?",
                       build: info["CFBundleVersion"] as? String ?? "?")
    }
}

struct DeviceInfo: Codable, Hashable {
    var model: String
    var system: String

    @MainActor static var current: DeviceInfo {
        var sys = utsname()
        uname(&sys)
        let machine = withUnsafePointer(to: &sys.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { String(cString: $0) }
        }
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? machine
        return DeviceInfo(model: model, system: "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
    }
}

struct Attachment: Codable, Hashable, Identifiable {
    var id: String
    var file: String
    var caption: String
    var roomId: String?
    var addedAt: Date
}

struct Glitch: Codable, Hashable {
    var ts: Double
    var roomId: String?
    var spotId: String?
    var measurementId: String?
    var legId: String?
    var walkId: String?
    var note: String
}

struct SurveyEvent: Codable, Hashable {
    var ts: Double
    var type: String
    var detail: String
}

struct JoinInfo: Codable, Hashable {
    var method: String          // already | hotspot | manual | demo
    var requestMs: Double
    var ssidSeenMs: Double?
    var ipMs: Double?
    var helperOkMs: Double?
    var totalMs: Double?
    var error: String?
}

struct RTTStats: Codable, Hashable {
    var p50: Double
    var p90: Double
    var p95: Double
    var p99: Double
    var max: Double
    var mean: Double
}

struct BSSIDTime: Codable, Hashable {
    var bssid: String
    var seconds: Double
}

struct WiFiStats: Codable, Hashable {
    var ssids: [String]
    var bssids: [BSSIDTime]
    var roams: Int
    var noWifiSeconds: Double
}

struct LossPart: Codable, Hashable {
    var sent: Int
    var received: Int
    var lossPct: Double
    var rtt: RTTStats?
}

struct UDPStats: Codable, Hashable {
    var sent: Int
    var received: Int
    var lossPct: Double
    var upLost: Int?
    var downLost: Int?
    var unknownLost: Int
    var upLossPct: Double?
    var downLossPct: Double?
    var late: Int
    var dup: Int
    var rtt: RTTStats?
    var jitterMs: Double?
    var maxLossBurst: Int
    var lossBursts3plus: Int
    var clockOffsetMs: Double?
    var idle: LossPart
    var loaded: LossPart
    var reconnects: Int? = nil      // times the probe socket had to be re-created (stalls, errors)
    var sendErrors: Int? = nil      // probes whose local send failed (no route): they never left the phone
}

struct PingStats: Codable, Hashable {
    var target: String
    var sent: Int
    var received: Int
    var lossPct: Double
    var rtt: RTTStats?
}

struct HeartbeatStats: Codable, Hashable {
    var sent: Int
    var ok: Int
    var failed: Int
    var skipped: Int
    var rtt: RTTStats?
}

struct DNSStats: Codable, Hashable {
    var server: String
    var sent: Int
    var ok: Int
    var failed: Int
    var rtt: RTTStats?
}

struct TputResult: Codable, Hashable {
    var mbps: Double?
    var mbpsSteady: Double?
    var bytes: Int
    var seconds: Double
    var error: String?
}

struct ThroughputStats: Codable, Hashable {
    var down: TputResult?
    var up: TputResult?
    var skipped: String?
}

struct RadioStats: Codable, Hashable {
    var samples: Int
    var rssiMedian: Double?
    var rssiMin: Double?
    var rssiMax: Double?
    var noiseMedian: Double?
    var snrMedian: Double?
    var channels: [Int]
    var standards: [String]
    var txRateMedian: Double?
    var rxRateMedian: Double?
    var bssids: [String]
}

struct APSideStats: Codable, Hashable {
    var samples: Int
    var apName: String?
    var apMac: String?
    var radioId: Int?
    var band: String?
    var channel: Int?
    var rssiMedian: Double?
    var rssiMin: Double?
    var snrMedian: Double?
    var txRateMedian: Double?
    var rxRateMedian: Double?
}

struct LegSummary: Codable, Hashable {
    var wifi: WiFiStats?
    var udp: UDPStats?
    var ping: PingStats?
    var heartbeat: HeartbeatStats?
    var dns: DNSStats?
    var throughput: ThroughputStats?
    var radioStats: RadioStats?
    var apSide: APSideStats?
}

struct RadioSample: Codable, Hashable {
    var ts: Double
    var rssi: Double?
    var noise: Double?
    var channel: Int?
    var txRate: Double?
    var rxRate: Double?
    var bssid: String?
    var standard: String?
    var mac: String?        // "Hardware MAC Address" (optional 9th field)
    var raw: String
}

struct Leg: Codable, Hashable, Identifiable {
    var id: String
    var network: String
    var ssidTarget: String
    var plannedSeconds: Int
    var startMs: Double
    var endMs: Double?
    var status: String          // running | complete | cancelled | failed | skipped
    var join: JoinInfo?
    var ip: String?
    var rawFile: String
    var grade: String = "none"
    var glitchMs: [Double] = []
    var errors: [String] = []
    var radio: [RadioSample] = []
    var summary: LegSummary?
    var interrupted: Bool? = nil   // the app was backgrounded mid-leg; data has gaps that aren't Wi-Fi
}

struct Measurement: Codable, Hashable, Identifiable {
    var id: String
    var startedAt: Date
    var endedAt: Date?
    var status: String          // running | complete | cancelled | failed
    var headingDeg: Double?
    var headingAccuracyDeg: Double?
    var legs: [Leg]
}

enum SpotKind: String, Codable, CaseIterable, Identifiable {
    case N, E, S, W, C, custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .N: return "North"
        case .E: return "East"
        case .S: return "South"
        case .W: return "West"
        case .C: return "Center"
        case .custom: return "Spot"
        }
    }
}

struct Spot: Codable, Hashable, Identifiable {
    var id: String
    var kind: SpotKind
    var label: String
    var problem: Bool
    var symptom: String
    var createdAt: Date
    var measurements: [Measurement]

    /// The measurement the analysis will use: newest complete one, else newest.
    var latest: Measurement? {
        measurements.last(where: { $0.status == "complete" }) ?? measurements.last
    }
}

struct Room: Codable, Hashable, Identifiable {
    var id: String
    var name: String
    var floor: String
    var notes: String
    var createdAt: Date
    var spots: [Spot]
}

struct WalkSummary: Codable, Hashable {
    var udp: UDPStats?
    var wifi: WiFiStats?
    var heartbeat: HeartbeatStats?
}

struct Walk: Codable, Hashable, Identifiable {
    var id: String
    var network: String?
    var startMs: Double
    var endMs: Double?
    var rawFile: String
    var summary: WalkSummary?
    /// Where a stationary soak was done ("master bedroom, bed"); nil for a walk through the house.
    var place: String?
}

struct Survey: Codable, Hashable, Identifiable {
    var schema = "wifisurvey/1"
    var id: String
    var name: String
    var notes: String
    var createdAt: Date
    var finishedAt: Date?
    var timeZone: String
    var app: AppInfo
    var device: DeviceInfo
    var settings: SurveySettings
    var checklist: Checklist
    var attachments: [Attachment] = []
    var rooms: [Room] = []
    var walks: [Walk] = []
    var glitches: [Glitch] = []
    var events: [SurveyEvent] = []

    var allLegs: [Leg] { rooms.flatMap { $0.spots.flatMap { $0.measurements.flatMap { $0.legs } } } }
    var measuredSpotCount: Int { rooms.reduce(0) { $0 + $1.spots.filter { $0.latest != nil }.count } }
}

// MARK: - Nested mutation helpers

extension Survey {
    mutating func withRoom(_ roomId: String, _ body: (inout Room) -> Void) {
        if let i = rooms.firstIndex(where: { $0.id == roomId }) { body(&rooms[i]) }
    }

    mutating func withSpot(_ roomId: String, _ spotId: String, _ body: (inout Spot) -> Void) {
        withRoom(roomId) { room in
            if let j = room.spots.firstIndex(where: { $0.id == spotId }) { body(&room.spots[j]) }
        }
    }

    mutating func withMeasurement(_ roomId: String, _ spotId: String, _ mId: String,
                                  _ body: (inout Measurement) -> Void) {
        withSpot(roomId, spotId) { spot in
            if let k = spot.measurements.firstIndex(where: { $0.id == mId }) { body(&spot.measurements[k]) }
        }
    }

    mutating func withLeg(_ roomId: String, _ spotId: String, _ mId: String, _ legId: String,
                          _ body: (inout Leg) -> Void) {
        withMeasurement(roomId, spotId, mId) { m in
            if let l = m.legs.firstIndex(where: { $0.id == legId }) { body(&m.legs[l]) }
        }
    }

    func room(_ id: String) -> Room? { rooms.first { $0.id == id } }

    func spot(_ roomId: String, _ spotId: String) -> Spot? {
        room(roomId)?.spots.first { $0.id == spotId }
    }
}

// MARK: - Navigation values

struct RoomRef: Hashable {
    let surveyId: String
    let roomId: String
}

struct SpotRef: Hashable, Identifiable {
    let surveyId: String
    let roomId: String
    let spotId: String
    var id: String { spotId }
}

enum SurveyRoute: Hashable {
    case preflight(String)
    case walk(String)
    case export(String)
}
