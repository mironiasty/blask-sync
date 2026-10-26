import AppKit
import SwiftUI

/// Reports whether the hosting window is actually on screen: open, not minimized and not fully covered.
/// SwiftUI's onDisappear doesn't reliably fire when a Settings window closes, so previews that start
/// screen or audio capture use this instead.
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> VisibilityView {
        let view = VisibilityView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: VisibilityView, context: Context) {
        view.onChange = onChange
    }

    final class VisibilityView: NSView {
        var onChange: ((Bool) -> Void)?
        private var observers: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard let window else {
                onChange?(false)
                return
            }
            let names = [
                NSWindow.didChangeOcclusionStateNotification,
                NSWindow.willCloseNotification,
                NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ]
            for name in names {
                observers.append(
                    NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                        [weak self] notification in
                        let closing = notification.name == NSWindow.willCloseNotification
                        MainActor.assumeIsolated { self?.report(closing: closing) }
                    })
            }
            report(closing: false)
        }

        private func report(closing: Bool) {
            guard let window else { return }
            onChange?(
                !closing && window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible))
        }
    }
}
