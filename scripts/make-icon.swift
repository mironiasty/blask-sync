// Renders the Blask Sync app icon with CoreGraphics.
// Usage: swift scripts/make-icon.swift <output.png> [variant]
// Variants: halo-sparkle (the app icon), dev (the app icon with a DEV badge, for local builds), halo, sparkle.
// scripts/make-icns.sh builds Resources/AppIcon.icns and Resources/AppIcon-Dev.icns.
import AppKit
import CoreImage

let size: CGFloat = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!

// MARK: Helpers

func makeContext() -> CGContext {
    CGContext(
        data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
        space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        colorSpace: colorSpace,
        components: [CGFloat((hex >> 16) & 0xFF) / 255, CGFloat((hex >> 8) & 0xFF) / 255, CGFloat(hex & 0xFF) / 255, alpha]
    )!
}

func linearGradient(_ colors: [CGColor], _ locations: [CGFloat]) -> CGGradient {
    CGGradient(colorsSpace: colorSpace, colors: colors as CFArray, locations: locations)!
}

func roundedRect(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}

/// Spectrum the halo cycles through, as (position 0...1, color).
let spectrum: [(CGFloat, UInt32)] = [
    (0.00, 0xFF2D95), // magenta
    (0.18, 0xFF7A1A), // orange
    (0.32, 0xFFD23F), // amber
    (0.50, 0x18E0C0), // aqua
    (0.68, 0x2F7BFF), // blue
    (0.84, 0x8B5CF6), // violet
    (1.00, 0xFF2D95),
]

func spectrumColor(at t: CGFloat) -> (CGFloat, CGFloat, CGFloat) {
    let t = t - floor(t)
    for i in 0..<(spectrum.count - 1) where t <= spectrum[i + 1].0 {
        let (p0, c0) = spectrum[i]
        let (p1, c1) = spectrum[i + 1]
        let f = (t - p0) / (p1 - p0)
        func ch(_ c: UInt32, _ shift: UInt32) -> CGFloat { CGFloat((c >> shift) & 0xFF) / 255 }
        return (
            ch(c0, 16) + (ch(c1, 16) - ch(c0, 16)) * f,
            ch(c0, 8) + (ch(c1, 8) - ch(c0, 8)) * f,
            ch(c0, 0) + (ch(c1, 0) - ch(c0, 0)) * f
        )
    }
    return (1, 1, 1)
}

/// Fills `clip` with a conic spectrum around `center`, starting at `startAngle`.
func drawConic(_ ctx: CGContext, center: CGPoint, clip: CGPath, startAngle: CGFloat, alpha: CGFloat = 1) {
    ctx.saveGState()
    ctx.addPath(clip)
    ctx.clip()
    let steps = 720
    let radius = size * 1.5
    for i in 0..<steps {
        let a0 = startAngle + CGFloat(i) / CGFloat(steps) * 2 * .pi
        let a1 = startAngle + CGFloat(i + 1) / CGFloat(steps) * 2 * .pi + 0.01
        let (r, g, b) = spectrumColor(at: CGFloat(i) / CGFloat(steps))
        ctx.setFillColor(CGColor(colorSpace: colorSpace, components: [r, g, b, alpha])!)
        ctx.move(to: center)
        ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: false)
        ctx.closePath()
        ctx.fillPath()
    }
    ctx.restoreGState()
}

func blurred(_ image: CGImage, radius: CGFloat) -> CGImage {
    let input = CIImage(cgImage: image).clampedToExtent()
    let output = input.applyingGaussianBlur(sigma: radius).cropped(to: CGRect(x: 0, y: 0, width: size, height: size))
    return CIContext(options: [.workingColorSpace: colorSpace]).createCGImage(output, from: output.extent, format: .RGBA8, colorSpace: colorSpace)!
}

/// A four-pointed sparkle with concave sides.
func sparklePath(center: CGPoint, radius: CGFloat, waist: CGFloat = 0.16) -> CGPath {
    let path = CGMutablePath()
    let points = (0..<4).map { i -> CGPoint in
        let a = CGFloat(i) * .pi / 2 + .pi / 2
        return CGPoint(x: center.x + cos(a) * radius, y: center.y + sin(a) * radius)
    }
    path.move(to: points[0])
    for i in 0..<4 {
        let next = points[(i + 1) % 4]
        path.addQuadCurve(to: next, control: CGPoint(
            x: center.x + (points[i].x + next.x - 2 * center.x) * waist,
            y: center.y + (points[i].y + next.y - 2 * center.y) * waist
        ))
    }
    path.closeSubpath()
    return path
}

