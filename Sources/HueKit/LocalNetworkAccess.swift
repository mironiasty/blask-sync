import Darwin
import Foundation
import Network
import os

/// macOS lets an app talk to devices on the local network only with the user's consent (System Settings →
/// Privacy & Security → Local Network). Without it, connections to the bridge never start: their path stays
/// unsatisfied with `.localNetworkDenied`. Right after launch, or while the consent prompt is up, macOS reports
/// the same, so a connection gets a few seconds to recover before the denial counts.
public enum LocalNetworkAccess {
    /// Whether macOS keeps this app from reaching `host`, or without one, the local network as a whole: macOS
    /// decides before connecting, so trying a neighbor's address on this Mac's subnet is enough.
    public static func isDenied(host: String? = nil, timeout: TimeInterval = 3) async -> Bool {
        guard let host = host ?? subnetAddress() else { return false }
        let connection = NWConnection(host: NWEndpoint.Host(host), port: 443, using: .tcp)
        return await connect(connection, timeout: timeout) == .localNetworkDenied
    }

    enum Outcome: Sendable {
        case ready
        case localNetworkDenied
        case failed
    }

    /// An address next to this Mac's on the subnet of its first active IPv4 interface. Not the router or the
    /// broadcast address: macOS lets those through either way.
    static func subnetAddress() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard flags & IFF_UP != 0, flags & (IFF_LOOPBACK | IFF_POINTOPOINT) == 0,
                let address = entry.ifa_addr, address.pointee.sa_family == UInt8(AF_INET),
                let mask = entry.ifa_netmask
            else { continue }
            if let probe = neighbor(of: ipv4(address), netmask: ipv4(mask)) { return probe }
        }
        return nil
    }

    /// A neighbor of `ip` on its subnet, skipping the network, router (`.1`) and broadcast addresses; nil for
    /// tiny subnets and link-local (169.254/16) addresses.
    static func neighbor(of ip: UInt32, netmask: UInt32) -> String? {
        guard netmask <= 0xFFFF_FFF8, ip >> 16 != 0xA9FE else { return nil }
        let network = ip & netmask
        let broadcast = network | ~netmask
        guard let probe = [ip ^ 1, ip ^ 2].first(where: { ![network, network | 1, broadcast].contains($0) })
        else { return nil }
        return [24, 16, 8, 0].map { String(probe >> $0 & 0xFF) }.joined(separator: ".")
    }

    private static func ipv4(_ address: UnsafeMutablePointer<sockaddr>) -> UInt32 {
        address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
    }

    /// Starts `connection`, waits until it's ready, fails, or `timeout` passes, then cancels it.
    static func connect(_ connection: NWConnection, timeout: TimeInterval) async -> Outcome {
        await withCheckedContinuation { continuation in
            let state = OSAllocatedUnfairLock(initialState: (finished: false, denied: false))
            @Sendable func finish(_ outcome: Outcome) {
                guard
                    state.withLock({ state in
                        defer { state.finished = true }
                        return !state.finished
                    })
                else { return }
                connection.cancel()
                continuation.resume(returning: outcome)
            }
            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    finish(.ready)
                case .waiting, .failed:
                    if connection.currentPath?.unsatisfiedReason == .localNetworkDenied {
                        // Keep waiting: access may still be granted. The timeout reports the denial.
                        state.withLock { $0.denied = true }
                        if case .failed = newState { finish(.localNetworkDenied) }
                    } else {
                        finish(.failed)
                    }
                case .cancelled:
                    finish(.failed)
                default:
                    break
                }
            }
            connection.start(queue: .global())
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                finish(state.withLock { $0.denied } ? .localNetworkDenied : .failed)
            }
        }
    }
}
