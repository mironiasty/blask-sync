import Foundation
import Network
import os

public enum BridgeDiscovery {
    /// Finds bridges via mDNS and the Hue cloud lookup in parallel. mDNS results win on conflicts
    /// since they carry the bridge's name and reflect the current local IP.
    public static func discover(timeout: Duration = .seconds(4)) async -> [DiscoveredBridge] {
        async let local = browseMDNS(timeout: timeout)
        async let cloud = (try? queryCloud()) ?? []

        var byId: [String: DiscoveredBridge] = [:]
        for bridge in await cloud { byId[bridge.id] = bridge }
        for bridge in await local { byId[bridge.id] = bridge }
        return byId.values.sorted { ($0.name ?? $0.id) < ($1.name ?? $1.id) }
    }

    /// Identifies the bridge at a manually entered address.
    public static func probe(host: String) async throws -> DiscoveredBridge {
        let config = try await BridgeClient(host: host, bridgeId: nil).publicConfig()
        return DiscoveredBridge(id: config.bridgeid, host: host, name: config.name)
    }

    // MARK: mDNS

    static func browseMDNS(timeout: Duration) async -> [DiscoveredBridge] {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: "_hue._tcp", domain: "local."), using: .tcp)
        let latest = OSAllocatedUnfairLock(initialState: Set<NWBrowser.Result>())
        browser.browseResultsChangedHandler = { results, _ in
            latest.withLock { $0 = results }
        }
        browser.start(queue: .global())
        try? await Task.sleep(for: timeout)
        browser.cancel()

        return await withTaskGroup(of: DiscoveredBridge?.self) { group in
            for result in latest.withLock({ $0 }) {
                group.addTask { await bridge(from: result) }
            }
            var bridges: [DiscoveredBridge] = []
            for await bridge in group {
                if let bridge { bridges.append(bridge) }
            }
            return bridges
        }
    }

    private static func bridge(from result: NWBrowser.Result) async -> DiscoveredBridge? {
        guard case .bonjour(let txt) = result.metadata, let id = txt["bridgeid"] else { return nil }
        var name: String?
        if case .service(let serviceName, _, _, _) = result.endpoint { name = serviceName }
        guard let host = await resolveIPv4(result.endpoint) else { return nil }
        return DiscoveredBridge(id: id, host: host, name: name)
    }

    /// Resolves a Bonjour service endpoint to an IP by opening (and immediately closing) a TCP connection.
    private static func resolveIPv4(_ endpoint: NWEndpoint) async -> String? {
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)

        return await withCheckedContinuation { continuation in
            let finished = OSAllocatedUnfairLock(initialState: false)
            @Sendable func finish(_ host: String?) {
                guard
                    finished.withLock({ done in
                        defer { done = true }
                        return !done
                    })
                else { return }
                connection.cancel()
                continuation.resume(returning: host)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if case .hostPort(let host, _) = connection.currentPath?.remoteEndpoint {
                        finish(hostString(host))
                    } else {
                        finish(nil)
                    }
                case .failed, .waiting, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }

    private static func hostString(_ host: NWEndpoint.Host) -> String {
        let raw =
            switch host {
            case .ipv4(let address): "\(address)"
            case .ipv6(let address): "\(address)"
            case .name(let name, _): name
            @unknown default: "\(host)"
            }
        // Drop any "%en0" interface scope suffix.
        return String(raw.split(separator: "%").first ?? Substring(raw))
    }

    // MARK: Cloud

    /// Signify's lookup service: returns bridges that recently checked in from the same public IP.
    /// Rate limited, so only a fallback.
    static func queryCloud() async throws -> [DiscoveredBridge] {
        struct Entry: Decodable {
            let id: String
            let internalipaddress: String
        }
        var request = URLRequest(url: URL(string: "https://discovery.meethue.com/")!)
        request.timeoutInterval = 4
        let (data, _) = try await URLSession.shared.data(for: request)
        return try JSONDecoder().decode([Entry].self, from: data)
            .map { DiscoveredBridge(id: $0.id, host: $0.internalipaddress) }
    }
}
