import AppKit
import Foundation

// Code-drawn identity: a crescent held by a quiet orbit. No downloaded or generated imagery.
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024,
                              bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false,
                              isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor(srgbRed: 0.047, green: 0.063, blue: 0.10, alpha: 1).setFill()
NSBezierPath(rect: NSRect(x: 0, y: 0, width: 1024, height: 1024)).fill()
NSColor(srgbRed: 0.74, green: 0.71, blue: 0.98, alpha: 0.18).setStroke()
let orbit = NSBezierPath(ovalIn: NSRect(x: 160, y: 160, width: 704, height: 704)); orbit.lineWidth = 2; orbit.stroke()
NSColor(srgbRed: 0.74, green: 0.71, blue: 0.98, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 272, y: 272, width: 480, height: 480)).fill()
NSColor(srgbRed: 0.047, green: 0.063, blue: 0.10, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 414, y: 385, width: 420, height: 420)).fill()
NSColor(srgbRed: 0.64, green: 0.85, blue: 0.78, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 720, y: 690, width: 26, height: 26)).fill()
NSGraphicsContext.restoreGraphicsState()
let data = bitmap.representation(using: .png, properties: [:])!
for (folder, platform) in [("iOSAssets", "ios"), ("WatchAssets", "watchos")] {
    let root = URL(fileURLWithPath: "Config/\(folder).xcassets")
    let icon = root.appendingPathComponent("AppIcon.appiconset")
    try FileManager.default.createDirectory(at: icon, withIntermediateDirectories: true)
    try data.write(to: icon.appendingPathComponent("AppIcon.png"))
    let contents: [String: Any] = ["images": [["filename": "AppIcon.png", "idiom": "universal", "platform": platform, "size": "1024x1024"]], "info": ["author": "xcode", "version": 1]]
    try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys]).write(to: icon.appendingPathComponent("Contents.json"))
    try JSONSerialization.data(withJSONObject: ["info": ["author": "xcode", "version": 1]]).write(to: root.appendingPathComponent("Contents.json"))
}
