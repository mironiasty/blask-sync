import Testing
@testable import SyncCore

struct LevelStatsTests {
    @Test func reportsPeakPerWindow() {
        var stats = LevelStats()
        #expect(stats.record([0.1, -0.5], now: 0) == nil)
        #expect(stats.record([0.2], now: 2) == nil)
        #expect(stats.record([0.05], now: 5) == "audio: 3 buffers in 5.0 s, peak -6 dB")
    }

    @Test func reportsSilence() {
        var stats = LevelStats()
        _ = stats.record([0, 0], now: 0)
        #expect(stats.record([0], now: 5) == "audio: 2 buffers in 5.0 s, peak silent")
    }
}
