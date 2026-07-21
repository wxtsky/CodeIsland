# CodeIsland Windows 完整复刻开发计划

## 1. 项目目标与边界

### 1.1 目标

在 Windows 10/11 上复刻 CodeIsland 的核心体验：

- 监控 Claude Code、Codex、Gemini CLI、Cursor、Copilot、Trae、Qoder、Factory、CodeBuddy、OpenCode、Kimi、Cline、Pi 等 AI 编程工具。
- 实时显示会话、工具调用、等待审批、提问、完成、失败等状态。
- 提供顶部悬浮岛面板、系统托盘、全局快捷键、声音通知和多显示器支持。
- 支持直接审批/拒绝权限、回答问题、跳转到对应终端或 IDE。
- 自动安装、检查、修复和卸载 AI 工具 Hook。
- 支持 ESP32 Buddy 硬件；移动端同步作为后续兼容功能。

### 1.2 复刻原则

- 复用协议、事件模型、Hook 语义、资源和交互流程，重写 macOS 专属桌面层。
- Windows 主版本采用 C#/.NET 8 + WPF；不尝试将 AppKit/SwiftUI 直接移植到 Windows。
- Unix Domain Socket 改用 Named Pipe，保留 localhost WebSocket 作为调试和远程模式。
- 对无法稳定获取的信息提供能力检测、可配置降级和明确的用户提示。

### 1.3 不纳入首个正式版本的内容

- macOS 刘海物理区域的精确融合。
- 直接替代 Apple Watch/ActivityKit/Live Activities；Windows 版本先提供局域网同步 API。
- 所有终端软件的标签页级精准定位；先实现窗口级跳转，再逐个适配。

## 2. 交付物与质量目标

### 2.1 交付物

1. `CodeIsland.Windows` 桌面应用。
2. `codeisland-bridge.exe` 事件桥接程序。
3. Hook 安装器、修复器和卸载器。
4. Windows 安装包、卸载程序、自动更新配置。
5. 协议文档、开发文档、用户文档和故障排查手册。
6. 单元测试、集成测试、UI 自动化测试和发布验收报告。

### 2.2 质量门槛

- 空闲状态 CPU < 1%，内存 < 150 MB（不含外部 CLI）。
- 事件从 Hook 到面板显示的 P95 延迟 < 300 ms。
- 面板异常退出后，Hook 不阻塞、不丢失 CLI 主流程。
- 断开/重启/升级后可自动恢复连接和 Hook 配置。
- 高 DPI、浅色/深色主题、多屏、缩放 100%/125%/150% 均通过验收。

## 3. 总体技术方案

### 3.1 技术栈

| 层 | 技术 |
|---|---|
| 桌面应用 | C#、.NET 8、WPF |
| 架构 | MVVM、CommunityToolkit.Mvvm、依赖注入 |
| Windows 互操作 | Win32 P/Invoke、UI Automation、DWM |
| IPC | Windows Named Pipes；调试用 localhost WebSocket |
| 数据 | `System.Text.Json`、JSONL、YamlDotNet |
| 日志 | Serilog + Rolling File |
| 动画 | WPF Storyboard/Composition；必要时使用 SkiaSharp |
| 音频 | NAudio 或 Windows Media APIs |
| BLE | `Windows.Devices.Bluetooth`、GATT |
| SSH | SSH.NET |
| 更新 | Velopack 或 MSIX App Installer |
| 测试 | xUnit、FluentAssertions、Moq、WinAppDriver/Playwright（辅助） |
| CI/CD | GitHub Actions Windows runner |
| Hook 脚本 | Node.js/TypeScript、Python、PowerShell |

### 3.2 分层结构

```text
CodeIsland.Windows.sln
├─ CodeIsland.Core              # 跨平台模型、事件、状态机、协议
├─ CodeIsland.Protocol          # JSON schema、Named Pipe、消息编解码
├─ CodeIsland.Hooks             # 工具检测、安装、修复、卸载
├─ CodeIsland.Bridge            # codeisland-bridge.exe
├─ CodeIsland.Windows           # WPF UI、托盘、快捷键、窗口管理
├─ CodeIsland.Terminals         # 终端/IDE 检测、激活和跳转
├─ CodeIsland.Bluetooth         # ESP32 BLE 协议和连接管理
├─ CodeIsland.Updater           # 更新、版本和回滚
└─ tests                         # 单元、集成、UI、发布测试
```

## 4. 软件开发流程与阶段计划

## 阶段 0：项目启动与基线确认（第 1 周）

### 工作内容

- 固定 CodeIsland 上游版本，记录 commit、支持工具列表和事件类型。
- 阅读并整理 `README`、`Package.swift`、`CodeIslandCore`、Hook 安装器、TerminalActivator、HookServer。
- 建立功能矩阵：macOS 原功能、Windows 等价实现、降级方案、验收方法。
- 明确目标系统：Windows 10 22H2、Windows 11 23H2 及以上，x64 优先，ARM64 后续。
- 建立 Git 仓库、分支策略、Issue 模板、代码规范和提交规范。

