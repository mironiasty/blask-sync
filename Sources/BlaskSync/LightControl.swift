import AppKit
import HueKit
import Observation
import os
import SwiftUI
import SyncCore

/// Manual control and screen sync of one entertainment area, driven over the streaming API.
@MainActor
@Observable
final class LightControl {
    enum StreamState: Equatable {
        case stopped, starting, streaming, stopping
    }

    enum Mode: String {
        case manual, screen, music
    }

    /// What sync follows when started from the menu.
    enum SyncSource: String, CaseIterable {
        case screen, music

        var mode: Mode { self == .screen ? .screen : .music }
    }

    enum CaptureState: Equatable {
        case idle, needsPermission, capturing
        case failed(String)
    }

    let area: EntertainmentArea
    private(set) var state: StreamState = .stopped
    /// What renders each channel (lamp or strip segment); empty until `loadLights()` finishes.
    private(set) var channelDescriptions: [UInt8: ChannelDescription] = [:]
    /// Manual color per channel, remembered per area across launches.
    private(set) var colors: [UInt8: LightColor] {
        didSet { saveManualColors() }
    }
    var brightness = 1.0 {
        didSet {
            pushColors()
            updateEngine()
            updateMusicEngine()
        }
    }
    /// Screen region each channel samples in screen sync. Saved per area.
    var mapping: ScreenMapping {
        didSet {
            mappingStore.save(mapping, areaId: area.id)
            updateEngine()
        }
    }
    /// While set, this channel shines white and all others go dark, to find it in the room.
    var identifiedChannel: UInt8? {
        didSet { routeOutput() }
    }
    var errorMessage: String?
    /// Whether any light in the area is switched on (regular power, not streaming); nil until known.
    private(set) var lightsOn: Bool?

    // MARK: Screen sync state

    /// What the lights follow while streaming. Manual while the Manual Control window is open.
    private(set) var mode: Mode = .screen {
        didSet {
            guard mode != oldValue else { return }
            routeOutput()
            updateEngines()
        }
    }
    /// Set while the music settings are visible, so the meters run without streaming.
    var musicPreviewing = false {
        didSet { updateMusic() }
    }
    /// Screen or music; switching while syncing switches live.
    var syncSource: SyncSource {
        didSet {
            UserDefaults.standard.set(syncSource.rawValue, forKey: Keys.syncSource)
            if mode != .manual, mode != syncSource.mode { mode = syncSource.mode }
        }
    }
    var musicPalette: MusicPalette {
        didSet {
            UserDefaults.standard.set(musicPalette.rawValue, forKey: Keys.musicPalette)
            updateMusicEngine()
        }
    }
    var musicStyle: MusicStyle {
        didSet {
            UserDefaults.standard.set(musicStyle.rawValue, forKey: Keys.musicStyle)
            updateMusicEngine()
        }
    }
    var musicIntensity: SyncIntensity {
        didSet {
            UserDefaults.standard.set(musicIntensity.rawValue, forKey: Keys.musicIntensity)
            updateMusicEngine()
        }
    }
    /// Latest audio analysis and music colors, refreshed ~10×/s while music sync or its meters run.
    private(set) var audioFeatures = AudioFeatures.silent
    private(set) var musicColors: [UInt8: LightColor] = [:]
    /// When the last beat landed, for the beat indicator.
    private(set) var lastBeat: Date?
    private(set) var musicError: String?

