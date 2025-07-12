import SwiftUI

@main
struct SpeedyBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // No window needed
        Settings {
            EmptyView()
        }
    }
}