### 产出物

- 《需求基线》
- 《Windows 功能差异矩阵》
- 架构 ADR-001（Windows 技术选型）
- 可构建的空白 `.sln`

### 完成条件

- 所有首版功能有唯一编号（F-001…）。
- 每项功能有负责人、依赖和验收标准。
- CI 能在 Windows runner 上完成 restore/build/test 空测试。

## 阶段 1：协议与领域模型（第 2-3 周）

### 工作内容

- 定义 `AgentKind`、`SessionState`、`ToolCall`、`PermissionRequest`、`QuestionRequest`、`SessionSnapshot`。
- 将事件统一为：`session_start`、`session_end`、`tool_start`、`tool_end`、`permission_request`、`question`、`message`、`error`、`heartbeat`。
- 为每种事件定义 JSON Schema、版本号、必填字段、幂等键和时间戳规范。
- 实现 JSON 编解码、未知字段兼容、协议版本协商和错误响应。
- 实现会话状态机、超时清理、重复事件去重、断线恢复和本地快照。
- 为上游 Hook 样本建立 golden fixtures。

### 产出物

- 协议文档和 JSON Schema
- `CodeIsland.Core`、`CodeIsland.Protocol`
- 状态机单元测试（目标覆盖率 > 90%）

### 完成条件

- 使用离线样本可重放完整会话。
- 任意畸形 JSON 不导致主进程崩溃。
- 状态机结果与上游样例一致。

## 阶段 2：Bridge 与 IPC（第 4 周）

### 工作内容

- 实现 `codeisland-bridge.exe`，支持一次性发送和常驻连接两种模式。
- 默认 Named Pipe：`\\.\pipe\codeisland-{userSid}`；权限限制为当前用户。
- 定义连接握手、心跳、发送确认、重试和超时策略。
- Bridge 不依赖 UI；UI 未启动时快速失败并返回成功码，避免阻塞 AI CLI。
- 增加 localhost WebSocket 调试模式和事件录制/回放命令。
- 记录 Windows 用户目录、临时目录和日志目录的路径策略。

### 完成条件

- 1000 条事件连续发送无丢失、无死锁。
- UI 重启期间 Hook 可重试并恢复。
- 普通用户权限可运行，不要求管理员权限。

## 阶段 3：Hook 发现、安装和修复（第 5-7 周）

### 工作内容

- 为每个 AI 工具定义 `Detector`、`Installer`、`Repairer`、`Uninstaller`、`HealthCheck`。
- 检测 npm 全局包、原生 exe、VS Code 扩展、Cursor/Trae/Qoder 配置目录和用户 PATH。
- 将 macOS shell 路径改为 Windows PowerShell/cmd 兼容命令。
- 支持用户级安装，避免写入 `Program Files`；配置文件修改前做备份和哈希记录。
- Hook 写入统一 Bridge 调用模板，包含 cwd、session id、tool name、事件 payload。
- 实现版本追踪、配置冲突检测、自动修复、卸载回滚。
- 设置页提供逐工具状态、重新安装、查看日志和复制诊断信息。

### 完成条件

- 每个首版工具都有安装、修复、卸载和健康检查测试。
- 配置文件损坏或字段缺失时能自动恢复。
- 安装器重复执行幂等，不覆盖用户自定义配置。

## 阶段 4：桌面窗口、托盘和基础 UI（第 8-10 周）

### 工作内容

- 创建 WPF 主进程和单实例互斥锁。
- 实现透明、无边框、置顶、可点击、可拖动的顶部悬浮窗口。
- 设计“收缩态、展开态、详情态、审批态、提问态、错误态、空闲态”。
- 实现系统托盘菜单：打开面板、暂停通知、设置、重新安装 Hook、导出诊断、退出。
- 使用 MVVM 将 UI 与状态机完全解耦。
- 适配 DPI、主题、键盘焦点、屏幕边界和任务栏区域。
- 加载像素角色、工具图标、音频资源；资源全部采用可替换文件或程序集资源。

### 完成条件

- UI 不依赖 AI 工具即可用模拟事件演示完整流程。
- 面板不会抢占当前应用焦点，审批卡片可正常点击。
- 多屏插拔和缩放变化后窗口位置正确。

## 阶段 5：事件面板和交互功能（第 11-14 周）

### 工作内容

