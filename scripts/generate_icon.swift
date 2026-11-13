import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("mac-app/resources")
let sourceURL = resources.appendingPathComponent("TVRemoteMouse-approved-icon.png")
guard let source = NSImage(contentsOf: sourceURL) else { fatalError("Missing approved icon: \(sourceURL.path)") }
let iconset = resources.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
let sizes: [(String, Int)] = [("icon_16x16.png",16),("icon_16x16@2x.png",32),("icon_32x32.png",32),("icon_32x32@2x.png",64),("icon_128x128.png",128),("icon_128x128@2x.png",256),("icon_256x256.png",256),("icon_256x256@2x.png",512),("icon_512x512.png",512),("icon_512x512@2x.png",1024)]
for (name, size) in sizes {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    // The approved artwork includes a white surround beyond its blue outline.
    // Match the artwork's wider corner curve and slightly overscan the source
    // so the packaged icon has transparent corners without a white fringe.
    NSBezierPath(roundedRect: rect, xRadius: CGFloat(size) * 0.30, yRadius: CGFloat(size) * 0.30).addClip()
    let artworkRect = rect.insetBy(dx: -CGFloat(size) * 0.01, dy: -CGFloat(size) * 0.01)
    source.draw(in: artworkRect, from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try process.run()
process.waitUntilExit()
if process.terminationStatus != 0 { fatalError("iconutil failed") }
try FileManager.default.removeItem(at: iconset)
