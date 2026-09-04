import AppKit

let canvas = 1024
guard let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: canvas,
    pixelsHigh: canvas,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else { fatalError("Could not create icon bitmap") }

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: canvas, height: canvas).fill()

// macOS does not automatically add optical padding to a raw .icns. Keep the
// tile inset so its Dock weight matches system and App Store applications.
let inset: CGFloat = 88
let scale = (CGFloat(canvas) - inset * 2) / CGFloat(canvas)
func scaled(_ value: CGFloat) -> CGFloat { inset + value * scale }
let tile = NSBezierPath(
    roundedRect: NSRect(x: inset, y: inset, width: CGFloat(canvas) - inset * 2, height: CGFloat(canvas) - inset * 2),
    xRadius: 224 * scale,
    yRadius: 224 * scale
)
NSColor(red: 0.067, green: 0.067, blue: 0.094, alpha: 1).setFill()
tile.fill()

func bar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, color: NSColor) {
    let path = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: width * 0.42, yRadius: width * 0.42)
    color.setFill()
    path.fill()
}

let violet = NSColor(red: 0.35, green: 0.38, blue: 0.96, alpha: 1)
let lime = NSColor(red: 0.65, green: 0.93, blue: 0.22, alpha: 1)
bar(x: scaled(224), y: scaled(232), width: 144 * scale, height: 296 * scale, color: violet)
bar(x: scaled(440), y: scaled(232), width: 144 * scale, height: 608 * scale, color: lime)
bar(x: scaled(656), y: scaled(232), width: 144 * scale, height: 444 * scale, color: violet)
NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode icon") }
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png")
try data.write(to: output)
