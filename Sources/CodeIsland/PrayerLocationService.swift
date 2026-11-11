import Foundation
import CoreLocation
import AppKit
import CodeIslandCore

/// Native on-device macOS location service for prayer time hisab and sunrise/sunset calculations.
/// Supports both coarse privacy-preserving matching and high-precision coordinates with CLGeocoder reverse geocoding.
@MainActor
public final class PrayerLocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    public static let shared = PrayerLocationService()

    @Published public private(set) var activeCity: OfflineCity
    @Published public private(set) var preciseCoordinates: Coordinates?
    @Published public private(set) var preciseElevation: Double?
    @Published public private(set) var resolvedNativeCityName: String?
    @Published public private(set) var authorizationStatus: CLAuthorizationStatus

    private let locationManager = CLLocationManager()
    private var lastFetchTimestamp: Date?

    public var usePreciseLocation: Bool {
        UserDefaults.standard.bool(forKey: SettingsKey.prayerUsePreciseLocation)
    }

    /// Effective coordinates for astronomical calculations.
    /// Returns exact device coordinates when precise location is enabled and available; otherwise fallback to matched city coordinates.
    public var effectiveCoordinates: Coordinates {
        if usePreciseLocation, let coords = preciseCoordinates {
            return coords
        }
        return activeCity.coordinates
    }

    /// Effective elevation in meters.
    /// Returns device altitude if available (> 0) and precise location is on; otherwise uses the city catalog elevation.
    public var effectiveElevation: Double {
        if usePreciseLocation, let elev = preciseElevation, elev > 0 {
            return elev
        }
        return activeCity.elevationMeters
    }

    /// Display city name for diorama and widget subtitles.
    public var displayName: String {
        if let native = resolvedNativeCityName, !native.isEmpty {
            return native
        }
        return activeCity.name
    }

    private override init() {
        self.activeCity = OfflineCityDatabase.defaultCity
        self.authorizationStatus = locationManager.authorizationStatus
        super.init()

        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyHundredMeters

        restoreLastSavedCity()
        setupWakeNotification()
    }

    /// Triggers location permission request from the user.
    public func requestAuthorization() {
        locationManager.requestWhenInUseAuthorization()
    }

    /// Triggers a location update if automatic mode is active.
    public func requestCurrentLocation(force: Bool = false) {
        let mode = UserDefaults.standard.string(forKey: SettingsKey.prayerLocationMode) ?? SettingsDefaults.prayerLocationMode
        if mode == "manual" {
            let manualId = UserDefaults.standard.string(forKey: SettingsKey.prayerManualCityId) ?? SettingsDefaults.prayerManualCityId
            if let city = OfflineCityDatabase.city(byId: manualId) {
                self.activeCity = city
                self.preciseCoordinates = nil
                self.preciseElevation = nil
                self.resolvedNativeCityName = city.name
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
            // Denied or restricted: fallback to last saved or default city
            break
        }
    }

    public func setManualCity(id: String) {
        if let city = OfflineCityDatabase.city(byId: id) {
            self.activeCity = city
            self.preciseCoordinates = nil
            self.preciseElevation = nil
            self.resolvedNativeCityName = city.name
            UserDefaults.standard.set(city.coordinates.latitude, forKey: SettingsKey.prayerLastLatitude)
            UserDefaults.standard.set(city.coordinates.longitude, forKey: SettingsKey.prayerLastLongitude)
            UserDefaults.standard.set(city.elevationMeters, forKey: SettingsKey.prayerLastAltitude)
            UserDefaults.standard.set(city.name, forKey: SettingsKey.prayerResolvedCityName)
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

        let lat = location.coordinate.latitude
        let lon = location.coordinate.longitude
        let altitude = location.verticalAccuracy >= 0 ? location.altitude : nil
        let exactCoords = Coordinates(latitude: lat, longitude: lon)
        let matched = OfflineCityDatabase.closestCity(to: exactCoords)

        Task { @MainActor in
            self.activeCity = matched
            self.preciseCoordinates = exactCoords
            self.preciseElevation = altitude.map { max(0, $0) }

            UserDefaults.standard.set(lat, forKey: SettingsKey.prayerLastLatitude)
            UserDefaults.standard.set(lon, forKey: SettingsKey.prayerLastLongitude)
            if let alt = altitude {
                UserDefaults.standard.set(alt, forKey: SettingsKey.prayerLastAltitude)
            }

            // Native reverse geocoding via CLGeocoder
            let geocoder = CLGeocoder()
            geocoder.reverseGeocodeLocation(location) { placemarks, error in
                guard let placemark = placemarks?.first, error == nil else {
                    Task { @MainActor in
                        self.resolvedNativeCityName = matched.name
                        UserDefaults.standard.set(matched.name, forKey: SettingsKey.prayerResolvedCityName)
                    }
                    return
                }

                let cityName = placemark.locality ?? placemark.subAdministrativeArea ?? placemark.administrativeArea ?? matched.name
                Task { @MainActor in
                    self.resolvedNativeCityName = cityName
                    UserDefaults.standard.set(cityName, forKey: SettingsKey.prayerResolvedCityName)
                }
            }
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Silent failure; offline database fallback remains active
    }

    // MARK: - Private Helpers

    private func restoreLastSavedCity() {
        let lat = UserDefaults.standard.double(forKey: SettingsKey.prayerLastLatitude)
        let lon = UserDefaults.standard.double(forKey: SettingsKey.prayerLastLongitude)
        let alt = UserDefaults.standard.double(forKey: SettingsKey.prayerLastAltitude)
        let savedName = UserDefaults.standard.string(forKey: SettingsKey.prayerResolvedCityName)

        if lat != 0.0 && lon != 0.0 {
            let coords = Coordinates(latitude: lat, longitude: lon)
            self.activeCity = OfflineCityDatabase.closestCity(to: coords)
            self.preciseCoordinates = coords
            if alt > 0 {
                self.preciseElevation = alt
            }
            if let savedName = savedName, !savedName.isEmpty {
                self.resolvedNativeCityName = savedName
            }
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
