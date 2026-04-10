# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Development commands

- Debug build + run app:
  - `swift build && ./.build/debug/CodeIsland`
- Build only:
  - `swift build`
- Run all tests:
  - `swift test`
- Run a single test target:
  - `swift test --filter CodeIslandCoreTests`
  - `swift test --filter CodeIslandTests`
- Run a single test case/method:
  - `swift test --filter DerivedSessionStateTests/testAllIdleSessionsUseMostRecentlyActiveSource`

## Packaging / release commands

- Universal release app bundle (arm64 + x86_64), sign, optional notarize+DMG:
  - `./build.sh`
  - `./build.sh --notarize`
- Versioned DMG build script:
  - `./scripts/build-dmg.sh <version>`

## Architecture overview

### Project layout (SwiftPM multi-target)

- `Sources/CodeIslandCore`: shared core domain logic (event models, reducer, summary derivation, socket path utilities, text formatting).
- `Sources/CodeIsland`: macOS app (SwiftUI + AppKit), hook server, UI panel, settings, discovery, persistence, terminal activation.
- `Sources/CodeIslandBridge`: lightweight native bridge binary invoked by CLI hooks.
- `Tests/CodeIslandCoreTests`, `Tests/CodeIslandTests`: core vs app-level tests.

### End-to-end event flow

1. External AI tool hook fires (Claude/Codex/Gemini/Cursor/Copilot/Qoder/Factory/CodeBuddy/OpenCode).
2. Hook invokes `codeisland-bridge` (or OpenCode plugin), which enriches payload with terminal/session metadata and writes to Unix socket (`/tmp/codeisland-<uid>.sock`, overridable by `CODEISLAND_SOCKET_PATH`).
3. `HookServer` receives payload, parses `HookEvent`, and routes:
   - permission events to approval flow,
   - `AskUserQuestion` / question notifications to question flow,
   - all other events to normal session reducer path.
4. `AppState` updates sessions and surface state; `NotchPanelView` reflects changes in real time.

Key files:

- `Sources/CodeIslandBridge/main.swift`
- `Sources/CodeIsland/HookServer.swift`
- `Sources/CodeIsland/AppState.swift`
- `Sources/CodeIslandCore/Models.swift`
- `Sources/CodeIslandCore/SessionSnapshot.swift`

### State model and reducer split

- Core logic is intentionally extracted into pure functions in `CodeIslandCore`:
  - `reduceEvent(...)` applies event -> session mutations + side effects.
  - `deriveSessionSummary(...)` computes top-level status/source/counts.
- App target executes side effects (sound, monitor attach/detach, removal, UI transitions).

This split is important: behavior changes to event semantics should usually start in `CodeIslandCore/SessionSnapshot.swift`, while platform behavior remains in `CodeIsland/AppState.swift`.

### Session lifecycle management

`AppState` is the operational center:

- Owns session map, active session, and current panel surface.
- Manages permission/question queues and continuations (`approve/deny/answer/skip`).
- Tracks process liveness with PID + start-time identity to avoid PID reuse bugs.
- Runs cleanup timers for stale/idle sessions.
- Performs discovery of sessions from provider stores and watches filesystem updates via FSEvents.
- Persists/restores sessions at `~/.codeisland/sessions.json`.

### Hook installation and auto-repair

`ConfigInstaller` manages hook config for all supported CLIs and OpenCode plugin installation.

- Writes/updates tool-specific config formats (Claude-style, nested, flat, Copilot format).
- Installs shared hook script and bridge binary under `~/.claude/hooks/`.
- Supports version-gated events (e.g., Claude CLI minimum versions for some hooks).
- `AppDelegate` runs periodic + activation-triggered `verifyAndRepair()`.

Key file:

- `Sources/CodeIsland/ConfigInstaller.swift`

### UI shell and interaction model

- `PanelWindowController` owns the always-on-top notch panel window, display selection, screen-hop animation, fullscreen visibility policy, and global click/drag behavior.
- `NotchPanelView` renders compact/expanded surfaces:
  - collapsed bar,
  - session list,
  - permission card,
  - question card,
  - completion card.
- `TerminalActivator` performs “jump to session” across terminals/IDEs (iTerm2, Ghostty, Terminal, WezTerm, kitty, native app bundle IDs).

### Release automation

- GitHub release workflow updates `wxtsky/homebrew-tap` cask on published release.
- See `.github/workflows/release.yml` for the Homebrew update flow.
