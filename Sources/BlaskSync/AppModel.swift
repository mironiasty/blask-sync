import AppKit
import HueKit
import Observation
import os

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
    /// True while fetching areas, including startup retries.
    private(set) var isLoadingAreas = false
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
    /// macOS doesn't let Blask Sync reach the local network, so it can't find or control the bridge.
    private(set) var localNetworkDenied = false {
        didSet {
            if localNetworkDenied, !oldValue { watchLocalNetwork() }
        }
    }
    @ObservationIgnored private var localNetworkWatch: Task<Void, Never>?

    private static let defaultAreaKey = "defaultAreaId"

    private let store = CredentialStore()
    @ObservationIgnored private var sleepMonitor: SleepMonitor?
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
        sleepMonitor = SleepMonitor(
            onSleep: { [weak self] displayOnly in await self?.lightControl?.prepareForSleep(displayOnly: displayOnly) },
            onWake: { [weak self] in await self?.lightControl?.wakeFromSleep() }
        )
        Task { await reconnect() }
    }

    /// Fetches the paired bridge's areas, or looks for bridges when none is paired.
    private func reconnect() async {
        if credentials != nil {
            await refreshAreas()
        } else {
            await discover()
        }
    }

    /// While local network access is missing, checks every few seconds and reconnects once the user allows it
    /// (in the consent prompt or in System Settings).
    private func watchLocalNetwork() {
        localNetworkWatch?.cancel()
        localNetworkWatch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                guard let self, self.localNetworkDenied else { return }
                if await !LocalNetworkAccess.isDenied(host: self.credentials?.host) {
                    await self.reconnect()
                    return
                }
            }
        }
    }

    /// Opens System Settings → Privacy & Security → Local Network.
    func openLocalNetworkSettings() {
        NSWorkspace.shared.open(
            URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!)
    }

    // MARK: Discovery

    func discover() async {
        guard !isDiscovering else { return }
        isDiscovering = true
        defer { isDiscovering = false }
        errorMessage = nil
        bridges = await BridgeDiscovery.discover()
        localNetworkDenied = bridges.isEmpty ? await LocalNetworkAccess.isDenied() : false
        if bridges.isEmpty, !localNetworkDenied {
            errorMessage = String(
                localized: "No bridges found. Check that this Mac is on the same network, or enter the bridge's IP.")
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
            localNetworkDenied = await LocalNetworkAccess.isDenied(host: host)
            if !localNetworkDenied {
                errorMessage = String(localized: "No Hue Bridge at \(host): \(error.localizedDescription)")
            }
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
                localNetworkDenied = await LocalNetworkAccess.isDenied(host: bridge.host)
                if !localNetworkDenied { errorMessage = error.localizedDescription }
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

    /// The app delegate releases the lights before the app actually exits.
    func quit() {
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

    private static let logger = Logger(subsystem: "local.blasksync", category: "bridge")

    private func fetchAreas() async {
        guard let credentials, !isLoadingAreas else { return }
        isLoadingAreas = true
        defer { isLoadingAreas = false }
        errorMessage = nil
        localNetworkDenied = false

        // Right after launch, macOS briefly blocks local network access ("Local network prohibited",
        // reported as -1009 "offline") until it applies the app's permission. Retry before giving up.
        var delay = Duration.milliseconds(500)
        for attempt in 1...5 {
            do {
                areas = try await BridgeClient(credentials: credentials).entertainmentAreas(
                    applicationKey: credentials.applicationKey)
                if attempt > 1 { Self.logger.notice("fetched areas on attempt \(attempt)") }
                return
            } catch HueError.unauthorized {
                errorMessage = HueError.unauthorized.localizedDescription
                return
            } catch let error as URLError where Self.isTransient(error) && attempt < 5 {
                Self.logger.notice(
                    "areas attempt \(attempt) failed (\(error.code.rawValue)); retrying in \(delay, privacy: .public)")
                try? await Task.sleep(for: delay)
                delay *= 2
            } catch {
                Self.logger.error("fetching areas failed: \(error.localizedDescription, privacy: .public)")
                break
            }
        }

        localNetworkDenied = await LocalNetworkAccess.isDenied(host: credentials.host)
        guard !localNetworkDenied else { return }

        // DHCP may have given the bridge a new address; look it up by ID and retry once.
        guard let moved = await relocate(credentials) else {
            errorMessage = Self.unreachableMessage
            return
        }
        do {
            areas = try await BridgeClient(credentials: moved).entertainmentAreas(applicationKey: moved.applicationKey)
        } catch {
            errorMessage = Self.unreachableMessage
        }
    }

    private static func isTransient(_ error: URLError) -> Bool {
        [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost].contains(error.code)
    }

    private static let unreachableMessage =
        String(
            localized:
                "Can't reach the Hue Bridge. Check that it's on the same network, and that Blask Sync is allowed in System Settings → Privacy & Security → Local Network."
        )

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
