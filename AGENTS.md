# AirDisplay 工作约定

## 项目上下文

- 修改前读取 `CLAUDE.md`，沿用其中的架构、构建方式、目录和隐私规则。
- 用户当前指令优先；文档与实现不一致时，以代码和最新验证记录交叉核对，不能沿用过时结论。

## 文件与目录

- `README.md`：中文项目入口；`README_EN.md`：英文入口。顶部互链，命令、数据、限制和同步标记保持一致。
- `LICENSE`：MIT 许可证标准文本，署名使用公开 GitHub 账号；README 的许可说明和徽章须与其一致。
- `THIRD_PARTY_NOTICES.md`：第三方代码来源及其原始版权和许可声明；保留上游公开署名。
- `docs/`：已脱敏的里程碑报告和实验记录。README 引用报告，不复制完整开发日志。
- `Sender/`、`Receiver/`、`Shared/`、`Config/` 和 `project.yml` 的职责沿用 `CLAUDE.md`。
- 外部写作 Skill、临时校验脚本和生成预览不放进项目源码。
- `Tests/`：不创建实际显示器、不修改系统设置、不连接网络或注入真实输入的 Swift 回归测试；按被测行为命名，使用可控时钟和替身验证并发、恢复状态和失败终态。AppKit 界面检查仅在本进程离屏创建视图，不能运行 Sender 或显示测试窗口。测试可执行文件和界面预览放在被忽略的 `build/`，不随 Sender 打包。
- 恢复规则和实验入口的实现必须遵守 `docs/sidecar-stream-mismatch-plan.md`；按用户最新指令先完成生命周期、恢复界面及本地验证，再统一进行设备实测；实测通过前仅标记代码完成，不声称错配已修复。
- 临时产物按 `.gitignore` 约定存放；清理或删除文件前必须得到用户授权。

## 文档事实与验证

- 功能说明核对实际代码；实测数据注明日期、设备、测量方法与来源。
- 区分工程部署目标和已实测系统，区分抓屏到解码的延迟与包含屏幕刷新的延迟。
- 不编造兼容性、Release、CI、截图、许可证或维护承诺；不公开本机身份、签名信息、地址或绝对路径。
- 文档修改后运行 `git diff --check`，检查相对链接、代码围栏及中英命令一致性；使用写作 Skill 时同时运行其适用校验。
- 涉及代码时按 `CLAUDE.md` 构建受影响的 target；跨机体验仍须实际设备验证，不能用构建通过代替。
- 恢复回归命令：`mkdir -p build && xcrun swiftc -parse-as-library Sender/Sources/RecoveryPolicy.swift Tests/RecoveryTests.swift -o build/recovery-tests && build/recovery-tests`。使用系统 Swift，不安装依赖。
- 离屏界面回归命令：`xcrun swiftc -parse-as-library Sender/Sources/RecoveryPolicy.swift Sender/Sources/ControlPanel.swift Sender/Sources/FirstClickView.swift Sender/Sources/TestPattern.swift Shared/Log.swift Tests/ControlPanelTests.swift -o build/control-panel-tests && build/control-panel-tests`。
- 删除、密钥或系统配置变更、数据库变更、`git push`、历史改写及公开发布必须先取得用户明确许可。
