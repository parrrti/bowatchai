import SwiftUI

@main
struct BowatchApp: App {
    init() {
        Notifier.shared.requestAuthorization()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
