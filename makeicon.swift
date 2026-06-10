// Renders AppIcon: white lightning bolt on a clay-orange squircle (1024px PNG).
// Run: swift makeicon.swift <output.png>

import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// Background squircle with standard macOS icon margins
let bg = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                      xRadius: 185, yRadius: 185)
let topColor = NSColor(calibratedRed: 0.88, green: 0.55, blue: 0.40, alpha: 1)  // light clay
let bottomColor = NSColor(calibratedRed: 0.72, green: 0.36, blue: 0.22, alpha: 1)  // deep clay
NSGradient(starting: topColor, ending: bottomColor)!.draw(in: bg, angle: -90)

// White lightning bolt (coordinates are y-up)
let bolt = NSBezierPath()
bolt.move(to: NSPoint(x: 580, y: 854))
bolt.line(to: NSPoint(x: 350, y: 464))
bolt.line(to: NSPoint(x: 490, y: 464))
bolt.line(to: NSPoint(x: 430, y: 164))
bolt.line(to: NSPoint(x: 690, y: 594))
bolt.line(to: NSPoint(x: 540, y: 594))
bolt.close()

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.25)
shadow.shadowOffset = NSSize(width: 0, height: -8)
shadow.shadowBlurRadius = 18
shadow.set()
NSColor.white.setFill()
bolt.fill()

NSGraphicsContext.restoreGraphicsState()

try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
