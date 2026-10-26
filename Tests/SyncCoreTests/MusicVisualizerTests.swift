import Foundation
import HueKit
import Testing

@testable import SyncCore

struct PulseStyleTests {
    let settings = MusicVisualizer.Settings(palette: .vivid, intensity: .moderate, style: .pulse)

    private func brightness(_ color: LightColor) -> Double { max(color.red, color.green, color.blue) }

    /// Runs the visualizer at 50 Hz for `seconds` with constant features; beats at the given tick indices.
    private func run(
        _ visualizer: inout MusicVisualizer,
        seconds: Double,
        features: AudioFeatures,
        beatsAt: Set<Int> = [],
        start: TimeInterval = 0
    ) -> [[UInt8: LightColor]] {
        (0..<Int(seconds * 50)).map { tick in
            visualizer.update(
                features: features, beat: beatsAt.contains(tick) ? 1 : nil, settings: settings,
                now: start + Double(tick) / 50)
        }
    }

    @Test func paletteLoopsAndBlends() {
        let palette = MusicPalette.vivid
        #expect(palette.color(at: 0) == palette.colors[0])
        #expect(palette.color(at: Double(palette.colors.count)) == palette.colors[0])
        #expect(palette.color(at: -1) == palette.colors.last!)
        let halfway = palette.color(at: 0.5)
        #expect(abs(halfway.red - (palette.colors[0].red + palette.colors[1].red) / 2) < 1e-9)
    }

    @Test func silenceGlowsAtTheFloor() {
        var visualizer = MusicVisualizer(stripChannels: [0, 1], lampChannels: [7])
        let frames = run(&visualizer, seconds: 2, features: .silent)
        let floor = MusicVisualizer.Dynamics(.moderate).floor
        for color in frames.last!.values {
            #expect(abs(brightness(color) - floor) < 0.05)
        }
    }

    @Test func beatFlashesThenFades() {
        var visualizer = MusicVisualizer(stripChannels: [0], lampChannels: [7])
        let quiet = AudioFeatures(loudness: 0.2, bass: 0.2)
        let frames = run(&visualizer, seconds: 2, features: quiet, beatsAt: [50])
        let lamp = frames.map { brightness($0[7]!) }
        #expect(lamp[50] > lamp[49] + 0.3, "beat should flash")
        #expect(lamp[99] < lamp[50] - 0.3, "flash should fade within a second")
    }

    @Test func beatAdvancesThePalette() {
        var visualizer = MusicVisualizer(stripChannels: [0], lampChannels: [])
        _ = run(&visualizer, seconds: 1, features: .silent)
        let before = visualizer.position
        _ = run(&visualizer, seconds: 1, features: .silent, beatsAt: [0], start: 1)
        #expect(visualizer.position - before > 0.9)
    }

    @Test func louderMusicIsBrighter() {
        var quiet = MusicVisualizer(stripChannels: [0], lampChannels: [])
        var loud = MusicVisualizer(stripChannels: [0], lampChannels: [])
        let quietColor = run(&quiet, seconds: 1, features: AudioFeatures(loudness: 0.1)).last![0]!
        let loudColor = run(&loud, seconds: 1, features: AudioFeatures(loudness: 0.9)).last![0]!
        #expect(brightness(loudColor) > brightness(quietColor) + 0.3)
    }

    @Test func stripSegmentsFormAGradientAndLampsContrast() {
        var visualizer = MusicVisualizer(stripChannels: [0, 1, 2, 3], lampChannels: [7])
        let colors = run(&visualizer, seconds: 0.1, features: AudioFeatures(loudness: 0.5)).last!
        let strip = (0...3).map { colors[UInt8($0)]! }
        #expect(Set(strip.map { "\($0)" }).count == 4, "each segment gets its own color")
        #expect(!strip.contains(colors[7]!), "the lamp contrasts with the strip")
    }
}

struct FlowStyleTests {
    let settings = MusicVisualizer.Settings(palette: .vivid, intensity: .high, style: .flow)

    private func brightness(_ color: LightColor) -> Double { max(color.red, color.green, color.blue) }

