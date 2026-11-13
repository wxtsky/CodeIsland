import Foundation

/// A city representation stored offline for zero-network reverse geocoding and manual selection.
public struct OfflineCity: Equatable, Sendable, Identifiable, Codable {
    public let id: String
    public let name: String
    public let provinceOrCountry: String
    public let coordinates: Coordinates
    public let timeZoneIdentifier: String
    public let elevationMeters: Double

    public init(
        id: String,
        name: String,
        provinceOrCountry: String,
        coordinates: Coordinates,
        timeZoneIdentifier: String,
        elevationMeters: Double = 10.0
    ) {
        self.id = id
        self.name = name
        self.provinceOrCountry = provinceOrCountry
        self.coordinates = coordinates
        self.timeZoneIdentifier = timeZoneIdentifier
        self.elevationMeters = elevationMeters
    }

    public var timeZone: TimeZone {
        if let tz = TimeZone(identifier: timeZoneIdentifier) {
            return tz
        }
        // Fallback by Indonesian longitude bands:
        // WIB (GMT+7): lon < 115°
        // WITA (GMT+8): 115° <= lon < 125°
        // WIT (GMT+9): lon >= 125°
        let lon = coordinates.longitude
        let offsetHours = lon < 115.0 ? 7 : (lon < 125.0 ? 8 : 9)
        return TimeZone(secondsFromGMT: offsetHours * 3600) ?? TimeZone.current
    }
}

/// Offline catalog of Indonesian regencies/cities and international capitals with Haversine distance matching.
public enum OfflineCityDatabase {

    /// Finds the closest city in the database using the spherical Haversine formula.
    public static func closestCity(to coordinates: Coordinates) -> OfflineCity {
        var closest: OfflineCity = defaultCity
        var minDistance = Double.infinity

        for city in allCities {
            let dist = haversineDistanceKilometers(from: coordinates, to: city.coordinates)
            if dist < minDistance {
                minDistance = dist
                closest = city
            }
        }
        return closest
    }

    public static func city(byId id: String) -> OfflineCity? {
        allCities.first { $0.id == id }
    }

    public static let defaultCity = OfflineCity(
        id: "jakarta",
        name: "Jakarta",
        provinceOrCountry: "DKI Jakarta",
        coordinates: Coordinates(latitude: -6.2088, longitude: 106.8456),
        timeZoneIdentifier: "Asia/Jakarta",
        elevationMeters: 8.0
    )

    /// Great-circle distance between two points on a sphere (radius 6371 km).
    public static func haversineDistanceKilometers(from p1: Coordinates, to p2: Coordinates) -> Double {
        let r = 6371.0 // Earth radius in km
        let dLat = (p2.latitude - p1.latitude) * .pi / 180.0
        let dLon = (p2.longitude - p1.longitude) * .pi / 180.0
        let lat1 = p1.latitude * .pi / 180.0
        let lat2 = p2.latitude * .pi / 180.0

        let a = sin(dLat / 2.0) * sin(dLat / 2.0)
            + cos(lat1) * cos(lat2) * sin(dLon / 2.0) * sin(dLon / 2.0)
        let c = 2.0 * atan2(sqrt(a), sqrt(max(0, 1.0 - a)))
        return r * c
    }

    // MARK: - Cities Catalog

