import SwiftUI

@main
struct BlaskSyncApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    // Not @State: the Command Line Tools lack the SwiftUI macro plugin. The App value is created once anyway.
    private let model = AppModel()

    var body: some Scene {
        MenuBarExtra("Blask Sync", systemImage: "lightbulb.led") {
            MenuView(model: model)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The bundled app sets LSUIElement; this covers `swift run`, which has no Info.plist.
        NSApp.setActivationPolicy(.accessory)
    }
}
