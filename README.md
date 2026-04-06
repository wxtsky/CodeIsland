<h1 align="center">
  <img src="logo.svg" width="48" height="48" alt="CodeIsland Logo" valign="middle">&nbsp;
  CodeIsland
</h1>
<p align="center">
  <b>Real-time AI coding agent status panel for macOS Dynamic Island (Notch)</b><br>
  <a href="#installation">Install</a> •
  <a href="#features">Features</a> •
  <a href="#supported-tools">Supported Tools</a> •
  <a href="#build-from-source">Build</a><br>
  English | <a href="README.zh-CN.md">简体中文</a>
</p>

---

<p align="center">
  <img src="docs/images/notch-panel.png" width="700" alt="CodeIsland Panel Preview">
</p>

## What is CodeIsland?

CodeIsland lives in your MacBook's notch area and shows you what your AI coding agents are doing — in real time. No more switching windows to check if Claude is waiting for approval or if Codex finished its task.

It connects to **8 AI coding tools** via Unix socket IPC, displaying session status, tool calls, permission requests, and more — all in a compact, pixel-art styled panel.

## Features

- **Notch-native UI** — Expands from the MacBook notch, collapses when idle
- **8 AI tools supported** — Claude Code, Codex, Gemini CLI, Cursor, Qoder, Factory, CodeBuddy, OpenCode
- **Live status tracking** — See active sessions, tool calls, and AI responses in real time
- **Permission management** — Approve/deny tool permissions directly from the panel
- **Question answering** — Respond to agent questions without leaving your current app
- **Pixel-art mascots** — Each AI tool has its own animated character
- **One-click jump** — Click a session to jump to its terminal tab or IDE window
- **Sound effects** — Optional 8-bit sound notifications for session events
- **Auto hook install** — Automatically configures hooks for all detected CLI tools
- **Bilingual UI** — English and Chinese, auto-detects system language
- **Multi-display** — Works with external monitors, auto-detects notch displays

## Supported Tools

| | Tool | Events | Jump | Status |
|:---:|------|--------|------|--------|
| <img src="docs/images/mascots/claude.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/claude.png" width="16"> Claude Code | 13 | Terminal tab | Full |
| <img src="docs/images/mascots/codex.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/codex.png" width="16"> Codex | 3 | Terminal | Basic |
| <img src="docs/images/mascots/gemini.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/gemini.png" width="16"> Gemini CLI | 6 | Terminal | Full |
| <img src="docs/images/mascots/cursor.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/cursor.png" width="16"> Cursor | 10 | IDE | Full |
| <img src="docs/images/mascots/qoder.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/qoder.png" width="16"> Qoder | 10 | IDE | Full |
| <img src="docs/images/mascots/factory.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/factory.png" width="16"> Factory | 10 | IDE | Full |
| <img src="docs/images/mascots/codebuddy.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/codebuddy.png" width="16"> CodeBuddy | 10 | APP/Terminal | Full |
| <img src="docs/images/mascots/opencode.gif" width="28"> | <img src="Sources/CodeIsland/Resources/cli-icons/opencode.png" width="16"> OpenCode | All | APP/Terminal | Full |

## Installation

### Homebrew (Recommended)

```bash
brew tap efan404/codeisland
brew install --cask codeisland
```

### Download

1. Go to [Releases](https://github.com/wxtsky/CodeIsland/releases)
2. Download `CodeIsland.app.zip`
3. Unzip and drag `CodeIsland.app` to your Applications folder
4. Launch CodeIsland — it will automatically install hooks for all detected AI tools

> **Note:** On first launch, macOS may show a security warning. Go to **System Settings → Privacy & Security** and click **Open Anyway**.

### Build from Source

Requires **macOS 14+** and **Swift 5.9+**.

```bash
git clone https://github.com/wxtsky/CodeIsland.git
cd CodeIsland

# Development (debug build + launch)
./dev.sh

# Release (universal binary: Apple Silicon + Intel)
./build.sh
open .build/release/CodeIsland.app
```

## How It Works

```
AI Tool (Claude/Codex/Gemini/Cursor/...)
  → Hook event triggered
    → codeisland-bridge (native Swift binary, ~86KB)
      → Unix socket → /tmp/codeisland-<uid>.sock
        → CodeIsland app receives event
          → Updates UI in real time
```

CodeIsland installs lightweight hooks into each AI tool's config. When the tool triggers an event (session start, tool call, permission request, etc.), the hook sends a JSON message through a Unix socket. CodeIsland listens on this socket and updates the notch panel instantly.

For **OpenCode**, a JS plugin connects directly to the socket — no bridge binary needed.

## Settings

CodeIsland provides a 7-tab settings panel:

- **General** — Language, launch at login, display selection
- **Behavior** — Auto-hide, smart suppress, session cleanup
- **Appearance** — Panel height, font size, AI reply lines
- **Mascots** — Preview all pixel-art characters and their animations
- **Sound** — 8-bit sound effects for session events
- **Hooks** — View CLI installation status, reinstall or uninstall hooks
- **About** — Version info and links

## Requirements

- macOS 14.0 (Sonoma) or later
- Works best on MacBooks with a notch, but also works on external displays

## Acknowledgments

This project was inspired by [claude-island](https://github.com/farouqaldori/claude-island) by [@farouqaldori](https://github.com/farouqaldori). Thanks for the original idea of bringing AI agent status into the macOS notch.

## License

MIT License — see [LICENSE](LICENSE) for details.
