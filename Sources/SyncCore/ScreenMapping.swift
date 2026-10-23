import Foundation
import HueKit

/// A rectangle in screen coordinates: origin top-left, the screen spans 0...1 on both axes.
/// Lamps may sit beside the screen, so coordinates can extend `surroundingsMargin` past it.
public struct ScreenRegion: Codable, Hashable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public static let minimumSize = 0.05
    /// How far beside the screen a lamp can be placed, as a fraction of the screen's width or height.
    public static let surroundingsMargin = 0.4
    /// The most a lamp beside the screen blends toward the screen's overall color.
    public static let maximumAmbientBlend = 0.8

    /// Where a region may be placed.
    public enum Bounds: Sendable {
        /// On the screen: strip segments and lamps sampling a specific area.
        case screen
        /// On the screen or on the wall around it: lamps.
        case surroundings

        var lower: Double { self == .screen ? 0 : -ScreenRegion.surroundingsMargin }
        var upper: Double { self == .screen ? 1 : 1 + ScreenRegion.surroundingsMargin }
    }

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var centerX: Double { x + width / 2 }
    public var centerY: Double { y + height / 2 }

    /// Keeps the size within `minimumSize...1` and the whole rectangle within `bounds`.
    public func clamped(to bounds: Bounds = .screen) -> ScreenRegion {
        let width = min(max(width, Self.minimumSize), 1)
        let height = min(max(height, Self.minimumSize), 1)
        return ScreenRegion(
            x: min(max(x, bounds.lower), bounds.upper - width),
            y: min(max(y, bounds.lower), bounds.upper - height),
            width: width,
            height: height
        )
    }

    public func moved(dx: Double, dy: Double, within bounds: Bounds = .screen) -> ScreenRegion {
        ScreenRegion(x: x + dx, y: y + dy, width: width, height: height).clamped(to: bounds)
    }

    /// Grows or shrinks from the bottom-right corner; the top-left corner stays put.
    public func resized(dWidth: Double, dHeight: Double, within bounds: Bounds = .screen) -> ScreenRegion {
        ScreenRegion(
            x: x,
            y: y,
            width: min(max(width + dWidth, Self.minimumSize), 1, bounds.upper - x),
            height: min(max(height + dHeight, Self.minimumSize), 1, bounds.upper - y)
        )
    }

    /// The screen area this region takes its color from: itself when on screen, otherwise the
    /// nearest same-size area inside the screen.
    public var sampledRegion: ScreenRegion { clamped(to: .screen) }

    /// How far this region's center lies outside the screen, in screen widths/heights; zero when
    /// the center is on screen.
    public var distanceFromScreen: Double {
        hypot(max(0, -centerX, centerX - 1), max(0, -centerY, centerY - 1))
    }

    /// How much a region beside the screen blends toward the screen's overall color: a lamp across
    /// the room lights it with the general mood, not with whatever is at the nearest edge.
    public var ambientBlend: Double {
        min(Self.maximumAmbientBlend, distanceFromScreen * 1.2)
    }
}

/// Which part of the screen each channel samples its color from.
public struct ScreenMapping: Codable, Equatable, Sendable {
    public var regions: [UInt8: ScreenRegion]

    public init(regions: [UInt8: ScreenRegion]) {
        self.regions = regions
    }

    public static let defaultRegionSize = 0.25

    /// - Parameter lampChannels: Standalone lamps. When the area also has strip segments, their extent
    ///   marks where the screen is, and lamps outside it are placed beside the screen accordingly.
    public static func defaults(for channels: [EntertainmentArea.Channel], lampChannels: Set<UInt8> = []) -> ScreenMapping {
        let screen = screenExtent(of: channels.filter { !lampChannels.contains($0.id) })
        return ScreenMapping(regions: Dictionary(uniqueKeysWithValues: channels.map { channel in
            if lampChannels.contains(channel.id), let screen {
                return (channel.id, lampRegion(for: channel.position, screen: screen))
            }
            return (channel.id, defaultRegion(for: channel.position))
        }))
    }

    /// The left/right and down/up extent of the channels around the screen (typically a strip on its back).
    struct Extent {
        let minX: Double, maxX: Double, minZ: Double, maxZ: Double
    }

    static func screenExtent(of channels: [EntertainmentArea.Channel]) -> Extent? {
        guard let first = channels.first else { return nil }
        var extent = Extent(minX: first.position.x, maxX: first.position.x, minZ: first.position.z, maxZ: first.position.z)
        for channel in channels.dropFirst() {
            extent = Extent(
                minX: min(extent.minX, channel.position.x), maxX: max(extent.maxX, channel.position.x),
                minZ: min(extent.minZ, channel.position.z), maxZ: max(extent.maxZ, channel.position.z)
            )
        }
        // A strip along one edge only doesn't say where the screen is.
        guard extent.maxX - extent.minX > 0.05, extent.maxZ - extent.minZ > 0.05 else { return nil }
        return extent
    }

    /// Places a lamp relative to the screen's extent; one outside it lands beside the screen.
    static func lampRegion(for position: EntertainmentArea.Channel.Position, screen: Extent) -> ScreenRegion {
        let size = defaultRegionSize
        let u = (position.x - screen.minX) / (screen.maxX - screen.minX)
        let v = (screen.maxZ - position.z) / (screen.maxZ - screen.minZ)
        return ScreenRegion(x: u - size / 2, y: v - size / 2, width: size, height: size).clamped(to: .surroundings)
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
