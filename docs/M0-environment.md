# M0 环境确认（2026-10-24）

只读检查，结果已脱敏。

| 项目 | 结果 |
|---|---|
| Sender | MacBook Pro 16"，Apple M4 Max，macOS 26.6.2（25G83） |
| Xcode | 26.3（17C529） |
| Apple Development 证书 | 检查时为 0 个，需要在 Xcode → Settings → Accounts 添加 |
| 雷雳连接 | Air 被识别为雷雳设备，链路 40 Gb/s（Air M3 的上限） |
| bridge0 | active，有 169.254 网段地址，ARP 能看到对端 |
| 延迟 | `ping -b bridge0` 5 次，0% 丢包，平均 0.61 ms（0.44–0.82） |
| 带宽 | iperf3 未安装，未测 |

## 结论

- 雷雳网桥可用，线材合格，不用换。
- **路由坑**：Wi‑Fi 接口上也有 169.254/16 路由，不指定接口时流量走 Wi‑Fi，表现为 `No route to host`。Sender/Receiver 的连接必须绑定 bridge0。
- 下一步前需要补上 Apple Development 签名证书（屏幕录制权限和签名绑定）。
