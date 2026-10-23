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
        let a = colors[index % colors.count], b = colors[(index + 1) % colors.count]
        return LightColor(
            red: a.red + (b.red - a.red) * fraction,
            green: a.green + (b.green - a.green) * fraction,
            blue: a.blue + (b.blue - a.blue) * fraction
        )
    }

    private static func color(_ hex: UInt32) -> LightColor {
        LightColor(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

/// Turns audio features into channel colors.
///
/// Colors come from a palette that steps to the next color on every beat and drifts slowly in between.
/// Strip segments spread across the palette as a moving gradient; lamps take a contrasting color and
/// pulse with the bass. Brightness follows loudness, with a flash on each beat that decays.
public struct MusicVisualizer: Sendable {
    public struct Settings: Sendable, Equatable {
        public var palette: MusicPalette
        public var intensity: SyncIntensity

        public init(palette: MusicPalette, intensity: SyncIntensity) {
            self.palette = palette
            self.intensity = intensity
        }
    }

    /// How hard and how long beats hit, per intensity.
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

    /// Strip segments in physical order; they form the gradient.
    public let stripChannels: [UInt8]
    public let lampChannels: [UInt8]

    /// Palette position shown now, and where it's heading.
    private(set) var position = 0.0
    private var targetPosition = 0.0
    private(set) var pulse = 0.0
    private(set) var level = 0.0
    private var bass = 0.0
    private var lastUpdate: TimeInterval?

    /// Palette steps per second between beats.
    static let drift = 0.04
    /// Time constant of the palette moving to its next color.
    static let colorEase = 0.18
    static let attack = 0.04

    public init(stripChannels: [UInt8], lampChannels: [UInt8]) {
        self.stripChannels = stripChannels
        self.lampChannels = lampChannels
    }

    /// - Parameters:
    ///   - features: The latest audio features.
    ///   - beat: Strength of the strongest beat since the last update, if any.
    public mutating func update(features: AudioFeatures, beat: Double?, settings: Settings, now: TimeInterval) -> [UInt8: LightColor] {
        let dt = lastUpdate.map { max(0, now - $0) } ?? 0
        lastUpdate = now
        let dynamics = Dynamics(settings.intensity)

        if let beat {
            targetPosition += 1
            pulse = max(pulse, beat * dynamics.pulseGain)
        }
        targetPosition += dt * Self.drift
        position += (targetPosition - position) * ease(dt, Self.colorEase)
        pulse *= exp(-dt / dynamics.pulseDecay)
        level = follow(level, toward: features.loudness, dt: dt, release: dynamics.release)
        bass = follow(bass, toward: features.bass, dt: dt, release: dynamics.release * 0.8)

        var colors: [UInt8: LightColor] = [:]
        let segmentCount = Double(max(stripChannels.count, 1))
        for (index, channel) in stripChannels.enumerated() {
            let drive = min(1, 0.55 * level + 0.15 * features.high + pulse)
            let brightness = dynamics.floor + (1 - dynamics.floor) * drive
            colors[channel] = settings.palette.color(at: position + Double(index) / segmentCount * 1.5).scaled(by: brightness)
        }
        for (index, channel) in lampChannels.enumerated() {
            let drive = min(1, 0.4 * level + 0.4 * bass + 1.2 * pulse)
            let brightness = dynamics.floor + (1 - dynamics.floor) * drive
            colors[channel] = settings.palette.color(at: position + 0.5 + Double(index) * 0.33).scaled(by: brightness)
        }
        return colors
    }

    /// Rises quickly, falls with the `release` time constant.
    private func follow(_ value: Double, toward target: Double, dt: TimeInterval, release: TimeInterval) -> Double {
        value + (target - value) * ease(dt, target > value ? Self.attack : release)
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

        public init(palette: MusicPalette, intensity: SyncIntensity, brightness: Double) {
            visualizer = MusicVisualizer.Settings(palette: palette, intensity: intensity)
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
