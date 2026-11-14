import AppKit
import Foundation

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
let resources = root.appendingPathComponent("mac-app/resources")
let iconset = resources.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func drawIcon(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let context = NSGraphicsContext.current!.cgContext
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let background = NSBezierPath(roundedRect: NSRect(x: 20, y: 20, width: 984, height: 984), xRadius: 230, yRadius: 230)
    background.addClip()
    NSGradient(starting: NSColor(red: 0.07, green: 0.16, blue: 0.29, alpha: 1),
               ending: NSColor(red: 0.10, green: 0.48, blue: 0.64, alpha: 1))!
        .draw(in: background, angle: 45)

    let monitor = NSBezierPath(roundedRect: NSRect(x: 145, y: 317, width: 735, height: 515), xRadius: 48, yRadius: 48)
    NSColor.white.setFill(); monitor.fill()
    let screen = NSBezierPath(roundedRect: NSRect(x: 176, y: 359, width: 673, height: 434), xRadius: 22, yRadius: 22)
    NSColor(red: 0.12, green: 0.27, blue: 0.43, alpha: 1).setFill(); screen.fill()
    let screenGlow = NSBezierPath(roundedRect: NSRect(x: 197, y: 380, width: 631, height: 391), xRadius: 12, yRadius: 12)
    NSGradient(starting: NSColor(red: 0.12, green: 0.34, blue: 0.55, alpha: 1),
               ending: NSColor(red: 0.16, green: 0.66, blue: 0.70, alpha: 1))!
        .draw(in: screenGlow, angle: -28)
    let neck = NSBezierPath(roundedRect: NSRect(x: 462, y: 236, width: 100, height: 82), xRadius: 8, yRadius: 8)
    NSColor.white.setFill(); neck.fill()
    let base = NSBezierPath(roundedRect: NSRect(x: 344, y: 204, width: 336, height: 40), xRadius: 20, yRadius: 20)
    base.fill()

    let mouseShadow = NSBezierPath(roundedRect: NSRect(x: 606, y: 174, width: 246, height: 326), xRadius: 116, yRadius: 116)
    NSColor(red: 0.03, green: 0.13, blue: 0.22, alpha: 0.45).setFill(); mouseShadow.fill()
    let mouse = NSBezierPath(roundedRect: NSRect(x: 590, y: 190, width: 246, height: 326), xRadius: 116, yRadius: 116)
    NSColor.white.setFill(); mouse.fill()
    let wheel = NSBezierPath(roundedRect: NSRect(x: 698, y: 422, width: 28, height: 62), xRadius: 14, yRadius: 14)
    NSColor(red: 0.13, green: 0.46, blue: 0.60, alpha: 1).setFill(); wheel.fill()
    let seam = NSBezierPath()
    seam.move(to: NSPoint(x: 713, y: 403)); seam.line(to: NSPoint(x: 713, y: 499))
    seam.lineWidth = 5
    NSColor(red: 0.20, green: 0.55, blue: 0.65, alpha: 0.55).setStroke(); seam.stroke()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [("icon_16x16.png",16),("icon_16x16@2x.png",32),
    ("icon_32x32.png",32),("icon_32x32@2x.png",64),("icon_128x128.png",128),
    ("icon_128x128@2x.png",256),("icon_256x256.png",256),
    ("icon_256x256@2x.png",512),("icon_512x512.png",512),("icon_512x512@2x.png",1024)]
for (name, size) in sizes { try drawIcon(size: size).write(to: iconset.appendingPathComponent(name)) }
let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try process.run(); process.waitUntilExit()
if process.terminationStatus != 0 { fatalError("iconutil failed") }
try FileManager.default.removeItem(at: iconset)
try drawIcon(size: 1024).write(to: resources.appendingPathComponent("RemoteMouse-icon.png"))