// MARK: Layers

// macOS icon grid: an 824 pt body centered in the 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let bodyPath = roundedRect(body, 185)

func drawBody(_ ctx: CGContext) {
    // Drop shadow under the body.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: color(0x000000, 0.45))
    ctx.addPath(bodyPath)
    ctx.setFillColor(color(0x0A0A14))
    ctx.fillPath()
    ctx.restoreGState()

    // Deep night background, a touch lighter in the middle where the light hits the wall.
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.drawRadialGradient(
        linearGradient([color(0x221640), color(0x0E0B1E), color(0x06060C)], [0, 0.55, 1]),
        startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
        endCenter: CGPoint(x: 512, y: 560), endRadius: 560, options: [.drawsAfterEndLocation]
    )
    ctx.restoreGState()
}

func drawBodyRim(_ ctx: CGContext) {
    ctx.saveGState()
    ctx.addPath(roundedRect(body.insetBy(dx: 1.5, dy: 1.5), 184))
    ctx.setStrokeColor(color(0xFFFFFF, 0.10))
    ctx.setLineWidth(3)
    ctx.strokePath()
    ctx.restoreGState()
}

/// The ambilight: a spectrum ring around `screen`, blurred so it spills onto the wall.
func drawHalo(_ ctx: CGContext, screen: CGRect, spread: CGFloat, blur: CGFloat, intensity: CGFloat) {
    let layer = makeContext()
    drawConic(layer, center: CGPoint(x: screen.midX, y: screen.midY), clip: roundedRect(screen.insetBy(dx: -spread, dy: -spread), 80), startAngle: .pi * 0.9)
    let glow = blurred(layer.makeImage()!, radius: blur)

    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.setAlpha(intensity)
    ctx.setBlendMode(.screen)
    ctx.draw(glow, in: CGRect(x: 0, y: 0, width: size, height: size))
    // A second, tighter pass keeps the colors saturated right at the screen edge.
    let tight = makeContext()
    drawConic(tight, center: CGPoint(x: screen.midX, y: screen.midY), clip: roundedRect(screen.insetBy(dx: -spread * 0.45, dy: -spread * 0.45), 50), startAngle: .pi * 0.9)
    ctx.draw(blurred(tight.makeImage()!, radius: blur * 0.4), in: CGRect(x: 0, y: 0, width: size, height: size))
    ctx.restoreGState()
}

func drawMonitor(_ ctx: CGContext, screen: CGRect) {
    // Stand: neck and foot, lit from above by the halo.
    let neck = CGRect(x: screen.midX - 34, y: screen.minY - 92, width: 68, height: 100)
    let foot = CGRect(x: screen.midX - 130, y: screen.minY - 112, width: 260, height: 30)
    for (rect, radius) in [(neck, CGFloat(10)), (foot, CGFloat(15))] {
        ctx.saveGState()
        ctx.addPath(roundedRect(rect, radius))
        ctx.clip()
        ctx.drawLinearGradient(
            linearGradient([color(0x3A3550), color(0x15131F)], [0, 1]),
            start: CGPoint(x: 0, y: rect.maxY), end: CGPoint(x: 0, y: rect.minY), options: []
        )
        ctx.restoreGState()
    }

    // Bezel.
    let bezel = screen.insetBy(dx: -14, dy: -14)
    ctx.saveGState()
    ctx.setShadow(offset: .zero, blur: 30, color: color(0x000000, 0.6))
    ctx.addPath(roundedRect(bezel, 34))
    ctx.setFillColor(color(0x101018))
    ctx.fillPath()
    ctx.restoreGState()

    // Screen content: a dim version of the same colors, so the light reads as coming from the picture.
    ctx.saveGState()
    ctx.addPath(roundedRect(screen, 22))
    ctx.clip()
    ctx.setFillColor(color(0x0B0D18))
    ctx.fill(screen)
    let content = makeContext()
    drawConic(content, center: CGPoint(x: screen.midX, y: screen.midY), clip: roundedRect(screen, 22), startAngle: .pi * 0.9)
    ctx.setAlpha(0.42)
    ctx.draw(blurred(content.makeImage()!, radius: 50), in: CGRect(x: 0, y: 0, width: size, height: size))
    ctx.setAlpha(1)
    // Glass sheen.
    ctx.drawLinearGradient(
        linearGradient([color(0xFFFFFF, 0.16), color(0xFFFFFF, 0)], [0, 1]),
        start: CGPoint(x: screen.minX, y: screen.maxY), end: CGPoint(x: screen.midX, y: screen.midY), options: []
    )
    ctx.restoreGState()

    ctx.addPath(roundedRect(bezel, 34))
    ctx.setStrokeColor(color(0xFFFFFF, 0.14))
    ctx.setLineWidth(2)
    ctx.strokePath()
}

