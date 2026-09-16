import AppKit
import Foundation
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(size)
    NSColor(calibratedRed: 0.36, green: 0.29, blue: 0.73, alpha: 1).setFill()
    NSBezierPath(roundedRect: NSRect(x: s * 0.05, y: s * 0.05, width: s * 0.9, height: s * 0.9), xRadius: s * 0.21, yRadius: s * 0.21).fill()
    NSColor.white.withAlphaComponent(0.94).setFill()
    for (x, h) in [(0.23, 0.24), (0.43, 0.42), (0.63, 0.6)] {
        NSBezierPath(roundedRect: NSRect(x: s * x, y: s * 0.2, width: s * 0.14, height: s * h), xRadius: s * 0.035, yRadius: s * 0.035).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    let data = rep.representation(using: .png, properties: [:])!
    if size <= 512 { try data.write(to: destination.appendingPathComponent("icon_\(size)x\(size).png")) }
    if size >= 32 { try data.write(to: destination.appendingPathComponent("icon_\(size/2)x\(size/2)@2x.png")) }
}
