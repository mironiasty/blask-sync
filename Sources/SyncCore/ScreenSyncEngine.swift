import Foundation
import HueKit
import os

/// Turns captured frames into smoothed channel colors.
///
/// Frames only set the target colors. A separate 50 Hz tick eases toward them, so transitions
/// complete even when the screen goes static and ScreenCaptureKit stops delivering frames.
public final class ScreenSyncEngine: @unchecked Sendable {
    // @unchecked: `timer` and `smoother` are only touched on `queue`; everything else is lock-protected or immutable.

    public struct Settings: Sendable, Equatable {
        public var mapping: ScreenMapping
        public var intensity: SyncIntensity
        public var brightness: Double
        public var adjustment: ColorAdjustment

        public init(mapping: ScreenMapping, intensity: SyncIntensity, brightness: Double, adjustment: ColorAdjustment = .none) {
            self.mapping = mapping
            self.intensity = intensity
            self.brightness = brightness
            self.adjustment = adjustment
        }
    }

    private let settings: OSAllocatedUnfairLock<Settings>
    private let target = OSAllocatedUnfairLock(initialState: [UInt8: LightColor]())
    private let output: @Sendable ([UInt8: LightColor]) -> Void
    private let queue = DispatchQueue(label: "blask.screen-sync", qos: .userInteractive)
    private var smoother = ColorSmoother()
    private var timer: DispatchSourceTimer?
    private var tickStats = IntervalStats()
    private let frameStats = OSAllocatedUnfairLock(initialState: IntervalStats())
    private static let logger = Logger(subsystem: "local.blasksync", category: "screen-sync")

    /// - Parameter output: Called on the engine's queue with brightness-scaled colors, 50 times a second.
    public init(settings: Settings, output: @escaping @Sendable ([UInt8: LightColor]) -> Void) {
        self.settings = OSAllocatedUnfairLock(initialState: settings)
        self.output = output
    }

    public func update(_ settings: Settings) {
        self.settings.withLock { $0 = settings }
    }

    /// Safe to call from any thread; cheap enough for every captured frame.
    public func process(_ frame: Frame) {
        let (mapping, adjustment) = settings.withLock { ($0.mapping, $0.adjustment) }
        let colors = ColorExtractor.averageColors(in: frame, mapping: mapping).mapValues(adjustment.apply)
        target.withLock { $0 = colors }
        if let summary = frameStats.withLock({ $0.record() }) {
            Self.logger.notice("captured \(summary.description, privacy: .public)")
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
            smoother = ColorSmoother()
        }
    }

    /// Runs on `queue`.
    private func tick() {
        let goal = target.withLock { $0 }
        guard !goal.isEmpty else { return }
        let settings = settings.withLock { $0 }
        let smoothed = smoother.update(
            toward: goal,
            timeConstant: settings.intensity.timeConstant,
            now: ProcessInfo.processInfo.systemUptime
        )
        output(smoothed.mapValues { $0.scaled(by: settings.brightness) })
        if let summary = tickStats.record() {
            Self.logger.notice("ticked \(summary.description, privacy: .public)")
        }
    }
}
