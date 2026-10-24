# AirDisplay：把 MacBook Air 变成 MacBook Pro 的有线扩展屏

> 本文件是项目说明，给在这个文件夹里工作的 Claude Code 读。和用户沟通请用中文。

## 1. 要做什么

自制一个类似 Luna Display（Mac-to-Mac 模式）的软件方案：

1. 在 **MacBook Pro** 上创建一块**虚拟显示器**，macOS 把它当成真的外接屏（窗口能拖过去、鼠标能滑过去）。
2. 抓取这块虚拟屏的画面，用硬件编码器压缩，通过两台 Mac 之间的**雷雳网桥（Thunderbolt Bridge）**发送。
3. **MacBook Air** 上的接收程序解码后全屏显示。

最终目标是三屏同时工作：**Pro 本机屏幕 + iPad（随航 Sidecar）+ Air（AirDisplay）**。

## 2. 为什么不用现成方案（已经讨论并排除）

| 方案 | 排除原因 |
|---|---|
| 苹果"隔空播放到 Mac"（AirPlay to Mac） | 能把 Air 当扩展屏，但**和 iPad 随航互斥**：用户实测，Air 一连上，随航就断开 |
| 通用控制（Universal Control） | 只是共用键鼠，不是扩展屏；用户担心文件分散在两台机器上 |
| Deskreen 等浏览器方案 | 延迟高，用户明确不想要卡顿 |
| Luna Display | 需要买硬件；用户想自己做 |
| Sunshine + Moonlight | macOS 上是实验性质；用户选择自己写 |

用户最在意的两件事：**低卡顿**、**文字清晰**。

## 3. 设备情况

- **发送端（Sender）**：16 英寸 MacBook Pro，Apple M4 Max，macOS 26.6.2，Xcode 26.3。内建屏默认分辨率 1728×1117。
- **接收端（Receiver）**：MacBook Air 15 英寸 M3（2024）。屏幕原生分辨率 2880×1864。
- **iPad**：通过随航连在 Pro 上，作为另一块副屏，**必须继续可用**。
- **连接**：两台 Mac 用一根雷雳 / USB4 线直连，链路 40 Gb/s，雷雳网桥已建立，ping 平均约 0.6 ms（M0 已确认，见 `docs/M0-environment.md`）。
- **网络坑**：Wi‑Fi（en0）上也有 169.254/16 路由，系统默认把这个网段的流量走 Wi‑Fi。代码里必须把连接绑定到 bridge0（`NWParameters.requiredInterface`），不能只按 IP 连。
- 两台登录同一个 Apple 账户。
- **Claude Code 只在 Pro 上运行**，Air 那一端的安装和测试需要用户动手。

## 4. 架构

两个 App 加一个共享模块。

### 4.1 Sender（Pro 上，菜单栏 App）

1. **虚拟显示器**：使用 `CGVirtualDisplay`（CoreGraphics 里**未公开的私有 API**），需要在桥接头文件里自己声明 `CGVirtualDisplay`、`CGVirtualDisplayDescriptor`、`CGVirtualDisplaySettings`、`CGVirtualDisplayMode`。可参考开源项目 DeskPad（github.com/Stengo/DeskPad）的声明和用法。
   - 显示器命名为 "AirDisplay"。
   - 默认模式：1440×932 点 @2x，即 2880×1864 像素，和 Air 屏幕像素一一对应，文字最清楚。之后可以加其他缩放档位。
   - 刷新率 60Hz。
2. **抓屏**：ScreenCaptureKit，`SCStream` 只抓虚拟显示器这一块。
   - 输出尺寸等于虚拟屏的像素尺寸，`minimumFrameInterval` = 1/60，`showsCursor = true`（光标画进画面里），`queueDepth` 尽量小。
   - 只处理状态为 `.complete` 的帧。画面静止时不发新帧，省带宽。
3. **编码**：VideoToolbox `VTCompressionSession`，使用硬件编码。
   - 开启 RealTime，关闭帧重排（不用 B 帧），尽量使用低延迟码率控制（`EnableLowLatencyRateControl`，先确认当前系统上 H.264 / HEVC 是否支持）。
   - 雷雳网桥带宽充足，码率可以设得很高（先试 100–300 Mbps），优先保证文字清晰。
   - 在客户端连上时，以及客户端请求时，发关键帧。
   - **画质实验项**：4:4:4 色度、更高码率等方案对彩色小字的改善，要实测再定。
4. **传输**：Network.framework。
   - v1 用 TCP + `TCP_NODELAY`。线直连基本不丢包，TCP 足够，实现也最简单。
   - 每帧加长度前缀：帧号、抓取时间戳、是否关键帧、数据长度，后面跟编码数据。关键帧前带上参数集（SPS/PPS/VPS）。
   - 发现机制：Bonjour（`_airdisplay._tcp`），**优先走雷雳网桥接口**（通常是 `bridge0`，地址是 169.254.x.x）。默认不走 Wi‑Fi。
5. **菜单栏界面**：开始/停止、分辨率、码率，统计信息（fps、编码耗时、实际码率）。
6. 客户端断开时移除虚拟显示器，让窗口回到主屏。也可以做成选项。
7. **权限**：需要"屏幕录制"权限。

### 4.2 Receiver（Air 上，App）

