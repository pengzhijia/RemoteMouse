import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let isUIPreview = ProcessInfo.processInfo.arguments.contains("--ui-preview")
    private let isStatusPreview = ProcessInfo.processInfo.arguments.contains("--status-preview")
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Run as menu bar accessory app (no dock icon clutter)
        NSApplication.shared.setActivationPolicy(.accessory)

        if isUIPreview {
            ConsoleWindow.shared.show()
            return
        }
        if isStatusPreview {
            StatusItemManager.shared.setup(preview: true)
            return
        }

        PointerSettings.set("mouse")

        // Setup status item in system menu bar
        StatusItemManager.shared.setup()

        MouseEventServer.shared.start()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            AccessibilityHelper.requestHostPermission()
        }

        // Start native Swift Debug Web Server on port 18766
        DebugWebServer.shared.start(port: 18766)
        WebRemoteManager.shared.start()
        WebRemoteManager.shared.setupLoginIfNeeded()

        // Start the atv-core Rust backend process if not already running
        ProcessManager.shared.startCoreIfNeeded { success in
            if success {
                print("✅ TVRemoteMouse core service is ready.")
            } else {
                print("⚠️ TVRemoteMouse core service could not be started.")
            }
            StatusItemManager.shared.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        if isUIPreview || isStatusPreview { return }
        DebugWebServer.shared.stop()
        WebRemoteManager.shared.stop()
        ProcessManager.shared.stopCore()
        MouseEventServer.shared.stop()
    }
}
