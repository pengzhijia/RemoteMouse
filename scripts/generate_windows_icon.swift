import AppKit
import Foundation
let root=URL(fileURLWithPath:CommandLine.arguments[0]).deletingLastPathComponent().deletingLastPathComponent()
guard let image=NSImage(contentsOf:root.appendingPathComponent("mac-app/resources/AppIcon.icns")) else { fatalError("Missing AppIcon.icns") }
var entries:[Data]=[]
for size in [16,32,48,128,256] {
 let rep=NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:size,pixelsHigh:size,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
 NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current=NSGraphicsContext(bitmapImageRep:rep)
 image.draw(in:NSRect(x:0,y:0,width:size,height:size));NSGraphicsContext.restoreGraphicsState()
 entries.append(rep.representation(using:.png,properties:[:])!)
}
var ico=Data()
func u16(_ n:UInt16){var v=n.littleEndian;withUnsafeBytes(of:&v){ico.append(contentsOf:$0)}}
func u32(_ n:UInt32){var v=n.littleEndian;withUnsafeBytes(of:&v){ico.append(contentsOf:$0)}}
u16(0);u16(1);u16(UInt16(entries.count));var offset=6+entries.count*16
for (i,size) in [16,32,48,128,256].enumerated(){ico.append(UInt8(size==256 ? 0:size));ico.append(UInt8(size==256 ? 0:size));ico.append(contentsOf:[0,0]);u16(1);u16(32);u32(UInt32(entries[i].count));u32(UInt32(offset));offset+=entries[i].count}
for entry in entries {ico.append(entry)}
try ico.write(to:root.appendingPathComponent("windows-app/AppIcon.ico"))
try ico.write(to:root.appendingPathComponent("crates/atv-cli/app_icon.ico"))
