<h1 align="center">
  <img src="logo.png" width="48" height="48" alt="CodeIsland Logo" valign="middle">&nbsp;
  CodeIsland
</h1>
<p align="center">
  <b>macOS 灵动岛（刘海）实时 AI 编码 Agent 状态面板</b><br>
  <a href="#安装">安装</a> •
  <a href="#功能特性">功能</a> •
  <a href="#支持的工具">支持的工具</a> •
  <a href="#从源码构建">构建</a><br>
  <a href="README.md">English</a> | 简体中文
</p>

---

<p align="center">
  <img src="docs/images/notch-panel.png" width="700" alt="CodeIsland Panel Preview">
</p>

## CodeIsland 是什么？

CodeIsland 住在你 MacBook 的刘海区域，实时展示 AI 编码 Agent 的工作状态。不用再频繁切窗口去看 Claude 是否在等审批、Codex 是否完成了任务。

它通过 Unix socket IPC 连接 **16 种 AI 编码工具**，在刘海面板中展示会话状态、工具调用、权限请求等信息——全部呈现在一个紧凑的像素风面板中。

## 功能特性

- **刘海原生 UI** — 从 MacBook 刘海处展开，空闲时自动收起
- **支持 16 种 AI 工具** — Claude Code、Codex、Grok CLI、Gemini CLI、Cursor、Copilot、Trae/Traecli、Qoder、Factory、CodeBuddy、OpenCode、Kimi Code CLI、Cline、Pi / Oh My Pi、DeepSeek Harness、AiWork
- **实时状态追踪** — 查看活跃会话、工具调用和 AI 回复
- **权限管理** — 直接在面板上审批/拒绝工具权限请求
- **问题回答** — 无需离开当前应用即可回答 Agent 的问题
- **像素风角色** — 每个 AI 工具都有专属的像素动画角色
- **一键跳转** — 点击会话直接跳转到对应的终端标签页、IDE 窗口或 Herdr Agent 面板
- **智能通知抑制** — 标签页与 Herdr 面板级检测：只在你正在看该会话时抑制通知，而不是整个终端应用
- **音效提示** — 可选的 8-bit 风格音效通知
- **自动安装 Hook** — 自动为所有检测到的 CLI 工具配置 hooks，支持自动修复和版本追踪
- **iPhone 与 Apple Watch Buddy** — 将会话状态同步到灵动岛、锁屏、StandBy 和 Apple Watch
- **中英双语** — 支持中文和英文，自动跟随系统语言
- **多显示器** — 支持外接显示器，自动检测刘海屏幕

## 支持的工具

| | 工具 | 事件 | 跳转 | 状态 |
|:---:|------|------|------|------|
| <img src="docs/images/mascots/claude.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/claude.png" width="16"> Claude Code | 13 | 终端标签页 | 完整 |
| <img src="docs/images/mascots/codex.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/codex.png" width="16"> Codex | 3 | 终端 | 基础 |
| | <img src="Sources/CodeIsland/Resources/cli-icons/grok.png" width="16"> Grok CLI | 14 | 终端 | 基础 |
| <img src="docs/images/mascots/gemini.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/gemini.png" width="16"> Gemini CLI | 6 | 终端 | 完整 |
| <img src="docs/images/mascots/cursor.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/cursor.png" width="16"> Cursor | 10 | IDE | 完整 |
| <img src="docs/images/mascots/trae.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/traecli.png" width="16"> TraeCli | 10 | 终端 | 完整 |
| <img src="docs/images/mascots/qoder.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/qoder.png" width="16"> Qoder | 10 | IDE | 完整 |
| | <img src="Sources/CodeIsland/Resources/cli-icons/copilot.png" width="16"> Copilot | 6 | 终端 | 完整 |
| <img src="docs/images/mascots/factory.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/factory.png" width="16"> Factory | 10 | IDE | 完整 |
| <img src="docs/images/mascots/codebuddy.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/codebuddy.png" width="16"> CodeBuddy | 10 | APP/终端 | 完整 |
| | <img src="Sources/CodeIsland/Resources/cli-icons/kimi.png" width="16"> Kimi Code CLI | 10 | 终端 | 完整 |
| <img src="docs/images/mascots/opencode.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/opencode.png" width="16"> OpenCode | All | APP/终端 | 完整 |
| <img src="docs/images/mascots/cline.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/cline.png" width="16"> Cline | 5 | VSCode | 完整 |
| | <img src="Sources/CodeIsland/Resources/cli-icons/pi.png" width="16"> Pi / Oh My Pi | 8 | 终端 | 完整 |
| | <img src="Sources/CodeIsland/Resources/cli-icons/dsh.png" width="16"> DeepSeek Harness | 9 | 终端 | 完整 |
| | <img src="Sources/CodeIsland/Resources/cli-icons/aiwork.png" width="16"> AiWork | 20 | IDE/终端 | 完整 |

