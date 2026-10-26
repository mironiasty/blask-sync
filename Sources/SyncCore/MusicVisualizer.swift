import Foundation
import HueKit
import os

/// Colors music sync cycles through.
public enum MusicPalette: String, CaseIterable, Codable, Sendable {
    case vivid, sunset, ocean, party

    public var colors: [LightColor] {
        switch self {
        case .vivid: [0xFF2D95, 0xFF7A1A, 0xFFD23F, 0x18E0C0, 0x2F7BFF, 0x8B5CF6].map(Self.color)
        case .sunset: [0xE8203A, 0xFF6B1A, 0xFFB23F, 0xFF4F8B, 0x9B3CFF].map(Self.color)
        case .ocean: [0x1438FF, 0x00C8FF, 0x00E0B0, 0x6A3CFF, 0x2F9BFF].map(Self.color)
        case .party: [0xFF0040, 0x00FF6A, 0x0050FF, 0xFFE600, 0xFF00D4].map(Self.color)
        }
    }

    /// The palette as a loop: position 0 is the first color, 1 the second, and so on, blending in between.
    public func color(at position: Double) -> LightColor {
        let colors = colors
        let wrapped = position - floor(position / Double(colors.count)) * Double(colors.count)
        let index = Int(wrapped)
        let fraction = wrapped - Double(index)
        let a = colors[index % colors.count]
        let b = colors[(index + 1) % colors.count]
        return LightColor(
            red: a.red + (b.red - a.red) * fraction,
            green: a.green + (b.green - a.green) * fraction,
            blue: a.blue + (b.blue - a.blue) * fraction
        )
    }

    private static func color(_ hex: UInt32) -> LightColor {
        LightColor(
            red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255)
    }
}

/// How music sync visualizes a song.
public enum MusicStyle: String, CaseIterable, Codable, Sendable {
    /// Colors flow along the strip at a speed set by the music; beats travel through it as soft waves.
    case flow
    /// Colors step to the next palette color on every beat, with a brightness flash.
    case pulse
}

/// Turns audio features into channel colors, in one of two styles (see `MusicStyle`).
public struct MusicVisualizer: Sendable {
    public struct Settings: Sendable, Equatable {
        public var palette: MusicPalette
        public var intensity: SyncIntensity
        public var style: MusicStyle

        public init(palette: MusicPalette, intensity: SyncIntensity, style: MusicStyle = .flow) {
            self.palette = palette
            self.intensity = intensity
            self.style = style
        }
    }

    /// Pulse style: how hard and how long beats hit, per intensity.
    struct Dynamics {
        /// Brightness added by a full-strength beat.
        let pulseGain: Double
        /// Time constant of the beat flash fading out.
        let pulseDecay: TimeInterval
        /// Time constant of brightness falling when the music gets quieter.
        let release: TimeInterval
        /// Brightness with no sound.
        let floor: Double

        init(_ intensity: SyncIntensity) {
            switch intensity {
            case .subtle: (pulseGain, pulseDecay, release, floor) = (0.35, 0.45, 0.6, 0.25)
            case .moderate: (pulseGain, pulseDecay, release, floor) = (0.6, 0.32, 0.4, 0.2)
            case .high: (pulseGain, pulseDecay, release, floor) = (0.85, 0.22, 0.25, 0.15)
            case .extreme: (pulseGain, pulseDecay, release, floor) = (1, 0.14, 0.15, 0.08)
            }
        }
    }

    /// Flow style: how lively the movement is, per intensity.
    struct FlowDynamics {
        /// Multiplies the flow speed.
        let speed: Double
        /// Brightness a full-strength beat wave adds at its crest.
        let waveGain: Double
        /// Time constants of brightness following loudness up and down.
        let attack: TimeInterval
        let release: TimeInterval
        /// Brightness with no sound.
        let floor: Double

        init(_ intensity: SyncIntensity) {
            switch intensity {
            case .subtle: (speed, waveGain, attack, release, floor) = (0.5, 0.35, 0.5, 1.6, 0.3)
            case .moderate: (speed, waveGain, attack, release, floor) = (0.75, 0.5, 0.35, 1.2, 0.25)
            case .high: (speed, waveGain, attack, release, floor) = (1, 0.65, 0.25, 0.9, 0.2)
            case .extreme: (speed, waveGain, attack, release, floor) = (1.4, 0.8, 0.15, 0.6, 0.15)
            }
        }
    }

    /// A beat traveling from the middle of the strip to both ends.
    struct Wave: Sendable {
        var age: TimeInterval
        let strength: Double
    }

    /// Strip segments in physical order; they form the gradient.
    public let stripChannels: [UInt8]
    public let lampChannels: [UInt8]
    private var lastUpdate: TimeInterval?

    // Pulse state.
    /// Palette position shown now, and where it's heading.
    private(set) var position = 0.0
    private var targetPosition = 0.0
    private(set) var pulse = 0.0
    private(set) var level = 0.0
    private var bass = 0.0

