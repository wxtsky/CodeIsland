import XCTest
@testable import CodeIslandCore

final class OfflineCityDatabaseTests: XCTestCase {

    func testExactCityMatches() {
        // Monas coordinates should resolve to Jakarta
        let monas = Coordinates(latitude: -6.1754, longitude: 106.8272)
        let matched = OfflineCityDatabase.closestCity(to: monas)
        XCTAssertEqual(matched.id, "jakarta")
        XCTAssertEqual(matched.name, "Jakarta")

        // Juanda airport coordinates should resolve to Surabaya
        let juanda = Coordinates(latitude: -7.3798, longitude: 112.7874)
        let sby = OfflineCityDatabase.closestCity(to: juanda)
        XCTAssertEqual(sby.id, "surabaya")
    }

    func testHaversineDistanceCalculation() {
        // Jakarta to Bandung is roughly 120-150 km
        let jkt = Coordinates(latitude: -6.2088, longitude: 106.8456)
        let bdg = Coordinates(latitude: -6.9175, longitude: 107.6191)

        let dist = OfflineCityDatabase.haversineDistanceKilometers(from: jkt, to: bdg)
        XCTAssertGreaterThan(dist, 110)
        XCTAssertLessThan(dist, 160)
    }

    func testCityLookupById() {
        let city = OfflineCityDatabase.city(byId: "banda_aceh")
        XCTAssertNotNil(city)
        XCTAssertEqual(city?.name, "Banda Aceh")
        XCTAssertEqual(city?.provinceOrCountry, "Aceh")

        let nonExistent = OfflineCityDatabase.city(byId: "atlantis")
        XCTAssertNil(nonExistent)
    }

    func testCityElevationsAndLongitudeTimezoneFallback() {
        // High elevation cities should reflect their actual elevation
        let bdg = OfflineCityDatabase.city(byId: "bandung")
        XCTAssertEqual(bdg?.elevationMeters, 708)

        let bkt = OfflineCityDatabase.city(byId: "bukittinggi")
        XCTAssertEqual(bkt?.elevationMeters, 930)

        // Timezone fallback test without identifier:
        // Longitude 106° (WIB) -> GMT+7
        let wibCity = OfflineCity(id: "c1", name: "WIB City", provinceOrCountry: "ID", coordinates: Coordinates(latitude: -6.0, longitude: 106.0), timeZoneIdentifier: "invalid_tz")
        XCTAssertEqual(wibCity.timeZone.secondsFromGMT(), 7 * 3600)

        // Longitude 119° (WITA) -> GMT+8
        let witaCity = OfflineCity(id: "c2", name: "WITA City", provinceOrCountry: "ID", coordinates: Coordinates(latitude: -5.0, longitude: 119.0), timeZoneIdentifier: "invalid_tz")
        XCTAssertEqual(witaCity.timeZone.secondsFromGMT(), 8 * 3600)

        // Longitude 140° (WIT) -> GMT+9
        let witCity = OfflineCity(id: "c3", name: "WIT City", provinceOrCountry: "ID", coordinates: Coordinates(latitude: -2.0, longitude: 140.0), timeZoneIdentifier: "invalid_tz")
        XCTAssertEqual(witCity.timeZone.secondsFromGMT(), 9 * 3600)
    }
}
