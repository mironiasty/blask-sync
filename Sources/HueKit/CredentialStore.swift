import Foundation
import Security

/// Stores the paired bridge's credentials as a generic password in the login Keychain.
public struct CredentialStore: Sendable {
    public let service: String
    private let account = "paired-bridge"

    public init(service: String = "local.blasksync.bridge") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() throws -> BridgeCredentials? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else { throw HueError.keychain(status) }
        return try JSONDecoder().decode(BridgeCredentials.self, from: data)
    }

    public func save(_ credentials: BridgeCredentials) throws {
        let data = try JSONEncoder().encode(credentials)
        let update = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw HueError.keychain(update) }

        var query = baseQuery
        query[kSecValueData as String] = data
        let add = SecItemAdd(query as CFDictionary, nil)
        guard add == errSecSuccess else { throw HueError.keychain(add) }
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw HueError.keychain(status) }
    }
}
