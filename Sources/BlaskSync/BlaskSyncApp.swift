import SwiftUI

@main
struct BlaskSyncApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate
    @State private var model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            // Filled while the lights are being driven.
            Image(systemName: model.lightControl?.isStreaming == true ? "lightbulb.led.fill" : "lightbulb.led")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }

        Window("Manual Control", id: ManualControlView.windowId) {
            ManualControlView(model: model)
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
