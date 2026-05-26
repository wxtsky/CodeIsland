import Foundation

#if os(watchOS)
enum WatchStateStore {
    static let appGroupIdentifier = "group.top.fengye.CodeIslandCompanion"
    private static let latestStateKey = "latestCompanionState"

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func save(_ state: CompanionStatePayload) {
        guard let data = try? encoder.encode(state) else { return }
        defaults.set(data, forKey: latestStateKey)
    }

    static func load() -> CompanionStatePayload? {
        guard let data = defaults.data(forKey: latestStateKey) else { return nil }
        return try? decoder.decode(CompanionStatePayload.self, from: data)
    }

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    }
}
#endif
