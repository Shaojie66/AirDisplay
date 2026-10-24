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

## 窗口与鼠标（程序化验证）

用户不在机器旁，改用程序验证（Sender 带 `--start --test-windows` 启动，在每块屏放一个测试窗口）：

| 屏幕 | 全局坐标范围（点） | 测试窗口落点 | 鼠标移到中心 |
|---|---|---|---|
| 内建屏（主屏） | (0, 0) 1728×1117 | 在屏内 ✅ | ✅ |
| Sidecar | (1728, 95) 1194×834 | 在屏内 ✅ | ✅ |
| AirDisplay | (-1440, 0) 1440×932，位于主屏左侧 | 在屏内 ✅ | ✅ |

## 修过的问题

- 第一次实现在主线程上阻塞等待显示模式登记，但虚拟屏的回调也在主线程，导致模式列表一直为空、报"开启失败"。改为异步重试；找不到时保持系统默认（系统默认本来就是 1440×932 @2x）。
- 日志同时写到 `~/Library/Logs/AirDisplay/sender.log`，方便远程排查。

## 待用户手动确认（可选）

- [ ] 用触控板把窗口拖到 AirDisplay（主屏左侧）和 iPad 上
- [ ] 系统设置 → 显示器 里调整 AirDisplay 的排列位置
