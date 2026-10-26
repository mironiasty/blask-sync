import Foundation

/// Tracks how regularly a periodic event fires; reports once per window.
/// Used to spot timer throttling (e.g. App Nap), which shows up as long gaps.
public struct IntervalStats: Sendable {
    public struct Summary: Sendable, CustomStringConvertible {
        public let count: Int
        public let duration: TimeInterval
        public let maxGap: TimeInterval
        public let gapsOver50ms: Int

        public var description: String {
            String(
                format: "%d events in %.1f s (%.1f/s), max gap %.0f ms, %d gaps > 50 ms",
                count, duration, Double(count) / duration, maxGap * 1000, gapsOver50ms)
        }
    }

    private let window: TimeInterval
    private var windowStart: TimeInterval?
    private var last: TimeInterval?
    private var count = 0
    private var maxGap: TimeInterval = 0
    private var gapsOver50ms = 0

    public init(window: TimeInterval = 5) {
        self.window = window
    }

    /// Records one event; returns a summary when the window is complete.
    public mutating func record(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Summary? {
        if let last {
            let gap = now - last
            maxGap = max(maxGap, gap)
            if gap > 0.05 { gapsOver50ms += 1 }
        }
        last = now
        count += 1

        guard let start = windowStart else {
            windowStart = now
            return nil
        }
        guard now - start >= window else { return nil }
        let summary = Summary(count: count, duration: now - start, maxGap: maxGap, gapsOver50ms: gapsOver50ms)
        windowStart = now
        count = 0
        maxGap = 0
        gapsOver50ms = 0
        return summary
    }
}