func drawSparkle(_ ctx: CGContext, center: CGPoint, radius: CGFloat, glow: CGFloat) {
    // Soft white bloom behind the star.
    let bloom = makeContext()
    bloom.addPath(sparklePath(center: center, radius: radius * 1.05, waist: 0.2))
    bloom.setFillColor(color(0xFFFFFF))
    bloom.fillPath()
    ctx.saveGState()
    ctx.addPath(bodyPath)
    ctx.clip()
    ctx.setBlendMode(.screen)
    ctx.draw(blurred(bloom.makeImage()!, radius: glow), in: CGRect(x: 0, y: 0, width: size, height: size))
    ctx.restoreGState()

    // The star: white core fading to a warm tint at the tips.
    ctx.saveGState()
    ctx.addPath(sparklePath(center: center, radius: radius))
    ctx.clip()
    ctx.drawRadialGradient(
        linearGradient([color(0xFFFFFF), color(0xFFF4E0), color(0xFFC9E8)], [0, 0.45, 1]),
        startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: []
    )
    ctx.restoreGState()
}

/// An orange "DEV" pill across the monitor's foot, so local builds stand out in the Dock and Finder.
func drawDevBadge(_ ctx: CGContext) {
    let badge = CGRect(x: 512 - 190, y: 150, width: 380, height: 150)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: color(0x000000, 0.5))
    ctx.addPath(roundedRect(badge, 75))
    ctx.setFillColor(color(0xFB7C3C))
    ctx.fillPath()
    ctx.restoreGState()

    let text = NSAttributedString(string: "DEV", attributes: [
        .font: NSFont.systemFont(ofSize: 104, weight: .heavy),
        .foregroundColor: NSColor.white,
        .kern: 6,
    ])
    let line = CTLineCreateWithAttributedString(text)
    let bounds = CTLineGetImageBounds(line, ctx)
    ctx.textPosition = CGPoint(x: badge.midX - bounds.midX, y: badge.midY - bounds.midY)
    CTLineDraw(line, ctx)
}

// MARK: Variants

func render(_ variant: String) -> CGImage {
    let ctx = makeContext()
    drawBody(ctx)
    switch variant {
    case "sparkle":
        let center = CGPoint(x: 512, y: 512)
        let ring = makeContext()
        drawConic(ring, center: center, clip: CGPath(ellipseIn: CGRect(x: 512 - 300, y: 512 - 300, width: 600, height: 600), transform: nil), startAngle: .pi * 0.9)
        ctx.saveGState()
        ctx.addPath(bodyPath)
        ctx.clip()
        ctx.setBlendMode(.screen)
        ctx.setAlpha(0.95)
        ctx.draw(blurred(ring.makeImage()!, radius: 70), in: CGRect(x: 0, y: 0, width: size, height: size))
        ctx.restoreGState()
        drawSparkle(ctx, center: center, radius: 250, glow: 40)
    case "halo":
        let screen = CGRect(x: 512 - 270, y: 560 - 168, width: 540, height: 336)
        drawHalo(ctx, screen: screen, spread: 95, blur: 55, intensity: 1)
        drawMonitor(ctx, screen: screen)
    default: // halo-sparkle, dev
        let screen = CGRect(x: 512 - 270, y: 560 - 168, width: 540, height: 336)
        drawHalo(ctx, screen: screen, spread: 95, blur: 55, intensity: 1)
        drawMonitor(ctx, screen: screen)
        drawSparkle(ctx, center: CGPoint(x: screen.maxX - 70, y: screen.maxY - 64), radius: 95, glow: 22)
    }
    drawBodyRim(ctx)
    if variant == "dev" { drawDevBadge(ctx) }
    return ctx.makeImage()!
}

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: swift make-icon.swift <output.png> [halo-sparkle|dev|halo|sparkle]")
    exit(1)
}
let image = render(arguments.count > 2 ? arguments[2] : "halo-sparkle")
let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: arguments[1]) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, nil)
CGImageDestinationFinalize(destination)
print("wrote \(arguments[1])")
