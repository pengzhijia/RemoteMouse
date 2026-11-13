import AppKit
import SwiftUI

private struct RemoteInput: Identifiable {
    let id: String
    let label: String
    let symbol: String
}

private let remoteInputs: [RemoteInput] = [
    .init(id: "power", label: "电源", symbol: "power"),
    .init(id: "select", label: "触控区轻点", symbol: "circle.fill"),
    .init(id: "two_finger_tap", label: "双指轻点", symbol: "hand.tap"),
    .init(id: "three_finger_tap", label: "三指轻点", symbol: "hand.tap"),
    .init(id: "four_finger_tap", label: "四指轻点", symbol: "hand.tap"),
    .init(id: "menu", label: "返回", symbol: "chevron.left"),
    .init(id: "home", label: "电视 / 主页", symbol: "tv"),
    .init(id: "guide", label: "列表", symbol: "list.bullet"),
    .init(id: "channel_up", label: "频道加", symbol: "chevron.up"),
    .init(id: "channel_down", label: "频道减", symbol: "chevron.down"),
    .init(id: "play_pause", label: "播放 / 暂停", symbol: "playpause.fill"),
    .init(id: "mute", label: "静音", symbol: "speaker.slash.fill"),
    .init(id: "volume_up", label: "音量加", symbol: "plus"),
    .init(id: "volume_down", label: "音量减", symbol: "minus")
]
private let actionOptions: [(String, String)] = [
    ("default", "默认功能"), ("disabled", "禁用"),
    ("left_click", "鼠标左键"), ("right_click", "鼠标右键"),
    ("toggle_scroll", "切换鼠标 / 双指滚动"),
    ("toggle_three_finger_drag", "切换鼠标 / 三指按住拖移"),
    ("toggle_four_finger_desktop", "切换鼠标 / 四指切换桌面"),
    ("hold_drag", "按住拖移"),
    ("desktop_previous", "切换桌面：上一个"), ("desktop_next", "切换桌面：下一个"),
    ("fn_key", "Fn / 地球仪键"), ("voice_input", "语音输入（系统听写）"),
    ("up", "方向上"), ("down", "方向下"), ("left", "方向左"), ("right", "方向右"),
    ("select", "确认 / 左键"), ("menu", "返回 / Escape"), ("home", "主页"),
    ("play_pause", "播放 / 暂停"), ("prev_track", "上一曲"), ("next_track", "下一曲"),
    ("volume_up", "音量加"), ("volume_down", "音量减"), ("mute", "静音"), ("power", "屏幕休眠 / 唤醒")
]

