# M6 与 macOS 屏幕共享共存（2026-10-27）

问题：AirDisplay 开着一块 `CGVirtualDisplay` 虚拟屏并且正在推流时，macOS 自带的屏幕共享还能不能正常抓屏幕？反过来，屏幕共享进行中，AirDisplay 的抓屏-编码链路会不会被拖慢？

## 实测环境

- 发送端：MacBook Pro `Mac16,5`，Apple M4 Max，macOS 26.6.2（build 25G83）
- 虚拟屏：`AirDisplay` 2880×1864（1440×932 @2x），60 Hz
- 编码：HEVC，不开低延迟码率控制（项目默认）
- 屏幕共享：macOS 内置「屏幕共享」，观看端是另一台 Mac，经 Tailscale 连接，实测走 DERP 中继（伦敦，约 25 ms）
- 同时在线显示器：内建屏 3456×2234、AirDisplay 虚拟屏 2880×1864、随航 2388×1668
- Sender 以 `--loopback` 启动，Receiver 经雷雳网桥连回，因此屏幕共享、本机回环、网络推流三条链路同时在跑

## 结果

同一次会话内先开着屏幕共享采样，再断开屏幕共享采样；按连接状态对齐时间戳分组。

| 条件 | 样本 | 编码耗时 | 抓屏帧率 | 码率 |
|---|---|---|---|---|
| 屏幕共享活跃 + AirDisplay 推流 | 9 | 11.32 ms（10.8–12.0） | 57.1 fps（56–58） | 7.5 Mbps |
| 仅 AirDisplay 推流 | 8 | 11.74 ms（10.7–12.5） | 57.9 fps（57–58） | 8.6 Mbps |
| [M2](./M2-loopback.md) 基线（另一次会话） | — | 10.90 ms | 58.0 fps | — |

GPU 侧（`powermetrics --samplers gpu_power`，2 s 间隔）：

| 条件 | 样本 | GPU 功耗（中位 / 峰值） | GPU 频率（中位 / 均值） |
|---|---|---|---|
| 仅 AirDisplay | 11 | 0.77 W / 18.41 W | 338 MHz / 695 MHz |
| 屏幕共享 + AirDisplay | 49 | 4.21 W / 18.51 W | 722 MHz / 788 MHz |

「仅 AirDisplay」的 11 个样本里有 4 个是断开共享瞬间的过渡态（8.6–18.4 W），已排除在中位数之外；稳定段是 7 个样本，全部落在 338 MHz / 0.66–0.81 W。

## 关键发现：编码不占 GPU 核心

稳定段里 GPU 停在最低频率 338 MHz、功耗 0.7 W，而同一时刻 Sender 日志仍是：

```
00:15:33.303 统计：推流：抓屏 58 fps · 发送 57 fps · 编码 11.8 ms · 14.3 Mbps · 关键帧 0
00:15:38.300 统计：推流：抓屏 58 fps · 发送 57 fps · 编码 13.6 ms · 7.2 Mbps · 关键帧 0
```

也就是说 **58 fps、约 12 ms 的 HEVC 编码在 GPU 处于最低频率时照常完成**。测下来编码走的是 VideoToolbox 硬件编码器（媒体引擎），几乎不消耗 GPU 核心。

屏幕共享那部分 GPU 开销（中位 4.21 W vs 0.77 W，差约 3.4 W）来自它自己的合成与缩放，对应日志中的 `scaled adaptive opencl`，不是和 AirDisplay 争夺。

## 结论

两者可以同时工作，未观察到资源竞争：叠加屏幕共享后 AirDisplay 的抓屏帧率（56–58 fps）与编码耗时（11.3 vs 11.7 ms）都没有劣化，差异落在内容变化范围内。

## 局限

- 「仅 AirDisplay」的稳态样本只有 7 个，窗口偏短（断开共享后约 22 s）。
- 两组画面内容不同（码率 7.5 vs 8.6 Mbps），而 HEVC 编码耗时随内容复杂度变化，所以上表 0.4 ms 的差异不能归因于任何一方。要做严格对照，需要让虚拟屏内容固定不动后再各测 60 s。
- GPU `active residency` 常态已接近 99%，无法区分负载，因此改用功耗和活跃频率作为指标。
- 屏幕共享的观看端经 Tailscale 中继；这条只影响共享侧自身的码率，不影响本文件的对比结论。

## 一处误判（记录在案）

排查时一度以为统计上报出现了重复：`sender.log` 里同时能找到 `.30x` 相位（57–58 fps）和 `.56x` 相位（恒 0 fps）两组统计流。

实际原因与代码无关：`Shared/Log.swift` 的时间格式是 `HH:mm:ss.SSS`，**没有日期**。`.56x` 那组是前一天 00:14–00:16 的旧会话留下的，它排在文件前部（约第 2470 行），当前会话在今天的位置（约第 28650 行）。按行号一比就能分开。

结论：统计上报没有重复，同名时刻的多条记录来自不同日期。但这个坑会反复出现——建议后续给 `Log` 的时间格式加上日期（或直接用 `os_log` 自带时间戳），否则跨天排查还会误读。本文件上面的数据是在采样当时逐次读取 `tail -1` 得到的，不受此问题影响。

## 复现

```sh
# 1) 让 Sender 跑本机回环（同时保持屏幕共享会话）
open -a AirDisplaySender --args --loopback

# 2) 采样 AirDisplay 统计
grep "统计：" ~/Library/Logs/AirDisplay/sender.log | tail -20

# 3) 采样 GPU（需要 root）
sudo powermetrics --samplers gpu_power -i 2000 -n 60

# 4) 开关屏幕共享，按时间戳把两路采样按连接状态分组
sudo lsof -nP -iTCP:5900 | grep ESTABLISHED
```

## 另记：与 macOS 屏幕共享本身相关的三个坑

排查过程中确认的、与 AirDisplay 无关但会影响远程使用的事实：

- 只用 `launchctl enable system/com.apple.screensharing` 打开服务不够：端口会监听、认证能通过，但客户端报「屏幕共享不被允许」。必须在系统设置 → 通用 → 共享里打开开关。`system_profiler SPSharingDataType` 在 macOS 26 上不再报告该项，不能作为判据。
- `pmset displaysleep` 必须为 0。显示器休眠后屏幕共享抓到的是黑帧，表现为两端都黑屏。系统休眠和显示器休眠是两回事。
- 首次连接可能报一次 `invalid agent port`，重试即恢复；持续出现时用 `launchctl bootout` + `disable` 后从系统设置重新打开开关可以恢复。
