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
}
