# M3 跨机显示（2026-10-24）

## 架构

- **Sender**：启动就开始监听 TCP，用 Bonjour 广播 `_airdisplay._tcp`。接收端连上后，如果虚拟屏没开就自动开，然后开始抓屏、编码、发送。接收端断开就停止抓屏和编码。
- **Receiver**：用 `NWBrowser` 找服务，只连接在 bridge0 上发现的那个，并把连接钉死在 bridge0 上。全屏无边框窗口，隐藏 Air 自己的光标，防止显示器睡眠，断线后自动重连。
- **背压**：发送端还没写进 socket 的帧超过 3 个，就丢掉非关键帧，等下一个关键帧再恢复，避免花屏。
- **延迟测量**：接收端每 0.5 秒发一次 ping，取 RTT 最小的样本估算两台机器的时钟差，算出"Pro 抓屏 → Air 解码完"。

## Pro 本机自测（Receiver 带 `-anyInterface YES -windowed YES`）

| 指标 | 结果 |
|---|---|
| 帧率 | 57–58 fps |
| 码率 | ~32 Mbps（画面里有 60Hz 毫秒时钟） |
| 解码 | 2.1 ms |
| 抓屏 → 解码完（跨进程，经 TCP） | 14.3 ms（最大约 17 ms） |
| RTT | 0.3–0.7 ms |
| 断线重连 | Sender 重启后约 4 秒自动连回 |

## 修过的问题

- Sender 端读控制消息的 `MessageReader` 是局部变量，创建后立即被释放，导致 ping 和"请求关键帧"都收不到。改为由 server 持有。

## 待 Air 实测

- [ ] Receiver 在 Air 上通过 bridge0 连上（日志 `~/Library/Logs/AirDisplay/receiver.log` 里写"已连接，网卡 bridge0"）
- [ ] 全屏画面正常，窗口能在 Pro 上拖到 Air 上
- [ ] 三屏同时工作：Pro + iPad 随航 + Air
- [ ] 文字清晰度：Air 的显示设置如果不是"1440×932"，画面会被系统再缩放一次，可能略糊（M4 处理）