struct RemoteMappingView: View {
    @ObservedObject var model: ConsoleModel
    @State private var captureShortcut = false
    @State private var confirmReset = false
    @State private var trigger = "single"
    private var mappingKey: String { trigger == "single" ? model.selectedButton : model.selectedButton + "." + trigger }
    private var selectedName: String { remoteInputs.first { $0.id == model.selectedButton }?.label ?? model.selectedButton }
    private var selection: String {
        let value = model.mappings[mappingKey] ?? "default"
        return value.hasPrefix("shortcut:") ? "custom" : value
    }
    private func remoteButton(_ id: String, size: CGFloat = 42) -> some View {
        let input = remoteInputs.first { $0.id == id }!
        return Button { model.selectedButton = id } label: {
            Image(systemName: input.symbol).font(.system(size: size * 0.35, weight: .semibold))
                .frame(width: size, height: size)
                .background(model.selectedButton == id ? Color.blue : Color.white.opacity(0.13))
                .clipShape(Circle()).overlay(Circle().stroke(model.selectedButton == id ? Color.cyan : .clear,lineWidth:3)).foregroundColor(.white)
        }.buttonStyle(.plain).help("设置：\(input.label)")
    }
    private func bareButton(_ id: String, size: CGFloat = 38) -> some View {
        let input = remoteInputs.first { $0.id == id }!
        return Button { model.selectedButton = id } label: {
            Image(systemName: input.symbol).font(.system(size: size * 0.48, weight: .semibold))
                .frame(width: size, height: size)
                .background(model.selectedButton == id ? Color.blue : .clear).clipShape(Circle())
                .overlay(Circle().stroke(model.selectedButton == id ? Color.cyan : .clear,lineWidth:2)).foregroundColor(.white)
        }.buttonStyle(.plain).help("设置：\(input.label)")
    }
    private func gestureChip(_ id: String) -> some View {
        let input = remoteInputs.first { $0.id == id }!
        return Button(input.label) { model.selectedButton = id }
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(model.selectedButton == id ? .white : .primary)
            .padding(.horizontal, 9).padding(.vertical, 6)
            .background(model.selectedButton == id ? Color.blue : Color.secondary.opacity(0.12))
            .clipShape(Capsule()).buttonStyle(.plain)
    }
    private var touchSurface: some View {
        Button { model.selectedButton = "select" } label: {
            RoundedRectangle(cornerRadius: 34)
                .fill(model.selectedButton == "select" ? Color.blue.opacity(0.4) : Color(red: 0.12, green: 0.12, blue: 0.13))
                .overlay(RoundedRectangle(cornerRadius: 34).stroke(model.selectedButton == "select" ? Color.cyan : .clear, lineWidth: 3))
                .frame(height: 248)
        }.buttonStyle(.plain).help("设置：触控区轻点")
    }
    private var legacyRemote: some View {
        VStack(spacing: 18) {
            Text(model.status?.client_name ?? "Apple TV Remote")
                .font(.system(size: 17, weight: .semibold)).lineLimit(1)
            HStack { bareButton("mute"); Spacer(); bareButton("guide"); Spacer(); bareButton("power") }
                .padding(.horizontal, 16)
            touchSurface
            HStack(alignment: .center, spacing: 14) {
                VStack(spacing: 10) { remoteButton("home", size: 58); remoteButton("play_pause", size: 58) }
                Spacer(minLength: 0)
                remoteButton("menu", size: 112)
                Spacer(minLength: 0)
                VStack(spacing: 13) {
                    bareButton("channel_up", size: 31)
                    Text("CH").font(.system(size: 14, weight: .medium))
                    bareButton("channel_down", size: 31)
                }.frame(width: 52, height: 116)
                    .background(Color.white.opacity(0.12)).clipShape(Capsule())
            }.padding(.horizontal, 8)
        }.padding(16).frame(width: 322)
            .background(Color.black).cornerRadius(28)
            .foregroundColor(.white)
    }
    var body: some View {
        GroupBox("遥控器与按键映射") {
            HStack(alignment:.top,spacing:16) {
                legacyRemote
                VStack(alignment:.leading,spacing:14) {
                    Text("点选左侧遥控器按键，在这里设置执行的动作。")
                        .font(.caption).foregroundColor(.secondary)
                    VStack(alignment:.leading,spacing:6) {
                        Text("已选择").font(.caption)
                        Text(selectedName).font(.title3.bold())
                    }.foregroundColor(.white).frame(maxWidth:.infinity,alignment:.leading)
                        .padding(16).background(Color.blue).cornerRadius(12)
                    Text("多指轻点").font(.caption).foregroundColor(.secondary)
                    HStack { gestureChip("two_finger_tap"); gestureChip("three_finger_tap"); gestureChip("four_finger_tap") }
                    Text("三指、四指轻点需手机发送独立触点；当前系统遥控器尚未观察到这些数据。")
                        .font(.caption).foregroundColor(.secondary)
                    if model.status?.remote_surface == "direction" {
                        Label("检测到 iPhone 遥控器的方向按钮。请在 iPhone 的 Apple TV 遥控器设置中关闭方向按钮，改用触摸板。", systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundColor(.orange)
                    }
                    Divider()
                Picker("触发方式", selection: $trigger) { Text("单击").tag("single"); Text("双击").tag("double"); Text("三击").tag("triple") }.pickerStyle(.segmented)
                if trigger != "single" { Text("多击间隔最多 380 毫秒；设置后单击会稍等片刻再执行。") .font(.caption).foregroundColor(.secondary) }
                Picker("映射动作", selection: Binding(get: { selection }, set: { value in
                    if value == "custom" { captureShortcut = true } else { model.setMapping(value, for: mappingKey) }
                })) {
                    ForEach(actionOptions, id: \.0) { value in Text(value.0 == "default" && trigger != "single" ? "未设置" : value.1).tag(value.0) }
                    Text("录制 Mac 快捷键…").tag("custom")
                }
                if selection == "custom" {
                    Text(UserDefaults.standard.string(forKey: "shortcut-label-\(mappingKey)") ?? "已设置自定义快捷键")
                        .font(.caption).foregroundColor(.secondary)
                    Button("重新录制快捷键") { captureShortcut = true }
                }
                HStack {
                    Button("测试当前按键") { model.action(mappingKey) }.disabled(model.status == nil || (trigger != "single" && selection == "default"))
                    Button(trigger == "single" ? "恢复此键默认" : "清除此映射") { model.setMapping("default", for: mappingKey) }
                    Spacer()
                    Button("释放拖移") { model.action("release_drag") }.disabled(model.status == nil)
                    Button("重置全部") { confirmReset = true }
                }
                Text(selection == "hold_drag" ? "触发一次按住左键，用触控区移动拖动物体；再次触发释放。断开连接后会自动释放。" : selection == "fn_key" ? "映射到实体遥控按键后，按住会保持 Fn，松开才释放；触控区轻点只会短按。" : selection == "voice_input" ? "使用 Mac 的麦克风开始系统听写；请在键盘设置中将听写快捷键设为按两次 Fn。" : "三个切换动作分别让遥控器触控区模拟双指滚动、三指按住拖移、四指左右切换桌面；再次触发同一动作返回鼠标移动。")
                    .font(.caption).foregroundColor(.secondary)
                    if let error=model.mappingError { Text(error).foregroundColor(.red).font(.caption) }
                }.frame(minWidth:300,maxWidth:.infinity,alignment:.topLeading)
            }.padding(12)
        }
        .alert("恢复所有按键的默认功能？", isPresented: $confirmReset) {
            Button("恢复默认", role: .destructive) { model.resetMappings() }
            Button("取消", role: .cancel) {}
        }
        .sheet(isPresented: $captureShortcut) {
            ShortcutCaptureView { key, flags, label in
                model.setMapping("shortcut:\(key):\(flags)", for: mappingKey)
                if !ProcessInfo.processInfo.arguments.contains("--ui-preview") {
                    UserDefaults.standard.set(label, forKey: "shortcut-label-\(mappingKey)")
                }
                captureShortcut = false
            } cancel: { captureShortcut = false }
        }
    }
}

private struct ShortcutCaptureView: View {
    let recorded: (UInt16, UInt64, String) -> Void
    let cancel: () -> Void
    var body: some View {
        VStack(spacing: 14) {
            Text("录制 Mac 快捷键").font(.headline)
            Text("请按下要映射的按键或组合键，例如 ⌘C。")
            ShortcutKeyView(recorded: recorded).frame(width: 320, height: 56)
                .background(Color.secondary.opacity(0.12)).cornerRadius(8)
            Button("取消", action: cancel)
        }.padding(24).frame(width: 400)
    }
}

private struct ShortcutKeyView: NSViewRepresentable {
    let recorded: (UInt16, UInt64, String) -> Void
    func makeNSView(context: Context) -> KeyCapture {
        let view = KeyCapture(); view.recorded = recorded
        DispatchQueue.main.async { view.window?.makeFirstResponder(view) }
        return view
    }
    func updateNSView(_ view: KeyCapture, context: Context) { view.recorded = recorded }
    final class KeyCapture: NSView {
        var recorded: ((UInt16, UInt64, String) -> Void)?
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.makeFirstResponder(self) }
        override func keyDown(with event: NSEvent) {
            let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
            var label = ""
            if flags.contains(.control) { label += "⌃" }; if flags.contains(.option) { label += "⌥" }
            if flags.contains(.shift) { label += "⇧" }; if flags.contains(.command) { label += "⌘" }
            let key = event.charactersIgnoringModifiers?.uppercased() ?? ""
            label += key.isEmpty || key.unicodeScalars.contains(where: { $0.value < 32 || $0.value >= 0xf700 }) ? "按键 \(event.keyCode)" : key
            recorded?(event.keyCode, UInt64(flags.rawValue), label)
        }
        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            let text = "点击此处后按下快捷键" as NSString
            text.draw(at: NSPoint(x: 70, y: 20), withAttributes: [.foregroundColor: NSColor.secondaryLabelColor])
        }
        override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self) }
    }
}
