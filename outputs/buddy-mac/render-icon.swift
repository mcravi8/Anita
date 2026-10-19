import AppKit

// Rasterize Buddy's logo for Finder and Dock: a white tile carrying the current logo artwork (icon-logo.png).
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
// Buddy's current logo (the dot-matrix head, saved by make-icon-logo.mjs from the figure engine) on the tile.
guard let logo = NSImage(contentsOf: URL(fileURLWithPath: CommandLine.arguments[2])) else { fatalError("The logo artwork is missing.") }
let logoSide: CGFloat = 840
logo.draw(in: NSRect(x: 512 - logoSide / 2, y: 512 - logoSide / 2, width: logoSide, height: logoSide), from: .zero, operation: .sourceOver, fraction: 1)
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
