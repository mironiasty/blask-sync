import SwiftUI

@main
struct BlaskSyncApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Blask Sync", systemImage: "lightbulb.led") {
            MenuView(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Light Control", id: LightControlView.windowId) {
            LightControlView(model: model)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The bundled app sets LSUIElement; this covers `swift run`, which has no Info.plist.
        NSApp.setActivationPolicy(.accessory)
    }
}
