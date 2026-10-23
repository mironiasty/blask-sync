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
    public let channels: [Channel]
    /// IDs of the `light` resources in the area, for regular (non-streaming) control such as power.
    public let lightIds: [String]

    /// One independently colorable zone. A plain bulb is one channel; a gradient strip may be several.
    public struct Channel: Identifiable, Hashable, Sendable, Decodable {
        public let id: UInt8
        /// Position in the room, each axis in -1...1: x left→right, y back→front (screen side is +1), z down→up.
        public let position: Position
        /// The lights (or strip segments) that render this channel; usually exactly one.
        public let members: [Member]

        /// IDs of the `entertainment` services (one per light) that render this channel.
        public var serviceIds: [String] { members.map(\.serviceId) }

        public struct Position: Hashable, Sendable, Decodable {
            public let x: Double
            public let y: Double
            public let z: Double

            public init(x: Double, y: Double, z: Double) {
                self.x = x
                self.y = y
                self.z = z
            }
        }

        public struct Member: Hashable, Sendable, Decodable {
            /// The light's `entertainment` service ID.
            public let serviceId: String
            /// Segment of that light; always 0 for single-segment lights.
            public let index: Int

            public init(serviceId: String, index: Int) {
                self.serviceId = serviceId
                self.index = index
            }

            private struct Service: Decodable { let rid: String }
            private enum CodingKeys: String, CodingKey { case service, index }

            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                serviceId = try c.decode(Service.self, forKey: .service).rid
                index = try c.decodeIfPresent(Int.self, forKey: .index) ?? 0
            }
        }

        private enum CodingKeys: String, CodingKey {
            case id = "channel_id"
            case position, members
        }

        public init(id: UInt8, position: Position, members: [Member]) {
            self.id = id
            self.position = position
            self.members = members
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(UInt8.self, forKey: .id)
            position = try c.decode(Position.self, forKey: .position)
            members = try c.decode([Member].self, forKey: .members)
        }
    }

    private struct Metadata: Decodable { let name: String }
    private struct LightService: Decodable { let rid: String }

    private enum CodingKeys: String, CodingKey {
        case id, metadata, status, channels
        case lightServices = "light_services"
        case configurationType = "configuration_type"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(Metadata.self, forKey: .metadata).name
        configurationType = try c.decode(String.self, forKey: .configurationType)
        status = try c.decode(String.self, forKey: .status)
        channels = try c.decode([Channel].self, forKey: .channels)
        lightIds = try c.decodeIfPresent([LightService].self, forKey: .lightServices)?.map(\.rid) ?? []
    }
}

/// A light that takes part in entertainment areas, as seen through its `entertainment` service.
public struct EntertainmentLight: Hashable, Sendable {
    public let serviceId: String
    public let name: String
    /// The light's archetype as set in the Hue app, e.g. `hue_lightstrip_pc`, `table_shade`, `hue_play`.
    public let archetype: String
    /// Number of independently streamable segments: more than 1 for gradient strips.
    public let segmentCount: Int
    /// The `light` resource, for regular (non-streaming) control.
    public let lightId: String?

    public init(serviceId: String, name: String, archetype: String, segmentCount: Int, lightId: String? = nil) {
        self.serviceId = serviceId
        self.name = name
        self.archetype = archetype
        self.segmentCount = segmentCount
        self.lightId = lightId
    }
}

/// What physically renders a channel: a standalone lamp or one segment of a gradient strip.
public struct ChannelDescription: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case lamp
        case stripSegment(index: Int, count: Int)
    }

    public let channelId: UInt8
    public let kind: Kind
    /// Usually one light; a channel can have several members.
    public let lights: [EntertainmentLight]

    public var name: String {
        var seen = Set<String>()
        return lights.map(\.name).filter { seen.insert($0).inserted }.joined(separator: ", ")
    }

    /// The strip this channel belongs to, if it's a strip segment.
    public var strip: EntertainmentLight? {
        guard case .stripSegment = kind else { return nil }
        return lights.first { $0.segmentCount > 1 }
    }

    public init(channel: EntertainmentArea.Channel, lights lightsByService: [String: EntertainmentLight]) {
        channelId = channel.id
        lights = channel.members.compactMap { lightsByService[$0.serviceId] }
        let segmented = channel.members.first { (lightsByService[$0.serviceId]?.segmentCount ?? 1) > 1 }
        if let segmented, let light = lightsByService[segmented.serviceId] {
            kind = .stripSegment(index: segmented.index, count: light.segmentCount)
        } else {
            kind = .lamp
        }
    }
}

/// The Hue API's color for regular light control: CIE xy chromaticity plus brightness.
public struct HueLightState: Equatable, Sendable {
    public let x: Double
    public let y: Double
    /// 0...1; the light's dimming level.
    public let brightness: Double
}

/// An RGB light color with components in 0...1.
public struct LightColor: Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double

    public init(red: Double, green: Double, blue: Double) {
        self.red = red
        self.green = green
        self.blue = blue
    }

    public static let black = LightColor(red: 0, green: 0, blue: 0)
    public static let white = LightColor(red: 1, green: 1, blue: 1)

    public func scaled(by factor: Double) -> LightColor {
        LightColor(red: red * factor, green: green * factor, blue: blue * factor)
    }

    /// Converts sRGB to CIE xy with Philips' wide-gamut matrix (the bridge clips to each light's gamut).
    /// Brightness is the brightest component. Black maps to brightness 0.
    public var hueState: HueLightState {
        func linear(_ c: Double) -> Double {
            c > 0.04045 ? pow((c + 0.055) / 1.055, 2.4) : c / 12.92
        }
        let brightness = max(red, green, blue)
        guard brightness > 0 else { return HueLightState(x: 0.3127, y: 0.329, brightness: 0) }
        // Chromaticity only depends on the color's ratios, so normalize before linearizing.
        let r = linear(red / brightness), g = linear(green / brightness), b = linear(blue / brightness)
        let X = r * 0.664511 + g * 0.154324 + b * 0.162028
        let Y = r * 0.283881 + g * 0.668433 + b * 0.047685
        let Z = r * 0.000088 + g * 0.072310 + b * 0.986039
        let sum = X + Y + Z
        return HueLightState(x: X / sum, y: Y / sum, brightness: brightness)
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
    case invalidClientKey
    case streamingHandshakeTimeout

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
        case .invalidClientKey:
            "The stored client key is malformed. Forget the bridge and pair again."
        case .streamingHandshakeTimeout:
            "The bridge didn't accept the streaming connection in time."
        }
    }
}
