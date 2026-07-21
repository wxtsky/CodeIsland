# CodeIsland for Windows

面向 Windows 的实时 AI 编程智能体状态面板，改编自 [wxtsky/CodeIsland](https://github.com/wxtsky/CodeIsland)。

[安装](#安装) · [功能](#功能) · [支持的工具](#支持的工具) · [源码构建](#源码构建) · [English](README.md)

---

![CodeIsland for Windows 展开界面](docs/images/big.png)

## CodeIsland for Windows 是什么？

CodeIsland for Windows 是一款置顶显示的紧凑型 AI 编程智能体状态面板。它能够展示正在运行的会话、工具调用、权限申请、智能体提问、完成状态和错误信息，减少在终端、IDE 与 AI 桌面应用之间反复切换的操作。

软件采用纯黑色像素风 Windows 灵动岛界面。双击可以在完整会话列表与极简状态条之间切换，也可以将界面拖到任意屏幕边缘，或在多个显示器之间移动。当收到权限申请、问题或错误事件时，缩小界面会自动展开，避免遗漏重要交互。

本项目改编自 macOS 平台的 [CodeIsland](https://github.com/wxtsky/CodeIsland)，是独立实现的 Windows 移植版本，并非上游项目的官方 Windows 发行版。

## 功能

- **Windows 原生界面** — 使用 WPF 开发，无边框置顶显示，并集成系统托盘
- **展开与缩小模式** — 双击面板即可切换完整会话列表和像素风紧凑状态条
- **实时会话跟踪** — 显示会话状态、最近消息、当前工具、运行时间和工作目录
- **权限处理** — Bridge 接入的权限请求可直接允许、拒绝或始终允许；Codex Desktop 审批会自动展开并提示在 Codex 中处理
- **问题回答** — 无需离开当前应用即可回答智能体的问题
- **Codex Desktop 集成** — 通过对话深层链接直接打开对应的 Codex 会话
- **Codex 会话恢复** — 自动恢复活跃会话并实时读取 JSONL，包括 MCP/插件调用
- **像素风智能体宠物** — 使用 GIF 动画，并针对展开与缩小背景分别适配
- **拖动调整会话优先级** — 按住会话卡片上下拖动，首个活跃会话将显示在缩小界面
- **多显示器贴边** — 根据面板当前所在显示器，与四条屏幕边缘平滑连接
- **全屏感知** — 只在同一显示器出现真实全屏应用时隐藏
- **统一深色控件** — 设置页、托盘菜单、交互按钮和滚动条均使用像素深色主题
- **全局快捷键** — 支持自定义面板切换、允许和拒绝快捷键
- **Hook 管理** — 检测、安装、修复、卸载并检查智能体 Hook 健康状态
- **本地 IPC** — 使用按 Windows 用户隔离的命名管道传递本地事件

## 支持的工具

当前 Windows Hook 定义覆盖以下工具：

| 工具 | 会话与工具事件 | 权限交互 | 跳转目标 |
| --- | --- | --- | --- |
| Claude Code | 支持 | 支持 | 终端/工作目录 |
| Codex | 支持，并可实时恢复会话记录 | 支持 | Codex Desktop 对话或终端 |
| Gemini CLI | 支持 | 取决于 CLI Hook 能力 | 终端/工作目录 |
| Cursor | 支持 | 取决于 Hook 能力 | IDE/工作目录 |
| Qoder | 支持 | 支持 | IDE/工作目录 |
| Factory Droid | 支持 | 支持 | 终端/工作目录 |
| CodeBuddy | 支持 | 支持 | 应用/终端 |
| GitHub Copilot CLI | 支持 | 取决于 Hook 能力 | 终端/工作目录 |

具体事件覆盖范围取决于各工具公开的 Hook API，不同版本之间可能存在差异。

## 安装

### 使用发布包

1. 下载发布产物中的 `CodeIsland-Windows-0.1.0-win-x64.zip`。
2. 将 ZIP 完整解压到固定目录。
3. 运行 `CodeIsland.Windows.exe`。
4. 打开 **设置 → Hooks**，为检测到的工具安装或修复 Hook。

> 不能只复制 EXE。CodeIsland 使用依赖框架的发布方式，运行时还需要同目录中的 DLL、运行时配置、Bridge 程序、图标和 GIF 资源。

### 系统要求

- Windows 10 或 Windows 11，x64
- [.NET 8 Desktop Runtime](https://dotnet.microsoft.com/zh-cn/download/dotnet/8.0)
- 至少安装一个受支持的 AI 编程工具，才能接收实时会话事件

未签名版本首次启动时可能出现 Windows SmartScreen 提示。运行前请确认下载来源并核对文件校验值。

## 工作原理

```text
AI 编程工具
    → CodeIsland Hook 或 Codex JSONL 会话记录
    → CodeIsland.Bridge
    → 当前用户专属的 Windows 命名管道
    → CodeIsland.Windows
    → 实时会话状态与交互控件
```

Hook 会将不同智能体的事件转换为统一的数据模型，Bridge 再通过仅限当前 Windows 用户访问的命名管道发送给桌面应用。桌面端使用状态机更新界面；对于受支持的权限申请或问题事件，还会将用户选择返回给调用方。

Codex Desktop 还支持实时会话记录恢复。即使没有传统 CLI Hook，函数调用、自定义工具以及 MCP/插件完成事件也能反映到面板中。

## 设置

自定义深色设置窗口包含：

- **General** — 语言、开机启动和首选显示器
- **Behavior** — 会话清理和全屏隐藏
- **Appearance** — 最大可见会话数与事件历史数量
- **Sound** — 会话事件提示音
- **Hooks** — 工具检测、安装、修复、卸载与健康状态
- **Shortcuts** — 自定义全局快捷键
- **About** — 版本和应用信息

## 快捷键

| 操作 | 默认快捷键 |
| --- | --- |
| 切换展开/缩小界面 | `Ctrl+Shift+I` |
| 允许当前权限申请 | `Ctrl+Shift+A` |
| 拒绝当前权限申请 | `Ctrl+Shift+D` |

所有快捷键都可以在 **设置 → Shortcuts** 中修改。

## 源码构建

需要安装 `global.json` 指定的 .NET 8 SDK。

```powershell
# 在已经克隆的源码目录中执行
cd CodexStatus
dotnet build CodeIsland.Windows.sln -c Release
dotnet run --project CodeIsland.Windows\CodeIsland.Windows.csproj
```

运行 Smoke 测试：

```powershell
dotnet run --project CodeIsland.Windows.Smoke\CodeIsland.Windows.Smoke.csproj -c Release
```

生成 Windows 发布 ZIP：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-release.ps1
```

生成的发布包和 SHA-256 清单位于 `artifacts/`。

## 项目结构

| 项目 | 职责 |
| --- | --- |
| `CodeIsland.Windows` | WPF 界面、托盘、设置、会话显示和 Codex 会话跟踪 |
| `CodeIsland.Core` | 统一事件模型与会话状态机 |
| `CodeIsland.Protocol` | 智能体事件转换与 Codex 会话记录解析 |
| `CodeIsland.Ipc` | 当前用户专属的 Windows 命名管道通信 |
| `CodeIsland.Hooks` | 支持工具定义与 Hook 配置 |
| `CodeIsland.Bridge` | Hook 到桌面应用的事件桥接 |
| `CodeIsland.Windows.Smoke` | 端到端 Smoke 验证 |

## 致谢

本项目改编自 [wxtsky/CodeIsland](https://github.com/wxtsky/CodeIsland)。原项目率先将 AI 编程智能体的实时状态带入 macOS 刘海区域，为本 Windows 移植版提供了产品概念、交互方式、像素风视觉方向和开源实现参考。

特别感谢 [@wxtsky](https://github.com/wxtsky) 以及所有上游贡献者。若你正在使用或继续开发本项目，也请关注并支持原始 CodeIsland 项目。

## 许可证

MIT License。重新分发本项目时，请保留本项目及其上游依赖所要求的版权和许可证声明。
