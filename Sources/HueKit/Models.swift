import Foundation

/// A bridge found on the local network (via mDNS, the Hue cloud lookup, or a manually entered IP).
public struct DiscoveredBridge: Identifiable, Hashable, Sendable {
    /// Bridge ID, normalized to lowercase hex, e.g. `001788fffe123456`.
    public let id: String
    public var host: String
    public var name: String?

    public init(id: String, host: String, name: String? = nil) {
        self.id = id.lowercased()
        self.host = host
        self.name = name
    }
}

/// Everything needed to talk to a paired bridge. Persisted in the Keychain.
public struct BridgeCredentials: Codable, Sendable, Equatable {
    public let bridgeId: String
    public var host: String
    public var name: String?
    /// The "username" returned by pairing; sent as the `hue-application-key` header.
    public let applicationKey: String
    /// 32-char hex PSK used for the Entertainment API's DTLS handshake.
    public let clientKey: String

    public init(bridgeId: String, host: String, name: String?, applicationKey: String, clientKey: String) {
        self.bridgeId = bridgeId.lowercased()
        self.host = host
        self.name = name
        self.applicationKey = applicationKey
        self.clientKey = clientKey
    }
}

/// An entertainment area ("entertainment_configuration" in CLIP v2), the unit the streaming API drives.
public struct EntertainmentArea: Identifiable, Hashable, Sendable, Decodable {
    public let id: String
    public let name: String
    /// `screen`, `monitor`, `music`, `3dspace` or `other`.
    public let configurationType: String
    /// `active` while some app is streaming to it, otherwise `inactive`.
    public let status: String
    public let channelCount: Int

    private struct Metadata: Decodable { let name: String }
    private struct Channel: Decodable { let channel_id: Int }

    private enum CodingKeys: String, CodingKey {
        case id, metadata, status, channels
        case configurationType = "configuration_type"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(Metadata.self, forKey: .metadata).name
        configurationType = try c.decode(String.self, forKey: .configurationType)
        status = try c.decode(String.self, forKey: .status)
        channelCount = try c.decode([Channel].self, forKey: .channels).count
    }
}

public enum HueError: LocalizedError, Equatable {
    case linkButtonTimeout
    case missingClientKey
    case unauthorized
    case bridge(type: Int, description: String)
    case http(status: Int)
    case unexpectedResponse
    case certificateMismatch(expected: String)
    case keychain(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .linkButtonTimeout:
            "The link button wasn't pressed in time. Try again."
        case .missingClientKey:
            "The bridge didn't return a client key. Update the bridge firmware in the Hue app."
        case .unauthorized:
            "The bridge no longer accepts this app's key. Forget the bridge and pair again."
        case .bridge(_, let description):
            "Bridge error: \(description)"
        case .http(let status):
            "The bridge responded with HTTP \(status)."
        case .unexpectedResponse:
            "Unexpected response from the bridge."
        case .certificateMismatch(let expected):
            "The device's certificate doesn't belong to bridge \(expected)."
        case .keychain(let status):
            "Keychain error \(status): \(SecCopyErrorMessageString(status, nil) as String? ?? "unknown")"
        }
    }
}
