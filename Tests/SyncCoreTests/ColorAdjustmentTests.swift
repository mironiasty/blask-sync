import Foundation
import HueKit
import Testing

@testable import SyncCore

struct ColorAdjustmentTests {
    private func isClose(_ a: LightColor, _ b: LightColor) -> Bool {
        abs(a.red - b.red) < 1e-9 && abs(a.green - b.green) < 1e-9 && abs(a.blue - b.blue) < 1e-9
    }

    @Test func noneLeavesColorsAlone() {
        let color = LightColor(red: 0.6, green: 0.4, blue: 0.2)
        #expect(ColorAdjustment.none.apply(color) == color)
    }

    @Test func saturationBoostKeepsBrightnessAndHueOrder() {
        // Saturation 0.5 → 1.0 with boost 0.5 (factor 2).
        let result = ColorAdjustment(saturationBoost: 0.5).apply(LightColor(red: 0.8, green: 0.6, blue: 0.4))
        #expect(isClose(result, LightColor(red: 0.8, green: 0.4, blue: 0)))
    }

    @Test func saturationBoostCapsAtFullySaturated() {
        let result = ColorAdjustment(saturationBoost: 1).apply(LightColor(red: 1, green: 0.5, blue: 0.5))
        #expect(result.blue == 0 && result.red == 1)
    }

    @Test func grayStaysGray() {
        let gray = LightColor(red: 0.5, green: 0.5, blue: 0.5)
        #expect(ColorAdjustment(saturationBoost: 1).apply(gray) == gray)
    }

    @Test func minimumBrightnessLiftsDarkColors() {
        let adjustment = ColorAdjustment(minimumBrightness: 0.2)
        #expect(isClose(adjustment.apply(.black), LightColor(red: 0.2, green: 0.2, blue: 0.2)))
        #expect(isClose(adjustment.apply(.white), .white))
        // Hue is kept: pure red at half brightness → 0.2 + 0.5 × 0.8 = 0.6.
        #expect(
            isClose(adjustment.apply(LightColor(red: 0.5, green: 0, blue: 0)), LightColor(red: 0.6, green: 0, blue: 0)))
    }
}
