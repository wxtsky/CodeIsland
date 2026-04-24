<h1 align="center">
  <img src="logo.png" width="48" height="48" alt="CodeIsland Logo" valign="middle">&nbsp;
  CodeIsland (Uncle-Peke fork)
</h1>

<p align="center">
  <b>Real-time AI coding agent status panel for the macOS notch.</b>
</p>

---

> Fork of [wxtsky/CodeIsland](https://github.com/wxtsky/CodeIsland) (MIT) — huge thanks to [@wxtsky](https://github.com/wxtsky). This fork adds small UX tweaks around Claude Code's ExitPlanMode approval UI. For the official signed & notarized upstream build, use [`wxtsky/tap`](https://github.com/wxtsky/CodeIsland#installation).

---

## Install

```bash
brew install --cask Uncle-Peke/tap/codeisland
```

Update later with:

```bash
brew upgrade --cask codeisland
```

## Build from Source

Requires **macOS 14+** and **Swift 5.9+**.

```bash
git clone https://github.com/Uncle-Peke/CodeIsland.git
cd CodeIsland
./build.sh
open .build/release/CodeIsland.app
```

## Limitations vs upstream

- **Unsigned DMG** — no Developer ID signing or notarization. Homebrew Cask handles quarantine automatically; direct DMG users need `xattr -dr com.apple.quarantine /Applications/CodeIsland.app`
- **No Sparkle auto-update** — the in-app "Check for Updates" is a no-op. Use `brew upgrade` instead
- **Independent release cadence** — upstream changes need to be manually merged

## License

MIT — see [LICENSE](LICENSE).
