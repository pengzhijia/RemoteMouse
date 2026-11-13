import AppKit
import Combine
import Foundation
import SwiftUI
import UserNotifications
import ApplicationServices

enum RemoteConnectionState {
    case stopped, waiting, connecting, connected, busy

    var color: NSColor {
        switch self {
        case .stopped: return NSColor(red: 0.94, green: 0.34, blue: 0.35, alpha: 1)
        case .waiting: return NSColor(red: 0.29, green: 0.62, blue: 0.98, alpha: 1)
        case .connecting, .busy: return NSColor(red: 0.98, green: 0.68, blue: 0.22, alpha: 1)
        case .connected: return NSColor(red: 0.22, green: 0.78, blue: 0.50, alpha: 1)
        }
    }

    var title: String {
        switch self {
        case .stopped: return "服务已停止"
        case .waiting: return "等待 iPhone 连接"
        case .connecting: return "正在连接"
        case .connected: return "已连接"
        case .busy: return "处理中"
        }
    }
}

/// Outline remote and pointer matching the supplied menu-bar reference.
/// The stroke retains the existing connection-state colors.
enum StatusRemoteGlyph {
    static func image(state: RemoteConnectionState, size: CGFloat = 22) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size))
        image.lockFocus()
        NSGraphicsContext.saveGraphicsState()
        let scale = size / 22
        NSGraphicsContext.current?.cgContext.scaleBy(x: scale, y: scale)
        state.color.setStroke()
        let remote = NSBezierPath(roundedRect: NSRect(x: 4.5, y: 6.5, width: 8.5, height: 14), xRadius: 1.1, yRadius: 1.1)
        remote.lineWidth = 1.05
        remote.stroke()
        let pointer = NSBezierPath()
        pointer.move(to: NSPoint(x: 9.1, y: 12.4))
        pointer.line(to: NSPoint(x: 9.1, y: 2.1))
        pointer.line(to: NSPoint(x: 12.1, y: 5.1))
        pointer.line(to: NSPoint(x: 14.4, y: 0.9))
        pointer.line(to: NSPoint(x: 16.1, y: 1.8))
        pointer.line(to: NSPoint(x: 13.9, y: 5.9))
        pointer.line(to: NSPoint(x: 18.1, y: 5.9))
        pointer.close()
        NSColor.windowBackgroundColor.setFill()
        pointer.fill()
        state.color.setStroke()
        pointer.lineWidth = 1.05
        pointer.lineJoinStyle = .round
        pointer.stroke()
        NSGraphicsContext.restoreGraphicsState()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }
}

final class StatusItemManager: NSObject, ObservableObject {
    static let shared = StatusItemManager()

    @Published private(set) var status: ServerStatus?
    @Published private(set) var isServiceRunning = false
    @Published private(set) var isBusy = false
    @Published private(set) var showStatusTextInBar: Bool
    @Published var pointerSource = PointerSettings.source
    @Published private(set) var panelHeight: CGFloat = 300
    @Published var speed = 0.5
    @Published private(set) var pairingPIN = PairingSettings.pin()
    @Published private(set) var accessibilityTrusted = AXIsProcessTrusted()
    @Published private(set) var operationMessage: String?
    @Published private(set) var permissionMessage: String?

    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var previewWindow: NSWindow?
    private var measuredPanelSize = NSSize(width: 330, height: 300)
    private var resizeObserver: NSObjectProtocol?
    private var contentHeight: CGFloat = 300
    private var syncTimer: Timer?
    private var previousSessionReady = false
    private var speedEditing = false
    private var preview = false

    var connectionState: RemoteConnectionState {
        if isBusy { return .busy }
        if !isServiceRunning { return .stopped }
        if status?.session_ready == true { return .connected }
        if status?.client_connected == true { return .connecting }
        return .waiting
    }

    override private init() {
        showStatusTextInBar = (UserDefaults.standard.object(forKey: "ShowStatusTextInBar") as? Bool) ?? true
        super.init()
    }

