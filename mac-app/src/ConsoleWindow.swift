import AppKit
import SwiftUI
import Combine
import ApplicationServices

final class ConsoleModel: NSObject, ObservableObject, URLSessionDataDelegate {
    @Published var status: ServerStatus?
    @Published var mode = "mouse"
    @Published var speed = 0.5
    @Published var accel = true
    @Published var verbose = false
    @Published var history: [String] = []
    @Published var raw: [String] = []
    @Published var segments: [[CGPoint]] = []
    @Published var contactPaths: [Int: [CGPoint]] = [:]
    @Published var activeContacts: Set<Int> = []
    @Published var maximumContacts = 0
    @Published var phase = "等待触控"
    @Published var coordinates = "dx —  dy —"
    @Published var logText = ""
    @Published var logFilter = ""
    @Published var logLevel = "全部"
    @Published var liveLogs = true
    @Published var tab = 0
    @Published var mappings: [String: String] = [:]
    @Published var selectedButton = "select"
    @Published var mappingError: String?
    private var mappingsURL: URL {
        if ProcessInfo.processInfo.arguments.contains("--ui-preview") {
            return FileManager.default.temporaryDirectory.appendingPathComponent("RemoteMouse-preview-\(ProcessInfo.processInfo.processIdentifier)/button-mappings.txt")
        }
        return URL(fileURLWithPath: MouseEventServer.shared.supportDirectoryPath).appendingPathComponent("button-mappings.txt")
    }