    public static let allCities: [OfflineCity] = [
        // DKI Jakarta & Bodetabek
        OfflineCity(id: "jakarta", name: "Jakarta", provinceOrCountry: "DKI Jakarta", coordinates: Coordinates(latitude: -6.2088, longitude: 106.8456), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 8),
        OfflineCity(id: "bogor", name: "Bogor", provinceOrCountry: "Jawa Barat", coordinates: Coordinates(latitude: -6.5971, longitude: 106.8060), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 265),
        OfflineCity(id: "depok", name: "Depok", provinceOrCountry: "Jawa Barat", coordinates: Coordinates(latitude: -6.4025, longitude: 106.7942), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 90),
        OfflineCity(id: "tangerang", name: "Tangerang", provinceOrCountry: "Banten", coordinates: Coordinates(latitude: -6.1783, longitude: 106.6319), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 18),
        OfflineCity(id: "tangerang_selatan", name: "Tangerang Selatan", provinceOrCountry: "Banten", coordinates: Coordinates(latitude: -6.2889, longitude: 106.7179), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 40),
        OfflineCity(id: "bekasi", name: "Bekasi", provinceOrCountry: "Jawa Barat", coordinates: Coordinates(latitude: -6.2383, longitude: 106.9756), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 19),

        // Jawa Barat & Banten
        OfflineCity(id: "bandung", name: "Bandung", provinceOrCountry: "Jawa Barat", coordinates: Coordinates(latitude: -6.9175, longitude: 107.6191), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 708),
        OfflineCity(id: "serang", name: "Serang", provinceOrCountry: "Banten", coordinates: Coordinates(latitude: -6.1104, longitude: 106.1607), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 20),
        OfflineCity(id: "cirebon", name: "Cirebon", provinceOrCountry: "Jawa Barat", coordinates: Coordinates(latitude: -6.7320, longitude: 108.5523), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 8),
        OfflineCity(id: "sukabumi", name: "Sukabumi", provinceOrCountry: "Jawa Barat", coordinates: Coordinates(latitude: -6.9277, longitude: 106.9300), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 584),
        OfflineCity(id: "tasikmalaya", name: "Tasikmalaya", provinceOrCountry: "Jawa Barat", coordinates: Coordinates(latitude: -7.3274, longitude: 108.2207), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 351),

        // Jawa Tengah & DIY
        OfflineCity(id: "semarang", name: "Semarang", provinceOrCountry: "Jawa Tengah", coordinates: Coordinates(latitude: -6.9667, longitude: 110.4167), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 5),
        OfflineCity(id: "yogyakarta", name: "Yogyakarta", provinceOrCountry: "DI Yogyakarta", coordinates: Coordinates(latitude: -7.7956, longitude: 110.3695), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 113),
        OfflineCity(id: "surakarta", name: "Surakarta (Solo)", provinceOrCountry: "Jawa Tengah", coordinates: Coordinates(latitude: -7.5755, longitude: 110.8243), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 105),
        OfflineCity(id: "magelang", name: "Magelang", provinceOrCountry: "Jawa Tengah", coordinates: Coordinates(latitude: -7.4706, longitude: 110.2178), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 380),
        OfflineCity(id: "purwokerto", name: "Purwokerto", provinceOrCountry: "Jawa Tengah", coordinates: Coordinates(latitude: -7.4243, longitude: 109.2302), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 84),
        OfflineCity(id: "pekalongan", name: "Pekalongan", provinceOrCountry: "Jawa Tengah", coordinates: Coordinates(latitude: -6.8886, longitude: 109.6753), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 8),
        OfflineCity(id: "tegal", name: "Tegal", provinceOrCountry: "Jawa Tengah", coordinates: Coordinates(latitude: -6.8694, longitude: 109.1402), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 5),

        // Jawa Timur
        OfflineCity(id: "surabaya", name: "Surabaya", provinceOrCountry: "Jawa Timur", coordinates: Coordinates(latitude: -7.2575, longitude: 112.7521), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 5),
        OfflineCity(id: "malang", name: "Malang", provinceOrCountry: "Jawa Timur", coordinates: Coordinates(latitude: -7.9666, longitude: 112.6326), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 444),
        OfflineCity(id: "kediri", name: "Kediri", provinceOrCountry: "Jawa Timur", coordinates: Coordinates(latitude: -7.8480, longitude: 112.0178), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 67),
        OfflineCity(id: "madiun", name: "Madiun", provinceOrCountry: "Jawa Timur", coordinates: Coordinates(latitude: -7.6298, longitude: 111.5239), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 65),
        OfflineCity(id: "banyuwangi", name: "Banyuwangi", provinceOrCountry: "Jawa Timur", coordinates: Coordinates(latitude: -8.2192, longitude: 114.3691), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 15),
        OfflineCity(id: "jember", name: "Jember", provinceOrCountry: "Jawa Timur", coordinates: Coordinates(latitude: -8.1724, longitude: 113.7007), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 89),

        // Sumatera
        OfflineCity(id: "banda_aceh", name: "Banda Aceh", provinceOrCountry: "Aceh", coordinates: Coordinates(latitude: 5.5483, longitude: 95.3238), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 10),
        OfflineCity(id: "medan", name: "Medan", provinceOrCountry: "Sumatera Utara", coordinates: Coordinates(latitude: 3.5952, longitude: 98.6722), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 26),
        OfflineCity(id: "padang", name: "Padang", provinceOrCountry: "Sumatera Barat", coordinates: Coordinates(latitude: -0.9471, longitude: 100.4172), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 10),
        OfflineCity(id: "bukittinggi", name: "Bukittinggi", provinceOrCountry: "Sumatera Barat", coordinates: Coordinates(latitude: -0.3056, longitude: 100.3692), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 930),
        OfflineCity(id: "pekanbaru", name: "Pekanbaru", provinceOrCountry: "Riau", coordinates: Coordinates(latitude: 0.5071, longitude: 101.4478), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 12),
        OfflineCity(id: "batam", name: "Batam", provinceOrCountry: "Kepulauan Riau", coordinates: Coordinates(latitude: 1.1301, longitude: 104.0529), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 10),
        OfflineCity(id: "tanjungpinang", name: "Tanjungpinang", provinceOrCountry: "Kepulauan Riau", coordinates: Coordinates(latitude: 0.9167, longitude: 104.4500), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 15),
        OfflineCity(id: "jambi", name: "Jambi", provinceOrCountry: "Jambi", coordinates: Coordinates(latitude: -1.6101, longitude: 103.6131), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 15),
        OfflineCity(id: "palembang", name: "Palembang", provinceOrCountry: "Sumatera Selatan", coordinates: Coordinates(latitude: -2.9909, longitude: 104.7565), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 8),
        OfflineCity(id: "bengkulu", name: "Bengkulu", provinceOrCountry: "Bengkulu", coordinates: Coordinates(latitude: -3.8004, longitude: 102.2655), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 15),
        OfflineCity(id: "bandar_lampung", name: "Bandar Lampung", provinceOrCountry: "Lampung", coordinates: Coordinates(latitude: -5.4500, longitude: 105.2667), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 20),
        OfflineCity(id: "pangkalpinang", name: "Pangkalpinang", provinceOrCountry: "Bangka Belitung", coordinates: Coordinates(latitude: -2.1333, longitude: 106.1167), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 15),

        // Kalimantan
        OfflineCity(id: "pontianak", name: "Pontianak", provinceOrCountry: "Kalimantan Barat", coordinates: Coordinates(latitude: 0.0000, longitude: 109.3333), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 3),
        OfflineCity(id: "palangkaraya", name: "Palangka Raya", provinceOrCountry: "Kalimantan Tengah", coordinates: Coordinates(latitude: -2.2167, longitude: 113.9167), timeZoneIdentifier: "Asia/Jakarta", elevationMeters: 10),
        OfflineCity(id: "banjarmasin", name: "Banjarmasin", provinceOrCountry: "Kalimantan Selatan", coordinates: Coordinates(latitude: -3.3194, longitude: 114.5908), timeZoneIdentifier: "Asia/Makassar", elevationMeters: 2),
        OfflineCity(id: "banjarbaru", name: "Banjarbaru", provinceOrCountry: "Kalimantan Selatan", coordinates: Coordinates(latitude: -3.4400, longitude: 114.8300), timeZoneIdentifier: "Asia/Makassar", elevationMeters: 25),
        OfflineCity(id: "samarinda", name: "Samarinda", provinceOrCountry: "Kalimantan Timur", coordinates: Coordinates(latitude: -0.5022, longitude: 117.1536), timeZoneIdentifier: "Asia/Makassar", elevationMeters: 10),
        OfflineCity(id: "balikpapan", name: "Balikpapan", provinceOrCountry: "Kalimantan Timur", coordinates: Coordinates(latitude: -1.2379, longitude: 116.8529), timeZoneIdentifier: "Asia/Makassar", elevationMeters: 15),
        OfflineCity(id: "ikn", name: "Nusantara (IKN)", provinceOrCountry: "Kalimantan Timur", coordinates: Coordinates(latitude: -0.9700, longitude: 116.7000), timeZoneIdentifier: "Asia/Makassar", elevationMeters: 40),
        OfflineCity(id: "tarakan", name: "Tarakan", provinceOrCountry: "Kalimantan Utara", coordinates: Coordinates(latitude: 3.3000, longitude: 117.6333), timeZoneIdentifier: "Asia/Makassar", elevationMeters: 10),

        // Bali & Nusa Tenggara
        OfflineCity(id: "denpasar", name: "Denpasar", provinceOrCountry: "Bali", coordinates: Coordinates(latitude: -8.6705, longitude: 115.2126), timeZoneIdentifier: "Asia/Makassar", elevationMeters: 15),
        OfflineCity(id: "mataram", name: "Mataram", provinceOrCountry: "Nusa Tenggara Barat", coordinates: Coordinates(latitude: -8.5833, longitude: 116.1167), timeZoneIdentifier: "Asia/Makassar", elevationMeters: 25),
        OfflineCity(id: "bima", name: "Bima", provinceOrCountry: "Nusa Tenggara Barat", coordinates: Coordinates(latitude: -8.4600, longitude: 118.7300), timeZoneIdentifier: "Asia/Makassar", elevationMeters: 15),
        OfflineCity(id: "kupang", name: "Kupang", provinceOrCountry: "Nusa Tenggara Timur", coordinates: Coordinates(latitude: -10.1772, longitude: 123.6070), timeZoneIdentifier: "Asia/Makassar", elevationMeters: 25),
        OfflineCity(id: "labuan_bajo", name: "Labuan Bajo", provinceOrCountry: "Nusa Tenggara Timur", coordinates: Coordinates(latitude: -8.4964, longitude: 119.8877), timeZoneIdentifier: "Asia/Makassar", elevationMeters: 20),

        // Sulawesi
        OfflineCity(id: "makassar", name: "Makassar", provinceOrCountry: "Sulawesi Selatan", coordinates: Coordinates(latitude: -5.1477, longitude: 119.4327), timeZoneIdentifier: "Asia/Makassar", elevationMeters: 15),
        OfflineCity(id: "manado", name: "Manado", provinceOrCountry: "Sulawesi Utara", coordinates: Coordinates(latitude: 1.4748, longitude: 124.8428), timeZoneIdentifier: "Asia/Makassar", elevationMeters: 20),
        OfflineCity(id: "palu", name: "Palu", provinceOrCountry: "Sulawesi Tengah", coordinates: Coordinates(latitude: -0.8917, longitude: 119.8707), timeZoneIdentifier: "Asia/Makassar", elevationMeters: 10),
        OfflineCity(id: "kendari", name: "Kendari", provinceOrCountry: "Sulawesi Tenggara", coordinates: Coordinates(latitude: -3.9985, longitude: 122.5126), timeZoneIdentifier: "Asia/Makassar", elevationMeters: 15),
        OfflineCity(id: "gorontalo", name: "Gorontalo", provinceOrCountry: "Gorontalo", coordinates: Coordinates(latitude: 0.5435, longitude: 123.0568), timeZoneIdentifier: "Asia/Makassar", elevationMeters: 15),
        OfflineCity(id: "mamuju", name: "Mamuju", provinceOrCountry: "Sulawesi Barat", coordinates: Coordinates(latitude: -2.6748, longitude: 118.8885), timeZoneIdentifier: "Asia/Makassar", elevationMeters: 15),

        // Maluku & Papua
        OfflineCity(id: "ambon", name: "Ambon", provinceOrCountry: "Maluku", coordinates: Coordinates(latitude: -3.6554, longitude: 128.1908), timeZoneIdentifier: "Asia/Jayapura", elevationMeters: 12),
        OfflineCity(id: "ternate", name: "Ternate", provinceOrCountry: "Maluku Utara", coordinates: Coordinates(latitude: 0.7833, longitude: 127.3667), timeZoneIdentifier: "Asia/Jayapura", elevationMeters: 15),
        OfflineCity(id: "jayapura", name: "Jayapura", provinceOrCountry: "Papua", coordinates: Coordinates(latitude: -2.5489, longitude: 140.7197), timeZoneIdentifier: "Asia/Jayapura", elevationMeters: 25),
        OfflineCity(id: "sorong", name: "Sorong", provinceOrCountry: "Papua Barat Daya", coordinates: Coordinates(latitude: -0.8762, longitude: 131.2558), timeZoneIdentifier: "Asia/Jayapura", elevationMeters: 15),
        OfflineCity(id: "manokwari", name: "Manokwari", provinceOrCountry: "Papua Barat", coordinates: Coordinates(latitude: -0.8615, longitude: 134.0620), timeZoneIdentifier: "Asia/Jayapura", elevationMeters: 20),
        OfflineCity(id: "merauke", name: "Merauke", provinceOrCountry: "Papua Selatan", coordinates: Coordinates(latitude: -8.4932, longitude: 140.4019), timeZoneIdentifier: "Asia/Jayapura", elevationMeters: 8),
        OfflineCity(id: "timika", name: "Timika", provinceOrCountry: "Papua Tengah", coordinates: Coordinates(latitude: -4.5467, longitude: 136.8837), timeZoneIdentifier: "Asia/Jayapura", elevationMeters: 35),

        // Global Capitals & Holy Cities
        OfflineCity(id: "makkah", name: "Makkah", provinceOrCountry: "Arab Saudi", coordinates: Coordinates(latitude: 21.4225, longitude: 39.8262), timeZoneIdentifier: "Asia/Riyadh", elevationMeters: 277),
        OfflineCity(id: "madinah", name: "Madinah", provinceOrCountry: "Arab Saudi", coordinates: Coordinates(latitude: 24.5247, longitude: 39.5692), timeZoneIdentifier: "Asia/Riyadh", elevationMeters: 608),
        OfflineCity(id: "kuala_lumpur", name: "Kuala Lumpur", provinceOrCountry: "Malaysia", coordinates: Coordinates(latitude: 3.1390, longitude: 101.6869), timeZoneIdentifier: "Asia/Kuala_Lumpur", elevationMeters: 22),
        OfflineCity(id: "singapore", name: "Singapura", provinceOrCountry: "Singapura", coordinates: Coordinates(latitude: 1.3521, longitude: 103.8198), timeZoneIdentifier: "Asia/Singapore", elevationMeters: 15),
        OfflineCity(id: "tokyo", name: "Tokyo", provinceOrCountry: "Jepang", coordinates: Coordinates(latitude: 35.6762, longitude: 139.6503), timeZoneIdentifier: "Asia/Tokyo", elevationMeters: 44),
        OfflineCity(id: "london", name: "London", provinceOrCountry: "Britania Raya", coordinates: Coordinates(latitude: 51.5074, longitude: -0.1278), timeZoneIdentifier: "Europe/London", elevationMeters: 11),
        OfflineCity(id: "new_york", name: "New York", provinceOrCountry: "Amerika Serikat", coordinates: Coordinates(latitude: 40.7128, longitude: -74.0060), timeZoneIdentifier: "America/New_York", elevationMeters: 10),
        OfflineCity(id: "cairo", name: "Kairo", provinceOrCountry: "Mesir", coordinates: Coordinates(latitude: 30.0444, longitude: 31.2357), timeZoneIdentifier: "Africa/Cairo", elevationMeters: 23),
        OfflineCity(id: "istanbul", name: "Istanbul", provinceOrCountry: "Turki", coordinates: Coordinates(latitude: 41.0082, longitude: 28.9784), timeZoneIdentifier: "Europe/Istanbul", elevationMeters: 39)
    ]
}
