import AppKit
import HueKit
import Observation

@MainActor
@Observable
final class AppModel {
    enum PairingState: Equatable {
        case idle
        case waitingForLinkButton(bridgeId: String, deadline: Date)
    }

    private(set) var bridges: [DiscoveredBridge] = []
    private(set) var isDiscovering = false
    private(set) var pairing: PairingState = .idle
    private(set) var credentials: BridgeCredentials?
    private(set) var areas: [EntertainmentArea] = []
    /// The entertainment area Blask Sync drives. Saved across launches.
    var defaultAreaId: String? {
        didSet {
            guard defaultAreaId != oldValue else { return }
            UserDefaults.standard.set(defaultAreaId, forKey: Self.defaultAreaKey)
            updateLightControl()
        }
    }
    /// Sync session for the default area; lives as long as the app, independent of any window.
    private(set) var lightControl: LightControl?
    var errorMessage: String?

    private static let defaultAreaKey = "defaultAreaId"

    private let store = CredentialStore()
    private var pairingTask: Task<Void, Never>?
    private static let pairingTimeout = 30

    /// `app#device`; the bridge allows at most 40 characters.
    private static let deviceType: String = {
        let device = ProcessInfo.processInfo.hostName.replacingOccurrences(of: ".local", with: "")
        return "blask-sync#\(device.prefix(30))"
    }()

    init() {
        defaultAreaId = UserDefaults.standard.string(forKey: Self.defaultAreaKey)
        do {
            credentials = try store.load()
        } catch {
            errorMessage = error.localizedDescription
        }
        Task {
            if credentials != nil {
                await refreshAreas()
            } else {
                await discover()
            }
        }
    }

    // MARK: Discovery

    func discover() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        defer { isDiscovering = false }
        errorMessage = nil
        bridges = await BridgeDiscovery.discover()
        if bridges.isEmpty {
            errorMessage = "No bridges found. Check that this Mac is on the same network, or enter the bridge's IP."
        }
    }

    func addBridge(host: String) async {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return }
        errorMessage = nil
        do {
            let bridge = try await BridgeDiscovery.probe(host: host)
            bridges.removeAll { $0.id == bridge.id }
            bridges.append(bridge)
        } catch {
            errorMessage = "No Hue Bridge at \(host): \(error.localizedDescription)"
        }
    }

    // MARK: Pairing

    func pair(with bridge: DiscoveredBridge) {
        pairingTask?.cancel()
        errorMessage = nil
        pairing = .waitingForLinkButton(
            bridgeId: bridge.id,
            deadline: .now.addingTimeInterval(TimeInterval(Self.pairingTimeout))
        )
        pairingTask = Task {
            do {
                let client = BridgeClient(host: bridge.host, bridgeId: bridge.id)
                let keys = try await client.pair(deviceType: Self.deviceType, timeout: .seconds(Self.pairingTimeout))
                let credentials = BridgeCredentials(
                    bridgeId: bridge.id,
                    host: bridge.host,
                    name: bridge.name,
                    applicationKey: keys.applicationKey,
                    clientKey: keys.clientKey
                )
                try store.save(credentials)
                self.credentials = credentials
                pairing = .idle
                await refreshAreas()
            } catch {
                // A cancelled task has already been superseded; leave its state alone.
                guard !Task.isCancelled else { return }
                pairing = .idle
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelPairing() {
        pairingTask?.cancel()
        pairingTask = nil
        pairing = .idle
    }

    func forgetBridge() {
        do {
            try store.delete()
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        credentials = nil
        areas = []
        updateLightControl()
        Task { await discover() }
    }

    // MARK: Light control

    var defaultArea: EntertainmentArea? {
        areas.first { $0.id == defaultAreaId }
    }

    /// Keeps `lightControl` in step with the paired bridge and default area. An existing session
    /// survives area refreshes, so streaming isn't interrupted.
    private func updateLightControl() {
        guard let credentials, let area = defaultArea else {
            replaceLightControl(with: nil)
            return
        }
        guard lightControl?.area.id != area.id else { return }
        replaceLightControl(with: LightControl(area: area, credentials: credentials))
    }

    private func replaceLightControl(with control: LightControl?) {
        let previous = lightControl
        lightControl = control
        Task {
            await previous?.shutdown()
            await control?.loadLights()
        }
    }

    /// Releases the streaming session before quitting; otherwise the bridge holds the lights for ~10 s.
    func quit() async {
        await lightControl?.shutdown()
        NSApplication.shared.terminate(nil)
    }

    // MARK: Paired bridge

    func refreshAreas() async {
        await fetchAreas()
        // First run: default to the first screen area, which is what screen sync is meant for.
        if defaultArea == nil, !areas.isEmpty {
            defaultAreaId = (areas.first { $0.configurationType == "screen" } ?? areas.first)?.id
        }
        updateLightControl()
    }

    private func fetchAreas() async {
        guard let credentials else { return }
        errorMessage = nil
        do {
            areas = try await BridgeClient(credentials: credentials).entertainmentAreas(applicationKey: credentials.applicationKey)
        } catch HueError.unauthorized {
            errorMessage = HueError.unauthorized.localizedDescription
        } catch {
            // DHCP may have given the bridge a new address; look it up by ID and retry once.
            guard let moved = await relocate(credentials) else {
                errorMessage = error.localizedDescription
                return
            }
            do {
                areas = try await BridgeClient(credentials: moved).entertainmentAreas(applicationKey: moved.applicationKey)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private func relocate(_ credentials: BridgeCredentials) async -> BridgeCredentials? {
        let found = await BridgeDiscovery.discover()
        guard let bridge = found.first(where: { $0.id == credentials.bridgeId }), bridge.host != credentials.host else {
            return nil
        }
        var moved = credentials
        moved.host = bridge.host
        try? store.save(moved)
        self.credentials = moved
        return moved
    }
}
