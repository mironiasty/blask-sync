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

    @Test func smootherJumpsFirstThenEases() {
        var smoother = ColorSmoother()
        let white = [UInt8(0): LightColor.white]
        let black = [UInt8(0): LightColor.black]
        #expect(smoother.update(toward: white, timeConstant: 1, now: 0) == white)

        // One time constant later: ~63% of the way from white to black.
        let next = smoother.update(toward: black, timeConstant: 1, now: 1)[0]!
        #expect(abs(next.red - exp(-1)) < 1e-9)
    }

    @Test func smootherIsRateIndependent() {
        var coarse = ColorSmoother()
        var fine = ColorSmoother()
        let start = [UInt8(0): LightColor.white]
        let goal = [UInt8(0): LightColor.black]
        _ = coarse.update(toward: start, timeConstant: 0.3, now: 0)
        _ = fine.update(toward: start, timeConstant: 0.3, now: 0)

        _ = coarse.update(toward: goal, timeConstant: 0.3, now: 0.2)
        for step in 1...10 { _ = fine.update(toward: goal, timeConstant: 0.3, now: Double(step) * 0.02) }
        #expect(abs(coarse.current[0]!.red - fine.current[0]!.red) < 1e-9)
    }
}
