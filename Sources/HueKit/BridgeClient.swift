import Foundation
import Security

/// Talks to one bridge over HTTPS: pairing (v1 `/api`) and the CLIP v2 resources.
public final class BridgeClient: Sendable {
    public let host: String
    private let session: URLSession

    /// - Parameter bridgeId: When known, the bridge's TLS certificate must carry this ID as its common name.
    public init(host: String, bridgeId: String?) {
        self.host = host
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 5
        session = URLSession(configuration: config, delegate: BridgeTrustDelegate(expectedBridgeId: bridgeId), delegateQueue: nil)
    }

    public convenience init(credentials: BridgeCredentials) {
        self.init(host: credentials.host, bridgeId: credentials.bridgeId)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    // MARK: Pairing

    public enum PairingResult: Equatable, Sendable {
        case success(applicationKey: String, clientKey: String)
        case linkButtonNotPressed
    }

    /// A single pairing attempt. Succeeds only within 30 s of the link button being pressed.
    /// - Parameter deviceType: `app#device`, at most 40 characters.
    public func requestPairing(deviceType: String) async throws -> PairingResult {
        let body = try JSONSerialization.data(withJSONObject: [
            "devicetype": deviceType,
            "generateclientkey": true,
        ])
        let data = try await send("POST", "/api", body: body)
        return try Self.parsePairingResponse(data)
    }

    /// Polls `requestPairing` until the user presses the link button or `timeout` elapses.
    public func pair(
        deviceType: String,
        timeout: Duration = .seconds(30),
        pollInterval: Duration = .seconds(2)
    ) async throws -> (applicationKey: String, clientKey: String) {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while true {
            try Task.checkCancellation()
            switch try await requestPairing(deviceType: deviceType) {
            case .success(let applicationKey, let clientKey):
                return (applicationKey, clientKey)
            case .linkButtonNotPressed:
                guard clock.now + pollInterval < deadline else { throw HueError.linkButtonTimeout }
                try await Task.sleep(for: pollInterval)
            }
        }
    }

    static func parsePairingResponse(_ data: Data) throws -> PairingResult {
        struct Item: Decodable {
            struct Success: Decodable { let username: String; let clientkey: String? }
            struct Failure: Decodable { let type: Int; let description: String }
            let success: Success?
            let error: Failure?
        }
        guard let item = try JSONDecoder().decode([Item].self, from: data).first else {
            throw HueError.unexpectedResponse
        }
        if let success = item.success {
            guard let clientKey = success.clientkey else { throw HueError.missingClientKey }
            return .success(applicationKey: success.username, clientKey: clientKey)
        }
        if let error = item.error {
            // 101: "link button not pressed"
            if error.type == 101 { return .linkButtonNotPressed }
            throw HueError.bridge(type: error.type, description: error.description)
        }
        throw HueError.unexpectedResponse
    }

    // MARK: Unauthenticated info

    public struct PublicConfig: Decodable, Sendable {
        public let name: String
        public let bridgeid: String
        public let apiversion: String
        public let swversion: String
    }

    /// `/api/0/config` answers without an application key; used to identify a bridge by IP.
    public func publicConfig() async throws -> PublicConfig {
        try JSONDecoder().decode(PublicConfig.self, from: await send("GET", "/api/0/config"))
    }

    // MARK: CLIP v2

    public func entertainmentAreas(applicationKey: String) async throws -> [EntertainmentArea] {
        try await resources("entertainment_configuration", applicationKey: applicationKey)
    }

    /// Every light that can render entertainment streams, keyed by its `entertainment` service ID.
    /// Combines three resources: `entertainment` (segments), `device` (name) and `light` (archetype).
    public func entertainmentLights(applicationKey: String) async throws -> [String: EntertainmentLight] {
        struct Reference: Decodable { let rid: String; let rtype: String }
        struct Service: Decodable {
            struct Segments: Decodable {
                struct Segment: Decodable {}
                let segments: [Segment]
            }
            let id: String
            let owner: Reference
            let renderer: Bool
            let segments: Segments?
        }
        struct Device: Decodable {
            struct Metadata: Decodable { let name: String; let archetype: String? }
            let id: String
            let metadata: Metadata
            let services: [Reference]
        }
        struct Light: Decodable {
            struct Metadata: Decodable { let archetype: String }
            let id: String
            let metadata: Metadata
        }
        async let services: [Service] = resources("entertainment", applicationKey: applicationKey)
        async let devices: [Device] = resources("device", applicationKey: applicationKey)
        async let lights: [Light] = resources("light", applicationKey: applicationKey)

        let devicesById = Dictionary(try await devices.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // The light's archetype is what the user picked in the Hue app; the device's is the product default.
        let lightArchetypes = Dictionary(try await lights.map { ($0.id, $0.metadata.archetype) }, uniquingKeysWith: { a, _ in a })

        var result: [String: EntertainmentLight] = [:]
        for service in try await services where service.renderer {
            guard let device = devicesById[service.owner.rid] else { continue }
            let lightId = device.services.first { $0.rtype == "light" }?.rid
            result[service.id] = EntertainmentLight(
                serviceId: service.id,
                name: device.metadata.name,
                archetype: lightId.flatMap { lightArchetypes[$0] } ?? device.metadata.archetype ?? "classic_bulb",
                segmentCount: max(1, service.segments?.segments.count ?? 1)
            )
        }
        return result
    }

    /// Switches lights on or off through the regular API (they stay that way, unlike streamed colors).
    public func setPower(_ on: Bool, lightIds: [String], applicationKey: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["on": ["on": on]])
        try await withThrowingTaskGroup(of: Void.self) { group in
            for id in lightIds {
                group.addTask {
                    _ = try await self.send("PUT", "/clip/v2/resource/light/\(id)", body: body, applicationKey: applicationKey)
                }
            }
            try await group.waitForAll()
        }
    }

    /// Whether any of the given lights is switched on.
    public func anyLightOn(_ lightIds: [String], applicationKey: String) async throws -> Bool {
        struct Light: Decodable {
            struct Power: Decodable { let on: Bool }
            let id: String
            let on: Power
        }
        let ids = Set(lightIds)
        let lights: [Light] = try await resources("light", applicationKey: applicationKey)
        return lights.contains { ids.contains($0.id) && $0.on.on }
    }

    /// Claims (`active: true`) or releases an entertainment area for streaming.
    /// The bridge only accepts the DTLS connection after a successful start.
    public func setStreaming(areaId: String, active: Bool, applicationKey: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: ["action": active ? "start" : "stop"])
        let data = try await send("PUT", "/clip/v2/resource/entertainment_configuration/\(areaId)", body: body, applicationKey: applicationKey)
        let envelope = try JSONDecoder().decode(ResourceEnvelope<ResourceIdentifier>.self, from: data)
        if let first = envelope.errors.first {
            throw HueError.bridge(type: 0, description: first.description)
        }
    }

