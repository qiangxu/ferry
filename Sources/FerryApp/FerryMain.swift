import AppKit
import SwiftUI

struct FerryRootApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Running as a bare SwiftPM executable (no .app bundle): become a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Ferry") {
            RootView(model: model)
        }
    }
}

public enum FerryMain {
    public static func main() {
        FerryRootApp.main()
    }
}
