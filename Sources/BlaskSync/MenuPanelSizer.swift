import AppKit
import SwiftUI
import os

/// Keeps the menu bar panel's window exactly as tall as its content. SwiftUI grows the window when the
/// content grows (an error message, a status banner) but doesn't always shrink it back, which left empty
/// margins above and below the content. Applied whenever the content's height changes and whenever the
/// panel opens; the top edge stays put under the menu bar.
struct MenuPanelSizer: NSViewRepresentable {
    let contentHeight: CGFloat

    func makeNSView(context: Context) -> SizerView { SizerView() }

    func updateNSView(_ view: SizerView, context: Context) {
        view.contentHeight = contentHeight
        view.fit()
    }

    final class SizerView: NSView {
        var contentHeight: CGFloat = 0
        private var observer: NSObjectProtocol?
        private static let logger = Logger(subsystem: "local.blasksync", category: "menu")

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            guard let window else { return }
            observer = NotificationCenter.default.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.fit() }
            }
        }

        func fit() {
            guard let window, contentHeight > 0, abs(window.frame.height - contentHeight) > 0.5 else { return }
            Self.logger.notice("Panel was \(window.frame.height, privacy: .public) pt tall for \(self.contentHeight, privacy: .public) pt of content; resizing")
            var frame = window.frame
            frame.origin.y += frame.height - contentHeight
            frame.size.height = contentHeight
            window.setFrame(frame, display: true)
        }
    }
}
