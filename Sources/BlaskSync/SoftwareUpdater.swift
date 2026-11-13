import AppKit
import Observation

#if !APP_STORE
    import Sparkle
#endif

/// Checks for, downloads and installs new releases through Sparkle. The feed (`SUFeedURL`) is the
/// `appcast.xml` attached to the latest GitHub release; updates must be signed with the key in
/// `SUPublicEDKey`. Development builds have no feed, so they never replace themselves with a release.
/// The Mac App Store build (`APP_STORE`) is built without Sparkle: the App Store updates it.
@MainActor
@Observable
final class SoftwareUpdater: NSObject {
    /// False while a check or update is already in progress, and when updates aren't available.
    private(set) var canCheckForUpdates = false

    /// Whether this build updates itself: release builds do, development builds and `swift run` don't.
    var isAvailable: Bool { controller != nil }

    #if APP_STORE
        private let controller: AnyObject? = nil
    #else
        @ObservationIgnored private var controller: SPUStandardUpdaterController?
        @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?
    #endif

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            ?? String(localized: "development", comment: "Version shown for builds without one")
    }

    #if APP_STORE
        var automaticallyChecks: Bool {
            get { false }
            set {}
        }

        func checkForUpdates() {}
    #else
        var automaticallyChecks: Bool {
            get {
                access(keyPath: \.automaticallyChecks)
                return controller?.updater.automaticallyChecksForUpdates ?? false
            }
            set {
                withMutation(keyPath: \.automaticallyChecks) {
                    controller?.updater.automaticallyChecksForUpdates = newValue
                }
            }
        }

        override init() {
            super.init()
            // Development builds drop the feed from Info.plist; `swift run` has no Info.plist at all.
            guard Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") != nil else { return }
            let controller = SPUStandardUpdaterController(
                startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
            self.controller = controller
            canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) {
                [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
            }
        }

        func checkForUpdates() {
            NSApp.activate()
            controller?.checkForUpdates(nil)
        }
    #endif
}

#if !APP_STORE
    extension SoftwareUpdater: SPUStandardUserDriverDelegate {
        /// A menu bar app has no window of its own in front, so let Sparkle show scheduled update alerts
        /// without stealing focus mid-task, and bring them forward when it does.
        nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

        nonisolated func standardUserDriverWillHandleShowingUpdate(
            _ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState
        ) {
            guard handleShowingUpdate else { return }
            MainActor.assumeIsolated { NSApp.activate() }
        }
    }
#endif
