// Renders the website's images from the 1024 px app icon: the 1200×630 link preview (social.png) and the
// 180×180 home screen icon for iPhone and iPad (apple-touch-icon.png).
// Usage: swift scripts/make-web-images.swift <icon-1024.png> <output-dir>
// scripts/make-icns.sh runs this with the freshly rendered icon.
import AppKit

let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: colorSpace,
        components: [
            CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha,
        ]
    )!
}

func makeContext(width: Int, height: Int) -> CGContext {
    CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func save(_ image: CGImage, to path: String) {
    let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    print("wrote \(path)")
}

/// Draws one line of text with its left edge at `x` and its baseline at `y`.
func drawText(
    _ ctx: CGContext, _ string: String, x: CGFloat, y: CGFloat, size: CGFloat, weight: NSFont.Weight,
    color textColor: NSColor, kern: CGFloat = 0
) {
    let text = NSAttributedString(
        string: string,
        attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: textColor,
            .kern: kern,
        ])
    ctx.textPosition = CGPoint(x: x, y: y)
    CTLineDraw(CTLineCreateWithAttributedString(text), ctx)
}

let background = color(0x0B0A10)  // the website's --bg

// MARK: Link preview

/// Website-style card: the icon over a soft spectrum glow, name and tagline beside it.
func socialImage(icon: CGImage) -> CGImage {
    let (width, height) = (1200, 630)
    let ctx = makeContext(width: width, height: height)
    ctx.setFillColor(background)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

    // Colored light spilling onto the "wall" around the icon, as in the website hero.
    let iconRect = CGRect(x: 70, y: 105, width: 420, height: 420)
    let glows: [(CGPoint, CGFloat, UInt32)] = [
        (CGPoint(x: 150, y: 470), 330, 0xEF4FA6),  // pink
        (CGPoint(x: 430, y: 480), 320, 0x8B5CF6),  // violet
        (CGPoint(x: 460, y: 170), 320, 0x22D3EE),  // cyan
        (CGPoint(x: 140, y: 150), 300, 0xFBBF24),  // amber
    ]
    ctx.saveGState()
    ctx.setBlendMode(.screen)
    for (center, radius, hex) in glows {
        let gradient = CGGradient(
            colorsSpace: colorSpace, colors: [color(hex, 0.42), color(hex, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(
            gradient, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
    }
    ctx.restoreGState()
    ctx.draw(icon, in: iconRect)

    let textX: CGFloat = 540
    drawText(ctx, "Blask Sync", x: textX, y: 360, size: 92, weight: .bold, color: .white, kern: -2.5)
    drawText(
        ctx, "Free Hue Sync alternative for Mac", x: textX, y: 290, size: 34, weight: .semibold,
        color: NSColor(white: 0.95, alpha: 1))
    drawText(
        ctx, "Philips Hue lights in sync with", x: textX, y: 232, size: 28, weight: .regular,
        color: NSColor(white: 0.66, alpha: 1))
    drawText(
        ctx, "your screen and music", x: textX, y: 194, size: 28, weight: .regular,
        color: NSColor(white: 0.66, alpha: 1))
    drawText(
        ctx, "blask.miron.asia", x: textX, y: 120, size: 24, weight: .medium, color: NSColor(white: 0.5, alpha: 1),
        kern: 0.5)
    return ctx.makeImage()!
}

// MARK: Apple touch icon

/// The icon's rounded body, full-bleed on the dark background: iOS adds its own rounded mask and would
/// show the transparent margin around the macOS icon shape as a black frame.
func touchIcon(icon: CGImage) -> CGImage {
    let size = 180
    // macOS icon grid: the body is the centered 824 of the 1024 canvas.
    let body = icon.cropping(to: CGRect(x: 100, y: 100, width: 824, height: 824))!
    let ctx = makeContext(width: size, height: size)
    ctx.setFillColor(color(0x06060C))  // the body's darkest edge
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.interpolationQuality = .high
    ctx.draw(body, in: CGRect(x: 0, y: 0, width: size, height: size))
    return ctx.makeImage()!
}

let arguments = CommandLine.arguments
guard arguments.count == 3,
    let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, nil),
    let icon = CGImageSourceCreateImageAtIndex(source, 0, nil)
else {
    print("usage: swift make-web-images.swift <icon-1024.png> <output-dir>")
    exit(1)
}
save(socialImage(icon: icon), to: "\(arguments[2])/social.png")
save(touchIcon(icon: icon), to: "\(arguments[2])/apple-touch-icon.png")
