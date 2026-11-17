import AppKit
import ApplicationServices

enum AccessibilityHelper {
    /// Request consent for the Swift host, which posts the input events.
    static func requestHostPermission() {
        guard !AXIsProcessTrusted() else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openAccessibilitySettings()
    }

    /// Open System Settings directly into the Accessibility (辅助功能) sub-pane
    static func openAccessibilitySettings() {
        // 1. Try modern macOS (macOS 13, 14, 15+) Settings deep link
        if let url = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }

        // 2. Also run AppleScript to reveal the exact sub-anchor inside Device Control and Data Access
        let script = """
        tell application "System Settings"
            activate
            try
                reveal anchor "Privacy_Accessibility" of pane id "com.apple.settings.PrivacySecurity.extension"
            end try
        end tell
        """
        if let appleScript = NSAppleScript(source: script) {
            var error: NSDictionary?
            appleScript.executeAndReturnError(&error)
        }
    }

    /// Explain and open Accessibility settings for the app process that posts input.
    static func showHostPermissionGuide() {
        let alert = NSAlert()
        alert.messageText = "请授权 RemoteMouse 控制鼠标"
        alert.informativeText = """
鼠标和键盘事件由 RemoteMouse 主程序发出，需要为当前 App 开启辅助功能权限。

请在辅助功能列表中启用当前 RemoteMouse App。后台 atv-cli helper 不需要单独授权。
"""
        alert.alertStyle = .warning
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")

        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilitySettings()
        }
    }
}
