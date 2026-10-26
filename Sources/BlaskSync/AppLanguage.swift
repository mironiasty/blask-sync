import AppKit

/// The app's language: the system's, or one of the translations, chosen in Settings → General.
///
/// Stored as the app's own `AppleLanguages`, which is what macOS's per-app language setting (System Settings
/// → General → Language & Region) writes too. macOS reads it at launch, so a change needs a relaunch.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, pl, de, es, fr

    var id: Self { self }

    /// Each language in its own language, so it can be found whatever the app currently shows.
    var title: String {
        switch self {
        case .system: String(localized: "System Default", comment: "Language setting: follow macOS")
        case .en: "English"
        case .pl: "Polski"
        case .de: "Deutsch"
        case .es: "Español"
        case .fr: "Français"
        }
    }

    private static let key = "AppleLanguages"

    /// The saved choice. Reads only the app's own preferences; the standard lookup would fall back to the
    /// system's languages.
    static var current: AppLanguage {
        get {
            let domain = Bundle.main.bundleIdentifier.flatMap(UserDefaults.standard.persistentDomain(forName:))
            guard let code = (domain?[key] as? [String])?.first else { return .system }
            return AppLanguage(rawValue: code) ?? .system
        }
        set {
            if newValue == .system {
                UserDefaults.standard.removeObject(forKey: key)
            } else {
                UserDefaults.standard.set([newValue.rawValue], forKey: key)
            }
        }
    }

    /// The language the running app shows.
    static let atLaunch = current
}

extension NSApplication {
    /// Opens a fresh copy of the app, then quits this one.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { self.terminate(nil) }
        }
    }
}
