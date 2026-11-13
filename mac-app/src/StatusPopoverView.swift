import AppKit
import SwiftUI

struct StatusPopoverView: View {
    @ObservedObject var manager: StatusItemManager
    @State private var editingPIN = false
    @State private var draftPIN = ""
    @State private var pinError: String?
    @FocusState private var pinFocused: Bool

    private var tint: Color { Color(nsColor: manager.connectionState.color) }
    private var mode: String { manager.status?.currentTrackpadMode ?? "mouse" }
    private var badgeTitle: String {
        switch manager.connectionState {
        case .connected: return "已连接"
        case .waiting: return "等待连接"
        case .connecting: return "连接中"
        case .stopped: return "已暂停"
        case .busy: return "处理中"
        }
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) { panelContents }
            .frame(width:330,height:manager.panelHeight)
            .background(Color(nsColor:.windowBackgroundColor))
    }

    private var panelContents: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            device
            HStack(spacing: 3) {
                modeButton("mouse", title: "鼠标", symbol: "cursorarrow")
                modeButton("gyro", title: "陀螺仪", symbol: "gyroscope").disabled(true)
            }
            .padding(3).background(Color.primary.opacity(0.06)).cornerRadius(10)
            if mode == "idle" { Text("当前为轨迹预览，可在控制台调整").font(.caption).foregroundColor(.secondary) }
            Text("仅系统遥控器 · 陀螺仪尚未收到数据").font(.caption).foregroundColor(.secondary)
            HStack { Text("灵敏度").font(.caption); Picker("灵敏度",selection:Binding(get:{SensitivityPreset.nearest(manager.speed).rawValue},set:{manager.setSensitivity($0)})) { ForEach(SensitivityPreset.allCases,id:\.rawValue){p in Text(p.title).tag(p.rawValue)} }.pickerStyle(.segmented).labelsHidden() }
            pinRow
            if let error = pinError {
                Text(error).font(.system(size: 11)).foregroundColor(.red)
            } else if editingPIN && manager.isServiceRunning {
                Text("保存后将重启服务，当前连接会断开。")
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
            permissionRow
            if let message = manager.permissionMessage {
                Text(message).font(.system(size: 11)).foregroundColor(.secondary)
            }
            if let message = manager.operationMessage {
                Text(message).font(.system(size: 11)).foregroundColor(.red)
            }
            Button { manager.openConsole() } label: {
                HStack(spacing: 9) {
                    Image(systemName: "slider.horizontal.3")
                    Text("遥控控制台")
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.system(size: 10))
                }
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.accentColor).padding(12)
                .background(Color.accentColor.opacity(0.09)).cornerRadius(10)
            }.buttonStyle(.plain)
            Divider()
            footer
        }
        .padding(18)
        .frame(width: 330)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { geometry in
            Color.clear
                .onAppear { manager.resizePanel(to:geometry.size) }
                .onChange(of:geometry.size) { manager.resizePanel(to:$0) }
        })
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(spacing: 7) {
            Image(nsImage: StatusRemoteGlyph.image(state: manager.connectionState, size: 26))
                .frame(width: 26, height: 28)
            Text("TVRemoteMouse").font(.system(size: 14, weight: .semibold))
            Spacer(minLength: 2)
            HStack(spacing: 4) {
                Circle().fill(tint).frame(width: 6, height: 6)
                Text(badgeTitle).font(.system(size: 10)).lineLimit(1)
            }.foregroundColor(tint)
        }
    }

    private var device: some View {
        HStack(spacing: 10) {
            Image(systemName: "iphone").font(.system(size: 23, weight: .light)).foregroundColor(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(manager.status?.client_name ?? (manager.isServiceRunning ? "等待 iPhone 连接" : "服务已暂停"))
                    .font(.system(size: 14, weight: .medium)).lineLimit(1)
                Text(manager.status?.session_ready == true ? "可以控制这台 Mac" : (manager.isServiceRunning ? "打开 iPhone 系统遥控器" : "点按下方按钮启动服务"))
                    .font(.system(size: 11)).foregroundColor(.secondary)
            }
        }.padding(.vertical, 5)
    }

    private func modeButton(_ value: String, title: String, symbol: String) -> some View {
        Button { manager.setPointerSource(value) } label: {
            HStack(spacing: 7) {
                Image(systemName: symbol).font(.system(size: 12))
                Text(title).font(.system(size: 12, weight: .medium))
            }
            .frame(maxWidth: .infinity).frame(height: 31)
            .background(manager.pointerSource == value ? Color(nsColor: .controlBackgroundColor) : .clear)
            .cornerRadius(8)
        }.buttonStyle(.plain).disabled(!manager.isServiceRunning || manager.isBusy)
    }

    private var pinRow: some View {
        HStack(spacing: 8) {
            Label("配对 PIN", systemImage: "key").foregroundColor(.secondary)
            Spacer(minLength: 4)
            if editingPIN {
                TextField("四位数字", text: $draftPIN)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(width: 62).textFieldStyle(.roundedBorder)
                    .focused($pinFocused)
                    .onSubmit(savePIN)
                    .onExitCommand { editingPIN = false; pinError = nil }
                Button("保存", action: savePIN).foregroundColor(.accentColor)
                Button { editingPIN = false; pinError = nil } label: { Image(systemName: "xmark") }
                    .help("取消修改")
            } else {
                Text(manager.pairingPIN).font(.system(size: 14, weight: .medium, design: .monospaced)).tracking(2)
                Button("修改") { draftPIN = manager.pairingPIN; editingPIN = true; pinFocused = true }
                    .foregroundColor(.accentColor)
            }
        }
        .font(.system(size: 12)).buttonStyle(.plain)
        .disabled(manager.isBusy)
    }

    private func savePIN() {
        guard PairingSettings.isValid(draftPIN) else { pinError = "请输入四位数字（0000–9999）"; return }
        if manager.savePIN(draftPIN) { editingPIN = false; pinError = nil }
    }

    private var permissionRow: some View {
        HStack {
            Label(manager.accessibilityTrusted ? "辅助功能已授权" : "辅助功能待授权", systemImage: manager.accessibilityTrusted ? "checkmark.shield" : "exclamationmark.shield")
                .foregroundColor(.secondary)
            Spacer()
            Button("检查") { manager.checkPermissions() }.buttonStyle(.plain).foregroundColor(.accentColor)
        }.font(.system(size: 12))
    }

    private var footer: some View {
        HStack {
            Button {
                if manager.isServiceRunning { manager.stopService() } else { manager.startService() }
            } label: {
                Label(manager.isBusy ? "处理中…" : (manager.isServiceRunning ? "暂停服务" : "启动服务"), systemImage: manager.isServiceRunning ? "pause" : "play")
            }
            .buttonStyle(.plain).disabled(manager.isBusy)
            Spacer()
            Menu {
                Button("系统日志") { manager.openLogs() }
                Button("打开日志文件") { manager.openLogFile() }
                Button("重启服务") { manager.restartService() }.disabled(manager.isBusy || !manager.isServiceRunning)
                Button("刷新状态") { manager.refresh() }
                Toggle("状态栏显示文字", isOn: Binding(get: { manager.showStatusTextInBar }, set: manager.setStatusText))
                Divider()
                Button("退出应用") { manager.quit() }
            } label: { Image(systemName: "ellipsis").frame(width: 28, height: 24).contentShape(Rectangle()) }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().help("更多操作")
        }.font(.system(size: 11)).foregroundColor(.secondary)
    }
}

private struct StatusPanelSizeKey: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}
