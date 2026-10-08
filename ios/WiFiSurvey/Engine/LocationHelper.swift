import CoreLocation
import Foundation
import Observation

/// Location permission (iOS requires it to reveal SSID/BSSID) and compass heading.
@MainActor
@Observable
final class LocationHelper {
    var status: CLAuthorizationStatus
    var precise = false
    var headingDeg: Double?
    var headingAccuracy: Double?
    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private let delegate = LocationDelegate()

    init() {
        status = manager.authorizationStatus
        precise = manager.accuracyAuthorization == .fullAccuracy
        manager.delegate = delegate
        delegate.onAuth = { [weak self] s, full in
            Task { @MainActor in
                self?.status = s
                self?.precise = full
                if s == .authorizedWhenInUse || s == .authorizedAlways { self?.startHeading() }
            }
        }
        delegate.onHeading = { [weak self] deg, acc in
            Task { @MainActor in
                self?.headingDeg = deg
                self?.headingAccuracy = acc
            }
        }
        if authorized { startHeading() }
    }

    var authorized: Bool { status == .authorizedWhenInUse || status == .authorizedAlways }

    func request() { manager.requestWhenInUseAuthorization() }

    func startHeading() {
        guard CLLocationManager.headingAvailable() else { return }
        manager.headingFilter = 2
        manager.startUpdatingHeading()
    }
}

private final class LocationDelegate: NSObject, CLLocationManagerDelegate {
    var onAuth: ((CLAuthorizationStatus, Bool) -> Void)?
    var onHeading: ((Double, Double) -> Void)?

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        onAuth?(m.authorizationStatus, m.accuracyAuthorization == .fullAccuracy)
    }

    func locationManager(_ m: CLLocationManager, didUpdateHeading h: CLHeading) {
        onHeading?(h.trueHeading >= 0 ? h.trueHeading : h.magneticHeading, h.headingAccuracy)
    }
}