1. 用 `NWBrowser` 找到 Sender，通过雷雳网桥连接。
2. **解码和显示**：v1 用 `AVSampleBufferDisplayLayer`，直接把压缩数据喂给它，并设置 `kCMSampleAttachmentKey_DisplayImmediately`，实现最简单、延迟也低。以后如果需要更细的控制，再换成 `VTDecompressionSession` + Metal。
3. 无边框全屏窗口，隐藏 Air 自己的光标（光标已经画在画面里），用 IOPMAssertion 防止休眠，按快捷键退出。
4. 可以开关的统计浮层。
5. **v1 不做输入转发**：用户用 Pro 的触控板和键盘就行，因为系统把虚拟屏当真显示器，光标会自然滑过去。

### 4.3 Shared

协议定义（帧头格式、控制消息比如请求关键帧），两个 App 共用。

## 5. 工程注意事项

- **用正式的 .app 工程（Xcode 项目），不要用裸的命令行可执行文件。** 屏幕录制权限是和代码签名绑定的：如果用临时签名，每次重新编译签名都会变，系统会反复要求重新授权。请用用户 Xcode 里的 Apple Development 证书做固定签名。
- 用了私有 API，需要关闭 App Sandbox。这个 App 不上架 App Store。
- Receiver 在 Pro 上编译好以后，要拷到 Air 上运行（隔空投送，或者通过雷雳网桥的文件共享）。第一次打开可能被 Gatekeeper 拦截，需要告诉用户怎么放行。
- 用 git 管理，提交粒度小一点。
- **不要自己去改系统设置**。需要用户操作的地方（授权屏幕录制、放行 App、Air 上的设置）写清楚步骤，交给用户做。

## 6. 里程碑

每个里程碑结束后，请用户实测并反馈，再进入下一个。

- **M0 环境确认**
  - `sw_vers`、芯片型号（`sysctl -n machdep.cpu.brand_string`）。
  - 雷雳网桥：`ifconfig bridge0` 有没有 169.254.x.x 地址，能不能 ping 通 Air。如果网桥没建立，大概率是线材不是雷雳 / USB4 线，要告诉用户换线。
  - 可选：用 iperf3 测一下网桥带宽。
- **M1 虚拟显示器（关键的"做不做得下去"测试）**
  - Sender 创建 "AirDisplay" 虚拟屏，在 系统设置 → 显示器 里能看到，能把窗口拖进去。
  - **必须验证：虚拟屏和 iPad 随航能同时工作。** 如果有冲突，先停下来，向用户汇报。
- **M2 本机回环**：在 Pro 上跑通 抓屏 → 编码 → 解码 → 在一个窗口里显示。测编码和解码耗时，看文字清晰度。
- **M3 跨机**：Receiver 跑在 Air 上，通过网桥连接，全屏显示。
- **M4 打磨**
  - 延迟测量：两台机器的时钟不同步，简单的办法是在两块屏幕上同时显示一个毫秒计时器，用手机拍下来对比。
  - 码率和画质调优，静止画面的处理，断线自动重连，插线自动连接，防休眠。
- **M5 可选**：Air 的键盘 / 触控板输入转发到 Pro，开机自启动。

## 7. 成功标准

- 三屏同时稳定工作：Pro + iPad（随航）+ Air（AirDisplay）。
- 端到端延迟：目标 ≤ 2 帧（约 33 ms），可以接受 ≤ 50 ms。拖动窗口没有明显拖影。
- 静态文字和 Air 本机显示的清晰度很难看出区别。
- 稳定 60fps，Pro 上的 CPU 占用尽量低。
- 拔线或断开后窗口回到主屏，重新插上能自动恢复。

## 8. 已知风险

- `CGVirtualDisplay` 是私有 API，macOS 大版本更新可能会改坏它。出问题时参考 DeskPad、BetterDisplay 的跟进方式。
- 虚拟屏和随航能否共存还没验证，M1 优先测。
- 线材可能不支持雷雳网桥。
- 屏幕录制权限和签名绑定（见第 5 节）。

## 9. 仓库与隐私规则

本项目同步到 GitHub **公开仓库**。提交前必须遵守：

- **不能进仓库的内容**：电脑名、用户名、真实姓名、邮箱、Apple ID、开发者 Team ID、证书名、签名身份哈希、序列号、MAC 地址、具体 IP（只写"169.254 网段"）、本机绝对路径（如 `/Users/<name>/...`）。
- Xcode 工程里的 `DEVELOPMENT_TEAM` 不写进 `project.pbxproj`，放在被忽略的 `Config/Local.xcconfig` 里（仓库只提交 `Config/Local.xcconfig.example`）。
- `xcuserdata/`、`DerivedData/`、构建产物、`.env`、证书文件（`.p12`/`.cer`/`.mobileprovision`）由 `.gitignore` 排除。
- 测试报告、日志贴进 `docs/` 前先脱敏。
- 每次 push 前跑一遍：`git diff --cached | grep -nE '/Users/|169\.254\.[0-9]+\.[0-9]+|[0-9a-f]{2}(:[0-9a-f]{2}){5}|DEVELOPMENT_TEAM = [A-Z0-9]'`，有命中就先处理。

## 10. 目录约定

```
AirDisplay/
├── CLAUDE.md          项目说明（本文件）
├── README.md          对外介绍
├── docs/              里程碑报告（已脱敏）
├── Config/            xcconfig；Local.xcconfig 不提交
├── Shared/            协议定义（两个 App 共用）
├── Sender/            Pro 上的菜单栏 App
└── Receiver/          Air 上的接收 App
```
