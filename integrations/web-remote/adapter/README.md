# 网页遥控集成边界

`../WatchBridge.swift` 与用户提供的 `mac-remote-windows/WatchBridge.swift` 保持逐字节一致。`../web/remote.html` 也保持逐字节一致。构建 macOS App 时，`scripts/build_app.sh` 只对临时编译副本应用 `mac-embedded.patch`，以隐藏第二个状态栏图标、关闭重复的 Apple TV 接收端，并把原有菜单动作转发到 RemoteMouse 主面板。触控、键盘、语音、屏幕回传、证书和 HTTP/WebSocket 逻辑未修改。

Windows 的 `input.rs`、`commands.rs`、`screen.rs`、`server.rs`、`h264.rs`、`tls.rs`、`util.rs` 和网页文件均保持原样。`main.rs` 增加 `--embedded`、`--show-qr` 和 `--copy-link` 桌面启动方式；`tray.rs` 只公开原有二维码与复制链接函数。原始的 `main.rs` 与 `tray.rs` 保存在本目录，便于直接对照。

RemoteMouse 主界面仅组织两种遥控方式的入口和授权按钮。网页遥控的授权集中在「网页遥控授权」区域；每个按钮仍调用原项目的授权流程。