## 安装

### Homebrew（推荐）

```bash
brew tap wxtsky/tap
brew install --cask codeisland
```

### 手动下载

1. 前往 [Releases](https://github.com/wxtsky/CodeIsland/releases) 页面
2. 下载 `CodeIsland.dmg`
3. 打开 DMG，将 `CodeIsland.app` 拖入「应用程序」文件夹
4. 启动 CodeIsland — 会自动为所有检测到的 AI 工具安装 hooks

> **提示：** 首次启动时 macOS 可能弹出安全提示，前往 **系统设置 → 隐私与安全性** 点击 **仍要打开** 即可。

### iPhone 与 Apple Watch Buddy

Code Island Buddy 已在 App Store 上架：

[下载 Code Island Buddy](https://apps.apple.com/us/app/code-island-buddy/id6773881129)

iPhone App 可以把 Mac 上的会话状态同步到灵动岛、锁屏、StandBy 和 Apple Watch。它的工作方式很轻量：iPhone App 前台打开时，Mac 端通过本地网络发送会话快照；需要后台刷新实时活动和手表状态时，则通过蓝牙发送压缩后的状态摘要。

Code Island Buddy 完全免费，并且开源。它不需要账号，也不依赖外部服务器；伴随端源码就在本仓库的 `ios/CodeIslandCompanion` 和 `apple-companion` 目录中。

**开始使用：** Mac 端打开 **设置 → Buddy → iPhone Buddy**，勾选「允许 iPhone Buddy 发现这台 Mac」。同一 Wi-Fi 下打开手机 App 即可配对，配对成功后 Mac 端这里会显示已连接的设备名。首次连接时 macOS 会请求本地网络与蓝牙权限，两个都要允许——本地网络负责前台的完整快照，蓝牙负责 App 退到后台后刷新实时活动和手表状态。同一区块的「同步间隔」控制推送频率。

### 硬件桌宠 Buddy（ESP32）

除了手机端，CodeIsland 还支持一颗放在桌上的 ESP32 小屏幕，通过 BLE 实时播放当前 Agent 状态对应的像素动画（空闲睡觉 / 敲代码 / 等审批 / 等回答）。

完整的硬件清单、固件烧录和配对步骤见 **[hardware/README.md](hardware/README.md)**（中文，含开发板型号与购买参考）。Mac 端的开关在 **设置 → Buddy** 的硬件 Buddy 区块。

### 从源码构建

需要 **macOS 14+** 和 **Swift 5.9+**。

```bash
git clone https://github.com/wxtsky/CodeIsland.git
cd CodeIsland

# 开发模式（debug 构建 + 启动；Buddy 蓝牙需要下面的 .app）
swift build && ./.build/debug/CodeIsland

# 发布模式（通用二进制：Apple Silicon + Intel）
./build.sh
open .build/release/CodeIsland.app
```

## 工作原理

```
AI 工具 (Claude/Codex/Gemini/Cursor/...)
  → 触发 Hook 事件
    → codeisland-bridge（原生 Swift 二进制，约 86KB）
      → Unix socket → /tmp/codeisland-<uid>.sock
        → CodeIsland 接收事件
          → 实时更新 UI
          → 可选同步到 iPhone / Apple Watch Buddy
```

CodeIsland 在每个 AI 工具的配置中安装轻量级 hooks。当工具触发事件（会话开始、工具调用、权限请求等）时，hook 通过 Unix socket 发送 JSON 消息。CodeIsland 监听此 socket 并即时更新刘海面板。

**OpenCode** 使用 JS 插件直接连接 socket，无需 bridge 二进制。

**Codex** 多一步，而且这一步只能你自己做：Codex 不会执行没给它过目的 hook。装好之后启动 Codex，它会提示 `1 hook needs review before it can run.`，执行 `/hooks` 把 CodeIsland 的条目 review 并信任即可。在此之前 Codex 对这些 hook 不做任何事，也不报错——看起来就跟 CodeIsland 不支持 Codex 一模一样。Codex 会在 `~/.codex/config.toml` 的 `[hooks.state]` 里按内容哈希记录信任状态，所以 CodeIsland 更新重写了 `~/.codex/hooks.json` 之后，需要再 review 一次。

**DeepSeek Harness（DSH）** 通过 [dsh-island](https://github.com/cdxiaodong/dsh-island) cordis 插件接入：插件监听 DSH 内置事件（`session/created`、`tools/pre-execute`、`approval/request` 等），把同样的 JSON 写入 Unix socket。在 DSH 内安装：

```bash
dsh plugin --profile <profile> add github:cdxiaodong/dsh-island
```

DSH 是插件原生运行时，因此无需安装任何 hook 配置 —— CodeIsland 只需识别 `dsh` source 即可渲染它的会话卡片。

## 设置

CodeIsland 提供 7 个标签页的设置面板：

- **通用** — 语言、登录时启动、显示器选择
- **行为** — 自动隐藏、智能抑制、会话清理
- **外观** — 面板高度、字体大小、AI 回复行数
- **角色** — 预览所有像素风角色及动画
- **声音** — 8-bit 风格音效通知
- **Hooks** — 查看 CLI 安装状态、重新安装或卸载 hooks
- **关于** — 版本信息和链接

## 键盘快捷键

| 快捷键 | 功能 | 默认 |
|--------|------|------|
| ⌘⇧I | 展开 / 收起灵动岛面板 | 开启 |
| ⌘⇧A | 批准当前审批请求 | 关闭 |
| ⌘⇧D | 拒绝当前审批请求 | 关闭 |

所有快捷键都可以在 **设置 → 快捷键** 中自定义，还可以为「总是允许」「跳过提问」「跳转到终端」绑定按键。启用批准/拒绝快捷键后，对应键位会以角标形式直接显示在审批卡片按钮上。

## 系统要求

- macOS 14.0（Sonoma）或更高版本
- 在带刘海的 MacBook 上效果最佳，也支持外接显示器

## 致谢

本项目受 [@farouqaldori](https://github.com/farouqaldori) 的 [claude-island](https://github.com/farouqaldori/claude-island) 启发，感谢提供了将 AI Agent 状态带入 macOS 刘海的创意。

## Star History

<a href="https://star-history.dera.page/#wxtsky/CodeIsland&type=date&legend=bottom-right">
   <picture>
   <source media="(prefers-color-scheme: dark)" srcset="https://star-history.dera.page/svg?repos=wxtsky/CodeIsland&type=date&theme=dark&legend=top-left" />
   <source media="(prefers-color-scheme: light)" srcset="https://star-history.dera.page/svg?repos=wxtsky/CodeIsland&type=date&legend=top-left" />
   <img alt="Star History Chart" src="https://star-history.dera.page/svg?repos=wxtsky/CodeIsland&type=date&legend=top-left" />
   </picture>
</a>

## 许可证

MIT 许可证 — 详见 [LICENSE](LICENSE)。
