import Foundation
import CoreLocation
import AppKit
import CodeIslandCore

/// On-device, privacy-preserving location service for prayer time calculations.
/// Coordinates never leave the Mac and are rounded to 2 decimal places (~1.1 km).
@MainActor
public final class PrayerLocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    public static let shared = PrayerLocationService()

    @Published public private(set) var activeCity: OfflineCity
    @Published public private(set) var authorizationStatus: CLAuthorizationStatus

    private let locationManager = CLLocationManager()
    private var lastFetchTimestamp: Date?

    private override init() {
        self.activeCity = OfflineCityDatabase.defaultCity
        self.authorizationStatus = locationManager.authorizationStatus
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyKilometer

        restoreLastSavedCity()
        setupWakeNotification()
    }

    /// Triggers a single coarse location update if automatic mode is active.
    public func requestCurrentLocation(force: Bool = false) {
        let mode = UserDefaults.standard.string(forKey: SettingsKey.prayerLocationMode) ?? SettingsDefaults.prayerLocationMode
        if mode == "manual" {
            let manualId = UserDefaults.standard.string(forKey: SettingsKey.prayerManualCityId) ?? SettingsDefaults.prayerManualCityId
            if let city = OfflineCityDatabase.city(byId: manualId) {
                self.activeCity = city
            }
            return
        }

        if !force, let last = lastFetchTimestamp, Date().timeIntervalSince(last) < 21600 {
            // Checked within 6 hours, keep current
            return
        }

        switch locationManager.authorizationStatus {
        case .notDetermined:
            locationManager.requestWhenInUseAuthorization()
        case .authorizedAlways, .authorized:
            lastFetchTimestamp = Date()
            locationManager.requestLocation()
        default:
            // Denied or restricted: silently fallback to last saved or default city
            break
        }
    }

    public func setManualCity(id: String) {
        if let city = OfflineCityDatabase.city(byId: id) {
            self.activeCity = city
            UserDefaults.standard.set(city.coordinates.latitude, forKey: "prayerLastLatitude")
            UserDefaults.standard.set(city.coordinates.longitude, forKey: "prayerLastLongitude")
            UserDefaults.standard.set(city.name, forKey: "prayerResolvedCityName")
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorizationStatus = status
            if status == .authorized || status == .authorizedAlways {
                self.requestCurrentLocation(force: true)
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }

        // Round to 2 decimal places (~1.1 km) for strict privacy preservation
        let roundedLat = (location.coordinate.latitude * 100.0).rounded() / 100.0
        let roundedLon = (location.coordinate.longitude * 100.0).rounded() / 100.0
        let coords = Coordinates(latitude: roundedLat, longitude: roundedLon)

        let matched = OfflineCityDatabase.closestCity(to: coords)

        Task { @MainActor in
            self.activeCity = matched
            UserDefaults.standard.set(roundedLat, forKey: "prayerLastLatitude")
            UserDefaults.standard.set(roundedLon, forKey: "prayerLastLongitude")
            UserDefaults.standard.set(matched.name, forKey: "prayerResolvedCityName")
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Silent failure; fallback remains active
    }

    // MARK: - Private Helpers

    private func restoreLastSavedCity() {
        let lat = UserDefaults.standard.double(forKey: "prayerLastLatitude")
        let lon = UserDefaults.standard.double(forKey: "prayerLastLongitude")
        if lat != 0.0 && lon != 0.0 {
            let coords = Coordinates(latitude: lat, longitude: lon)
            self.activeCity = OfflineCityDatabase.closestCity(to: coords)
        }
    }

    private func setupWakeNotification() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.requestCurrentLocation(force: false)
            }
        }
    }
}
