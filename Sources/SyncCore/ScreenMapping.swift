import Foundation
import HueKit

/// A rectangle on the screen in normalized coordinates: origin top-left, both axes 0...1.
public struct ScreenRegion: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let minimumSize = 0.05

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }

    /// Keeps the size within `minimumSize...1` and the whole rectangle on screen.
    public func clamped() -> ScreenRegion {
        let width = min(max(width, Self.minimumSize), 1)
        let height = min(max(height, Self.minimumSize), 1)
        return ScreenRegion(
            x: min(max(x, 0), 1 - width),
            y: min(max(y, 0), 1 - height),
            width: width,
            height: height
        )
    }

    public func moved(dx: Double, dy: Double) -> ScreenRegion {
        ScreenRegion(x: x + dx, y: y + dy, width: width, height: height).clamped()
    }

    /// Grows or shrinks from the bottom-right corner; the top-left corner stays put.
    public func resized(dWidth: Double, dHeight: Double) -> ScreenRegion {
        ScreenRegion(
            x: x,
            y: y,
            width: min(max(width + dWidth, Self.minimumSize), 1 - x),
            height: min(max(height + dHeight, Self.minimumSize), 1 - y)
        )
    }
}

/// Which part of the screen each channel samples its color from.
public struct ScreenMapping: Codable, Equatable, Sendable {
    public var regions: [UInt8: ScreenRegion]

    public init(regions: [UInt8: ScreenRegion]) {
        self.regions = regions
    }

    public static let defaultRegionSize = 0.25

    public static func defaults(for channels: [EntertainmentArea.Channel]) -> ScreenMapping {
        ScreenMapping(regions: Dictionary(uniqueKeysWithValues: channels.map { ($0.id, defaultRegion(for: $0.position)) }))
    }

    /// Projects the channel's left/right (x) and height (z) position outward onto the screen border,
    /// the way an ambilight samples edges: a light at the top-left of the area samples the top-left
    /// corner, one centered above the screen samples the top edge. A channel dead center samples
    /// the middle of the screen. Depth (y) doesn't affect the default.
    public static func defaultRegion(for position: EntertainmentArea.Channel.Position) -> ScreenRegion {
        let size = defaultRegionSize
        let extent = max(abs(position.x), abs(position.z))
        guard extent > 0.01 else {
            return ScreenRegion(x: 0.5 - size, y: 0.5 - size, width: size * 2, height: size * 2)
        }
        let u = (position.x / extent + 1) / 2 // 0 = left edge, 1 = right edge
        let v = (1 - position.z / extent) / 2 // 0 = top edge, 1 = bottom edge
        return ScreenRegion(x: u - size / 2, y: v - size / 2, width: size, height: size).clamped()
    }

    /// Adds defaults for channels without a region and drops regions of channels that no longer exist,
    /// e.g. after the area was edited in the Hue app.
    public func reconciled(with channels: [EntertainmentArea.Channel]) -> ScreenMapping {
        ScreenMapping(regions: Dictionary(uniqueKeysWithValues: channels.map { channel in
            (channel.id, regions[channel.id] ?? Self.defaultRegion(for: channel.position))
        }))
    }
}
