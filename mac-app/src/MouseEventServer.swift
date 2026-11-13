import AppKit
import ApplicationServices
import Darwin

/// Receives local input commands from the Rust helper and posts them from the
/// user-approved Swift app process over a private per-launch Unix datagram socket.
final class MouseEventServer {
    static let shared = MouseEventServer()

    private let queue = DispatchQueue(label: "com.corvofeng.TVRemoteMouse.MouseEventServer", qos: .userInteractive)
    private let socketURL: URL
    private var source: DispatchSourceRead?
    private let aimEngine = AimInputEngine()
    private var aimSpeed = -1.0
    private var hardwareMonitor: Any?
    private var dragging = false
    private var dragGeneration: UInt64 = 0
    private var didWarnUntrusted = false
    private var fnHeld = false

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let directory = support.appendingPathComponent("TVRemoteMouse", isDirectory: true)
        socketURL = directory.appendingPathComponent("mouse-\(ProcessInfo.processInfo.processIdentifier).sock")
    }

    var socketPath: String { socketURL.path }
    var supportDirectoryPath: String { socketURL.deletingLastPathComponent().path }
    var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    func start() {
        guard source == nil else { return }
        do {
            try FileManager.default.createDirectory(
                at: socketURL.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        } catch {
            NSLog("[Swift Host] Could not create mouse relay directory: %@", error.localizedDescription)
            return
        }

        let fd = socket(AF_UNIX, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            NSLog("[Swift Host] Could not create mouse relay socket: %d", errno)
            return
        }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = socketURL.path.utf8CString.map { UInt8(bitPattern: $0) }
        guard pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            Darwin.close(fd)
            NSLog("[Swift Host] Mouse relay socket path is too long")
            return
        }
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            bytes.copyBytes(from: pathBytes)
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            let errorCode = errno
            Darwin.close(fd)
            NSLog("[Swift Host] Could not bind mouse relay socket: %d", errorCode)
            return
        }
        _ = socketURL.path.withCString { chmod($0, mode_t(S_IRUSR | S_IWUSR)) }

        let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        readSource.setEventHandler { [weak self] in self?.receiveOne(fd: fd) }
        readSource.setCancelHandler { [path = socketURL.path] in
            Darwin.close(fd)
            _ = path.withCString { Darwin.unlink($0) }
        }
        aimEngine.configure(displays: .current(), settings: .init())
        hardwareMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved,.leftMouseDragged,.rightMouseDragged]) { [weak self] event in
            guard event.cgEvent?.getIntegerValueField(.eventSourceUserData) != AimInputEngine.syntheticTag else { return }
            self?.aimEngine.noteHardwareMotion(dx:event.deltaX,dy:event.deltaY)
        }
        source = readSource
        readSource.resume()
        NSLog("[Swift Host] Mouse relay ready; host_accessibility_trusted=%@ path=%@",
              String(AXIsProcessTrusted()), socketURL.path)
    }

    func stop() {
        queue.sync { setFnHeld(false) }
        aimEngine.releaseEverythingNow()
        if let hardwareMonitor { NSEvent.removeMonitor(hardwareMonitor); self.hardwareMonitor=nil }
        source?.cancel()
        source = nil
    }

    private func receiveOne(fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 256)
        let length = buffer.withUnsafeMutableBytes { bytes in
            recv(fd, bytes.baseAddress, bytes.count, 0)
        }
        guard length > 0,
              let command = String(bytes: buffer.prefix(length), encoding: .utf8) else { return }
        handle(command)
    }

    private func handle(_ command: String) {
        guard AXIsProcessTrusted() else {
            if !didWarnUntrusted {
                didWarnUntrusted = true
                NSLog("[Swift Host] Input command dropped: host process lacks Accessibility permission")
            }
            return
        }

        let parts = command.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
        switch parts.first {
        case "mapped_drag" where parts.count == 2:
            if parts[1] == "1" {
                aimEngine.buttonDown(.left,startsDrag:true,source:"mapped")
                aimEngine.keepAlive(source:"mapped")
            } else { aimEngine.buttonUp(.left,source:"mapped") }
        case "aim_move", "aim_drag_move":
            guard parts.count == 4, parts[0] == "aim_drag_move" || PointerSettings.source != "gyro" else { return }
            guard let dx=Double(parts[1]), let dy=Double(parts[2]), let speed=Double(parts[3]), dx.isFinite, dy.isFinite, speed.isFinite else { return }
            if aimSpeed != speed {
                aimSpeed=speed
                var settings=AimInputEngine.Settings(); settings.speed=speed
                aimEngine.configure(displays:.current(),settings:settings)
            }
            aimEngine.move(dx:dx,dy:dy)
        case "drag" where parts.count == 4:
            guard let dx=Double(parts[2]), let dy=Double(parts[3]), dx.isFinite, dy.isFinite else { return }
            if parts[1] == "1" {
                aimEngine.buttonDown(.left,startsDrag:true,source:"native")
                aimEngine.keepAlive(source:"native")
                aimEngine.move(dx:dx,dy:dy)
            } else { aimEngine.buttonUp(.left,source:"native") }
        case "gyro" where parts.count == 3:
            guard PointerSettings.source == "gyro", let dx=Double(parts[1]), let dy=Double(parts[2]), dx.isFinite, dy.isFinite else { return }
            let current=CGEvent(source:nil)?.location ?? .zero
            let rect=NSScreen.screens.map { $0.frame }.reduce(CGRect.null) { $0.union($1) }
            let target=CGPoint(x:min(max(current.x+dx,rect.minX),rect.maxX),y:min(max(current.y+dy,rect.minY),rect.maxY))
            CGEvent(mouseEventSource:nil,mouseType:dragging ? .leftMouseDragged : .mouseMoved,mouseCursorPosition:target,mouseButton:.left)?.post(tap:.cghidEventTap)
        case "move" where parts.count == 3:
            guard PointerSettings.source != "gyro" else { return }
            guard let x = Double(parts[1]), let y = Double(parts[2]) else { return }
            CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                    mouseCursorPosition: CGPoint(x: x, y: y), mouseButton: .left)?
                .post(tap: .cghidEventTap)
        case "click" where parts.count == 3:
            aimEngine.buttonDown(.left,startsDrag:false,source:"native")
            aimEngine.buttonUp(.left,source:"native")
        case "right_click" where parts.count == 3:
            aimEngine.buttonDown(.right,startsDrag:false,source:"native")
            aimEngine.buttonUp(.right,source:"native")
        case "scroll" where parts.count == 3:
            guard let vertical = Int32(parts[1]), let horizontal = Int32(parts[2]) else { return }
            CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                    wheel1: vertical, wheel2: horizontal, wheel3: 0)?.post(tap: .cghidEventTap)
        case "key" where parts.count == 2:
            guard let rawKey = UInt16(parts[1]) else { return }
            for isDown in [true, false] {
                if let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(rawKey), keyDown: isDown) {
                    if fnHeld { event.flags = .maskSecondaryFn }
                    event.post(tap: .cghidEventTap)
                }
            }
        case "shortcut" where parts.count == 3:
            guard let key = UInt16(parts[1]), key <= 127,
                  let flags = UInt64(parts[2]), flags & ~UInt64(0x1f0000) == 0 else { return }
            postShortcut(key: key, flags: flags)
        case "fn_tap" where parts.count == 1:
            postFnTap()
        case "fn_down" where parts.count == 1:
            setFnHeld(true)
        case "fn_up" where parts.count == 1:
            setFnHeld(false)
        case "dictation" where parts.count == 1:
            postFnTap()
            Thread.sleep(forTimeInterval: 0.12)
            postFnTap()
        case "media" where parts.count == 2:
            guard let key = Int32(parts[1]) else { return }
            postMediaKey(key)
        default:
            break
        }
    }

    private func postFnTap() {
        guard !fnHeld else { return }
        setFnHeld(true)
        setFnHeld(false)
    }

    private func setFnHeld(_ held: Bool) {
        guard held != fnHeld else { return }
        fnHeld = held
        guard let event = CGEvent(keyboardEventSource: nil, virtualKey: 63, keyDown: held) else { return }
        event.type = .flagsChanged
        event.flags = held ? .maskSecondaryFn : []
        event.post(tap: .cghidEventTap)
    }

    private func postShortcut(key: UInt16, flags: UInt64) {
        let modifiers: [(UInt64, UInt16)] = [(0x40000, 59), (0x80000, 58), (0x100000, 55), (0x20000, 56)]
        let fnFlag = fnHeld ? CGEventFlags.maskSecondaryFn.rawValue : 0
        var activeFlags: UInt64 = 0
        for (flag, virtualKey) in modifiers where flags & flag != 0 {
            activeFlags |= flag
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(virtualKey), keyDown: true) else { continue }
            event.type = .flagsChanged
            event.flags = CGEventFlags(rawValue: activeFlags | fnFlag)
            event.post(tap: .cghidEventTap)
        }
        for isDown in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(key), keyDown: isDown) else { continue }
            event.flags = CGEventFlags(rawValue: flags | fnFlag)
            event.post(tap: .cghidEventTap)
        }
        for (flag, virtualKey) in modifiers.reversed() where flags & flag != 0 {
            activeFlags &= ~flag
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(virtualKey), keyDown: false) else { continue }
            event.type = .flagsChanged
            event.flags = CGEventFlags(rawValue: activeFlags | fnFlag)
            event.post(tap: .cghidEventTap)
        }
    }

    private func postMediaKey(_ key: Int32) {
        for isDown in [true, false] {
            let state: Int32 = isDown ? 0x0A : 0x0B
            let flags = NSEvent.ModifierFlags(rawValue: UInt(state) << 8)
            let data1 = Int((key << 16) | (state << 8))
            let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            )
            event?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