    private struct ResourceIdentifier: Decodable { let rid: String }

    private func resources<T: Decodable>(_ type: String, applicationKey: String) async throws -> [T] {
        let data = try await send("GET", "/clip/v2/resource/\(type)", applicationKey: applicationKey)
        let envelope = try JSONDecoder().decode(ResourceEnvelope<T>.self, from: data)
        if let first = envelope.errors.first {
            throw HueError.bridge(type: 0, description: first.description)
        }
        return envelope.data
    }

    private struct ResourceEnvelope<T: Decodable>: Decodable {
        struct Failure: Decodable { let description: String }
        let errors: [Failure]
        let data: [T]
    }

    // MARK: Transport

    private var baseURL: URL {
        // IPv6 literals need brackets in URLs.
        URL(string: host.contains(":") ? "https://[\(host)]" : "https://\(host)")!
    }

    private func send(_ method: String, _ path: String, body: Data? = nil, applicationKey: String? = nil) async throws -> Data {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let applicationKey { request.setValue(applicationKey, forHTTPHeaderField: "hue-application-key") }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HueError.unexpectedResponse }
        switch http.statusCode {
        case 200..<300: return data
        case 401, 403: throw HueError.unauthorized
        default:
            // CLIP v2 explains failures (e.g. "area already streaming") in the body.
            if let envelope = try? JSONDecoder().decode(ResourceEnvelope<ResourceIdentifier>.self, from: data),
               let first = envelope.errors.first {
                throw HueError.bridge(type: http.statusCode, description: first.description)
            }
            throw HueError.http(status: http.statusCode)
        }
    }
}

/// The bridge serves a certificate signed by Signify's private CA, which the system doesn't trust.
/// We accept it, but when the bridge ID is known we require it to match the certificate's common name,
/// so a different device at the same IP is rejected.
private final class BridgeTrustDelegate: NSObject, URLSessionDelegate, Sendable {
    let expectedBridgeId: String?

    init(expectedBridgeId: String?) {
        self.expectedBridgeId = expectedBridgeId?.lowercased()
    }

    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge
    ) async -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust
        else { return (.performDefaultHandling, nil) }

        if let expectedBridgeId {
            guard let leaf = (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first else {
                return (.cancelAuthenticationChallenge, nil)
            }
            var commonName: CFString?
            SecCertificateCopyCommonName(leaf, &commonName)
            guard (commonName as String?)?.lowercased() == expectedBridgeId else {
                return (.cancelAuthenticationChallenge, nil)
            }
        }
        return (.useCredential, URLCredential(trust: trust))
    }
}
