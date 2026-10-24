import AppKit
import Observation
import Sparkle

/// Checks for, downloads and installs new releases through Sparkle. The feed (`SUFeedURL`) is the
/// `appcast.xml` attached to the latest GitHub release; updates must be signed with the key in
/// `SUPublicEDKey`.
@MainActor
@Observable
final class SoftwareUpdater: NSObject, SPUStandardUserDriverDelegate {
    /// False while a check or update is already in progress, and when running outside an app bundle.
    private(set) var canCheckForUpdates = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private var canCheckObservation: NSKeyValueObservation?

    var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development"
    }

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
        // `swift run` has no Info.plist, so no feed or key to check against.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: self)
        self.controller = controller
        canCheckObservation = controller.updater.observe(\.canCheckForUpdates, options: [.initial, .new]) { [weak self] updater, _ in
            MainActor.assumeIsolated { self?.canCheckForUpdates = updater.canCheckForUpdates }
        }
    }

    func checkForUpdates() {
        NSApp.activate()
        controller?.checkForUpdates(nil)
    }

    // MARK: SPUStandardUserDriverDelegate

    /// A menu bar app has no window of its own in front, so let Sparkle show scheduled update alerts
    /// without stealing focus mid-task, and bring them forward when it does.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        guard handleShowingUpdate else { return }
        MainActor.assumeIsolated { NSApp.activate() }
    }
}
