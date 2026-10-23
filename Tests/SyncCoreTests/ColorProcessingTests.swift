import Foundation
import HueKit
import Testing
@testable import SyncCore

struct ColorProcessingTests {
    /// 4×2 BGRA frame: left half pure red, right half pure blue. Rows padded to 20 bytes like real buffers.
    private func splitFrame() -> Frame {
        let bytesPerRow = 20
        var pixels = Data(count: bytesPerRow * 2)
        for y in 0..<2 {
            for x in 0..<4 {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = x < 2 ? 0 : 255     // B
                pixels[offset + 1] = 0               // G
                pixels[offset + 2] = x < 2 ? 255 : 0 // R
                pixels[offset + 3] = 255             // A
            }
        }
        return Frame(width: 4, height: 2, bytesPerRow: bytesPerRow, pixels: pixels)
    }

    @Test func averagesEachRegion() {
        let mapping = ScreenMapping(regions: [
            0: ScreenRegion(x: 0, y: 0, width: 0.5, height: 1),
            1: ScreenRegion(x: 0.5, y: 0, width: 0.5, height: 1),
            2: ScreenRegion(x: 0, y: 0, width: 1, height: 1),
        ])
        let colors = ColorExtractor.averageColors(in: splitFrame(), mapping: mapping)
        #expect(colors[0] == LightColor(red: 1, green: 0, blue: 0))
        #expect(colors[1] == LightColor(red: 0, green: 0, blue: 1))
        #expect(colors[2] == LightColor(red: 0.5, green: 0, blue: 0.5))
    }

    @Test func tinyRegionStillSamplesAPixel() {
        let mapping = ScreenMapping(regions: [0: ScreenRegion(x: 0.99, y: 0.99, width: 0.001, height: 0.001)])
        let colors = ColorExtractor.averageColors(in: splitFrame(), mapping: mapping)
        #expect(colors[0] == LightColor(red: 0, green: 0, blue: 1))
    }

    /// Runs the smoother at 50 Hz from white toward black and returns the red channel at each tick.
    private func fade(timeConstant: TimeInterval, seconds: Double, rate: Double = 50) -> [Double] {
        var smoother = ColorSmoother()
        _ = smoother.update(toward: [0: .white], timeConstant: timeConstant, now: 0)
        return (1...Int(seconds * rate)).map { tick in
            smoother.update(toward: [0: .black], timeConstant: timeConstant, now: Double(tick) / rate)[0]!.red
        }
    }

    @Test func smootherStartsAtTarget() {
        var smoother = ColorSmoother()
        #expect(smoother.update(toward: [0: .white], timeConstant: 1, now: 0) == [0: .white])
    }

    @Test func smootherEasesInInsteadOfJolting() {
        let values = fade(timeConstant: 0.3, seconds: 1)
        let firstStep = 1 - values[0]
        let secondStep = values[0] - values[1]
        // A single exponential stage would take its biggest step first (~6% of the way).
        #expect(firstStep < 0.02)
        #expect(secondStep > firstStep)
    }

    @Test func smootherSettlesWithinFiveTimeConstants() {
        let values = fade(timeConstant: 0.3, seconds: 1.5)
        #expect(values.last! < 0.01)
        // Monotonic: no overshoot or wobble.
        #expect(zip(values, values.dropFirst()).allSatisfy { $0 >= $1 })
    }

    @Test func smootherIsNearlyRateIndependent() {
        // The 50 Hz and 100 Hz curves should agree at the same moments in time.
        let at50 = fade(timeConstant: 0.3, seconds: 1, rate: 50)
        let at100 = fade(timeConstant: 0.3, seconds: 1, rate: 100)
        for (index, value) in at50.enumerated() {
            #expect(abs(value - at100[index * 2 + 1]) < 0.02)
        }
    }
}

struct AmbientBlendTests {
    @Test func lampBesideScreenBlendsTowardOverallColor() {
        // Left half red, right half blue (overall: purple).
        let bytesPerRow = 16
        var pixels = Data(count: bytesPerRow * 2)
        for y in 0..<2 {
            for x in 0..<4 {
                let offset = y * bytesPerRow + x * 4
                pixels[offset] = x < 2 ? 0 : 255
                pixels[offset + 2] = x < 2 ? 255 : 0
                pixels[offset + 3] = 255
            }
        }
        let frame = Frame(width: 4, height: 2, bytesPerRow: bytesPerRow, pixels: pixels)
        // Left of the screen: samples the left (red) half, blended toward purple.
        let lamp = ScreenRegion(x: -0.4, y: 0, width: 0.5, height: 1)
        let color = ColorExtractor.averageColors(in: frame, mapping: ScreenMapping(regions: [0: lamp]))[0]!
        let blend = lamp.ambientBlend
        #expect(blend > 0)
        #expect(abs(color.red - (1 - 0.5 * blend)) < 1e-9)
        #expect(abs(color.blue - 0.5 * blend) < 1e-9)
    }
}
