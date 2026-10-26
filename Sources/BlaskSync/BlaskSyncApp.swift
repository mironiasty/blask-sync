import SwiftUI

@main
struct BlaskSyncApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    private var model: AppModel { appDelegate.model }
    private var updater: SoftwareUpdater { appDelegate.updater }

    var body: some Scene {
        MenuBarExtra {
            MenuView(model: model)
        } label: {
            // Filled while the lights are being driven.
            Image(nsImage: MenuBarIcon.image(active: model.lightControl?.isStreaming == true))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model, updater: updater)
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
    let updater = SoftwareUpdater()

    func applicationDidFinishLaunching(_ notification: Notification) {
        // The bundled app sets LSUIElement; this covers `swift run`, which has no Info.plist.
        NSApp.setActivationPolicy(.accessory)

        // Show in the Dock and ⌘-Tab while Settings or Manual Control is open, so a window that went
        // behind others can be brought back; go back to menu-bar-only once they're closed.
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { self.updateActivationPolicy(closing: nil) }
            }
        }
        center.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { notification in
            let closing = notification.object as? NSWindow
            MainActor.assumeIsolated { self.updateActivationPolicy(closing: closing) }
        }
    }

    /// Regular app while a titled window (Settings, Manual Control) is open; menu-bar-only otherwise.
    /// The menu bar panel is an NSPanel and doesn't count.
    private func updateActivationPolicy(closing: NSWindow?) {
        let hasAppWindow = NSApp.windows.contains { window in
            window !== closing && window.isVisible && window.styleMask.contains(.titled) && !(window is NSPanel)
        }
        let policy: NSApplication.ActivationPolicy = hasAppWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != policy else { return }
        NSApp.setActivationPolicy(policy)
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