    func setup(preview: Bool = false) {
        self.preview = preview
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        statusItem.button?.sendAction(on: [.leftMouseUp])

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentSize = measuredPanelSize
        popover.contentViewController = NSHostingController(rootView: StatusPopoverView(manager: self))
        resizeObserver = NotificationCenter.default.addObserver(forName:NSWindow.didResizeNotification,object:nil,queue:.main) { [weak self] notification in
            guard let self, let window=notification.object as? NSWindow,
                  window === self.popover.contentViewController?.view.window else { return }
            self.positionPopover()
        }

        if preview {
            let sample = """
            {"status":"ok","mode":"mouse","mouse_mode":true,"device_name":"PengZhijia MacBook Air","client_connected":true,"session_ready":true,"client_name":"PengZhijia iPhone","client_model":"iPhone14,5","mouse_speed":0.8,"mouse_accel":true,"verbose_events":false}
            """
            status = try? JSONDecoder().decode(ServerStatus.self, from: Data(sample.utf8))
            isServiceRunning = true
            speed = 0.8
            updateStatusItemUI()
            showPreviewWindow()
            return
        }

        updateStatusItemUI()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        refresh()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func updateStatusItemUI() {
        guard let button = statusItem?.button else { return }
        let state = connectionState
        button.image = StatusRemoteGlyph.image(state: state)
        button.imagePosition = showStatusTextInBar ? .imageLeading : .imageOnly
        button.title = showStatusTextInBar ? "  \(state.title)" : ""
        button.toolTip = "TVRemoteMouse · \(state.title)"
    }

    func refresh() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in self?.refresh() }
            return
        }
        pointerSource = PointerSettings.source
        accessibilityTrusted = AXIsProcessTrusted()
        guard !isBusy && !preview else { return }
        ApiClient.shared.fetchStatus { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                guard !self.isBusy else { return }
                self.status = result
                self.isServiceRunning = result != nil
                if !self.speedEditing { self.speed = result?.mouse_speed ?? 0.5 }
                self.updateStatusItemUI()
                let ready = result?.session_ready == true
                if ready != self.previousSessionReady {
                    self.previousSessionReady = ready
                    if self.isServiceRunning { self.postConnectionNotification(connected: ready, deviceName: result?.client_name) }
                }
            }
        }
    }

    private func postConnectionNotification(connected: Bool, deviceName: String?) {
        let content = UNMutableNotificationContent()
        content.title = connected ? "iPhone 已连接" : "iPhone 已断开"
        content.body = connected ? "\(deviceName ?? "iPhone") 可以控制这台 Mac。" : "遥控会话已结束。"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        refresh()
        resizePanel(to:NSSize(width:330,height:contentHeight))
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        positionPopover()
        DispatchQueue.main.async { [weak self] in self?.positionPopover() }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func closePopover() { if popover.isShown { popover.performClose(nil) } }

    private func showPreviewWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 330, height: measuredPanelSize.height),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "TVRemoteMouse 状态栏预览"
        window.contentViewController = NSHostingController(rootView: StatusPopoverView(manager: self))
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        previewWindow = window
    }

    private var panelScreen: NSScreen? { statusItem?.button?.window?.screen ?? previewWindow?.screen ?? NSScreen.main }

    private func positionPopover() {
        guard popover?.isShown == true, let window=popover.contentViewController?.view.window,
              let button=statusItem.button, let anchorWindow=button.window, let screen=panelScreen else { return }
        let anchor=anchorWindow.convertToScreen(button.convert(button.bounds,to:nil))
        let frame=StatusPanelPlacement.below(anchor:anchor,size:window.frame.size,visible:screen.visibleFrame)
        if abs(window.frame.minX-frame.minX)>0.5 || abs(window.frame.minY-frame.minY)>0.5 {
            window.setFrameOrigin(frame.origin)
        }
    }

    func resizePanel(to size: CGSize) {
        guard size.height>0,size.height.isFinite else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.contentHeight=ceil(size.height)
            if self.preview { NSLog("[Panel Layout] measured=%.0f screen=%.0f",self.contentHeight,self.panelScreen?.visibleFrame.height ?? -1) }
            // Reserve space for the popover arrow and screen-edge margins.
            let maximum=max(80,(self.panelScreen?.visibleFrame.height ?? 800)-40)
            let target=NSSize(width:330,height:min(self.contentHeight,maximum))
            if abs(self.measuredPanelSize.height-target.height)>0.5 {
                self.measuredPanelSize=target
                self.panelHeight=target.height
                self.popover?.contentSize=target
                if let window=self.previewWindow {
                    let windowSize=window.frameRect(forContentRect:NSRect(origin:.zero,size:target)).size
                    let visible=(window.screen ?? self.panelScreen)?.visibleFrame ?? window.frame
                    let anchor=NSRect(x:window.frame.midX,y:window.frame.maxY,width:0,height:0)
                    window.setFrame(StatusPanelPlacement.below(anchor:anchor,size:windowSize,visible:visible),display:true)
                }
            }
            self.positionPopover()
        }
    }

    func setPointerSource(_ value: String) { PointerSettings.set(value); pointerSource=value; setMode("mouse") }

    func setMode(_ mode: String) {
        guard isServiceRunning && !preview else { return }
        ApiClient.shared.updateSettings(mode: mode) { [weak self] _ in self?.refresh() }
    }

    func setSensitivity(_ value: Double) {
        guard isServiceRunning && !preview else { return }
        speed=value; speedEditing=true
        ApiClient.shared.updateSettings(speed:value,accel:false) { [weak self] _ in
            DispatchQueue.main.async { self?.speedEditing=false; self?.refresh() }
        }
    }
    func setSpeedEditing(_ editing: Bool) {
        speedEditing = editing
        if !editing && isServiceRunning && !preview {
            ApiClient.shared.updateSettings(speed: speed) { [weak self] _ in self?.refresh() }
        }
    }

    func setAcceleration(_ enabled: Bool) {
        guard isServiceRunning && !preview else { return }
        ApiClient.shared.updateSettings(accel: enabled) { [weak self] _ in self?.refresh() }
    }

    func setVerbose(_ enabled: Bool) {
        guard isServiceRunning && !preview else { return }
        ApiClient.shared.updateSettings(verbose: enabled) { [weak self] _ in self?.refresh() }
    }

    func setStatusText(_ enabled: Bool) {
        showStatusTextInBar = enabled
        UserDefaults.standard.set(enabled, forKey: "ShowStatusTextInBar")
        updateStatusItemUI()
    }

    @discardableResult
    func savePIN(_ value: String) -> Bool {
        guard !isBusy, PairingSettings.isValid(value) else { return false }
        guard value != pairingPIN else { return true }
        if !preview { PairingSettings.save(value) }
        pairingPIN = value
        operationMessage = nil
        if isServiceRunning && !preview { restartService() }
        return true
    }

    func startService() { performServiceAction { done in ProcessManager.shared.startService(completion: done) } }
    func restartService() { performServiceAction { done in ProcessManager.shared.restartService(completion: done) } }
    func stopService() {
        guard !isBusy && !preview else { return }
        isBusy = true
        updateStatusItemUI()
        ProcessManager.shared.stopService { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.isServiceRunning = false
                self.status = nil
                self.previousSessionReady = false
                self.updateStatusItemUI()
            }
        }
    }

    private func performServiceAction(_ action: @escaping (@escaping (Bool) -> Void) -> Void) {
        guard !isBusy && !preview else { return }
        isBusy = true
        operationMessage = nil
        updateStatusItemUI()
        action { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                self.isServiceRunning = success
                if !success { self.operationMessage = "服务启动失败，请检查日志；已保存的 PIN 会在下次启动时使用。" }
                self.updateStatusItemUI()
                self.refresh()
            }
        }
    }

    func openConsole() { closePopover(); ConsoleWindow.shared.show() }
    func openLogs() { closePopover(); ConsoleWindow.shared.showLogs() }
    func openLogFile() { closePopover(); ProcessManager.shared.openLogFile() }
    func checkPermissions() {
        pointerSource = PointerSettings.source
        accessibilityTrusted = AXIsProcessTrusted()
        if accessibilityTrusted {
            permissionMessage = "已授权，可以控制鼠标和键盘。"
        } else {
            closePopover()
            AccessibilityHelper.showHostPermissionGuide()
        }
    }
    func quit() { NSApplication.shared.terminate(nil) }
}
