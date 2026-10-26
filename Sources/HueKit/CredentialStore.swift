import Foundation

/// Stores the paired bridge's credentials in a JSON file only the user can read, by default
/// `~/Library/Application Support/BlaskSync/bridge.json`. Unlike the Keychain, a file never prompts for a
/// password when the app's code signature changes.
public struct CredentialStore: Sendable {
    public let fileURL: URL

    public init(fileURL: URL = URL.applicationSupportDirectory.appending(path: "BlaskSync/bridge.json")) {
        self.fileURL = fileURL
    }

    public func load() throws -> BridgeCredentials? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        return try JSONDecoder().decode(BridgeCredentials.self, from: Data(contentsOf: fileURL))
    }

    public func save(_ credentials: BridgeCredentials) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(credentials).write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    public func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