    private(set) var displays: [DisplayInfo] = DisplayInfo.all()
    var selectedDisplayID: CGDirectDisplayID {
        didSet {
            guard selectedDisplayID != oldValue else { return }
            UserDefaults.standard.set(Int(selectedDisplayID), forKey: Keys.displayID)
            if capture != nil { Task { await restartCapture() } }
        }
    }
    var intensity: SyncIntensity {
        didSet {
            UserDefaults.standard.set(intensity.rawValue, forKey: Keys.intensity)
            updateEngine()
        }
    }
    /// Pushes averaged (often grayish) screen colors toward vivid ones. 0...1.
    var saturationBoost: Double {
        didSet {
            UserDefaults.standard.set(saturationBoost, forKey: Keys.saturationBoost)
            updateEngine()
        }
    }
    /// Brightness floor so dark scenes glow faintly instead of going off. 0...1.
    var minimumBrightness: Double {
        didSet {
            UserDefaults.standard.set(minimumBrightness, forKey: Keys.minimumBrightness)
            updateEngine()
        }
    }
    private(set) var captureState: CaptureState = .idle
    /// Pause capture while a player of DRM-protected video is in front: macOS blanks protected video
    /// on screen while the display is being captured, so movies wouldn't play at all.
    var pauseForProtectedApps: Bool {
        didSet {
            UserDefaults.standard.set(pauseForProtectedApps, forKey: Keys.pauseForProtectedApps)
            updateProtectedPause()
            if capture != nil { Task { await restartCapture() } } // refresh the excluded apps
        }
    }
    /// Name of the protected-video app capture is paused for, e.g. "TV".
    private(set) var pausedForApp: String?
    /// Latest captured frame, refreshed ~10×/s while capturing.
    private(set) var preview: CGImage?
    /// Latest colors sent in screen mode (brightness applied), refreshed ~10×/s.
    private(set) var liveColors: [UInt8: LightColor] = [:]

    var selectedDisplay: DisplayInfo? {
        displays.first { $0.id == selectedDisplayID }
    }

    private let credentials: BridgeCredentials
    private let mappingStore = ScreenMappingStore()
    private var stream: EntertainmentStream?
    private var capture: ScreenCapture?
    private var engine: ScreenSyncEngine?
    /// Keeps App Nap from throttling the 50 Hz timers while the app works in the background.
    private var activity: NSObjectProtocol?
    /// Where the screen sync engine sends colors: the stream while it should follow the screen, else nil.
    /// Read on the engine's queue, so it lives outside the main actor.
    private let screenSink = OSAllocatedUnfairLock<EntertainmentStream?>(initialState: nil)
    /// Same for the music engine.
    private let musicSink = OSAllocatedUnfairLock<EntertainmentStream?>(initialState: nil)
    private var audioTap: SystemAudioTap?
    private var musicEngine: MusicSyncEngine?

    private static let logger = Logger(subsystem: "local.blasksync", category: "capture")

    /// Apps whose video is DRM-protected: the Apple TV app.
    static let protectedBundleIDs: Set<String> = ["com.apple.TV"]
    /// What the lights ease to while capture is paused: a soft warm glow.
    private static let pausedGlow = LightColor(red: 1, green: 0.62, blue: 0.32).scaled(by: 0.3)

    private var frontmostApp: (bundleID: String?, name: String?) = (nil, nil)
    private var activationObserver: NSObjectProtocol?
    /// Whether the SCStream is actually running; it pauses while `pausedForApp` is set.
    private var captureStreamRunning = false
    private var reconcilingCapture = false

    /// True while the stream runs only so `identify` can light a channel: no screen or audio capture,
    /// and it stops again when identifying ends.
    private var streamingForIdentify = false

    /// Whether screen sync was running when Manual Control opened, to resume it afterwards.
    private var resumeScreenAfterManual = false

    private enum Keys {
        static let displayID = "sync.displayID"
        static let intensity = "sync.intensity"
        static let saturationBoost = "sync.saturationBoost"
        static let minimumBrightness = "sync.minimumBrightness"
        static let pauseForProtectedApps = "sync.pauseForProtectedApps"
        static let syncSource = "sync.source"
        static let musicPalette = "sync.musicPalette"
        static let musicIntensity = "sync.musicIntensity"
        static let musicStyle = "sync.musicStyle"
    }

