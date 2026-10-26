import Foundation
import Testing

@testable import SyncCore

struct AudioAnalyzerTests {
    let sampleRate = 48_000.0

    private func sine(_ frequency: Double, seconds: Double, amplitude: Double = 0.5) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { Float(amplitude * sin(2 * .pi * frequency * Double($0) / sampleRate)) }
    }

    /// Averages the last half of the features, after auto-gain has settled.
    private func settled(_ features: [AudioFeatures]) -> AudioFeatures {
        let tail = features.suffix(features.count / 2)
        let n = Double(tail.count)
        return AudioFeatures(
            loudness: tail.map(\.loudness).reduce(0, +) / n,
            bass: tail.map(\.bass).reduce(0, +) / n,
            mid: tail.map(\.mid).reduce(0, +) / n,
            high: tail.map(\.high).reduce(0, +) / n
        )
    }

    @Test func silenceIsSilent() {
        let analyzer = AudioAnalyzer(sampleRate: sampleRate)
        let features = analyzer.process([Float](repeating: 0, count: 48_000))
        #expect(!features.isEmpty)
        #expect(features.allSatisfy { $0 == .silent })
    }

    @Test func emitsOneFeatureSetPerHop() {
        let analyzer = AudioAnalyzer(sampleRate: sampleRate, frameSize: 1024)
        // 1 s = 48 000 samples → (48 000 − 1024) / 512 + 1 = 92 hops.
        #expect(analyzer.process(sine(440, seconds: 1)).count == 92)
    }

    @Test func lowToneIsBass() {
        let analyzer = AudioAnalyzer(sampleRate: sampleRate)
        // Prime the peaks with broadband content so the bands are comparable.
        _ = analyzer.process(
            zip(sine(60, seconds: 1), zip(sine(600, seconds: 1), sine(5000, seconds: 1))).map { $0 + $1.0 + $1.1 })
        let result = settled(analyzer.process(sine(60, seconds: 1)))
        #expect(result.bass > 0.8)
        #expect(result.high < 0.3)
    }

    @Test func highToneIsHigh() {
        let analyzer = AudioAnalyzer(sampleRate: sampleRate)
        _ = analyzer.process(
            zip(sine(60, seconds: 1), zip(sine(600, seconds: 1), sine(5000, seconds: 1))).map { $0 + $1.0 + $1.1 })
        let result = settled(analyzer.process(sine(5000, seconds: 1)))
        #expect(result.high > 0.8)
        #expect(result.bass < 0.3)
    }

    @Test func autoGainMakesQuietMusicRegister() {
        let analyzer = AudioAnalyzer(sampleRate: sampleRate)
        let result = settled(analyzer.process(sine(60, seconds: 2, amplitude: 0.01)))
        #expect(result.loudness > 0.8)
    }

    @Test func detectsKickDrumBeats() {
        // A 60 Hz "kick" for 80 ms every 0.5 s over a quiet hi-hat bed: 120 BPM for 4 s.
        let seconds = 4.0
        let bed = sine(8000, seconds: seconds, amplitude: 0.02)
        let kick = (0..<Int(seconds * sampleRate)).map { index -> Float in
            let t = Double(index) / sampleRate
            let phase = t.truncatingRemainder(dividingBy: 0.5)
            return phase < 0.08 ? Float(0.8 * sin(2 * .pi * 60 * t)) : 0
        }
        let analyzer = AudioAnalyzer(sampleRate: sampleRate)
        let features = analyzer.process(zip(kick, bed).map { $0 + $1 })

        let hop = 512 / sampleRate
        let beatTimes = features.enumerated().filter(\.element.isBeat).map { Double($0.offset) * hop }
        // The first kick has no history to compare against; the other 7 should all register.
        #expect((6...8).contains(beatTimes.count), "beats at \(beatTimes)")
        for (a, b) in zip(beatTimes, beatTimes.dropFirst()) {
            #expect(abs((b - a) - 0.5) < 0.05, "beats should be 0.5 s apart: \(beatTimes)")
        }
        #expect(features.filter(\.isBeat).allSatisfy { $0.beatStrength > 0 })
    }

    @Test func steadyToneHasNoBeats() {
        let analyzer = AudioAnalyzer(sampleRate: sampleRate)
        #expect(analyzer.process(sine(60, seconds: 3)).filter(\.isBeat).isEmpty)
    }
}
