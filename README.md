# AirDisplay

把一台 Mac 变成另一台 Mac 的有线扩展屏，可以和 iPad 随航（Sidecar）同时用，实现三屏。

- **Sender**（主力 Mac）：用 `CGVirtualDisplay` 创建虚拟显示器 → ScreenCaptureKit 抓屏 → VideoToolbox 硬件编码 → 通过雷雳网桥发送。
- **Receiver**（副 Mac）：接收 → 解码 → 全屏显示。

为什么不用 AirPlay to Mac：它和随航互斥，一连上随航就断开。

> 使用了未公开的私有 API（`CGVirtualDisplay`），不上架 App Store，macOS 大版本更新可能失效。

## 进度

- [x] M0 环境确认（[报告](docs/M0-environment.md)）
- [x] M1 虚拟显示器 + 验证与随航共存（[报告](docs/M1-virtual-display.md)）
- [x] M2 本机回环（抓屏 → 编码 → 解码 → 显示）（[报告](docs/M2-loopback.md)）
- [x] M3 跨机显示（[报告](docs/M3-cross-machine.md)）
- [ ] M4 延迟、画质、重连打磨（进行中，[记录](docs/M4-polish.md)）
- [ ] M5 输入转发（代码完成，待实测，[记录](docs/M5-input.md)）

## 要求

- 两台 Apple 芯片 Mac，用雷雳 / USB4 线直连
- Xcode，Apple Development 签名证书

## 构建

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig   # 填入你的 Team ID
xcodegen generate
xcodebuild -project AirDisplay.xcodeproj -scheme Sender -derivedDataPath build build
open build/Build/Products/Debug/AirDisplaySender.app
```

## 在接收端 Mac 上安装

1. 构建 Receiver：`xcodebuild -project AirDisplay.xcodeproj -scheme Receiver -configuration Release -derivedDataPath build build`
2. 把 `build/Build/Products/Release/AirDisplayReceiver.app` 拷到接收端（隔空投送即可），放进「应用程序」。
3. 第一次打开会被 Gatekeeper 拦下：去 系统设置 → 隐私与安全性，点「仍要打开」。
4. 系统询问「查找本地网络上的设备」时选允许。
5. 连上后自动全屏：`⌃⌥⌘S` 统计浮层，`⌃⌥⌘Q` 退出。
6. 想用接收端的键盘触控板操作主力 Mac：在发送端 系统设置 → 隐私与安全性 → 辅助功能 里打开 AirDisplay Sender。

## 致谢

虚拟显示器的私有 API 声明参考了 [DeskPad](https://github.com/Stengo/DeskPad)。
