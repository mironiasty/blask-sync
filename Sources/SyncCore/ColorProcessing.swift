import Foundation
import HueKit

/// A small captured image: 8-bit BGRA, rows `bytesPerRow` apart.
public struct Frame: Sendable {
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int
    public let pixels: Data

    public init(width: Int, height: Int, bytesPerRow: Int, pixels: Data) {
        precondition(pixels.count >= bytesPerRow * height, "pixel buffer too small")
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.pixels = pixels
    }
}

public enum ColorExtractor {
    /// Average color of each channel's region. Regions always cover at least one pixel.
    public static func averageColors(in frame: Frame, mapping: ScreenMapping) -> [UInt8: LightColor] {
        frame.pixels.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            return mapping.regions.mapValues { region in
                let x0 = min(Int(region.x * Double(frame.width)), frame.width - 1)
                let y0 = min(Int(region.y * Double(frame.height)), frame.height - 1)
                let x1 = max(x0 + 1, min(Int((region.x + region.width) * Double(frame.width)), frame.width))
                let y1 = max(y0 + 1, min(Int((region.y + region.height) * Double(frame.height)), frame.height))

                var blue = 0, green = 0, red = 0
                for y in y0..<y1 {
                    var offset = y * frame.bytesPerRow + x0 * 4
                    for _ in x0..<x1 {
                        blue += Int(bytes[offset])
                        green += Int(bytes[offset + 1])
                        red += Int(bytes[offset + 2])
                        offset += 4
                    }
                }
                let scale = 1 / (255 * Double((x1 - x0) * (y1 - y0)))
                return LightColor(red: Double(red) * scale, green: Double(green) * scale, blue: Double(blue) * scale)
            }
        }
    }
}

/// How quickly lights follow the screen, like Hue Sync's intensity setting.
public enum SyncIntensity: String, CaseIterable, Codable, Sendable {
    case subtle, moderate, high, extreme

    /// Time for a color change to get ~63% of the way to its target.
    public var timeConstant: TimeInterval {
        switch self {
        case .subtle: 0.6
        case .moderate: 0.3
        case .high: 0.12
        case .extreme: 0.04
        }
    }
}

/// Exponential smoothing per channel that behaves the same whatever the update rate.
public struct ColorSmoother: Sendable {
    public private(set) var current: [UInt8: LightColor] = [:]
    private var lastUpdate: TimeInterval?

    public init() {}

    public mutating func update(toward target: [UInt8: LightColor], timeConstant: TimeInterval, now: TimeInterval) -> [UInt8: LightColor] {
        let elapsed = lastUpdate.map { max(0, now - $0) } ?? .infinity
        lastUpdate = now
        let alpha = timeConstant > 0 ? 1 - exp(-elapsed / timeConstant) : 1

        var next: [UInt8: LightColor] = [:]
        for (channel, goal) in target {
            guard let from = current[channel] else {
                next[channel] = goal
                continue
            }
            next[channel] = LightColor(
                red: from.red + (goal.red - from.red) * alpha,
                green: from.green + (goal.green - from.green) * alpha,
                blue: from.blue + (goal.blue - from.blue) * alpha
            )
        }
        current = next
        return next
    }
}
