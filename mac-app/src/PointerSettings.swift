import AppKit
import CoreImage

enum PointerSettings {
    static var source: String { UserDefaults.standard.string(forKey: "PointerSource") ?? "mouse" }
    static func set(_ value: String) {
        guard value == "mouse" || value == "gyro" else { return }
        do {
            let path = URL(fileURLWithPath: MouseEventServer.shared.supportDirectoryPath).appendingPathComponent("pointer-source.txt")
            try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
            try value.write(to: path, atomically: true, encoding: .utf8)
            UserDefaults.standard.set(value, forKey: "PointerSource")
        } catch { NSLog("Cannot save pointer source: %@", error.localizedDescription) }
    }
    static func showMotionSetup() {
        let path = URL(fileURLWithPath: MouseEventServer.shared.supportDirectoryPath).appendingPathComponent("motion-url.txt")
        guard let address = try? String(contentsOf: path, encoding: .utf8) else { let alert=NSAlert();alert.messageText="请先启动服务";alert.runModal();return }
        let alert=NSAlert();alert.messageText="iPhone 陀螺仪连接"
        alert.informativeText="用 iPhone 相机扫描二维码，在 Safari 打开。首次需要确认本地 HTTPS 证书并允许运动权限。点击网页中的开启按钮。\n\n保持采集页在前台；切到系统遥控器后采样可能暂停。\n\n\(address)"
        if let filter=CIFilter(name:"CIQRCodeGenerator") {
            filter.setValue(Data(address.utf8),forKey:"inputMessage")
            if let output=filter.outputImage?.transformed(by:CGAffineTransform(scaleX:7,y:7)) {
                let rep=NSCIImageRep(ciImage:output);let image=NSImage(size:rep.size);image.addRepresentation(rep);let view=NSImageView(frame:NSRect(x:0,y:0,width:220,height:220));view.image=image;view.imageScaling = .scaleProportionallyUpOrDown;alert.accessoryView=view
            }
        }
        alert.addButton(withTitle:"复制地址");alert.addButton(withTitle:"关闭")
        if alert.runModal() == .alertFirstButtonReturn {NSPasteboard.general.clearContents();NSPasteboard.general.setString(address,forType:.string)}
    }
}
