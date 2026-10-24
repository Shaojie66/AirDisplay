# M2 本机回环（2026-10-24）

管线：ScreenCaptureKit 抓 AirDisplay 虚拟屏（2880×1864，NV12）→ VideoToolbox 硬件编码 → 打包成线上帧格式 → 解包 → VideoToolbox 硬件解码 → `AVSampleBufferDisplayLayer` 预览窗口（主屏上 1:1 像素）。

打包/解包用的是 M3 走网络时同一套代码（`Shared/Protocol.swift`），只是没经过网络。

## 编码器对比（M4 Max，2880×1864，画面里有 60Hz 刷新的毫秒时钟）

| 配置 | 编码 | 解码 | 抓屏→显示层 | 帧率 |
|---|---|---|---|---|
| HEVC + 低延迟码率控制 | 15.0 ms | 1.7 ms | 17.1 ms | 58 fps |
| **HEVC，不开低延迟（默认）** | **10.9 ms** | 2.1 ms | **13.5 ms** | 58 fps |
| H.264 + 低延迟码率控制 | 14.0 ms | 1.6 ms | ~15.5 ms | 58 fps |
| H.264，不开低延迟 | 12.8 ms | 1.8 ms | 14.9 ms | 58 fps |

- "抓屏→显示层"：从抓屏回调到达，到解码完交给显示层。不含屏幕合成和刷新，也不含 M3 的网络传输。
- `MaxFrameDelayCount=0`、`PrioritizeEncodingSpeedOverQuality` 在这台机器的 HEVC 编码器上都不支持。
- 帧率 58 而不是 60：画面只有时钟在动，ScreenCaptureKit 偶尔判定为没变化，不送帧。

## 画质

同一帧保存编码前、解码后的 PNG 来对比（`-snapshot <tag>` 启动参数，存到本机 `~/Library/Logs/AirDisplay/snapshots/`）：

| 配置 | 文字区域 PSNR | 11pt 小字区域 PSNR |
|---|---|---|
| HEVC + 低延迟 | 44.4 dB | 37.8 dB |
| HEVC 不开低延迟 | 44.7 dB | 38.1 dB |

放大 3 倍看 11pt 中英文混排，编码前后看不出区别（黑字白底，4:2:0）。彩色小字、4:4:4 留到 M4 实验。

## 踩过的坑

- **抓屏时间戳**：`SCStreamFrameInfo.displayTime` 比回调到达时间晚 5–8 ms（指向下一次刷新），不能拿来算延迟。改用回调到达时刻。
- **模态弹窗卡住按钮**：请求屏幕录制权限时用 `NSAlert.runModal()` 会卡住整个 App，改成把提示写在面板上。
- 面板按钮加了 `acceptsFirstMouse`，面板在后台时第一次点击就能触发按钮。

## 调试用启动参数

`AirDisplaySender.app --args --loopback [-codec h264] [-lowLatency YES] [-bitrate 200] [-snapshot tag]`
