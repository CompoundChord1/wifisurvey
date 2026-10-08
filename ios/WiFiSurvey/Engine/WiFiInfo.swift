import Foundation
import Network
import NetworkExtension

struct WiFiSnapshot {
    var ssid: String?
    var bssid: String?
    var ts: Double
    /// iOS didn't answer in time. Not the same as "no Wi-Fi" — don't count it as a disconnect.
    var timedOut = false
}

enum WiFiInfo {
    /// Current SSID/BSSID. Needs the Access Wi-Fi Information entitlement plus precise location
    /// permission (or a network this app configured). Returns nils in the Simulator.
    /// Bounded by `timeout`: the measurement loop must never hang on a slow system call while the
    /// radio is flapping.
    static func current(demo: Bool = false, demoSSID: String? = nil, timeout: Double = 1.5) async -> WiFiSnapshot {
        if demo { return WiFiSnapshot(ssid: demoSSID, bssid: "02:00:00:00:00:01", ts: Clock.nowMs()) }
        return await withCheckedContinuation { cont in
            let gate = OnceGate()
            NEHotspotNetwork.fetchCurrent { net in
                let snap = WiFiSnapshot(ssid: net?.ssid, bssid: normalizeBSSID(net?.bssid), ts: Clock.nowMs())
                if gate.pass() { cont.resume(returning: snap) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                if gate.pass() {
                    cont.resume(returning: WiFiSnapshot(ssid: nil, bssid: nil, ts: Clock.nowMs(), timedOut: true))
                }
            }
        }
    }

    /// iOS sometimes drops leading zeros ("a0:b1:3:…"); normalize to aa:bb:cc:dd:ee:ff.
    static func normalizeBSSID(_ b: String?) -> String? {
        guard let b, !b.isEmpty else { return nil }
        return b.split(separator: ":").map { part -> String in
            let s = String(part).lowercased()
            return s.count == 1 ? "0" + s : s
        }.joined(separator: ":")
    }

    /// IPv4 address on the Wi-Fi interface (en0), if any.
    static func wifiIPv4() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        var result: String?
        while let p = ptr {
            let ifa = p.pointee
            if let sa = ifa.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET), String(cString: ifa.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(sa, socklen_t(sa.pointee.sa_len), &host, socklen_t(host.count), nil, 0,
                               NI_NUMERICHOST) == 0 {
                    result = String(cString: host)
                }
            }
            ptr = ifa.ifa_next
        }
        return result
    }
}

/// Logs network-path changes (Wi-Fi up/down, fallback to cellular) during a leg.
final class PathWatcher {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "wifisurvey.path")

    func start(_ onChange: @escaping (Network.NWPath) -> Void) {
        monitor.pathUpdateHandler = onChange
        monitor.start(queue: queue)
    }

    func stop() { monitor.cancel() }
}

enum NetworkSwitcher {
    /// Ask iOS to join `ssid`. iOS may show a one-tap "Join" confirmation.
    /// Returns nil on success (including "already associated"), else an error description.
    static func apply(ssid: String, passphrase: String) async -> String? {
        let cfg = NEHotspotConfiguration(ssid: ssid, passphrase: passphrase, isWEP: false)
        cfg.joinOnce = false
        do {
            try await NEHotspotConfigurationManager.shared.apply(cfg)
            return nil
        } catch {
            let ns = error as NSError
            if ns.domain == NEHotspotConfigurationErrorDomain,
               ns.code == NEHotspotConfigurationError.alreadyAssociated.rawValue {
                return nil
            }
            return "\(ns.localizedDescription) [\(ns.domain) \(ns.code)]"
        }
    }

    static func remove(_ ssids: [String]) {
        for s in ssids { NEHotspotConfigurationManager.shared.removeConfiguration(forSSID: s) }
    }

    static func configuredSSIDs() async -> [String] {
        await withCheckedContinuation { cont in
            NEHotspotConfigurationManager.shared.getConfiguredSSIDs { cont.resume(returning: $0) }
        }
    }
}
