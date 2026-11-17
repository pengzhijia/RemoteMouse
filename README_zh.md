# RemoteMouse

> [English Version](README.md) | **中文版本**

RemoteMouse 让 iPhone 或 iPad 在同一局域网内遥控 Mac 和 Windows 电脑。你可以直接使用控制中心自带的「Apple TV 遥控器」，也可以扫码打开网页遥控。网页遥控提供触控板、键盘、语音输入、快捷键和屏幕查看；Mac 版还支持 iPad 触屏与 Apple Pencil。项目源码保留 Android TV 接收端。

## 两种遥控方式

| 方式 | 怎么连接 | 适合做什么 |
| :--- | :--- | :--- |
| **控制中心遥控器** | iPhone/iPad 打开控制中心 → Apple TV 遥控器 → 选择电脑并输入配对码 | 用系统自带界面移动光标、点击和操作媒体按键；也可连接 Android TV 接收端 |
| **网页遥控** | 在电脑的 RemoteMouse 菜单栏或托盘面板选择「网页遥控」→ 打开扫码入口 → 手机用 Safari 扫码 | 触控板手势、键盘与中文输入、语音指令、快捷键、查看电脑屏幕 |

网页遥控无需在手机安装 App。手机与电脑须处于同一局域网；连接链接包含访问令牌，请仅分享给受信任的设备。Mac 首次使用需给 `WebRemoteBridge` 授予辅助功能权限，查看屏幕还需屏幕录制权限。视频模式的本地 HTTPS 证书设置见[网页遥控使用说明](integrations/web-remote/docs/使用说明.md)；Windows 的设置见[Windows 网页遥控说明](integrations/web-remote/windows/README.md)。

<!-- TODO: 把下面的图替换成 15–30 秒实机录屏：
     控制中心 → Apple TV 遥控器 → 选择设备 → 操控电视 / Mac。
     保存为 docs/images/zh/demo.gif 后替换 <img> 的 src。 -->

### iPhone：找到遥控器，开始使用

从屏幕右上角下滑打开控制中心，点击「Apple TV 遥控器」，选择已运行接收程序的设备并完成配对，就可以滑动和点按操作。

| **找到遥控器** | **使用遥控器** |
| :---: | :---: |
| <img src="docs/images/zh/ios_tv_control.jpg" width="220" alt="控制中心中的遥控器入口" /> | <img src="docs/images/zh/ios_apple_tv_remote.png" width="220" alt="iPhone 遥控器操作界面" /> |
| **屏幕右上角下滑**打开控制中心，点击红圈标记的遥控器图标<br>*(若未显示，前往 **设置 → 控制中心** 手动添加)* | 上方触控板滑动导航 / 移动光标<br>下方点按确认、返回、播放、音量等功能按键 |