    /// Runs at 50 Hz; `features(t)` gives the features at time t, beats every `beatInterval` seconds.
    private func run(
        _ visualizer: inout MusicVisualizer,
        seconds: Double,
        beatInterval: Double? = nil,
        features: (Double) -> AudioFeatures
    ) -> [[UInt8: LightColor]] {
        let ticksPerBeat = beatInterval.map { Int($0 * 50) }
        return (0..<Int(seconds * 50)).map { tick in
            let t = Double(tick) / 50
            let beat = ticksPerBeat.map { tick > 0 && tick % $0 == 0 } == true ? 1.0 : nil
            return visualizer.update(features: features(t), beat: beat, settings: settings, now: t)
        }
    }

    @Test func neverStepsEvenOnBeatsAndLoudnessJumps() {
        var visualizer = MusicVisualizer(stripChannels: Array(0...6), lampChannels: [7])
        // Loudness jumps between 0.1 and 1 every second, with a beat every 0.5 s.
        let frames = run(&visualizer, seconds: 6, beatInterval: 0.5) { t in
            AudioFeatures(loudness: Int(t) % 2 == 0 ? 0.1 : 1, bass: Int(t) % 2 == 0 ? 0.1 : 1)
        }
        var largestStep = 0.0
        for (previous, next) in zip(frames, frames.dropFirst()) {
            for (channel, color) in next {
                guard let before = previous[channel] else { continue }
                largestStep = max(
                    largestStep, abs(color.red - before.red), abs(color.green - before.green),
                    abs(color.blue - before.blue))
            }
        }
        // Measured: Pulse jumps by up to ~0.78 in one tick on a beat; Flow stays around 0.04.
        #expect(largestStep < 0.06, "largest step between ticks: \(largestStep)")
    }

    @Test func colorsFlowAlongTheStrip() {
        var visualizer = MusicVisualizer(stripChannels: Array(0...6), lampChannels: [])
        let frames = run(&visualizer, seconds: 4) { _ in AudioFeatures(loudness: 0.7) }
        let first = frames[50]
        let last = frames.last!
        // Segments show different colors (a gradient)…
        #expect(Set((0...6).map { "\(first[UInt8($0)]!)" }).count == 7)
        // …and the gradient moves over time.
        #expect(first[0]! != last[0]!)
        #expect(visualizer.flowPhase > 0.5)
    }

    @Test func louderMusicFlowsFaster() {
        var quiet = MusicVisualizer(stripChannels: [0], lampChannels: [])
        var loud = MusicVisualizer(stripChannels: [0], lampChannels: [])
        _ = run(&quiet, seconds: 3) { _ in AudioFeatures(loudness: 0.1) }
        _ = run(&loud, seconds: 3) { _ in AudioFeatures(loudness: 1) }
        #expect(loud.flowPhase > quiet.flowPhase * 2)
    }

    @Test func beatWaveTravelsFromTheMiddleToTheEnds() {
        var visualizer = MusicVisualizer(stripChannels: Array(0...6), lampChannels: [])
        let frames = run(&visualizer, seconds: 3, beatInterval: 1) { _ in AudioFeatures(loudness: 0.3) }
        // After the beat at t = 1 s: when does the middle segment (3) peak, and when does an end (0)?
        let window = Array(frames[50..<100])
        let middlePeak = window.indices.max { brightness(window[$0][3]!) < brightness(window[$1][3]!) }!
        let endPeak = window.indices.max { brightness(window[$0][0]!) < brightness(window[$1][0]!) }!
        #expect(middlePeak < endPeak, "middle peaks at tick \(middlePeak), end at \(endPeak)")
    }

    @Test func wavesSwellFromZero() {
        var visualizer = MusicVisualizer(stripChannels: [0, 1, 2], lampChannels: [])
        _ = visualizer.update(features: .silent, beat: 1, settings: settings, now: 0)
        #expect(visualizer.waveLevel(at: 0.5) == 0, "a new wave starts with no brightness")
    }

    @Test func silenceSettlesToTheFloor() {
        var visualizer = MusicVisualizer(stripChannels: [0, 1], lampChannels: [7])
        let frames = run(&visualizer, seconds: 3) { _ in .silent }
        let floor = MusicVisualizer.FlowDynamics(.high).floor
        for color in frames.last!.values {
            #expect(abs(brightness(color) - floor) < 0.02)
        }
    }
}
