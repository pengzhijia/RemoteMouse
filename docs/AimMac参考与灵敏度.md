# AimMac 参考与灵敏度

## 已采用

Mac 指针移动与鼠标按下/释放改用 AimMac `InputEngine.swift` 的鼠标部分，保留其 16 ms 平滑时间常数、240 Hz 更新定时器、相对真实光标移动、按键先结算剩余位移和按住超时释放。显示范围使用其 `DisplayMap.swift`。保留 MIT 许可及来源说明。

灵敏度只显示低、中、高，直接采用其 AppDelegate 中的 0.7、1.0、1.5。旧数值启动时归到最近档；设置保存在原配置内。Mac 控制台和状态栏均提供三档选择。原 Rust 到 Swift 路径的重复加速与绝对坐标移动已在主路径跳过，点击跟随 Swift 当前光标。

Windows 同步三档与线性倍率；没有移植仅 macOS 可用的 CoreGraphics 平滑引擎，因此不宣称手感完全相同。

## 多指为何不能只复制接收端

AimMac 的 `Apple/iOS/TrackpadSurface.swift` 用启用多点触控的 UIView 读取 UITouch 集合，并在手机上判定滚动、捏合等动作。`Shared/Protocol.swift` 定义的是它自己的 BLE GATT 服务和加密操作报文，主要发送 move/scroll/down/up 等操作结果，而不是保证向 Mac 传送每根手指的原始轨迹。

这需要运行它的 iPhone App；控制中心的系统遥控器不会因为电脑广播该服务，就改用这套 UUID 和报文。当前要求仍只使用系统遥控器，因此没有接入 AimMac 手机 App 或替换其系统发送端。

## 蓝牙及协议边界

苹果当前 Apple TV Remote 设置说明要求 iPhone 与目标在同一个 Wi-Fi 网络。暂无已验证方案可让控制中心遥控器改用 AimMac 自定义 BLE 服务完成纯蓝牙输入。实体 Siri Remote 的蓝牙连接不能作为 iPhone 系统遥控器的依据。

电脑端可以修正 Companion 解码、处理实际存在的事件、实现已知能力协商；不能仅修改接收端就让未修改的系统发送端产生新的多指轨迹或陀螺仪报文。当前尚未找到可确认启用这些数据的协商开关。

参考：
- https://support.apple.com/en-ca/108778
- https://developer.apple.com/documentation/corebluetooth

## 验收

1. 打开新版本，在控制台选低、中、高，分别以相似幅度滑动；确认位移大小变化。
2. 重新打开控制台、重启服务后确认所选档位保留。
3. 运行时仍通过系统遥控器连接；本包不代表纯蓝牙或原生多指已解决。