- 实现会话列表、当前会话、工具调用详情、AI 回复摘要和历史事件。
- 实现批准、拒绝、始终允许、跳过问题、取消会话等动作。
- 将用户响应通过 IPC 发送回对应 Hook/CLI；实现响应超时和失败提示。
- 实现会话选择、置顶、关闭、过期清理和最大可见数量设置。
- 实现 8-bit 启动、审批、完成、错误等声音及总开关/音量设置。
- 实现全局快捷键：展开/收起、批准、拒绝、跳转终端；支持冲突检测和重新绑定。
- 实现通知抑制策略：仅在对应会话处于前台且用户确实可见时抑制。

### 完成条件

- 每种状态都有视觉、声音、快捷键和响应测试。
- 审批/问题响应可端到端回到模拟 CLI。
- 快捷键与常见应用冲突时给出可操作提示。

## 阶段 6：终端和 IDE 跳转（第 15-17 周）

### 工作内容

- 建立进程识别器：Windows Terminal、PowerShell、cmd、WezTerm、ConEmu、VS Code、Cursor、Trae 等。
- 第一版实现窗口级激活：按 PID、窗口句柄、工作目录和命令行匹配。
- 实现 VS Code/Cursor URI 跳转和项目目录打开。
- 对 Windows Terminal 使用 `wt.exe`、窗口句柄枚举和 UI Automation；记录标签级定位能力差异。
- 提供“复制目录/命令”“在新终端打开”作为可靠兜底。
- 记录跳转诊断信息，允许用户选择终端类型和优先策略。

### 完成条件

- 常用终端和 IDE 的窗口级跳转成功率 > 95%。
- 标签级定位失败时不误激活其他会话，并提供降级动作。
- 前台窗口变化不会导致面板崩溃或死循环。

## 阶段 7：设置、持久化和本地化（第 18-19 周）

### 工作内容

- 实现 General、Behavior、Appearance、Mascots、Sound、Hooks、Shortcuts、About 设置页。
- 使用 `%AppData%\CodeIsland` 保存用户配置，使用 `%LocalAppData%` 保存缓存和日志。
- 配置版本迁移、默认值、导入/导出和恢复默认设置。
- 实现中英文资源、系统语言检测和运行时切换。
- 保存会话标题、已选显示器、通知偏好和最近状态。
- 提供诊断导出：版本、系统、Hook 状态、日志摘要、协议统计，不包含密钥。

### 完成条件

- 升级旧配置不会丢失设置。
- 中英文界面无截断、重叠和硬编码文本。
- 导出的诊断包可复现主要问题但不泄露敏感数据。

## 阶段 8：ESP32 Buddy 与远程能力（第 20-22 周）

### 工作内容

- 复用 ESP32 服务 UUID、特征 UUID、配对握手、状态上报和按钮命令协议。
- 实现 BLE 扫描、选择、配对、重连、超时、断开和固件错误提示。
- 通过 `Windows.Devices.Bluetooth` 完成 GATT 读写和通知订阅。
- 保留 SSH/远程主机事件接入，明确远端 Hook 到本机 Bridge 的认证方式。
- 为局域网同步定义只读 Session Snapshot API；默认关闭，支持配对码或局域网密钥。
- 移动端先提供独立 REST/WebSocket 协议，不承诺 Apple Live Activity 等价功能。

### 完成条件

- BLE 长时间运行 8 小时无内存泄漏。
- 设备断电、超出范围、重新配对后可以恢复。
- 远程接入默认拒绝未认证连接。

## 阶段 9：更新、安装与发布工程（第 23-24 周）

### 工作内容

- 选择 Velopack 或 MSIX；建立稳定版、测试版和回滚通道。
- 配置代码签名、时间戳、杀毒软件误报处理和发布证书保管流程。
- 构建 x64 安装包；验证 ARM64 兼容性后再发布 ARM64。
- 实现开机启动、卸载清理、升级期间进程退出和失败回滚。
- GitHub Actions 执行 restore、build、test、打包、签名、生成 SHA256、发布 Release。
- 编写安装、升级、降级、卸载和无网络安装测试。

### 完成条件

- 普通用户可完成安装和升级。
- 中断升级后可启动旧版本或自动修复。
- Release 包含安装包、校验值、变更日志和已知问题。

## 阶段 10：测试、稳定性和发布验收（第 25-28 周）

### 测试层级

1. 单元测试：模型、状态机、协议、配置迁移、Hook 合并算法。
2. 集成测试：Bridge、Named Pipe、Hook 到 UI 的事件链路。
3. 工具适配测试：每个 AI 工具的安装、事件、响应、卸载。
4. UI 自动化：展开、审批、提问、设置、快捷键、托盘和多屏。
5. 兼容性测试：Windows 10/11、管理员/普通用户、DPI、深浅色、网络断开。
6. 压力测试：多工具、多会话、每秒 100 条事件、长时间运行。
7. 安全测试：Named Pipe ACL、路径注入、配置注入、未授权远程连接、日志脱敏。
8. 发布测试：全新安装、覆盖升级、回滚、卸载、残留清理。