    // Flow state.
    private(set) var flowPhase = 0.0
    private(set) var waves: [Wave] = []
    private var energy = 0.0
    private var slowEnergy = 0.0
    private var slowBass = 0.0
    private var flowSmoother = ColorSmoother()

    /// Pulse: palette steps per second between beats, and how fast it moves to its next color.
    static let drift = 0.04
    static let colorEase = 0.18
    static let attack = 0.04

    /// Flow: palette steps per second at silence and at full loudness (before the intensity multiplier).
    static let flowSpeedQuiet = 0.05
    static let flowSpeedLoud = 0.4
    /// How many palette colors the strip shows at once.
    static let gradientSpread = 1.2
    static let waveDuration = 1.0
    /// Width of a wave's crest, as a fraction of half the strip.
    static let waveWidth = 0.18
    /// Final smoothing of every Flow color, so nothing ever steps.
    static let flowOutputSmoothing = 0.15

    public init(stripChannels: [UInt8], lampChannels: [UInt8]) {
        self.stripChannels = stripChannels
        self.lampChannels = lampChannels
    }

    /// - Parameters:
    ///   - features: The latest audio features.
    ///   - beat: Strength of the strongest beat since the last update, if any.
    public mutating func update(features: AudioFeatures, beat: Double?, settings: Settings, now: TimeInterval)
        -> [UInt8: LightColor]
    {
        let dt = lastUpdate.map { max(0, now - $0) } ?? 0
        lastUpdate = now
        switch settings.style {
        case .flow: return flow(features: features, beat: beat, settings: settings, dt: dt, now: now)
        case .pulse: return pulse(features: features, beat: beat, settings: settings, dt: dt)
        }
    }

    // MARK: Flow

    private mutating func flow(
        features: AudioFeatures, beat: Double?, settings: Settings, dt: TimeInterval, now: TimeInterval
    ) -> [UInt8: LightColor] {
        let dynamics = FlowDynamics(settings.intensity)
        energy = smooth(energy, toward: features.loudness, dt: dt, attack: dynamics.attack, release: dynamics.release)
        slowEnergy = smooth(slowEnergy, toward: features.loudness, dt: dt, attack: 0.6, release: 1.8)
        slowBass = smooth(slowBass, toward: features.bass, dt: dt, attack: 0.4, release: 1.2)
        flowPhase += dt * (Self.flowSpeedQuiet + (Self.flowSpeedLoud - Self.flowSpeedQuiet) * energy) * dynamics.speed

        for index in waves.indices { waves[index].age += dt }
        waves.removeAll { $0.age >= Self.waveDuration }
        if let beat {
            waves.append(Wave(age: 0, strength: beat * dynamics.waveGain))
            if waves.count > 6 { waves.removeFirst() }
        }

        var colors: [UInt8: LightColor] = [:]
        let lastIndex = Double(max(stripChannels.count - 1, 1))
        for (index, channel) in stripChannels.enumerated() {
            let along = stripChannels.count > 1 ? Double(index) / lastIndex : 0.5
            let drive = min(1, 0.6 * energy + waveLevel(at: along))
            let brightness = dynamics.floor + (1 - dynamics.floor) * drive
            colors[channel] = settings.palette.color(at: flowPhase + along * Self.gradientSpread).scaled(by: brightness)
        }
        for (index, channel) in lampChannels.enumerated() {
            let drive = min(1, 0.45 * slowEnergy + 0.35 * slowBass)
            let brightness = dynamics.floor + (1 - dynamics.floor) * drive
            let position = flowPhase + Self.gradientSpread / 2 + 0.5 + Double(index) * 0.33
            colors[channel] = settings.palette.color(at: position).scaled(by: brightness)
        }
        return flowSmoother.update(toward: colors, timeConstant: Self.flowOutputSmoothing, now: now)
    }

    /// Brightness the beat waves add at `along` (0 and 1 are the strip's ends). Each wave's crest moves
    /// from the middle to both ends while it swells and fades (zero at its start and end, so no jumps).
    func waveLevel(at along: Double) -> Double {
        let distanceFromMiddle = abs(along - 0.5) * 2
        var total = 0.0
        for wave in waves {
            let progress = wave.age / Self.waveDuration
            let envelope = sin(.pi * progress)
            let offset = distanceFromMiddle - progress
            total += wave.strength * envelope * exp(-offset * offset / (2 * Self.waveWidth * Self.waveWidth))
        }
        return min(1, total)
    }

    // MARK: Pulse