    init(area: EntertainmentArea, credentials: BridgeCredentials) {
        self.area = area
        self.credentials = credentials
        let savedColors = Self.loadManualColors(areaId: area.id)
        colors = Dictionary(uniqueKeysWithValues: area.channels.map { ($0.id, savedColors[$0.id] ?? LightColor.white) })
        mapping = (mappingStore.load(areaId: area.id) ?? .defaults(for: area.channels)).reconciled(with: area.channels)

        let defaults = UserDefaults.standard
        intensity = defaults.string(forKey: Keys.intensity).flatMap(SyncIntensity.init) ?? .moderate
        saturationBoost = defaults.object(forKey: Keys.saturationBoost) as? Double ?? 0.3
        minimumBrightness = defaults.object(forKey: Keys.minimumBrightness) as? Double ?? 0
        pauseForProtectedApps = defaults.object(forKey: Keys.pauseForProtectedApps) as? Bool ?? true
        syncSource = defaults.string(forKey: Keys.syncSource).flatMap(SyncSource.init) ?? .screen
        musicPalette = defaults.string(forKey: Keys.musicPalette).flatMap(MusicPalette.init) ?? .vivid
        musicIntensity = defaults.string(forKey: Keys.musicIntensity).flatMap(SyncIntensity.init) ?? .high
        musicStyle = defaults.string(forKey: Keys.musicStyle).flatMap(MusicStyle.init) ?? .flow
        let savedDisplay = CGDirectDisplayID(defaults.integer(forKey: Keys.displayID))
        selectedDisplayID = DisplayInfo.all().contains { $0.id == savedDisplay } ? savedDisplay : CGMainDisplayID()

        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let (bundleID, name) = (app?.bundleIdentifier, app?.localizedName)
            MainActor.assumeIsolated { self?.frontmostAppChanged(bundleID: bundleID, name: name) }
        }
        let front = NSWorkspace.shared.frontmostApplication
        frontmostAppChanged(bundleID: front?.bundleIdentifier, name: front?.localizedName)
    }

    /// Releases the lights and stops capturing, e.g. before quitting or switching areas.
    func shutdown() async {
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
            self.activationObserver = nil
        }
        musicPreviewing = false
        await stop()
        await stopCapture()
        stopMusic()
    }

    var isStreaming: Bool { stream != nil }

    // MARK: Sync control

    /// Starts streaming with the lights following the chosen source, fading them in over `fadeIn` if set.
    func startSync(fadeIn: Duration? = nil) async {
        if syncSource == .screen, !ScreenCapture.hasPermission {
            captureState = .needsPermission
            return
        }
        mode = syncSource.mode
        if streamingForIdentify {
            // Already streaming for identify: keep the stream and make it a real sync session.
            streamingForIdentify = false
            updateEngines()
            return
        }
        await start(fadeIn: fadeIn)
    }

    // MARK: Power

    func refreshPower() async {
        guard !area.lightIds.isEmpty else { return }
        lightsOn = try? await BridgeClient(credentials: credentials).anyLightOn(area.lightIds, applicationKey: credentials.applicationKey)
    }

    /// Switches the lights on showing the last manual colors, set directly on the lights (not streamed),
    /// so they stay after the app quits: lamps get their color, gradient strips a gradient of their
    /// segment colors. Falls back to a plain power-on when the lights aren't known yet.
    func turnOnWithManualColors() async {
        errorMessage = nil
        var colorsByLight: [String: [(segment: Int, color: LightColor)]] = [:]
        for channel in area.channels {
            guard let color = colors[channel.id] else { continue }
            for member in channel.members {
                guard let lightId = channelDescriptions[channel.id]?.lights.first(where: { $0.serviceId == member.serviceId })?.lightId else { continue }
                colorsByLight[lightId, default: []].append((member.index, color))
            }
        }
        guard !colorsByLight.isEmpty else {
            await setPower(true)
            return
        }
        let client = BridgeClient(credentials: credentials)
        do {
            for (lightId, segments) in colorsByLight {
                let ordered = segments.sorted { $0.segment < $1.segment }.map(\.color)
                try await client.showColors(ordered, onLight: lightId, applicationKey: credentials.applicationKey)
            }
            lightsOn = colorsByLight.values.contains { $0.contains { $0.color.hueState.brightness > 0 } }
        } catch {
            errorMessage = "Couldn't turn the lights on: \(error.localizedDescription)"
        }
    }

    /// Really switches the area's lights on or off. Turning off first stops sync, Manual Control and
    /// identifying, since streaming would otherwise keep them lit.
    func setPower(_ on: Bool, transition: Duration? = nil) async {
        errorMessage = nil
        if !on, state != .stopped {
            await stop()
            // Give the bridge a moment to restore the lights' pre-stream state, so ours wins.
            try? await Task.sleep(for: .milliseconds(400))
        }
        do {
            try await BridgeClient(credentials: credentials)
                .setPower(on, lightIds: area.lightIds, applicationKey: credentials.applicationKey, transition: transition)
            lightsOn = on
        } catch {
            errorMessage = "Couldn't turn the lights \(on ? "on" : "off"): \(error.localizedDescription)"
        }
    }

    // MARK: Sleep

    /// Settings → General: switch the lights off while the Mac or its display sleeps. On by default.
    static let turnOffWhenSleepingKey = "sync.turnOffWhenSleeping"

    /// How long the lights take to come back up after wake, so they don't jump to full brightness.
    private static let wakeFade = Duration.seconds(2)

    /// What to bring back when the displays wake; nil unless the lights were switched off for sleep.
    private var resumeAfterSleep: SleepResume?
    private enum SleepResume {
        /// Sync or Manual Control was streaming; `mode` still says which.
        case streaming
        case lightsOn
    }

    /// Stops streaming and switches the lights off, remembering what to bring back on wake. When only
    /// the display sleeps, music sync keeps playing.
    func prepareForSleep(displayOnly: Bool) async {
        guard UserDefaults.standard.object(forKey: Self.turnOffWhenSleepingKey) as? Bool ?? true,
              resumeAfterSleep == nil else { return }
        if displayOnly, isStreaming, mode == .music { return }
        if isStreaming, !streamingForIdentify {
            resumeAfterSleep = .streaming
        } else {
            if lightsOn == nil { await refreshPower() }
            guard lightsOn == true else { return }
            resumeAfterSleep = .lightsOn
        }
        await setPower(false)
    }

    /// Brings back what `prepareForSleep` switched off, fading the lights in, retrying while Wi-Fi
    /// reconnects. Gives up if the lights are taken over in the meantime.
    func wakeFromSleep() async {
        guard let resume = resumeAfterSleep else { return }
        resumeAfterSleep = nil
        for attempt in 0..<10 {
            if attempt > 0 {
                try? await Task.sleep(for: .seconds(2))
                guard state == .stopped, resumeAfterSleep == nil else { return }
            }
            switch resume {
            case .streaming:
                if mode == .manual { await start(fadeIn: Self.wakeFade) } else { await startSync(fadeIn: Self.wakeFade) }
                if state != .stopped || captureState == .needsPermission { return }
            case .lightsOn:
                await setPower(true, transition: Self.wakeFade)
                if lightsOn == true { return }
            }
        }
    }

    /// Lights only `channel`, in white with the others dark, so it can be found in the room; nil ends it.
    /// When nothing is streaming, starts a stream just for this (without capturing the screen) and
    /// releases the lights again afterwards.
    func identify(_ channel: UInt8?) async {
        identifiedChannel = channel
        if channel != nil, state == .stopped {
            streamingForIdentify = true
            await start()
            if state == .stopped { streamingForIdentify = false }
        } else if channel == nil, streamingForIdentify {
            streamingForIdentify = false
            await stop()
        }
    }

    /// Switches to manual colors, streaming if needed. Called when the Manual Control window opens.
    func beginManual() async {
        guard mode != .manual else { return }
        resumeScreenAfterManual = (isStreaming || state == .starting) && !streamingForIdentify
        streamingForIdentify = false
        identifiedChannel = nil
        mode = .manual
        if state == .stopped { await start() }
    }

    /// Leaves manual (or switches source) and makes the lights follow `source`, streaming if needed.
    func resumeSync(_ source: SyncSource) async {
        syncSource = source
        if source == .screen, !ScreenCapture.hasPermission {
            captureState = .needsPermission
            return
        }
        mode = source.mode
        if streamingForIdentify {
            streamingForIdentify = false
            updateEngines()
        }
        if state == .stopped { await start() }
    }

    /// Settings → General: switch the lights off when sync stops instead of restoring their previous state.
    static let turnOffWhenStoppingKey = "sync.turnOffWhenStopping"

    /// Stop Sync: ends streaming, then switches the lights off if that's the chosen behavior.
    func stopSync() async {
        if UserDefaults.standard.bool(forKey: Self.turnOffWhenStoppingKey) {
            await setPower(false)
        } else {
            await stop()
        }
    }

    /// Returns to screen sync if it was running before, else releases the lights.
    func endManual() async {
        guard mode == .manual else { return }
        if !resumeScreenAfterManual { await stopSync() }
        mode = syncSource.mode
    }

    func loadLights() async {
        guard channelDescriptions.isEmpty else { return }
        do {
            let lights = try await BridgeClient(credentials: credentials)
                .entertainmentLights(applicationKey: credentials.applicationKey)
            channelDescriptions = Dictionary(uniqueKeysWithValues: area.channels.map {
                ($0.id, ChannelDescription(channel: $0, lights: lights))
            })
            // Never customized: now that lamps are known, place them beside the screen where they belong.
            if mappingStore.load(areaId: area.id) == nil {
                resetMapping()
            }
            // The music engine needs to know which channels are strips and which are lamps.
            if musicEngine != nil {
                stopMusic()
                updateMusic()
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Gradient strips in the area, each with its channels in segment order.
    var strips: [(light: EntertainmentLight, channels: [UInt8])] {
        let segments = channelDescriptions.values.compactMap { description -> (EntertainmentLight, Int, UInt8)? in
            guard let strip = description.strip, case .stripSegment(let index, _) = description.kind else { return nil }
            return (strip, index, description.channelId)
        }
        return Dictionary(grouping: segments, by: { $0.0 })
            .map { light, segments in (light, segments.sorted { $0.1 < $1.1 }.map(\.2)) }
            .sorted { $0.light.name < $1.light.name }
    }

    /// Channels rendered by standalone lights, or every channel while light info is still loading.
    var lampChannels: [UInt8] {
        area.channels.map(\.id).filter { channelDescriptions[$0]?.strip == nil }
    }

    func resetMapping() {
        mapping = .defaults(for: area.channels, lampChannels: Set(lampChannels.filter(isLamp)))
    }

    /// Whether the channel is a standalone lamp (as opposed to a strip segment). False until lights load.
    func isLamp(_ channelId: UInt8) -> Bool {
        guard let description = channelDescriptions[channelId] else { return false }
        return description.strip == nil
    }

    /// Lamps may be placed beside the screen; strip segments stay on it.
    func placementBounds(for channelId: UInt8) -> ScreenRegion.Bounds {
        isLamp(channelId) ? .surroundings : .screen
    }

    func setColor(_ color: LightColor, channel: UInt8) {
        colors[channel] = color
        pushColors()
    }

    func setAllColors(_ color: LightColor) {
        for channel in colors.keys { colors[channel] = color }
        pushColors()
    }

    private var manualColorsKey: String { "manualColors.\(area.id)" }

    /// Stored as channel → [red, green, blue], since LightColor isn't Codable.
    private func saveManualColors() {
        let plist = Dictionary(uniqueKeysWithValues: colors.map { (String($0.key), [$0.value.red, $0.value.green, $0.value.blue]) })
        UserDefaults.standard.set(plist, forKey: manualColorsKey)
    }

    private static func loadManualColors(areaId: String) -> [UInt8: LightColor] {
        guard let plist = UserDefaults.standard.dictionary(forKey: "manualColors.\(areaId)") as? [String: [Double]] else { return [:] }
        return Dictionary(uniqueKeysWithValues: plist.compactMap { key, rgb in
            guard let channel = UInt8(key), rgb.count == 3 else { return nil }
            return (channel, LightColor(red: rgb[0], green: rgb[1], blue: rgb[2]))
        })
    }

    /// Sets several channels at once (one update to the lights).
    func setColors(_ updates: [UInt8: LightColor]) {
        colors.merge(updates) { _, new in new }
        pushColors()
    }

    /// - Parameter fadeIn: If set, the lights rise from black over this long instead of jumping in.
    func start(fadeIn: Duration? = nil) async {
        guard state == .stopped else { return }
        state = .starting
        errorMessage = nil
        // Start capturing while the stream connects, so screen colors are ready when it's up.
        updateEngines()
        let stream = EntertainmentStream(
            credentials: credentials,
            areaId: area.id,
            // Screen mode never falls back to the manual colors (white by default): with no screen
            // colors yet, the stream waits and the lights keep their current state.
            initialColors: followsSync ? (mode == .music ? musicColors : liveColors) : outputColors,
            fadeIn: fadeIn,
            onFailure: { [weak self] error in
                Task { @MainActor in self?.streamDropped(error) }
            }
        )
        do {
            try await stream.start()
            // stop() was called while connecting (e.g. the window closed).
            guard state == .starting else {
                await stream.stop()
                state = .stopped
                return
            }
            self.stream = stream
            state = .streaming
            lightsOn = true // the bridge powers lights up for streaming
            routeOutput()
            updateActivity()
            updateEngines()
        } catch {
            state = .stopped
            errorMessage = "Couldn't start streaming: \(error.localizedDescription)"
            updateEngines()
        }
    }

    func stop() async {
        streamingForIdentify = false
        identifiedChannel = nil
        guard let stream else {
            // Still connecting: start() sees this and tears the stream down once it's up.
            if state == .starting { state = .stopping }
            return
        }
        self.stream = nil
        routeOutput()
        updateActivity()
        state = .stopping
        await stream.stop()
        state = .stopped
        updateEngines()
        // The bridge restores each light's previous power state after streaming.
        Task {
            try? await Task.sleep(for: .seconds(1))
            await refreshPower()
        }
    }

    private func streamDropped(_ error: Error) {
        guard let stream else { return }
        self.stream = nil
        routeOutput()
        updateActivity()
        state = .stopped
        updateEngines()
        errorMessage = "Streaming stopped: \(error.localizedDescription)"
        Task { await stream.stop() }
    }

    private var outputColors: [UInt8: LightColor] {
        if let identifiedChannel {
            // The canvas colors, so lights and markers match; the identified one bright, the rest dim.
            return Dictionary(uniqueKeysWithValues: colors.keys.map { channel in
                let color = identifyColor(for: channel)
                return (channel, channel == identifiedChannel ? color : color.scaled(by: Self.identifyDim))
            })
        }
        // Manual colors carry their own brightness; the master brightness is for screen and music sync.
        return colors
    }

    /// Brightness of the other lights while one is identified.
    private static let identifyDim = 0.1

    /// A distinct color per channel, evenly spaced around the color wheel in channel order (a strip
    /// becomes a rainbow). Shown on the canvas when nothing is live and on the real lights while
    /// identifying, so the two match.
    func identifyColor(for channel: UInt8) -> LightColor {
        let index = area.channels.firstIndex { $0.id == channel } ?? 0
        return LightColor(hue: Double(index) / Double(max(area.channels.count, 1)), saturation: 1, brightness: 1)
    }

    /// Whether the lights currently follow the screen or music (as opposed to manual colors or identify).
    private var followsSync: Bool {
        mode != .manual && identifiedChannel == nil
    }

    private func pushColors() {
        guard !followsSync else { return }
        stream?.setColors(outputColors)
    }

    private func updateActivity() {
        // Debug switch to compare against App Nap: `defaults write local.blasksync.BlaskSync sync.allowAppNap -bool YES`
        let needed = (stream != nil || capture != nil || audioTap != nil) && !UserDefaults.standard.bool(forKey: "sync.allowAppNap")
        if needed, activity == nil {
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Streaming colors to Hue lights"
            )
        } else if !needed, let activity {
            ProcessInfo.processInfo.endActivity(activity)
            self.activity = nil
        }
    }

    /// Points the screen and music engines at the stream; only the one matching the mode drives the lights.
    private func routeOutput() {
        let screenTarget = followsSync && mode == .screen ? stream : nil
        let musicTarget = followsSync && mode == .music ? stream : nil
        screenSink.withLock { $0 = screenTarget }
        musicSink.withLock { $0 = musicTarget }
        pushColors()
    }

    // MARK: Music

    /// Music analysis runs for the meters, or while streaming follows the music.
    private var musicNeeded: Bool {
        musicPreviewing || (mode == .music && state != .stopped && !streamingForIdentify)
    }

    private func updateMusic() {
        musicNeeded ? startMusic() : stopMusic()
    }

    private var musicEngineSettings: MusicSyncEngine.Settings {
        MusicSyncEngine.Settings(palette: musicPalette, intensity: musicIntensity, style: musicStyle, brightness: brightness)
    }

    private func updateMusicEngine() {
        musicEngine?.update(musicEngineSettings)
    }

    private func startMusic() {
        guard musicNeeded, musicEngine == nil else { return }
        musicError = nil

        let stripChannels = strips.isEmpty ? area.channels.map(\.id) : strips.flatMap(\.channels)
        let lampChannels = area.channels.map(\.id).filter { !stripChannels.contains($0) }
        let preview = Throttle(interval: 0.1)
        let engine = MusicSyncEngine(settings: musicEngineSettings, stripChannels: stripChannels, lampChannels: lampChannels) {
            [musicSink, weak self] colors, features, beat in
            musicSink.withLock { $0 }?.setColors(colors)
            if beat {
                Task { @MainActor in self?.lastBeat = Date() }
            }
            if preview.ready() {
                Task { @MainActor in
                    self?.audioFeatures = features
                    self?.musicColors = colors
                }
            }
        }
        let tap = SystemAudioTap { samples, sampleRate in
            engine.process(samples, sampleRate: sampleRate)
        }
        do {
            try tap.start()
        } catch {
            musicError = error.localizedDescription
            return
        }
        engine.start()
        musicEngine = engine
        audioTap = tap
        updateActivity()
    }

    private func stopMusic() {
        audioTap?.stop()
        audioTap = nil
        musicEngine?.stop()
        musicEngine = nil
        audioFeatures = .silent
        musicColors = [:]
        updateActivity()
    }

    // MARK: Screen capture

    func requestScreenPermission() {
        if ScreenCapture.requestPermission() {
            captureState = .idle
            updateEngines()
        } else {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!)
        }
    }

    /// macOS only applies a newly granted Screen Recording permission after a relaunch.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApplication.shared.terminate(nil) }
        }
    }

    private var engineSettings: ScreenSyncEngine.Settings {
        ScreenSyncEngine.Settings(
            mapping: mapping,
            intensity: intensity,
            brightness: brightness,
            adjustment: ColorAdjustment(saturationBoost: saturationBoost, minimumBrightness: minimumBrightness)
        )
    }

    private func updateEngine() {
        engine?.update(engineSettings)
    }

    /// Screen capture runs only while streaming follows the screen; Settings and identify don't capture.
    private var captureNeeded: Bool {
        mode == .screen && state != .stopped && !streamingForIdentify
    }

    private func updateEngines() {
        updateMusic()
        Task {
            if captureNeeded {
                await startCapture()
            } else {
                await stopCapture()
            }
        }
    }

    private func startCapture() async {
        guard captureNeeded, capture == nil else { return }
        guard ScreenCapture.hasPermission else {
            captureState = .needsPermission
            return
        }

        let colorPreview = Throttle(interval: 0.1)
        let engine = ScreenSyncEngine(settings: engineSettings) { [screenSink, weak self] colors in
            screenSink.withLock { $0 }?.setColors(colors)
            if colorPreview.ready() {
                Task { @MainActor in self?.liveColors = colors }
            }
        }
        let framePreview = Throttle(interval: 0.1)
        let capture = ScreenCapture(
            onFrame: { [weak self] frame in
                engine.process(frame)
                if framePreview.ready() {
                    Task { @MainActor in self?.preview = frame.cgImage }
                }
            },
            onStop: { [weak self] error in
                Task { @MainActor in self?.captureStopped(error) }
            }
        )
        self.engine = engine
        self.capture = capture
        updateActivity()
        engine.start()
        if pausedForApp != nil { engine.hold(pausedColors) }
        await reconcileCaptureStream()
        // No longer needed by the time it started.
        if self.capture === capture, !captureNeeded {
            await stopCapture()
        }
    }

    /// Starts or stops the SCStream until it matches whether it should run (a capture session exists
    /// and no protected-video app is in front). Re-checks after every await, so a pause that arrives
    /// while the stream is starting still stops it.
    private func reconcileCaptureStream() async {
        guard !reconcilingCapture else { return }
        reconcilingCapture = true
        defer { reconcilingCapture = false }

        while let capture {
            let shouldRun = pausedForApp == nil
            guard shouldRun != captureStreamRunning else { return }
            if shouldRun {
                do {
                    try await capture.start(displayID: selectedDisplayID, excludedBundleIDs: excludedBundleIDs)
                } catch {
                    await stopCapture()
                    captureState = ScreenCapture.hasPermission ? .failed(error.localizedDescription) : .needsPermission
                    return
                }
                // Stopped or restarted while starting: this capture is orphaned.
                guard self.capture === capture else {
                    await capture.stop()
                    continue
                }
                captureStreamRunning = true
                captureState = .capturing
            } else {
                await capture.stop()
                captureStreamRunning = false
            }
        }
    }

    private var excludedBundleIDs: Set<String> {
        pauseForProtectedApps ? Self.protectedBundleIDs : []
    }

    private var pausedColors: [UInt8: LightColor] {
        Dictionary(uniqueKeysWithValues: area.channels.map { ($0.id, Self.pausedGlow) })
    }

    private func frontmostAppChanged(bundleID: String?, name: String?) {
        frontmostApp = (bundleID, name)
        updateProtectedPause()
    }

    private func updateProtectedPause() {
        let protectedInFront = pauseForProtectedApps && frontmostApp.bundleID.map(Self.protectedBundleIDs.contains) == true
        let paused = protectedInFront ? (frontmostApp.name ?? "Apple TV") : nil
        guard paused != pausedForApp else { return }
        pausedForApp = paused
        if let paused {
            Self.logger.notice("pausing capture while \(paused, privacy: .public) is in front")
        } else {
            Self.logger.notice("resuming capture")
        }
        engine?.hold(paused == nil ? nil : pausedColors)
        if paused != nil { preview = nil }
        Task { await reconcileCaptureStream() }
    }

    private func stopCapture() async {
        let capture = self.capture
        self.capture = nil
        captureStreamRunning = false
        updateActivity()
        engine?.stop()
        engine = nil
        preview = nil
        liveColors = [:]
        if captureState == .capturing { captureState = .idle }
        await capture?.stop()
    }

    private func restartCapture() async {
        await stopCapture()
        await startCapture()
    }

    private func captureStopped(_ error: Error) {
        guard capture != nil else { return }
        Task {
            await stopCapture()
            captureState = .failed("Screen capture stopped: \(error.localizedDescription)")
        }
    }
}

/// A display that can be captured.
struct DisplayInfo: Identifiable, Hashable {
    let id: CGDirectDisplayID
    let name: String
    let aspectRatio: Double

    static func all() -> [DisplayInfo] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            return DisplayInfo(id: number.uint32Value, name: screen.localizedName, aspectRatio: screen.frame.width / screen.frame.height)
        }
    }
}

/// Lets through at most one call per `interval`; safe from any thread.
private final class Throttle: Sendable {
    private let interval: TimeInterval
    private let last = OSAllocatedUnfairLock(initialState: -Double.infinity)

    init(interval: TimeInterval) {
        self.interval = interval
    }

    func ready() -> Bool {
        let now = ProcessInfo.processInfo.systemUptime
        return last.withLock { last in
            guard now - last >= interval else { return false }
            last = now
            return true
        }
    }
}

extension Frame {
    /// The frame as an image for previews.
    var cgImage: CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )
    }
}

extension LightColor {
    init(_ color: Color) {
        let srgb = NSColor(color).usingColorSpace(.sRGB) ?? .white
        self.init(red: srgb.redComponent, green: srgb.greenComponent, blue: srgb.blueComponent)
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue)
    }
}