### 发布门禁

- 自动化测试全部通过。
- P0/P1 缺陷为 0；P2 缺陷有明确规避方案。
- 连续运行 72 小时无崩溃和明显内存增长。
- 至少 5 台不同硬件、2 个 Windows 版本完成验收。
- 完成用户文档、隐私说明、许可证和第三方依赖清单。

## 5. 功能编号与验收清单

| 编号 | 功能 | 验收要点 |
|---|---|---|
| F-001 | 单实例启动 | 重复启动只激活已有面板 |
| F-002 | 托盘 | 菜单完整，退出可清理连接 |
| F-003 | 悬浮岛 | 无边框、置顶、可点击、不遮挡全屏应用 |
| F-004 | Hook 安装 | 检测、安装、修复、卸载幂等 |
| F-005 | 实时事件 | 延迟和乱序符合协议约定 |
| F-006 | 权限审批 | 允许/拒绝结果回到原会话 |
| F-007 | 问题回答 | 文本响应正确路由 |
| F-008 | 多会话 | 独立状态、标题、超时和清理 |
| F-009 | 声音 | 事件映射、开关、音量有效 |
| F-010 | 快捷键 | 注册、冲突检测、动态修改 |
| F-011 | 多屏/DPI | 显示器变化后位置和尺寸正确 |
| F-012 | 终端跳转 | 窗口级跳转可靠，失败可降级 |
| F-013 | IDE 跳转 | 项目和窗口匹配正确 |
| F-014 | 设置 | 配置持久化、迁移、导入导出 |
| F-015 | 本地化 | 中英文无布局问题 |
| F-016 | ESP32 | 扫描、配对、重连、控制命令 |
| F-017 | 更新 | 升级、回滚、签名和校验 |
| F-018 | 诊断 | 日志、导出、敏感信息脱敏 |

## 6. 主要风险与应对

| 风险 | 影响 | 应对 |
|---|---|---|
| Windows Terminal 无稳定标签 API | 高 | 先窗口级；使用 UI Automation 适配，提供新窗口/复制路径兜底 |
| 不同 AI 工具 Hook 格式变化 | 高 | 适配器版本化、golden fixtures、启动时健康检查 |
| 透明置顶窗口与全屏/游戏冲突 | 中高 | 检测独占全屏，自动隐藏并允许用户配置 |
| 杀毒软件拦截 Bridge | 中高 | 代码签名、最小权限、固定发布渠道、诊断文档 |
| BLE 驱动和权限差异 | 中 | 能力探测、重连退避、串口/局域网备用方案 |
| 远程同步泄露会话内容 | 高 | 默认关闭、只读快照、配对码、加密和日志脱敏 |
| UI 长时间运行泄漏 | 中 | 性能基线、事件限流、定时快照和 72 小时 soak test |

## 7. 建议团队与排期

### 最小团队

- 1 名 Windows/.NET 主程：窗口、IPC、系统集成。
- 1 名协议/Hook 主程：AI 工具适配、安装器、测试。
- 1 名 UI/交互开发：WPF、动画、设置页、本地化。
- 0.5 名测试/发布工程师：自动化、兼容性、打包和签名。

### 里程碑

- M1（第 4 周）：协议、Bridge、事件回放可用。
- M2（第 10 周）：悬浮面板、托盘和模拟数据闭环。
- M3（第 14 周）：三种 AI 工具端到端可用。
- M4（第 19 周）：全工具 Hook、设置、本地化完成。
- M5（第 22 周）：终端/IDE 跳转和 ESP32 Beta 完成。
- M6（第 28 周）：稳定版发布。

## 8. 开发执行顺序

实际编码时严格遵循以下顺序：

1. 先冻结事件协议和功能矩阵。
2. 先写 Core 状态机和协议测试，再写 UI。
3. 先完成 Bridge 和事件回放，再接入真实 AI 工具。
4. 先支持三个高价值工具，再批量扩展适配器。
5. 先实现窗口级跳转，再做终端标签级增强。
6. 先完成无硬件主流程，再接入 ESP32。
7. 所有功能进入设置页前，先具备配置、日志和测试。
8. 每个里程碑都生成可安装构建和回归报告。

## 9. 最终验收标准

项目只有在以下条件全部满足时才视为“完成复刻”：

- 首版支持工具均能自动安装 Hook 并接收真实事件。
- 状态、审批、提问、完成、失败和错误流程端到端闭环。
- 悬浮面板、托盘、快捷键、声音、多屏和设置功能完整可用。
- 常见 Windows 终端和 IDE 至少支持窗口级可靠跳转。
- ESP32 功能通过配对、断线、重连和长时间测试。
- 安装包能在干净 Windows 环境中安装、升级、卸载。
- 所有已知 macOS 差异写入用户文档，不能以“行为不一致但未说明”作为发布状态。