📖 完整图文教程与演示：[博客文章](https://corvo.myseu.cn/2026/09/27/2026-09-27-%E7%94%A8iPhone%E9%81%A5%E6%8E%A7%E5%99%A8%E6%8E%A7%E5%88%B6%E4%BD%A0%E7%9A%84Android-TV%E5%92%8CMac/)

---

## 下载

macOS 与 Windows 安装包见 [v1.1.0 发布页](https://github.com/pengzhijia/RemoteMouse/releases/tag/v1.1.0)。源码可[下载 ZIP](https://github.com/pengzhijia/RemoteMouse/archive/refs/heads/main.zip)或克隆本仓库。Android TV 版按下方步骤从源码构建。

---

## 兼容性

| | 支持范围 | 说明 |
| :--- | :--- | :--- |
| **遥控端** | 控制中心带原生 **Apple TV 遥控器**的 iPhone / iPad | 手机侧无需安装任何 App |
| **macOS 被控端** | Apple Silicon Mac（发布包）；Intel Mac 可自行编译 | 需授予「辅助功能」权限 |
| **Windows 被控端** | Windows 10/11 x64（托盘应用） | 需允许专用网络访问 |
| **Android 被控端** | Android TV、Google TV、电视盒子、模拟器 | 需开启网络 ADB，见[功能限制](#功能限制) |
| **网络** | 遥控端与被控端处于同一局域网 | 需关闭 AP 隔离 / 访客网络 |

**已测试机型** <!-- TODO: 补充你的真实测试矩阵，例如 iOS 17.x / macOS 14 (Apple Silicon) / 索尼 Bravia Google TV、小米盒子、模拟器 API 30 -->：

- iOS / iPadOS：_待补充_
- macOS：_待补充_
- Android TV 设备：_待补充_

### 功能限制

- **Android TV 必须开启网络 ADB。** Android 禁止普通应用向其它 App 注入方向键 / 确认键，因此按键注入依赖本地 ADB 通道；无障碍服务仅作兜底，并负责全局返回 / 主页动作。完整步骤见 [Android TV 前置要求](#android-tv)。
- **配对使用固定 PIN。** iPhone 提示输入配对码时，输入 **`1111`** 即可。
- v1.1.0 macOS 发布包使用临时签名，首次启动 Gatekeeper 可能告警，并需为此构建重新授予辅助功能权限，见 [macOS 前置要求](#macos)。

---

## 快速上手

1. 从[发布页](#下载)安装桌面版；Android TV 接收端按[从源码构建](#从源码构建)编译安装。
2. **让 iPhone 与被控端接入同一 Wi-Fi**（关闭 AP 隔离）。
3. **授予权限**——macOS 授予辅助功能；Android TV 开启网络 ADB 并在弹窗中点「始终允许」。详见下文。
4. **打开控制中心找到遥控器**：
   - 屏幕右上角向下滑动呼出**控制中心**，点击红圈标记的 **Apple TV 遥控器** 图标。
   - *(若控制中心未显示该图标，去 iOS **设置 → 控制中心**，在「更多控制」中添加「Apple TV 遥控器」即可)*。
   - 顶部选择你的目标设备，提示配对码时输入 **`1111`** 即可开始使用。

### macOS

v1.1.0 发布包使用临时签名。安装后如果 macOS 阻止打开，请在「系统设置 → 隐私与安全性」中选择允许打开；仍提示应用损坏时，可在终端执行：

```bash
xattr -dr com.apple.quarantine /Applications/RemoteMouse.app
```

然后授予 **系统设置 → 隐私与安全性 → 辅助功能 → RemoteMouse**（用命令行调试则勾选终端）。网页遥控还需为 `WebRemoteBridge` 单独授权；看屏幕时授予屏幕录制权限。

### Windows

完整解压 `RemoteMouse-windows-x64.zip`，运行 `RemoteMouse.exe`。程序在系统托盘运行；打开托盘面板即可切换「遥控器遥控 / 网页遥控」。首次运行时请在 Windows 防火墙弹窗中**允许专用网络访问**，否则手机无法连接。

> 已支持：系统托盘右键菜单（启停模拟服务、切换触控板模式、开机自启、查看日志、退出）、方向键 / 确认 / 返回 (Esc)、鼠标光标与点击、播放暂停（双击下一曲、三击上一曲）、音量 / 静音、电源键关闭/唤醒显示器。

### Android TV

1. **开启开发者选项**：系统设置 → 关于 → 连续点击**内部版本号** 7 次。
2. **开启 USB 调试与网络调试**：系统设置 → 系统 → 开发者选项。
3. 安装并启动 APK。首次运行会弹出 Android 安全对话框——用电视遥控器勾选**「始终允许来自此计算机」**并点**允许**。（点拒绝会导致 `Unauthorized`，遥控失效。）
4. *（可选兜底）*开启无障碍服务：主界面 → **ACCESSIBILITY SETTINGS** → 找到 **Apple TV Remote Receiver** → 打开。

> **为什么需要 ADB？** Android 禁止普通应用向第三方影视 App 注入全局方向键 / 确认键。内置的 `dadb` 驱动连接 `127.0.0.1:5555`，直接派发 Linux keycode（本地回环实测 <8 ms）。无障碍服务无法独立完成这件事，只能作兜底与全局返回 / 主页动作。

---

## 按键与手势映射

| Apple TV 遥控器动作 | Android TV | macOS |
| :--- | :--- | :--- |
| **滑动（方向模式）** | `KEYCODE_DPAD_UP/DOWN/LEFT/RIGHT` | 方向键 `↑ ↓ ← →` |
| **滑动（鼠标模式）** | 触摸拖拽 / 光标 | `CGEvent` 平滑光标 |
| **双指滑动** | 屏幕滚动手势 | 鼠标滚轮滚动 |
| **双指轻点** | 确认 | 鼠标左键 |
| **轻触 / SELECT** | `KEYCODE_DPAD_CENTER` | 回车 / 鼠标左键 |
| **返回（`<`）** | `GLOBAL_ACTION_BACK` | `Escape` |
| **电视 / Home** | `GLOBAL_ACTION_HOME` | 桌面 / 可自定义 |
| **单击 ⏯** | `KEYCODE_MEDIA_PLAY_PAUSE` | 播放 / 暂停（`NX_KEYTYPE_PLAY`） |
| **双击 ⏯** | 下一集 / 快进 | 下一曲（⏭） |
| **三击 ⏯** | 上一集 / 快退 | 上一曲（⏮） |
| **音量 +/-** | `KEYCODE_VOLUME_UP/DOWN` | 主音量 + 原生 HUD |
| **静音** | `KEYCODE_VOLUME_MUTE` | 系统静音 |
| **侧边 Siri 键** | 语音搜索（`KEYCODE_SEARCH`） | 切换 光标 ⇄ 方向键 / Siri |
| **电源** | `GLOBAL_ACTION_POWER_DIALOG` | 屏幕睡眠 / 唤醒 |

---

## 从源码构建

```bash
# macOS —— 打包独立 DMG
./scripts/build_dmg.sh
# → build/RemoteMouse-arm64.dmg，拖入 /Applications

# Android TV —— 编译并安装 APK
./scripts/build_android.sh
adb install -r android-tv/app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n com.corvofeng.fakeatv/.MainActivity
```

---

<details>
<summary><h2 style="display:inline">开发者文档与实现原理</h2></summary>

### Android 模拟器桥接

在 Android Studio 的 Android TV AVD 中测试时使用（物理设备无法发现模拟器隔离的 NAT 子网 `10.0.2.15`）：

```bash
# 1. 启动 Android TV AVD（API 30+），用 adb devices 确认
# 2. 安装接收端
./scripts/build_android.sh
adb -s emulator-5554 install -r android-tv/app/build/outputs/apk/debug/app-debug.apk
adb -s emulator-5554 shell am start -n com.corvofeng.fakeatv/.MainActivity

# 3. 启动桥接守护进程
python3 scripts/bridge_emulator.py start        # 或 start -f（前台实时日志）
python3 scripts/bridge_emulator.py status       # 端口转发与 mDNS 状态
python3 scripts/bridge_emulator.py logs -f      # 跟踪日志
python3 scripts/bridge_emulator.py stop         # 停止
```

随后在 iPhone → 控制中心 → Apple TV 遥控器 → 选择 **`Android TV Emulator`** → 输入 PIN `1111`。

桥接通过 `adb forward` 透传 `49152/49153/49154` 端口，并把 Bonjour 记录（`_mediaremotetv._tcp`、`_companion-link._tcp`）代理广播到物理 Wi-Fi，因此 iPhone 连接宿主机后会被透明路由到模拟器。

![模拟器桥接工作流](docs/images/zh/emulator_operation_flow.svg)

### RemoteMouse Web 控制面板（端口 18765）

启动菜单栏 App 后，浏览器访问 **`http://127.0.0.1:18765`**：

![macOS Web Inspector](docs/images/zh/mac_browser_inspector.png)

- 实时触摸矢量画布：手指坐标、手势阶段（`Began`/`Moved`/`Ended`）、速度矢量与方向判定。
- 网页端虚拟遥控器，无需拿手机即可触发 Mac / 电视响应。
- 动力学预设：`0.5x 精准`、`1.0x 标准`、`1.5x 快速`、`2.2x 极速大屏`。
- 已连接设备信息与实时音量遥测。

### RemoteMouse 宿主诊断（端口 18766）

访问 **`http://127.0.0.1:18766`** 查看进程健康、端口绑定与实时协议握手：

![macOS 宿主诊断](docs/images/zh/mac_debug_web_page.png)

- 会话跟踪：Companion 客户端接入、SRP 认证、MRP 加密信道建立。
- 进程遥测：核心 API（`18765`）、Web 调试（`18766`）、MediaRemote（`49152`）、后台 PID、日志过滤、重启控制。

### 触摸板手势与焦点累加

Companion Link 协议以高频流式发送增量坐标。`atv-core` 将其转换为网格焦点移动（Android TV）或带加速度的光标位移（macOS）：

![手势与页面移动流程](docs/images/zh/page_navigation_movement.svg)

1. **增量累加器**——聚合微位移，抑制抖动与误触。
2. **方向死区**——判定水平 / 垂直意图，过滤对角噪声。
3. **平台分发**——Android TV 触发 `KEYCODE_DPAD_*`；macOS 按速度计算加速度曲线并通过 `CGEvent` 派发。

### 驱动调度层级

![驱动层级与权限](docs/images/zh/prerequisites_and_permissions.svg)

- **Android**——首选：`dadb` 回环连接 `127.0.0.1:5555` 直接派发 keycode；兜底：无障碍服务处理全局窗体动作。
- **macOS**——辅助功能 API（`CGEvent`）驱动光标 / 键盘；CoreAudio / MediaRemote 联动硬件音量与媒体 HUD。

### Android TV 看板与配置

| 主仪表板 | 按键注入模式 | Menu 键映射 |
| :---: | :---: | :---: |
| ![主界面](docs/images/zh/android_tv_main_screen_ready.png) | ![注入模式](docs/images/zh/android_tv_injection_mode_dialog.png) | ![Menu 键绑定](docs/images/zh/android_tv_menu_binding_dialog.png) |

- **驱动健康状态**：`/dev/input/event*`、本地 `dadb`（`127.0.0.1:5555`）、`AtvAccessibilityService`。
- **注入策略**：*仅本地 ADB*、*仅无障碍*、*ADB 优先（无障碍兜底）*、*硬件优先*。
- **Menu 键重映射**：将 播放/暂停、Home 或 静音 映射为 `KEYCODE_MENU`，适配老电视应用。

**无障碍设置界面：**

| 服务列表 | 授权确认 | 就绪状态 |
| :---: | :---: | :---: |
| ![服务列表](docs/images/zh/android_tv_accessibility_service_list.png) | ![授权确认](docs/images/zh/android_tv_permission_dialog.png) | ![就绪](docs/images/zh/android_tv_main_screen_ready.png) |

</details>

---

## 常见问题排查（FAQ）

**控制中心找不到设备？**
1. 确认 iPhone 与被控端在同一 Wi-Fi 子网（关闭 AP 隔离 / 访客模式）。
2. macOS 上运行 `dns-sd -B _mediaremotetv._tcp` 检查 Bonjour 广播。
3. 模拟器场景检查桥接：`python3 scripts/bridge_emulator.py status`。

**电视按键无反应 / ADB 连接失败？**
1. 确认开发者选项里「网络调试」与「USB 调试」已开启。
2. 重启应用，留意 RSA 指纹授权弹窗——勾选**「始终允许」**并点**允许**。
3. 若无弹窗，从电脑执行 `adb connect <电视IP>:5555` 触发首次信任。

**Android TV 找不到无障碍设置？**
部分定制系统隐藏了该菜单。使用应用内的「ACCESSIBILITY SETTINGS」弹窗，或执行：
```bash
adb shell settings put secure enabled_accessibility_services com.corvofeng.fakeatv/.AtvAccessibilityService
adb shell settings put secure accessibility_enabled 1
```

**macOS 提示应用损坏 / 来自不受信任的开发者？**
```bash
xattr -dr com.apple.quarantine /Applications/RemoteMouse.app
```

---

## 许可证

MIT。仅供技术学习与局域网设备互通研究使用。

## RemoteMouse Windows 原生版

Windows 10/11 x64 原生托盘面板和 WPF 遥控控制台已与自定义 macOS 版同步；使用方法、构建方式和实测限制见 [Windows 说明](windows-app/README.md)。构建包为 build/RemoteMouse-windows-x64.zip，解压全部文件后运行 RemoteMouse.exe。

## 网页遥控与屏幕查看

桌面版现已集成 `integrations/web-remote` 的网页遥控功能。启动 RemoteMouse 后，状态栏或托盘面板提供「遥控器遥控 / 网页遥控」切换；选择网页遥控即可扫码、复制链接、查看授权和调整相关设置。网页支持触控板、键盘、中文输入、语音指令、快捷键、屏幕查看，以及原项目提供的 iPad 触屏和 Pencil 操作。Mac 的网页服务由同一 App 启停，Windows 版作为打包在同一目录内的后台组件运行，网页服务默认使用 HTTP 8765 和 HTTPS 8766 端口。控制中心 Apple TV 遥控器继续由原有 `atv-cli` 提供。

Mac 首次使用网页控制需给 `WebRemoteBridge` 单独授予辅助功能权限；看屏幕还需屏幕录制权限。视频模式的本地证书设置见 [网页遥控使用说明](integrations/web-remote/docs/使用说明.md)。macOS 网页服务要求 macOS 13 或更新版本。watchOS 体感鼠标实验项目和快捷指令生成脚本保留在 `integrations/web-remote/watch` 与 `integrations/web-remote/shortcuts`，不随桌面构建包自动安装。
