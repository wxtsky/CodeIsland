import SwiftUI

@main
struct CodeIslandCompanionApp: App {
    @StateObject private var connection = CompanionConnection()
    @StateObject private var liveActivity = LiveActivityController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(connection)
                .environmentObject(liveActivity)
        }
    }
}
