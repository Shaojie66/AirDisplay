# AirDisplay

把一台 Mac 变成另一台 Mac 的有线扩展屏，可以和 iPad 随航（Sidecar）同时用，实现三屏。

- **Sender**（主力 Mac）：用 `CGVirtualDisplay` 创建虚拟显示器 → ScreenCaptureKit 抓屏 → VideoToolbox 硬件编码 → 通过雷雳网桥发送。
- **Receiver**（副 Mac）：接收 → 解码 → 全屏显示。

为什么不用 AirPlay to Mac：它和随航互斥，一连上随航就断开。

> 使用了未公开的私有 API（`CGVirtualDisplay`），不上架 App Store，macOS 大版本更新可能失效。

## 进度

- [x] M0 环境确认（[报告](docs/M0-environment.md)）
- [ ] M1 虚拟显示器 + 验证与随航共存
- [ ] M2 本机回环（抓屏 → 编码 → 解码 → 显示）
- [ ] M3 跨机显示
- [ ] M4 延迟、画质、重连打磨
- [ ] M5 输入转发（可选）

## 要求

- 两台 Apple 芯片 Mac，用雷雳 / USB4 线直连
- Xcode，Apple Development 签名证书

## 致谢

虚拟显示器的私有 API 声明参考了 [DeskPad](https://github.com/Stengo/DeskPad)。
