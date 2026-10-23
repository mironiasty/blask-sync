import Foundation
import Network
import os

/// Encodes HueStream v2 messages, the UDP payload of the Entertainment API.
public enum HueStreamMessage {
    /// Size of the fixed header plus the 36-character area ID.
    static let headerSize = 52
    static let maxChannels = 20

    public static func encode(areaId: String, colors: [UInt8: LightColor]) -> Data {
        var data = Data(capacity: headerSize + 7 * colors.count)
        data.append(contentsOf: Array("HueStream".utf8))
        data.append(contentsOf: [0x02, 0x00]) // API version 2.0
        data.append(0x00)                     // sequence number (ignored by the bridge)
        data.append(contentsOf: [0x00, 0x00]) // reserved
        data.append(0x00)                     // color space: RGB
        data.append(0x00)                     // reserved
        data.append(contentsOf: Array(areaId.utf8))

        for (channel, color) in colors.sorted(by: { $0.key < $1.key }).prefix(maxChannels) {
            data.append(channel)
            for component in [color.red, color.green, color.blue] {
                let value = UInt16((min(max(component, 0), 1) * 65535).rounded())
                data.append(UInt8(value >> 8))
                data.append(UInt8(value & 0xFF))
            }
        }
        return data
    }
}

/// One streaming session to an entertainment area: `start()`, update colors freely, then `stop()`.
///
/// The current colors are re-sent at a fixed rate because UDP is lossy and the bridge ends the
/// session after 10 s without packets. When the session ends, lights return to their previous state.
public final class EntertainmentStream: @unchecked Sendable {
    // @unchecked: `connection` and `timer` are only touched on `queue`; `colors` is lock-protected.

    public let areaId: String
    private let credentials: BridgeCredentials
    private let client: BridgeClient
    private let frameInterval: DispatchTimeInterval
    private let onFailure: @Sendable (Error) -> Void

    private let queue = DispatchQueue(label: "blask.entertainment-stream", qos: .userInteractive)
    private let colors: OSAllocatedUnfairLock<[UInt8: LightColor]>
    private var connection: NWConnection?
    private var timer: DispatchSourceTimer?
    private var sendStats = IntervalStats()
    private static let logger = Logger(subsystem: "local.blasksync", category: "stream")

    /// - Parameters:
    ///   - initialColors: Colors sent from the first frame on, keyed by channel ID.
    ///   - onFailure: Called on the stream's queue if the connection drops after starting.
    public init(
        credentials: BridgeCredentials,
        areaId: String,
        initialColors: [UInt8: LightColor],
        framesPerSecond: Int = 50,
        onFailure: @escaping @Sendable (Error) -> Void
    ) {
        self.credentials = credentials
        self.areaId = areaId
        self.client = BridgeClient(credentials: credentials)
        self.colors = OSAllocatedUnfairLock(initialState: initialColors)
        self.frameInterval = .microseconds(1_000_000 / framesPerSecond)
        self.onFailure = onFailure
    }

    public func setColors(_ newColors: [UInt8: LightColor]) {
        colors.withLock { $0.merge(newColors) { _, new in new } }
    }

    public func start() async throws {
        let parameters = try Self.dtlsParameters(for: credentials)
        try await client.setStreaming(areaId: areaId, active: true, applicationKey: credentials.applicationKey)
        do {
            try await connect(using: parameters)
        } catch {
            try? await client.setStreaming(areaId: areaId, active: false, applicationKey: credentials.applicationKey)
            throw error
        }
        queue.sync { startSending() }
    }

    public func stop() async {
        queue.sync {
            timer?.cancel()
            timer = nil
            connection?.stateUpdateHandler = nil
            connection?.cancel()
            connection = nil
        }
        try? await client.setStreaming(areaId: areaId, active: false, applicationKey: credentials.applicationKey)
    }

    // MARK: Connection

    private func connect(using parameters: NWParameters) async throws {
        let connection = NWConnection(host: NWEndpoint.Host(credentials.host), port: 2100, using: parameters)
        queue.sync { self.connection = connection }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            /// Returns false if the continuation was already resumed.
            @Sendable func resume(_ result: Result<Void, Error>) -> Bool {
                guard resumed.withLock({ done in defer { done = true }; return !done }) else { return false }
                continuation.resume(with: result)
                return true
            }
            connection.stateUpdateHandler = { [onFailure] state in
                switch state {
                case .ready:
                    _ = resume(.success(()))
                case .waiting(let error), .failed(let error):
                    // Before .ready this fails start(); afterwards it's a dropped stream.
                    if !resume(.failure(error)) { onFailure(error) }
                case .cancelled:
                    _ = resume(.failure(CancellationError()))
                default:
                    break
                }
            }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 5) {
                if resume(.failure(HueError.streamingHandshakeTimeout)) { connection.cancel() }
            }
        }
    }

    /// Must be called on `queue`.
    private func startSending() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: frameInterval, leeway: .milliseconds(2))
        timer.setEventHandler { [weak self] in self?.sendFrame() }
        timer.resume()
        self.timer = timer
    }

    /// Must be called on `queue`.
    private func sendFrame() {
        let message = HueStreamMessage.encode(areaId: areaId, colors: colors.withLock { $0 })
        connection?.send(content: message, completion: .idempotent)
        if let summary = sendStats.record() {
            Self.logger.notice("sent \(summary.description, privacy: .public)")
        }
    }

    /// DTLS 1.2 with a pre-shared key: identity = application key, key = decoded client key.
    static func dtlsParameters(for credentials: BridgeCredentials) throws -> NWParameters {
        guard let psk = Data(hexString: credentials.clientKey), psk.count == 16 else { throw HueError.invalidClientKey }

        let tls = NWProtocolTLS.Options()
        let security = tls.securityProtocolOptions
        sec_protocol_options_set_min_tls_protocol_version(security, .DTLSv12)
        sec_protocol_options_set_max_tls_protocol_version(security, .DTLSv12)
        sec_protocol_options_add_pre_shared_key(
            security,
            psk.withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData,
            Data(credentials.applicationKey.utf8).withUnsafeBytes { DispatchData(bytes: $0) } as __DispatchData
        )
        // The only suite the bridge accepts.
        sec_protocol_options_append_tls_ciphersuite(
            security,
            tls_ciphersuite_t(rawValue: UInt16(TLS_PSK_WITH_AES_128_GCM_SHA256))!
        )
        return NWParameters(dtls: tls, udp: NWProtocolUDP.Options())
    }
}

extension Data {
    init?(hexString: String) {
        guard hexString.count.isMultiple(of: 2) else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(hexString.count / 2)
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard let byte = UInt8(hexString[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}