    func loadMappings() {
        guard let text = try? String(contentsOf: mappingsURL, encoding: .utf8) else { mappings = [:]; return }
        var result: [String: String] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { result[parts[0]] = parts[1] }
        }
        mappings = result
    }
    func setMapping(_ value: String, for input: String) {
        var updated = mappings
        if value == "default" { updated.removeValue(forKey: input) } else { updated[input] = value }
        let data = updated.keys.sorted().map { "\($0)=\(updated[$0]!)" }.joined(separator: "\n") + "\n"
        do {
            try FileManager.default.createDirectory(at: mappingsURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: mappingsURL, atomically: true, encoding: .utf8)
            mappings = updated; mappingError = nil
        } catch { mappingError = "无法保存按键设置：\(error.localizedDescription)" }
    }
    func resetMappings() {
        do {
            if FileManager.default.fileExists(atPath: mappingsURL.path) { try FileManager.default.removeItem(at: mappingsURL) }
            mappings = [:]; mappingError = nil
        } catch { mappingError = "无法恢复默认：\(error.localizedDescription)" }
    }
    private var cursor = CGPoint(x: 0.5, y: 0.5)
    private var buffer = Data()
    private var stream: URLSession?
    private var timer: Timer?
    private var connecting = false
    private var adjustingSpeed = false

    func start() {
        guard timer == nil else { return }
        loadMappings()
        refresh()
        connect()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.refresh()
            if !self.connecting { self.connect() }
            if self.liveLogs { self.readLogs() }
        }
        readLogs()
    }
    func refresh() {
        ApiClient.shared.fetchStatus { [weak self] status in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.status = status
                if let status = status {
                    self.mode = status.currentTrackpadMode
                    if !self.adjustingSpeed { self.speed = status.mouse_speed ?? 0.5 }
                    self.accel = status.mouse_accel ?? true
                    self.verbose = status.verbose_events ?? false
                }
            }
        }
    }
    func update(mode: String? = nil, speed: Double? = nil, accel: Bool? = nil, verbose: Bool? = nil) {
        ApiClient.shared.updateSettings(mode: mode, speed: speed, accel: accel, verbose: verbose) { [weak self] _ in self?.refresh() }
    }
    func setSensitivity(_ value: Double) {
        speed=value; adjustingSpeed=true
        ApiClient.shared.updateSettings(speed:value,accel:false) { [weak self] success in
            DispatchQueue.main.async { guard let self else { return }; self.adjustingSpeed=false; self.refresh() }
        }
    }
    func speedEditing(_ editing: Bool) { adjustingSpeed = editing; if !editing { update(speed: speed) } }
    func action(_ button: String) {
        guard let url = URL(string: ApiClient.shared.baseUrl + "/api/action") else { return }
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["button": button])
        URLSession.shared.dataTask(with: request) { [weak self] _, _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }.resume()
    }
    func connect() {
        guard !connecting, let url = URL(string: ApiClient.shared.baseUrl + "/events") else { return }
        connecting = true
        buffer = Data()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 86400
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        stream = session
        session.dataTask(with: url).resume()
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        buffer.append(data)
        let delimiter = Data("\n\n".utf8)
        while let range = buffer.range(of: delimiter) {
            let chunk = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            guard let line = String(data: chunk, encoding: .utf8), line.hasPrefix("data: "),
                  let bytes = String(line.dropFirst(6)).data(using: .utf8),
                  let packet = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else { continue }
            DispatchQueue.main.async { self.consume(packet, rawText: String(decoding: bytes, as: UTF8.self)) }
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.invalidateAndCancel()
        DispatchQueue.main.async { self.connecting = false; self.stream = nil }
    }
    private func consume(_ packet: [String: Any], rawText: String) {
        let event = packet["event"] as? String ?? ""
        let data = packet["data"] as? [String: Any] ?? [:]
        raw.append(rawText); if raw.count > 150 { raw.removeFirst(raw.count - 150) }
        if event == "button" {
            let item = "\(packet["timestamp"] as? String ?? "")  \(data["name"] as? String ?? "—")"
            history.insert(item, at: 0); if history.count > 25 { history.removeLast() }
        }
        if event == "contact", let finger=(data["finger"] as? NSNumber)?.intValue,
           let x=(data["x"] as? NSNumber)?.doubleValue, let y=(data["y"] as? NSNumber)?.doubleValue {
            let phase=(data["phase"] as? NSNumber)?.intValue ?? 0
            let point=CGPoint(x:x/1000,y:y/1000)
            if phase == 1 { contactPaths[finger]=[point]; activeContacts.insert(finger) }
            else { var points=contactPaths[finger] ?? []; points.append(point); if points.count>1000 { points.removeFirst(points.count-1000) }; contactPaths[finger]=points }
            if phase == 4 { activeContacts.remove(finger) }
            maximumContacts=max(maximumContacts,activeContacts.count)
        }
        if event == "contacts_cancelled" || event == "client_disconnected" { activeContacts=[] }
        if event == "touch" {
            let p = (data["phase"] as? NSNumber)?.intValue ?? 0
            let dx = (data["dx"] as? NSNumber)?.doubleValue ?? 0
            let dy = (data["dy"] as? NSNumber)?.doubleValue ?? 0
            phase = [1:"按下", 2:"移动", 4:"抬起"][p] ?? "\(p)"
            coordinates = String(format: "dx %.1f  dy %.1f", dx, dy)
            if p == 1 { segments.append([cursor]) }
            if p == 2 && !segments.isEmpty {
                cursor.x = min(0.98, max(0.02, cursor.x + dx / 500))
                cursor.y = min(0.98, max(0.02, cursor.y + dy / 500))
                segments[segments.count - 1].append(cursor)
            }
            if segments.count > 100 { segments.removeFirst() }
        }
        if ["mode_changed", "touchpad_settings", "mouse_settings", "audio_state", "client_connected", "client_disconnected", "remote_ready", "remote_surface_changed"].contains(event) { refresh() }
    }
    func clearTrajectory() { contactPaths=[:]; activeContacts=[]; maximumContacts=0; segments = []; cursor = CGPoint(x: 0.5, y: 0.5); phase = "等待触控"; coordinates = "dx —  dy —" }
    func readLogs() {
        let url = ProcessManager.shared.logFilePath
        guard let handle = try? FileHandle(forReadingFrom: url) else { logText = "暂无日志"; return }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > 300_000 ? end - 300_000 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        logText = String(decoding: data, as: UTF8.self)
    }
    var filteredLogs: String {
        logText.components(separatedBy: "\n").filter { line in
            (logFilter.isEmpty || line.localizedCaseInsensitiveContains(logFilter)) && (logLevel == "全部" || line.contains(logLevel))
        }.joined(separator: "\n")
    }
    func clearLogs() {
        let alert = NSAlert(); alert.messageText = "清空日志文件？"; alert.informativeText = "此操作无法撤销。"; alert.addButton(withTitle: "清空"); alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            if let file = try? FileHandle(forWritingTo: ProcessManager.shared.logFilePath) { try? file.truncate(atOffset: 0); try? file.close() }
            readLogs()
        }
    }
    func exportLogs() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "RemoteMouse.log"
        if panel.runModal() == .OK, let url = panel.url { try? FileManager.default.copyItem(at: ProcessManager.shared.logFilePath, to: url) }
    }
}

