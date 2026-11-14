import AppKit
import Foundation
import ServiceManagement

final class WebRemoteManager {
    static let shared = WebRemoteManager()
    private var process: Process?

    private init() {}
    var isRunning: Bool { process?.isRunning == true }

    func setupLoginIfNeeded() {
        guard #available(macOS 13.0, *), UserDefaults.standard.object(forKey: "didSetupLogin") == nil else { return }
        UserDefaults.standard.set(true, forKey: "didSetupLogin")
        try? SMAppService.mainApp.register()
    }

    func toggleLogin() {
        guard #available(macOS 13.0, *) else { return }
        do {
            let service = SMAppService.mainApp
            if service.status == .enabled { try service.unregister() }
            else { try service.register() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "开机启动设置失败"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    func start() {
        guard process?.isRunning != true else { return }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/WebRemoteBridge")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            NSLog("[Web Remote] Missing WebRemoteBridge helper")
            return
        }
        let child = Process()
        child.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        environment["TVREMOTE_EMBEDDED"] = "1"
        child.environment = environment
        do {
            try child.run()
            process = child
        } catch {
            NSLog("[Web Remote] Could not start helper: %@", error.localizedDescription)
        }
    }

    func perform(_ action: String) {
        let needsStart = process?.isRunning != true
        if needsStart { start() }
        let send = {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.corvofeng.TVRemoteMouse.webAction"), object: nil,
                userInfo: ["action": action], deliverImmediately: true
            )
        }
        if needsStart { DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: send) }
        else { send() }
    }

    func showQR() { perform("qr") }

    func showCertificateHelp() {
        let alert = NSAlert()
        alert.messageText = "网页遥控 HTTPS 证书"
        alert.informativeText = "在 iPhone 或 iPad 的网页遥控器中打开设置，点“下载电脑的证书”。安装描述文件后，到“设置 → 通用 → 关于本机 → 证书信任设置”启用该证书，再刷新网页。未安装时仍可使用图片模式看屏幕。"
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    func stop() {
        guard let process else { return }
        if process.isRunning {
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("com.corvofeng.TVRemoteMouse.webAction"), object: nil,
                userInfo: ["action": "quit"], deliverImmediately: true
            )
            for _ in 0..<20 where process.isRunning { Thread.sleep(forTimeInterval: 0.1) }
            if process.isRunning { process.terminate() }
        }
        self.process = nil
    }
}
