import SwiftUI

@main
struct BlaskSyncApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    private var model: AppModel { appDelegate.model }

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

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Owned here so termination can reach the sync session.
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The bundled app sets LSUIElement; this covers `swift run`, which has no Info.plist.
        NSApp.setActivationPolicy(.accessory)
    }

    /// Releases the lights before any graceful quit (menu, logout, shutdown, relaunch). Without the
    /// stop message the bridge would hold the lights for ~10 s.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let control = model.lightControl, control.state != .stopped else { return .terminateNow }
        Task {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await control.shutdown() }
                // An unreachable bridge mustn't block quitting.
                group.addTask { try? await Task.sleep(for: .seconds(2)) }
                await group.next()
                group.cancelAll()
            }
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
