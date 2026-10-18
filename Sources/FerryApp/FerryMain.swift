import AppKit
import SwiftUI

struct FerryRootApp: App {
    @StateObject private var model = AppModel()

    init() {
        // Running as a bare SwiftPM executable (no .app bundle): become a regular foreground app.
        NSApplication.shared.setActivationPolicy(.regular)
        // Bare SwiftPM executable: set the Dock icon at runtime (path relative to CWD, e.g. `swift run` from the repo).
        if let icon = NSImage(contentsOfFile: "icon/Ferry.icns") {
            NSApplication.shared.applicationIconImage = icon
        }
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
