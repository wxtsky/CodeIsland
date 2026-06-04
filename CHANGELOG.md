# Changelog

## [v1.0.27] - 2026-05-30

### English
- Fix Cursor / Trae / Qoder / Factory click-to-jump raising the most-recently-used window instead of the one running the clicked session — now matches the workspace window by project folder (#199)
- Install custom CLI hooks on SSH remote hosts too (claude / nested hook formats) — previously only the built-in CLIs were configured remotely (#192)

### 中文
- 修复 Cursor / Trae / Qoder / Factory 点击灵动岛跳到"最近用过的窗口"而不是正在对话的那个——现在按项目目录匹配对应 workspace 窗口 (#199)
- SSH 远程主机也会安装自定义 CLI 的 hooks（claude / nested 格式）——此前远程只配置内置 CLI (#192)

## [v1.0.26] - 2026-05-30

### English
- Add pi / Oh My Pi (OMP) coding agent integration — auto-install the bundled extension into `~/.pi/agent/extensions` and `~/.omp/agent/extensions` (#197)
- Isolate the remote SSH socket per user (`/tmp/codeisland-<uid>.sock`) so multiple OS users on a shared host no longer collide or steal each other's events (#193)
- Fix the SSH tunnel being misreported as `ssh exited (0)` when ControlMaster multiplexing makes `ssh -N` hand off the forward and exit immediately — force a dedicated connection (#190)
- Fix iTerm2 click-to-jump landing on the wrong window when the target session is fullscreen or on another Space — select the owning window so macOS switches to its Space (#198)

### 中文
- 新增 pi / Oh My Pi (OMP) 编码 agent 集成——自动把扩展装到 `~/.pi/agent/extensions` 和 `~/.omp/agent/extensions` (#197)
- 远程 SSH socket 改为按用户隔离（`/tmp/codeisland-<uid>.sock`），多用户共享主机不再互相串话或抢占事件 (#193)
- 修复 SSH 隧道在 ControlMaster 多路复用下 `ssh -N` 立即退出、被误报为 `ssh exited (0)` 的问题——强制独占连接 (#190)
- 修复 iTerm2 全屏 / 跨 Space 时点击会话跳到错误窗口——命中后选中目标窗口以触发 Space 切换 (#198)

## [v1.0.23] - 2026-04-25

### English
- Add ESP32 BLE companion device — port mascot animations to a real desk pet (#131)
- Make auto-approve tools configurable in Settings; default no longer auto-approves `ExitPlanMode` so plan-mode exit prompts an approval dialog (#126)
- Fix TraeCli YAML hook injection corruption on mixed indentation; preserve user comments via surgical merge (#122)
- Respect `$CODEX_HOME` in codex auto-config (local + ssh) (#129)
- Add WorkBuddy bundle ID for one-click jump from CodeIsland (#130)
- Fix remote SSH sessions being force-flipped to idle on local timeout (#121)
- Fix Ghostty click-to-jump no-op via System Events Accessibility fallback (#84)
- Fix Terminal.app: minimized window not raising + multi-tab clicks all jumping to same tab (root cause: AppleScript `tty` variable shadowed Terminal.app's tab `tty` property) (#124)
- Add configurable cwd-substring blocklist for hook events — filter out background plugins like claude-mem (#125)
- Add webhook forwarding for hook events to external HTTP endpoints — pipe agent activity into DingTalk / Lark / Slack receivers (#115)
- Add minimum Kiro CLI support — install hooks into `~/.kiro/agents/codeisland.json` (launch with `kiro --agent codeisland`) (#127)

### 中文
- 新增 ESP32 BLE 桌面伴侣设备——把吉祥物动画移植到实体小屏 (#131)
- "自动批准工具"可在设置里逐项配置，默认不再自动批准 `ExitPlanMode`，退出 plan 模式会弹审批 (#126)
- 修复 TraeCli YAML 在混合缩进下 hook 注入损坏的问题，并通过 surgical 合并保留用户注释 (#122)
- codex 自动配置遵循 `$CODEX_HOME`（本地和 ssh 都生效）(#129)
- 新增 WorkBuddy 一键跳转 (#130)
- 修复远程 SSH 任务被本地 timeout 误判完成 (#121)
- 修复 Ghostty 点击灵动岛无反应——加 System Events Accessibility 兜底 (#84)
- 修复 Terminal.app 最小化无法打开 + 多终端点哪个都跳同一 tab（真 root cause：AppleScript 局部变量 `tty` 跟 tab property `tty` 同名导致 Strategy 1 静默失效）(#124)
- 设置里新增"忽略指定路径的 Hook"——按子串过滤 claude-mem 等后台插件触发的事件 (#125)
- 设置里新增"Webhook 转发"——hook 事件以 JSON POST 到外部端点，方便对接钉钉/飞书/Slack (#115)
- 新增 Kiro CLI 最小可用支持——hooks 写到 `~/.kiro/agents/codeisland.json`，启动用 `kiro --agent codeisland` (#127)

## [v1.0.15] - 2026-04-07

### English
- Fix apps built with libghostty (e.g. Supacode) being misidentified as Ghostty (#27)
- Fix DMG release missing app icon by pre-building icns with all sizes
- Fix settings window opaque sidebar in .app bundle (add toolbar for translucent effect)
- Build universal binary (arm64 + x86_64) for DMG releases
- Use root Info.plist for DMG builds to include all required fields

### 中文
- 修复基于 libghostty 构建的应用（如 Supacode）被误识别为 Ghostty 的问题 (#27)
- 修复 DMG 发行版缺少应用图标的问题（预置完整尺寸 icns）
- 修复 .app 版本设置窗口侧边栏不透明的问题（添加 toolbar 实现毛玻璃效果）
- DMG 发行版改为 universal binary（arm64 + x86_64）
- DMG 构建使用完整 Info.plist，包含所有必要字段

## [v1.0.8] - 2026-04-07

### English
- Add GitHub Copilot CLI support as the 9th AI tool
- Allow horizontal drag of panel along the menu bar (Settings → General)
- Horizontal-only drag with no vertical jitter, 5px threshold to prevent accidental drag
- Reset panel to center when drag toggle is turned off
- Update mascot gif backgrounds to white for better README readability

### 中文
- 新增 GitHub Copilot CLI 支持（第 9 个 AI 工具）
- 允许沿菜单栏水平拖动面板（设置 → 通用）
- 仅水平拖动无垂直抖动，5px 阈值防误触
- 关闭拖动开关时面板自动归位居中
- 更新吉祥物 gif 为白色背景，提升 README 可读性

## [v1.0.7] - 2026-04-07

### English
- Add Homebrew Cask distribution support (`brew install --cask codeisland`)
- Add in-app auto-update: download, install and relaunch without leaving the app
- Add "Check for Updates" button in Settings → About
- Detect Homebrew installs and suggest `brew upgrade` instead of auto-update
- Add GitHub Actions CI for automated release builds
- Auto-approve safe internal tools (TaskCreate, TaskUpdate, etc.) to prevent hook blocking
- Fix compact bar showing project name and tool status from different sessions
- Fix restored sessions incorrectly shown as active when CLI process is idle
- Hide project name in tool status area when no tool is running

### 中文
- 新增 Homebrew Cask 分发支持（`brew install --cask codeisland`）
- 新增 App 内自动更新：下载、安装并重启，无需离开应用
- 设置 → 关于页面新增"检查更新"按钮
- 检测 Homebrew 安装并建议使用 `brew upgrade` 更新
- 新增 GitHub Actions CI 自动构建发布
- 自动放行安全内部工具（TaskCreate、TaskUpdate 等），防止 hook 阻塞
- 修复紧凑栏项目名和工具状态来自不同会话的问题
- 修复恢复的会话在 CLI 空闲时仍显示为活跃状态
- 修复无工具运行时仍显示项目名的问题

## [v1.0.6] - 2026-04-07

### English
- Show Claude and Codex session titles in the panel
- New idle state UI with hover interaction on the notch
- Add shimmer animation when AI is thinking
- Extend animation speed slider to 0% to freeze mascot animations
- Add Codex PreToolUse/PostToolUse hook events for tool status display
- Auto-configure codex_hooks=true in ~/.codex/config.toml
- Add IDE terminal detection for smarter notification suppress
- Add cmux terminal support
- Fix user messages rendered as markdown instead of plain text
- Add processing timeout fallback: reset to idle after 60s with no tool
- Fix idle mascot not aligned with the most recently active CLI

### 中文
- Claude 和 Codex 会话现在在面板中显示标题
- 新增空闲状态 UI，支持刘海区域悬停交互
- AI 思考时显示闪烁动画效果
- 动画速度滑块可调至 0% 以冻结吉祥物动画
- 新增 Codex PreToolUse/PostToolUse hook 事件，显示工具状态
- 自动配置 ~/.codex/config.toml 中的 codex_hooks=true
- 新增 IDE 终端检测，更智能的通知抑制
- 新增 cmux 终端支持
- 修复用户消息被渲染为 markdown 而非纯文本
- 增加处理超时回退：60 秒无工具调用后重置为空闲
- 修复空闲吉祥物未对齐最近活跃的 CLI

## [v1.0.5] - 2026-04-06

### English
- Smart suppress: only suppress notifications when looking at the specific session tab
- Support iTerm2, Ghostty, Terminal.app, WezTerm, kitty, and tmux tab detection
- Fix Codex Desktop not discovered due to case-sensitive path matching
- Fix npm/Homebrew Codex not discovered
- Fix OpenCode "Always allow" not persisting
- Fix model badge not showing
- Fix session short ID collision
- Fix bridge binary replacement drop window
- Fix hook script not updating for existing users
- Fix concurrent sessions in same repo incorrectly merged

### 中文
- 智能抑制：只有当你正在看该会话的标签页时才抑制通知
- 支持 iTerm2、Ghostty、Terminal.app、WezTerm、kitty、tmux 标签页检测
- 修复 Codex Desktop 因路径大小写不匹配无法发现
- 修复 npm/Homebrew 安装的 Codex 无法发现
- 修复 OpenCode "始终允许"没有持久化
- 修复 model 标签不显示
- 修复会话短 ID 冲突
- 修复 bridge 二进制替换存在时间窗口
- 修复已安装用户的 hook 脚本不会更新
- 修复同 repo 并发会话被错误合并

## [v1.0.4] - 2026-04-06

### English
- Fix OpenCode socket deadlock
- Fix stuck session states
- Fix AskUserQuestion parsing
- Fix double-click on outside click
- Performance: cache status/primarySource/activeSessionCount, reduce observation polling
- UI: smooth hover animations, panel collapse delay, entrance transitions

### 中文
- 修复 OpenCode socket 死锁
- 修复会话状态卡住
- 修复 AskUserQuestion 解析
- 修复外部点击双击问题
- 性能优化：缓存状态属性，减少轮询频率
- UI：平滑悬停动画，面板折叠延迟，入场过渡动画

## [v1.0.3] - 2026-04-06

### English
- Update checker: auto-check on launch + manual check
- Per-CLI hook toggles
- Boot sound: 8-bit startup jingle
- Behavior animations: animated previews for each setting
- Fix release build crash, OpenCode plugin install, hook fallback socket path

### 中文
- 更新检查器：启动时自动检查 + 手动检查
- 按 CLI 独立开关 hooks
- 启动音效：8-bit 开机音
- 行为动画：每个设置项的动画预览
- 修复发布版本崩溃、OpenCode 插件安装、hook socket 路径回退

## [v1.0.1] - 2026-04-06

### English
- Fix release build crash on Mascots/Hooks pages
- Fix OpenCode plugin installation in release builds
- Fix hook script fallback socket path
- Remove redundant page titles in settings

### 中文
- 修复吉祥物和 Hooks 设置页崩溃
- 修复发布版本中 OpenCode 插件安装
- 修复 hook 脚本 socket 路径回退
- 移除设置中多余的页面标题

## [v1.0.0] - 2026-04-06

### English
- Initial release

### 中文
- 初始发布
