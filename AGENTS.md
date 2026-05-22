# Agent Instructions for CodeIsland

## Quality safety bars

Before reporting any task as complete, the agent MUST:

1. **Read before edit**: Always read the target file before editing. Never edit blind.
2. **Compile check**: After all edits, run `swift build -c release --arch arm64` (or `./build.sh`) to verify compilation. A known pre-existing error (`#Preview` macro in ClineView.swift) should be ignored — it is NOT caused by your changes.
3. **Verify the change**: After editing, grep or read the file to confirm the edit took effect (e.g., `grep -c "old_pattern" file` should return 0).
4. **No behavior changes**: Performance optimizations must not change user-visible behavior. Animations should look the same (just at a different frame rate). State transitions must remain identical.
5. **No collateral damage**: Do not modify code outside the scope of the assigned task. Do not add imports, refactor adjacent functions, or "improve" unrelated code.

## Parallel work strategy

- When a task affects many independent files (e.g., changing frame rates across 17 mascot views), spawn subagents to work in parallel.
- Each subagent should handle a self-contained unit of work with clear instructions.
- After all subagents complete, run a single build verification.

## Code style

- KISS: simple, minimal changes. No over-engineering.
- No comments unless the WHY is non-obvious.
- Prefer editing existing files. Do not create new files unless strictly necessary.
- Match existing code style and patterns in each file.

## Common pitfalls

- `TimelineView` frame rates: idle/sleep = **no TimelineView** (static `sleepCanvas(t: 0)`), work = `by: 0.05` (20fps), alert = `by: 0.03` (33fps). Never add TimelineView to idle scenes — static Canvas renders once with zero CPU cost.
- `@Observable` property writes trigger SwiftUI view invalidation. Always guard with `if oldValue != newValue`.
- `NSCache` uses `object(forKey:)` / `setObject(_:forKey:)`, not subscript syntax. Keys must be `NSString`, not `String`.
- The `sessions` dictionary in AppState is a single @Observable blob — any mutation to any session triggers observation callbacks for all views that read `sessions`.
- `ESP32StatePublisher.notifyDirty()` should only be called when derived state actually changed, not on every `refreshDerivedState()` invocation.
