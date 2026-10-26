import AppKit

/// The menu bar icon: a monitor with the app icon's sparkle on its screen. Drawn as a template image,
/// so macOS tints it for light and dark menu bars, except in development builds, where it's orange to
/// tell it apart from the release running alongside.
enum MenuBarIcon {
    /// - Parameter active: Filled screen (sparkle cut out) while the lights are driven; outline otherwise.
    static func image(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
            draw(active: active)
            return true
        }
        image.isTemplate = !AppVariant.isDevelopment
        image.accessibilityDescription = active ? String(localized: "\(AppVariant.name), syncing") : AppVariant.name
        return image
    }

    private static func draw(active: Bool) {
        (AppVariant.isDevelopment ? NSColor.systemOrange : NSColor.black).set()
        let screen = NSRect(x: 2.25, y: 2.75, width: 13.5, height: 9.25)
        let screenPath = NSBezierPath(roundedRect: screen, xRadius: 2, yRadius: 2)

        if active {
            screenPath.fill()
        } else {
            screenPath.lineWidth = 1.5
            screenPath.stroke()
        }

        // Stand.
        let stand = NSBezierPath()
        stand.move(to: NSPoint(x: 9, y: 12.5))
        stand.line(to: NSPoint(x: 9, y: 14.75))
        stand.move(to: NSPoint(x: 5.75, y: 15.25))
        stand.line(to: NSPoint(x: 12.25, y: 15.25))
        stand.lineWidth = 1.5
        stand.lineCapStyle = .round
        stand.stroke()

        // Sparkle in the screen's upper right, cut out of the filled screen when active.
        let sparkle = sparklePath(center: NSPoint(x: 11.5, y: 6.6), radius: 2.9)
        if active {
            NSGraphicsContext.current?.compositingOperation = .destinationOut
            sparkle.fill()
            NSGraphicsContext.current?.compositingOperation = .sourceOver
        } else {
            sparkle.fill()
        }
    }

    /// Four-pointed star with concave sides, as in the app icon.
    private static func sparklePath(center: NSPoint, radius: CGFloat) -> NSBezierPath {
        let tips = (0..<4).map { i -> NSPoint in
            let angle = CGFloat(i) * .pi / 2
            return NSPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
        }
        let path = NSBezierPath()
        path.move(to: tips[0])
        for i in 0..<4 {
            let next = tips[(i + 1) % 4]
            let waist: CGFloat = 0.18
            let control = NSPoint(
                x: center.x + (tips[i].x + next.x - 2 * center.x) * waist,
                y: center.y + (tips[i].y + next.y - 2 * center.y) * waist
            )
            path.curve(to: next, controlPoint1: control, controlPoint2: control)
        }
        path.close()
        return path
    }
}
