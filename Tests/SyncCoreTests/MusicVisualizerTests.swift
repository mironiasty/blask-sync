import Foundation
import HueKit
import Testing
@testable import SyncCore

struct MusicVisualizerTests {
    let settings = MusicVisualizer.Settings(palette: .vivid, intensity: .moderate)

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
            visualizer.update(features: features, beat: beatsAt.contains(tick) ? 1 : nil, settings: settings, now: start + Double(tick) / 50)
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
