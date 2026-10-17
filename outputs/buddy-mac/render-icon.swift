import AppKit

// Rasterize Buddy's existing vector face for Finder and Dock. No generated artwork.
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
}
let image = NSImage(size: NSSize(width: 1024, height: 1024))
image.lockFocus()
let tile = NSBezierPath(roundedRect: NSRect(x: 80, y: 80, width: 864, height: 864), xRadius: 184, yRadius: 184)
NSGraphicsContext.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.12)
shadow.shadowBlurRadius = 18
shadow.shadowOffset = NSSize(width: 0, height: -9)
shadow.set()
NSColor.white.setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()
let faceTransform = NSAffineTransform()
faceTransform.translateX(by: 80, yBy: 944)
faceTransform.scaleX(by: 6.75, yBy: -6.75)
faceTransform.concat()
for x: CGFloat in [40, 88] {
    let eye = NSBezierPath(ovalIn: NSRect(x: x - 11, y: 40, width: 22, height: 26))
    NSGradient(colors: [color(81,65,95), color(48,38,54), color(33,28,41)])!.draw(in: eye, relativeCenterPosition: NSPoint(x: -0.25, y: -0.3))
    NSGraphicsContext.saveGraphicsState()
    let shine = NSAffineTransform()
    shine.translateX(by: x - 3.5, yBy: 47.5)
    shine.rotate(byDegrees: 32)
    shine.concat()
    NSColor.white.withAlphaComponent(0.92).setFill()
    NSBezierPath(ovalIn: NSRect(x: -2.5, y: -3.3, width: 5, height: 6.6)).fill()
    NSGraphicsContext.restoreGraphicsState()
}
let smile = NSBezierPath()
smile.move(to: NSPoint(x: 53, y: 75))
smile.curve(to: NSPoint(x: 75, y: 75), controlPoint1: NSPoint(x: 59, y: 80), controlPoint2: NSPoint(x: 69, y: 80))
smile.curve(to: NSPoint(x: 78.5, y: 78.8), controlPoint1: NSPoint(x: 77.5, y: 73), controlPoint2: NSPoint(x: 80.4, y: 76.2))
smile.curve(to: NSPoint(x: 49.5, y: 78.8), controlPoint1: NSPoint(x: 71, y: 87.4), controlPoint2: NSPoint(x: 57, y: 87.4))
smile.curve(to: NSPoint(x: 53, y: 75), controlPoint1: NSPoint(x: 47.6, y: 76.2), controlPoint2: NSPoint(x: 50.5, y: 73))
smile.close()
NSGradient(starting: color(198,145,156), ending: color(156,102,119))!.draw(in: smile, angle: 90)
color(139,88,109).setStroke()
smile.lineWidth = 1.2
smile.lineJoinStyle = .round
smile.stroke()
let highlight = NSBezierPath()
highlight.move(to: NSPoint(x: 52, y: 76.6))
highlight.curve(to: NSPoint(x: 76, y: 76.6), controlPoint1: NSPoint(x: 59, y: 82.3), controlPoint2: NSPoint(x: 69, y: 82.3))
color(224,180,189).setStroke()
highlight.lineWidth = 1.3
highlight.lineCapStyle = .round
highlight.stroke()
image.unlockFocus()
for (name, size) in [("icon_16x16",16),("icon_16x16@2x",32),("icon_32x32",32),("icon_32x32@2x",64),("icon_128x128",128),("icon_128x128@2x",256),("icon_256x256",256),("icon_256x256@2x",512),("icon_512x512",512),("icon_512x512@2x",1024)] {
    let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    NSGraphicsContext.current?.imageInterpolation = .high
    image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
    NSGraphicsContext.restoreGraphicsState()
    try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(name + ".png"))
}
