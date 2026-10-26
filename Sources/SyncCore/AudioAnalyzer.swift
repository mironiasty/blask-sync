import Accelerate
import Foundation

/// What the music is doing right now, normalized for display and light mapping.
public struct AudioFeatures: Sendable, Equatable {
    /// Overall level, 0...1 relative to the recent peak (auto-gain).
    public var loudness: Double
    /// Band levels, 0...1 relative to each band's recent peak.
    public var bass: Double
    public var mid: Double
    public var high: Double
    /// Whether this frame starts a beat (a sudden rise in bass energy).
    public var isBeat: Bool
    /// How pronounced the beat is, 0...1; 0 when `isBeat` is false.
    public var beatStrength: Double

    public init(
        loudness: Double = 0, bass: Double = 0, mid: Double = 0, high: Double = 0, isBeat: Bool = false,
        beatStrength: Double = 0
    ) {
        self.loudness = loudness
        self.bass = bass
        self.mid = mid
        self.high = high
        self.isBeat = isBeat
        self.beatStrength = beatStrength
    }

    public static let silent = AudioFeatures()
}

/// Turns a mono sample stream into `AudioFeatures`, one per hop of `frameSize / 2` samples
/// (about 11 ms at 48 kHz). Not thread-safe: feed it from one queue.
public final class AudioAnalyzer {
    public let sampleRate: Double
    public let frameSize: Int
    private var hopSize: Int { frameSize / 2 }

    private let fft: vDSP.FFT<DSPSplitComplex>
    private let window: [Float]
    private var pending: [Float] = []

    /// Recent peak level per band in dB, decaying slowly so quiet passages and quiet tracks still register.
    private var peaks = BandLevels(all: -120)
    /// Recent bass energy (linear), for beat detection.
    private var bassHistory: [Double] = []
    private var secondsSinceBeat = Double.infinity

    /// Band edges in Hz.
    static let bassRange = 20.0..<150.0
    static let midRange = 150.0..<2000.0
    static let highRange = 2000.0..<10000.0

    /// Levels this far below the recent peak read as 0.
    static let dynamicRange = 36.0
    /// How fast the recent peak falls, in dB per second.
    static let peakDecay = 4.0
    /// RMS below this is silence.
    static let silenceRMS: Float = 0.0005
    /// Beats need bass this many times above its recent average, and this far apart.
    static let beatRatio = 1.45
    static let minimumBeatInterval = 0.25

    public init(sampleRate: Double, frameSize: Int = 1024) {
        precondition(frameSize.nonzeroBitCount == 1, "frameSize must be a power of two")
        self.sampleRate = sampleRate
        self.frameSize = frameSize
        fft = vDSP.FFT(
            log2n: vDSP_Length(frameSize.trailingZeroBitCount), radix: .radix2, ofType: DSPSplitComplex.self)!
        window = vDSP.window(
            ofType: Float.self, usingSequence: .hanningDenormalized, count: frameSize, isHalfWindow: false)
    }

    /// Appends samples and returns features for every complete hop.
    public func process(_ samples: UnsafeBufferPointer<Float>) -> [AudioFeatures] {
        pending.append(contentsOf: samples)
        var results: [AudioFeatures] = []
        while pending.count >= frameSize {
            results.append(analyzeFrame(Array(pending[0..<frameSize])))
            pending.removeFirst(hopSize)
        }
        return results
    }

    public func process(_ samples: [Float]) -> [AudioFeatures] {
        samples.withUnsafeBufferPointer { process($0) }
    }

    // MARK: Analysis

    private struct BandLevels {
        var bass: Double, mid: Double, high: Double, total: Double
        init(all value: Double) { (bass, mid, high, total) = (value, value, value, value) }
    }

    private func analyzeFrame(_ frame: [Float]) -> AudioFeatures {
        let hopDuration = Double(hopSize) / sampleRate
        secondsSinceBeat += hopDuration

        let rms = vDSP.rootMeanSquare(frame)
        guard rms >= Self.silenceRMS else {
            decayPeaks(by: hopDuration)
            bassHistory.removeAll()
            return .silent
        }

        let power = powerSpectrum(vDSP.multiply(frame, window))
        let bassPower = bandPower(power, Self.bassRange)
        let levels = (
            bass: decibels(bassPower),
            mid: decibels(bandPower(power, Self.midRange)),
            high: decibels(bandPower(power, Self.highRange)),
            total: decibels(Double(vDSP.sum(power)))
        )

        decayPeaks(by: hopDuration)
        peaks.bass = max(peaks.bass, levels.bass)
        peaks.mid = max(peaks.mid, levels.mid)
        peaks.high = max(peaks.high, levels.high)
        peaks.total = max(peaks.total, levels.total)

        let bass = normalized(levels.bass, peak: peaks.bass)
        let (isBeat, strength) = detectBeat(bassPower: bassPower, bassLevel: bass, hopDuration: hopDuration)

        return AudioFeatures(
            loudness: normalized(levels.total, peak: peaks.total),
            bass: bass,
            mid: normalized(levels.mid, peak: peaks.mid),
            high: normalized(levels.high, peak: peaks.high),
            isBeat: isBeat,
            beatStrength: strength
        )
    }

    /// A beat is bass energy jumping well above its average over the last ~0.5 s.
    private func detectBeat(bassPower: Double, bassLevel: Double, hopDuration: Double) -> (Bool, Double) {
        let historyLength = max(8, Int(0.5 / hopDuration))
        defer {
            bassHistory.append(bassPower)
            if bassHistory.count > historyLength { bassHistory.removeFirst() }
        }
        guard bassHistory.count >= historyLength / 2 else { return (false, 0) }
        let average = bassHistory.reduce(0, +) / Double(bassHistory.count)
        guard average > 0 else { return (false, 0) }

        let ratio = bassPower / average
        guard ratio >= Self.beatRatio, bassLevel > 0.4, secondsSinceBeat >= Self.minimumBeatInterval else {
            return (false, 0)
        }
        secondsSinceBeat = 0
        return (true, min(1, 0.4 + (ratio - Self.beatRatio) / 3))
    }

    private func powerSpectrum(_ frame: [Float]) -> [Float] {
        let half = frameSize / 2
        var real = [Float](repeating: 0, count: half)
        var imaginary = [Float](repeating: 0, count: half)
        var power = [Float](repeating: 0, count: half)
        real.withUnsafeMutableBufferPointer { realPointer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryPointer in
                var split = DSPSplitComplex(realp: realPointer.baseAddress!, imagp: imaginaryPointer.baseAddress!)
                frame.withUnsafeBufferPointer { samples in
                    samples.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                fft.forward(input: split, output: &split)
                vDSP.squareMagnitudes(split, result: &power)
            }
        }
        return power
    }

    private func bandPower(_ power: [Float], _ range: Range<Double>) -> Double {
        let binWidth = sampleRate / Double(frameSize)
        let lower = max(1, Int(range.lowerBound / binWidth))
        let upper = min(power.count, max(lower + 1, Int(range.upperBound / binWidth)))
        return Double(vDSP.sum(power[lower..<upper]))
    }

    private func decibels(_ power: Double) -> Double {
        10 * log10(power + 1e-12)
    }

    private func normalized(_ level: Double, peak: Double) -> Double {
        min(1, max(0, (level - (peak - Self.dynamicRange)) / Self.dynamicRange))
    }

    private func decayPeaks(by seconds: Double) {
        let decay = Self.peakDecay * seconds
        peaks.bass -= decay
        peaks.mid -= decay
        peaks.high -= decay
        peaks.total -= decay
    }
}
