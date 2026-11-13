# TVRemoteMouse for Windows

Windows 10/11 x64 原生 WPF 控制台和托盘面板，附带 .NET 桌面运行时，无需单独安装 .NET。解压整个目录后启动 `TVRemoteMouse.exe`，保留所有随附文件。

在同一局域网中，打开 iPhone 控制中心的 Apple TV 遥控器，选择本机计算机名称。默认 PIN 为 1111，可在托盘面板修改。保存新 PIN 后服务重启，当前连接暂时断开；已配对设备可能不会再次要求输入 PIN。PIN、外观和按键映射保存在 `%LOCALAPPDATA%\TVRemoteMouse`，不会覆盖 macOS 设置。

点击托盘可切换鼠标/方向键模式、查看设备名称、修改 PIN、检查运行权限，打开原生遥控控制台。面板按内容自动调整高度；绿色已连接、蓝色等待、橙色处理中/连接中、红色停止。更多菜单提供日志、重启、开机启动和退出。开机启动菜单再次点击即取消。

控制台包含 iOS 16 / 新版外观、触摸 / 方向键控制区，接收真实触摸/方向输入后自动切换。iPhone 未报告 iOS 版本时显示提示并允许手动选择；不能仅凭手机型号推断系统版本。可查看协议事件和每个实际报告触点的轨迹，调节灵敏度、加速度、详细日志，测试/恢复映射，录制 Ctrl / Alt / Shift / Win 组合键。

双指轻点默认右键；三指、四指默认不执行操作，可各自设置。只有手机发送可区分的多个触点时才能识别三指、四指或画多条轨迹；系统遥控器未发送的数据无法补全。返回/主页支持双击映射，配置后单击最多等待 380ms。可将任意输入映射为“切换鼠标移动/滚动”，再按一次恢复移动。

Windows 普通桌面无 macOS 辅助功能授权流程。要控制管理员窗口，本工具也需要同等权限；不自动申请提权。首次运行按 Windows 提示允许程序在专用网络中通过防火墙。“检查”解释输入权限并打开 Windows 安全中心的防火墙界面。程序不自动修改防火墙规则。

日志：`%LOCALAPPDATA%\TVRemoteMouse\config\atv\atv-cli.log`。退出只终止本程序启动的核心进程。

## 构建和验证

- Windows：Rust stable、Visual Studio C++ Build Tools、.NET 10 SDK，运行 `powershell -File scripts/build_windows.ps1`。
- macOS 交叉编译：Rust 的 `x86_64-pc-windows-gnu` target、mingw-w64、.NET 10 SDK，运行 `scripts/build_windows.sh`。可用 `TVREMOTE_DOTNET` 指定 SDK 路径。
- 图标来自 macOS 已批准图标的透明圆角版本；修改后在 macOS 执行 `swift scripts/generate_windows_icon.swift` 同步 ICO。Windows 构建直接使用仓库内 ICO。
- 当前完成 Windows x64 交叉编译及共享 Rust 核心测试；Windows 界面、iPhone 配对、输入注入和防火墙仍需在真实 Windows 设备验证。安装包未做 Windows 代码签名。

权限行为参考：[Microsoft 输入注入权限说明](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput)。跨平台构建参考：[EnableWindowsTargeting](https://learn.microsoft.com/en-us/dotnet/core/tools/sdk-errors/netsdk1100)。

## 鼠标 / 陀螺仪验收版

控制模式更新为鼠标/陀螺仪，控制区统一触摸样式。从托盘“连接 iPhone 陀螺仪”复制 HTTPS 采集地址到手机 Safari；确认本地自签名证书并允许运动权限。陀螺仪数据来自这个前台页面，不是系统 Apple TV 遥控器提供。切到系统遥控器后采样可能暂停。捏合/三指滑动在采集页通过快捷键模拟缩放与桌面功能，不等同完整原生触控板。运动轴向和灵敏度需实测调整。