final class ConsoleWindow {
    static let shared = ConsoleWindow()
    private let model = ConsoleModel()
    private var window: NSWindow?
    func show() { present(tab: 0) }
    func showLogs() { present(tab: 1) }
    private func present(tab: Int) {
        model.tab = tab; model.start()
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            w.title = "RemoteMouse 控制台"; w.minSize = NSSize(width: 900, height: 600)
            w.contentViewController = NSHostingController(rootView: ConsoleView(model: model))
            w.isReleasedWhenClosed = false; w.center(); window = w
        }
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
}

struct ConsoleView: View {
    @ObservedObject var model: ConsoleModel
    @AppStorage("PointerSource") private var pointerSource = "mouse"
    @AppStorage("PairingPIN") private var pairingPIN = "1111"
    @State private var showTrajectory=false
    @State private var showEvents=false
    @State private var showHistory=false
    var body: some View {
        TabView(selection: $model.tab) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    HStack { VStack(alignment: .leading) { Text("遥控控制台").font(.largeTitle.bold()); Text(model.status?.client_name ?? (model.status?.client_connected == true ? "已连接的 iPhone" : "等待 iPhone 连接")).foregroundColor(.secondary) }; Spacer(); Text(model.status == nil ? "服务未运行" : (model.status?.client_connected == true ? "iPhone 已连接" : "等待 iPhone 连接 · PIN \(pairingPIN)")); Button("刷新") { model.refresh() } }
                    GroupBox("鼠标与陀螺仪") {
                        VStack(alignment: .leading, spacing: 12) {
                            Picker("控制模式", selection: Binding(get: { pointerSource }, set: { value in PointerSettings.set(value); model.update(mode: "mouse") })) { Text("鼠标").tag("mouse"); Text("陀螺仪（未收到数据）").tag("gyro").disabled(true) }.pickerStyle(.segmented)
                            Label("系统遥控器目前只提供触摸与按键事件，尚未收到陀螺仪数据。收到可识别的运动数据后才能启用陀螺仪控制。", systemImage: "gyroscope")
                                .font(.callout).foregroundColor(.secondary)
                            HStack {
                                Text("灵敏度")
                                Picker("灵敏度",selection:Binding(get:{SensitivityPreset.nearest(model.speed).rawValue},set:{model.setSensitivity($0)})) {
                                    ForEach(SensitivityPreset.allCases,id:\.rawValue){preset in Text(preset.title).tag(preset.rawValue)}
                                }.pickerStyle(.segmented).labelsHidden().frame(width:210)
                                Spacer()
                                Toggle("详细事件日志",isOn:Binding(get:{model.verbose},set:{model.verbose=$0;model.update(verbose:$0)}))
                            }
                            Text(model.mode == "mouse" ? "当前触控板：\(["two_finger_scroll": "双指滚动", "three_finger_drag": "三指按住拖移", "four_finger_desktop": "四指切换桌面"][model.status?.gesture_mode ?? "mouse"] ?? "鼠标移动")" : (model.mode == "direction" ? "当前触控板：方向键模式" : "当前触控板：轨迹预览")).font(.caption).foregroundColor(.accentColor)
                            Text("屏幕：\(model.status?.screen_size?.map(String.init).joined(separator: " × ") ?? "检测中")   ·   音量：\(Int((model.status?.audio?.volume ?? 0) * 100))% \(model.status?.audio?.muted == true ? "（静音）" : "")   ·   连接：\(model.status?.client_peer ?? "等待连接")").font(.caption).foregroundColor(.secondary)
                        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack(spacing:12) {
                        Button(showTrajectory ? "隐藏轨迹" : "显示轨迹"){showTrajectory.toggle()}
                        Button(showEvents ? "隐藏事件记录" : "显示事件记录"){showEvents.toggle()}
                        Button(showHistory ? "隐藏最近按键" : "显示最近按键"){showHistory.toggle()}
                        Spacer()
                    }
                    RemoteMappingView(model:model)
                    if showTrajectory {
                            GroupBox("触控轨迹 · \(model.phase)") {
                                VStack { HStack { Text("当前触点 \(model.activeContacts.count) · 本次最多 \(model.maximumContacts)  \(model.coordinates)").font(.caption.monospaced()); Spacer(); Button("清空轨迹") { model.clearTrajectory() } }; GeometryReader { geo in ZStack { RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.08)); ForEach(model.contactPaths.keys.sorted(), id: \.self) { finger in
                                    Path { path in
                                        let points=model.contactPaths[finger] ?? []
                                        if let first=points.first { path.move(to:CGPoint(x:first.x*geo.size.width,y:first.y*geo.size.height)) }
                                        for p in points.dropFirst() { path.addLine(to:CGPoint(x:p.x*geo.size.width,y:p.y*geo.size.height)) }
                                    }.stroke([Color.blue,.orange,.green,.purple][abs(finger)%4],lineWidth:2)
                                } } }.frame(height: 220) }.padding(8)
                            }
                    }
                    if showEvents {
                            GroupBox("协议事件流") { ScrollView { Text(model.raw.joined(separator: "\n")).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(height: 220).padding(8) }
                    }
                    if showHistory {
                            GroupBox("最近按键和历史") { VStack(alignment: .leading) { if model.history.isEmpty { Text("等待遥控器输入").foregroundColor(.secondary) }; ForEach(Array(model.history.enumerated()), id: \.offset) { _, item in Text(item).font(.system(.caption, design: .monospaced)) } }.frame(maxWidth: .infinity, alignment: .leading).padding(8) }
                    }
                }.padding(20)
            }.tabItem { Label("遥控控制台", systemImage: "cursorarrow.motionlines") }.tag(0)
            VStack(alignment: .leading, spacing: 12) {
                HStack { Text("系统日志").font(.title2.bold()); Spacer(); Text(AXIsProcessTrusted() ? "辅助功能已授权" : "辅助功能未授权"); Button("检查权限") { AccessibilityHelper.showHostPermissionGuide() } }
                Text(ProcessManager.shared.logFilePath.path).font(.caption).textSelection(.enabled)
                HStack { TextField("搜索日志", text: $model.logFilter); Picker("级别", selection: $model.logLevel) { ForEach(["全部","INFO","WARN","ERROR","DEBUG"], id: \.self) { Text($0) } }.frame(width: 130); Toggle("自动刷新", isOn: $model.liveLogs); Button("刷新") { model.readLogs() }; Button("重启服务") { ProcessManager.shared.restartService { _ in model.refresh() } } }
                HStack { Button("复制筛选结果") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.filteredLogs, forType: .string) }; Button("导出日志") { model.exportLogs() }; Button("在 Finder 中显示") { ProcessManager.shared.revealLogInFinder() }; Button("清空日志") { model.clearLogs() } }
                ScrollView([.vertical, .horizontal]) { Text(model.filteredLogs).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black.opacity(0.04))
            }.padding(20).tabItem { Label("系统日志", systemImage: "doc.text") }.tag(1)
        }
    }
}
