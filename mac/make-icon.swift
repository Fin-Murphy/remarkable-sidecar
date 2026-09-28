// Draws the app icon (a reMarkable-style tablet showing text, with a pen) into an .iconset folder;
// build-app.sh turns that into AppIcon.icns with iconutil.
// Usage: swift make-icon.swift OUTPUT.iconset
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

/// Draws the icon in a 1024x1024 space (macOS icon grid: an 824x824 rounded square, centered).
func drawIcon() {
    let gray = { (white: CGFloat) in NSColor(white: white, alpha: 1) }

    // Background tile.
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824), xRadius: 185, yRadius: 185)
    NSGradient(starting: gray(0.99), ending: gray(0.84))!.draw(in: tile, angle: -90)

    // Tablet, with a soft shadow.
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor(white: 0, alpha: 0.35)
    shadow.shadowBlurRadius = 28
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    gray(0.18).setFill()
    NSBezierPath(roundedRect: NSRect(x: 262, y: 190, width: 440, height: 600), xRadius: 44, yRadius: 44).fill()
    NSGraphicsContext.restoreGraphicsState()

    // E-ink screen with lines of text.
    gray(0.95).setFill()
    NSBezierPath(roundedRect: NSRect(x: 294, y: 250, width: 376, height: 508), xRadius: 10, yRadius: 10).fill()
    gray(0.45).setFill()
    for (i, width) in [300, 260, 290, 180, 300, 240, 120].enumerated() {
        let y = CGFloat(690 - i * 58)
        NSBezierPath(roundedRect: NSRect(x: 332, y: y, width: CGFloat(width), height: 20), xRadius: 10, yRadius: 10).fill()
    }

    // Pen across the lower right corner, tip pointing down-left onto the screen.
    let transform = NSAffineTransform()
    transform.translateX(by: 730, yBy: 480)
    transform.rotate(byDegrees: 48)
    transform.concat()
    gray(0.1).setFill()
    NSBezierPath(roundedRect: NSRect(x: -230, y: -30, width: 420, height: 60), xRadius: 30, yRadius: 30).fill()
    let tip = NSBezierPath()
    tip.move(to: NSPoint(x: -214, y: -24))
    tip.line(to: NSPoint(x: -300, y: 0))
    tip.line(to: NSPoint(x: -214, y: 24))
    tip.close()
    gray(0.55).setFill()
    tip.fill()
    gray(0.7).setFill()
    NSBezierPath(rect: NSRect(x: 130, y: -30, width: 14, height: 60)).fill()
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                      colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let scaleTransform = NSAffineTransform()
        scaleTransform.scale(by: CGFloat(pixels) / 1024)
        scaleTransform.concat()
        drawIcon()
        NSGraphicsContext.restoreGraphicsState()
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name))
    }
}
