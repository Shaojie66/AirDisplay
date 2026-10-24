# M1 虚拟显示器（2026-10-24）

## 结果：通过（自动检查部分）

Sender 用 `CGVirtualDisplay` 创建名为 "AirDisplay" 的虚拟屏，`system_profiler SPDisplaysDataType` 显示：

| 显示器 | 分辨率（像素） | 看起来像 | 刷新率 |
|---|---|---|---|
| Pro 内建屏（主屏） | 3456×2234 | — | — |
| **AirDisplay** | 2880×1864 | 1440×932 | 60 Hz |
| Sidecar（iPad） | 2388×1668 | 1194×834 | 60 Hz |

- **虚拟屏与随航共存**：三块屏同时在线，持续 20 秒随航没有断开。
- **退出后清理**：Sender 进程退出（包括被 kill）后虚拟屏立即消失，随航不受影响。
- 签名：Apple Development 固定签名，Team ID 来自本地 `Config/Local.xcconfig`。

## 实现要点

- 私有类方法名已用 ObjC runtime 在 macOS 26.6 上核对，和 DeskPad 的声明一致。Swift 里 `applySettings:` 被自动重命名为 `apply(_:)`。
- `hiDPI = 1` 时，提供 2880×1864 的像素模式，系统会生成 1440×932 @2x；启动后用 `CGConfigureDisplayWithDisplayMode` 显式切到这个模式。
- 物理尺寸设为 327×211 mm（15" Air，224 ppi）。

## 待用户手动确认

- [ ] 菜单栏图标 → 开启虚拟屏，窗口能拖到 AirDisplay 上，鼠标能滑过去
- [ ] 同时窗口也能拖到 iPad 上
- [ ] 系统设置 → 显示器 里能看到 AirDisplay，可以调整排列位置