    private mutating func pulse(features: AudioFeatures, beat: Double?, settings: Settings, dt: TimeInterval) -> [UInt8:
        LightColor]
    {
        let dynamics = Dynamics(settings.intensity)
        if let beat {
            targetPosition += 1
            pulse = max(pulse, beat * dynamics.pulseGain)
        }
        targetPosition += dt * Self.drift
        position += (targetPosition - position) * ease(dt, Self.colorEase)
        pulse *= exp(-dt / dynamics.pulseDecay)
        level = smooth(level, toward: features.loudness, dt: dt, attack: Self.attack, release: dynamics.release)
        bass = smooth(bass, toward: features.bass, dt: dt, attack: Self.attack, release: dynamics.release * 0.8)

        var colors: [UInt8: LightColor] = [:]
        let segmentCount = Double(max(stripChannels.count, 1))
        for (index, channel) in stripChannels.enumerated() {
            let drive = min(1, 0.55 * level + 0.15 * features.high + pulse)
            let brightness = dynamics.floor + (1 - dynamics.floor) * drive
            colors[channel] = settings.palette.color(at: position + Double(index) / segmentCount * 1.5).scaled(
                by: brightness)
        }
        for (index, channel) in lampChannels.enumerated() {
            let drive = min(1, 0.4 * level + 0.4 * bass + 1.2 * pulse)
            let brightness = dynamics.floor + (1 - dynamics.floor) * drive
            colors[channel] = settings.palette.color(at: position + 0.5 + Double(index) * 0.33).scaled(by: brightness)
        }
        return colors
    }

    // MARK: Helpers

    /// Follows `target` with separate rise and fall time constants.
    private func smooth(
        _ value: Double, toward target: Double, dt: TimeInterval, attack: TimeInterval, release: TimeInterval
    ) -> Double {
        value + (target - value) * ease(dt, target > value ? attack : release)
    }

    private func ease(_ dt: TimeInterval, _ timeConstant: TimeInterval) -> Double {
        1 - exp(-dt / timeConstant)
    }
}

/// Analyzes captured audio and drives `MusicVisualizer` at 50 Hz.
public final class MusicSyncEngine: @unchecked Sendable {
    // @unchecked: `analyzer` is only touched from process() (the tap's serial queue), `timer` and
    // `visualizer` only on `queue`; everything else is lock-protected or immutable.

    public struct Settings: Sendable, Equatable {
        public var visualizer: MusicVisualizer.Settings
        public var brightness: Double

        public init(palette: MusicPalette, intensity: SyncIntensity, style: MusicStyle = .flow, brightness: Double) {
            visualizer = MusicVisualizer.Settings(palette: palette, intensity: intensity, style: style)
            self.brightness = brightness
        }
    }

    private let settings: OSAllocatedUnfairLock<Settings>
    /// Latest features plus the strongest beat not yet shown.
    private let latest = OSAllocatedUnfairLock(initialState: (features: AudioFeatures.silent, beat: Double?.none))
    private let output: @Sendable ([UInt8: LightColor], AudioFeatures, Bool) -> Void
    private let queue = DispatchQueue(label: "blask.music-sync", qos: .userInteractive)
    private var analyzer: AudioAnalyzer?
    private var visualizer: MusicVisualizer
    private var timer: DispatchSourceTimer?

    /// - Parameter output: Called on the engine's queue 50 times a second with brightness-scaled colors,
    ///   the features they came from, and whether a beat landed since the last call.
    public init(
        settings: Settings,
        stripChannels: [UInt8],
        lampChannels: [UInt8],
        output: @escaping @Sendable ([UInt8: LightColor], AudioFeatures, Bool) -> Void
    ) {
        self.settings = OSAllocatedUnfairLock(initialState: settings)
        visualizer = MusicVisualizer(stripChannels: stripChannels, lampChannels: lampChannels)
        self.output = output
    }

    public func update(_ settings: Settings) {
        self.settings.withLock { $0 = settings }
    }

    /// Feeds captured samples; call from one serial queue.
    public func process(_ samples: UnsafeBufferPointer<Float>, sampleRate: Double) {
        if analyzer?.sampleRate != sampleRate {
            analyzer = AudioAnalyzer(sampleRate: sampleRate)
        }
        for features in analyzer!.process(samples) {
            latest.withLock { latest in
                latest.features = features
                if features.isBeat { latest.beat = max(latest.beat ?? 0, features.beatStrength) }
            }
        }
    }

    public func start() {
        queue.sync {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(20), leeway: .milliseconds(2))
            timer.setEventHandler { [weak self] in self?.tick() }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop() {
        queue.sync {
            timer?.cancel()
            timer = nil
        }
    }

    /// Runs on `queue`.
    private func tick() {
        let (features, beat) = latest.withLock { latest in
            defer { latest.beat = nil }
            return (latest.features, latest.beat)
        }
        let settings = settings.withLock { $0 }
        let colors = visualizer.update(
            features: features,
            beat: beat,
            settings: settings.visualizer,
            now: ProcessInfo.processInfo.systemUptime
        )
        output(colors.mapValues { $0.scaled(by: settings.brightness) }, features, beat != nil)
    }
}
