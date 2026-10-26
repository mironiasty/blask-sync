import Foundation

/// Local builds are "Blask Sync Dev" (bundle ID ending in `.dev`, see `scripts/bundle.sh`), so they can be
/// installed next to the release. `swift run` has no bundle and counts as development too.
enum AppVariant {
    static let isDevelopment = Bundle.main.bundleIdentifier.map { $0.hasSuffix(".dev") } ?? true

    static let name =
        Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
        ?? (isDevelopment ? "Blask Sync Dev" : "Blask Sync")
}
