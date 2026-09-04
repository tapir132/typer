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

let tile = NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: canvas, height: canvas), xRadius: 224, yRadius: 224)
NSColor(red: 0.067, green: 0.067, blue: 0.094, alpha: 1).setFill()
tile.fill()

func bar(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, color: NSColor) {
    let path = NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: height), xRadius: width * 0.42, yRadius: width * 0.42)
    color.setFill()
    path.fill()
}

let violet = NSColor(red: 0.35, green: 0.38, blue: 0.96, alpha: 1)
let lime = NSColor(red: 0.65, green: 0.93, blue: 0.22, alpha: 1)
bar(x: 224, y: 232, width: 144, height: 296, color: violet)
bar(x: 440, y: 232, width: 144, height: 608, color: lime)
bar(x: 656, y: 232, width: 144, height: 444, color: violet)
NSGraphicsContext.restoreGraphicsState()

guard let data = bitmap.representation(using: .png, properties: [:]) else { fatalError("Could not encode icon") }
let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png")
try data.write(to: output)
