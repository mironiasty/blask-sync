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
        case manual, screen
    }

    enum CaptureState: Equatable {
        case idle, needsPermission, capturing
        case failed(String)
    }

    let area: EntertainmentArea
    private(set) var state: StreamState = .stopped
    /// What renders each channel (lamp or strip segment); empty until `loadLights()` finishes.
    private(set) var channelDescriptions: [UInt8: ChannelDescription] = [:]
    /// Base color per channel; `brightness` is applied on top when sending.
    private(set) var colors: [UInt8: LightColor]
    var brightness = 1.0 {
        didSet {
            pushColors()
            updateEngine()
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

    // MARK: Screen sync state

    var mode: Mode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Keys.mode)
            routeOutput()
            Task { mode == .screen ? await startCapture() : await stopCapture() }
        }
    }
    private(set) var displays: [DisplayInfo] = DisplayInfo.all()
    var selectedDisplayID: CGDirectDisplayID {
        didSet {
            guard selectedDisplayID != oldValue else { return }
            UserDefaults.standard.set(Int(selectedDisplayID), forKey: Keys.displayID)
            Task { await restartCapture() }
        }
    }
    var intensity: SyncIntensity {
        didSet {
            UserDefaults.standard.set(intensity.rawValue, forKey: Keys.intensity)
            updateEngine()
        }
    }
    private(set) var captureState: CaptureState = .idle
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

    private enum Keys {
        static let mode = "sync.mode"
        static let displayID = "sync.displayID"
        static let intensity = "sync.intensity"
    }

    init(area: EntertainmentArea, credentials: BridgeCredentials) {
        self.area = area
        self.credentials = credentials
        colors = Dictionary(uniqueKeysWithValues: area.channels.map { ($0.id, LightColor.white) })
        mapping = (mappingStore.load(areaId: area.id) ?? .defaults(for: area.channels)).reconciled(with: area.channels)

        let defaults = UserDefaults.standard
        mode = defaults.string(forKey: Keys.mode).flatMap(Mode.init) ?? .manual
        intensity = defaults.string(forKey: Keys.intensity).flatMap(SyncIntensity.init) ?? .moderate
        let savedDisplay = CGDirectDisplayID(defaults.integer(forKey: Keys.displayID))
        selectedDisplayID = DisplayInfo.all().contains { $0.id == savedDisplay } ? savedDisplay : CGMainDisplayID()
    }

    /// Called when the window appears.
    func activate() async {
        displays = DisplayInfo.all()
        if mode == .screen { await startCapture() }
        await loadLights()
    }

    /// Called when the window closes: releases the lights and stops capturing.
    func deactivate() async {
        await stopCapture()
        await stop()
    }

    func loadLights() async {
        guard channelDescriptions.isEmpty else { return }
        do {
            let lights = try await BridgeClient(credentials: credentials)
                .entertainmentLights(applicationKey: credentials.applicationKey)
            channelDescriptions = Dictionary(uniqueKeysWithValues: area.channels.map {
                ($0.id, ChannelDescription(channel: $0, lights: lights))
            })
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
        mapping = .defaults(for: area.channels)
    }

    func setColor(_ color: LightColor, channel: UInt8) {
        colors[channel] = color
        pushColors()
    }

    func setAllColors(_ color: LightColor) {
        for channel in colors.keys { colors[channel] = color }
        pushColors()
    }

    func start() async {
        guard state == .stopped else { return }
        state = .starting
        errorMessage = nil
        let stream = EntertainmentStream(
            credentials: credentials,
            areaId: area.id,
            initialColors: followsScreen && !liveColors.isEmpty ? liveColors : outputColors,
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
            routeOutput()
            updateActivity()
        } catch {
            state = .stopped
            errorMessage = "Couldn't start streaming: \(error.localizedDescription)"
        }
    }

    func stop() async {
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
    }

    private func streamDropped(_ error: Error) {
        guard let stream else { return }
        self.stream = nil
        routeOutput()
        updateActivity()
        state = .stopped
        errorMessage = "Streaming stopped: \(error.localizedDescription)"
        Task { await stream.stop() }
    }

    private var outputColors: [UInt8: LightColor] {
        if let identifiedChannel {
            return Dictionary(uniqueKeysWithValues: colors.keys.map { ($0, $0 == identifiedChannel ? LightColor.white : .black) })
        }
        return colors.mapValues { $0.scaled(by: brightness) }
    }

    /// Whether the lights currently follow the screen (as opposed to manual colors or identify).
    private var followsScreen: Bool {
        mode == .screen && identifiedChannel == nil
    }

    private func pushColors() {
        guard !followsScreen else { return }
        stream?.setColors(outputColors)
    }

    private func updateActivity() {
        // Debug switch to compare against App Nap: `defaults write local.blasksync.BlaskSync sync.allowAppNap -bool YES`
        let needed = (stream != nil || capture != nil) && !UserDefaults.standard.bool(forKey: "sync.allowAppNap")
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

    private func routeOutput() {
        let target = followsScreen ? stream : nil
        screenSink.withLock { $0 = target }
        pushColors()
    }

    // MARK: Screen capture

    func requestScreenPermission() {
        if ScreenCapture.requestPermission() {
            Task { await startCapture() }
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
        ScreenSyncEngine.Settings(mapping: mapping, intensity: intensity, brightness: brightness)
    }

    private func updateEngine() {
        engine?.update(engineSettings)
    }

    private func startCapture() async {
        guard mode == .screen, capture == nil else { return }
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
        do {
            try await capture.start(displayID: selectedDisplayID)
            // Mode switched back or capture restarted while starting.
            guard self.capture === capture else {
                await capture.stop()
                return
            }
            captureState = .capturing
        } catch {
            await stopCapture()
            captureState = ScreenCapture.hasPermission ? .failed(error.localizedDescription) : .needsPermission
        }
    }

    private func stopCapture() async {
        let capture = self.capture
        self.capture = nil
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
