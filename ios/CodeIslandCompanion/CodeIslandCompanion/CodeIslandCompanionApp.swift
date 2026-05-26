import SwiftUI

@main
struct CodeIslandCompanionApp: App {
    @StateObject private var connection: CompanionConnection
    @StateObject private var liveActivity: LiveActivityController

    init() {
        let connection = CompanionConnection()
        let liveActivity = LiveActivityController()
        connection.onStateReceived = { [weak liveActivity] state in
            Task { @MainActor in
                liveActivity?.updateIfRunning(with: state)
            }
        }
        _connection = StateObject(wrappedValue: connection)
        _liveActivity = StateObject(wrappedValue: liveActivity)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connection)
                .environmentObject(liveActivity)
        }
    }
}
