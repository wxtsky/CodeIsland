# Notch Gesture Support Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add configurable hover opening, click opening, local two-finger trackpad gestures, and horizontal `ALL` / `STA` / `CLI` filter navigation to CodeIsland's notch header.

**Architecture:** A pure `NotchGestureInterpreter` converts normalized AppKit scroll samples into semantic actions, while a lifecycle-owned local event monitor observes only the notch header region. `NotchPanelView` owns state-aware action routing, and persisted settings plus a dedicated Gestures page control hover behavior.

**Tech Stack:** Swift 5.9+, SwiftUI, AppKit `NSEvent`, UserDefaults/AppStorage, XCTest, Swift Package Manager

**Spec:** `docs/superpowers/specs/2026-08-14-notch-gesture-support-design.md`

## Global Constraints

- Keep the deployment floor at macOS 14 and add no dependencies.
- Recognize gestures only while the pointer is inside the visible notch header.
- Default Open on hover to `true` and hover delay to `0.5` seconds.
- Clamp hover delay to `0.1...1.5` seconds in `0.1`-second UI steps.
- Keep the existing `0.5`-second mouse-leave close delay unchanged.
- Never let a gesture approve, deny, answer, skip, or dismiss a pending request.
- Horizontal physical swipe left navigates right; physical swipe right navigates left; filters clamp without wrapping.
- Preserve Smart Suppress for hover opening only; click and swipe-down are explicit opening actions.

---

### Task 1: Persisted Hover Settings

**Files:**
- Modify: `Sources/CodeIsland/Settings.swift`
- Create: `Tests/CodeIslandTests/NotchGestureSettingsTests.swift`

**Interfaces:**
- Produces: `HoverOpenDelay.minimum`, `.maximum`, `.step`, and `clamped(_:)`.
- Produces: `SettingsKey.openOnHover`, `SettingsKey.hoverOpenDelay`.
- Produces: `SettingsDefaults.openOnHover == true`, `SettingsDefaults.hoverOpenDelay == 0.5`.
- Produces: `SettingsManager.openOnHover: Bool`, `SettingsManager.hoverOpenDelay: Double`.

- [ ] **Step 1: Write failing settings tests**

```swift
import XCTest
@testable import CodeIsland

final class NotchGestureSettingsTests: XCTestCase {
    func testHoverSettingsPreserveExistingDefaults() {
        XCTAssertTrue(SettingsDefaults.openOnHover)
        XCTAssertEqual(SettingsDefaults.hoverOpenDelay, 0.5, accuracy: 0.001)
    }

    func testHoverDelayBoundsAndStepAreStable() {
        XCTAssertEqual(HoverOpenDelay.minimum, 0.1, accuracy: 0.001)
        XCTAssertEqual(HoverOpenDelay.maximum, 1.5, accuracy: 0.001)
        XCTAssertEqual(HoverOpenDelay.step, 0.1, accuracy: 0.001)
    }

    func testHoverDelayClampsMalformedSavedValues() {
        XCTAssertEqual(HoverOpenDelay.clamped(-4), 0.1, accuracy: 0.001)
        XCTAssertEqual(HoverOpenDelay.clamped(0.7), 0.7, accuracy: 0.001)
        XCTAssertEqual(HoverOpenDelay.clamped(8), 1.5, accuracy: 0.001)
    }
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `swift test --filter NotchGestureSettingsTests`

Expected: compilation fails because the new settings symbols do not exist.

- [ ] **Step 3: Add the minimal settings implementation**

Add near the other settings value helpers:

```swift
enum HoverOpenDelay {
    static let minimum = 0.1
    static let maximum = 1.5
    static let step = 0.1

    static func clamped(_ value: Double) -> Double {
        min(max(value, minimum), maximum)
    }
}
```

Add keys, defaults, default registration, and manager accessors:

```swift
static let openOnHover = "openOnHover"
static let hoverOpenDelay = "hoverOpenDelay"

static let openOnHover = true
static let hoverOpenDelay = 0.5

var openOnHover: Bool {
    get { defaults.bool(forKey: SettingsKey.openOnHover) }
    set { defaults.set(newValue, forKey: SettingsKey.openOnHover) }
}

var hoverOpenDelay: Double {
    get { HoverOpenDelay.clamped(defaults.double(forKey: SettingsKey.hoverOpenDelay)) }
    set { defaults.set(HoverOpenDelay.clamped(newValue), forKey: SettingsKey.hoverOpenDelay) }
}
```

- [ ] **Step 4: Run the focused tests and verify pass**

Run: `swift test --filter NotchGestureSettingsTests`

Expected: PASS.

- [ ] **Step 5: Commit the settings contract**

```bash
git add Sources/CodeIsland/Settings.swift Tests/CodeIslandTests/NotchGestureSettingsTests.swift
git commit -m "feat(settings): add notch hover preferences"
```

### Task 2: Pure Trackpad Gesture Interpreter

**Files:**
- Create: `Sources/CodeIsland/NotchGesture.swift`
- Create: `Tests/CodeIslandTests/NotchGestureInterpreterTests.swift`

**Interfaces:**
- Produces: `enum NotchGestureAction: Equatable { case open, close, navigatePrevious, navigateNext }`.
- Produces: `struct NotchScrollSample` with physical deltas, phase flags, precision, and momentum state.
- Produces: `struct NotchGestureInterpreter` with `mutating func consume(_:) -> NotchGestureAction?` and `mutating func reset()`.

- [ ] **Step 1: Write failing interpreter tests**

Cover these exact cases using a local sample helper:

```swift
func testPhysicalDirectionsMapToNaturalNotchActions() {
    XCTAssertEqual(action(x: -30, y: 0), .navigateNext)
    XCTAssertEqual(action(x: 30, y: 0), .navigatePrevious)
    XCTAssertEqual(action(x: 0, y: -30), .open)
    XCTAssertEqual(action(x: 0, y: 30), .close)
}

func testGestureRequiresThresholdAndDominantAxis() {
    XCTAssertNil(action(x: 8, y: 0))
    XCTAssertNil(action(x: 30, y: 28))
}

func testGestureEmitsOnlyOnceUntilEnded() {
    var interpreter = NotchGestureInterpreter()
    XCTAssertEqual(interpreter.consume(sample(x: -30, phase: .changed)), .navigateNext)
    XCTAssertNil(interpreter.consume(sample(x: -30, phase: .changed)))
    XCTAssertNil(interpreter.consume(sample(phase: .ended)))
    XCTAssertEqual(interpreter.consume(sample(x: -30, phase: .began)), .navigateNext)
}

func testMomentumAndNonPreciseScrollAreIgnored() {
    var interpreter = NotchGestureInterpreter()
    XCTAssertNil(interpreter.consume(sample(y: -40, momentum: true)))
    XCTAssertNil(interpreter.consume(sample(y: -40, precise: false)))
}
```

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `swift test --filter NotchGestureInterpreterTests`

Expected: compilation fails because the interpreter types do not exist.

- [ ] **Step 3: Implement the minimal interpreter**

Use a 24-point activation threshold and 1.2 axis-dominance ratio. Accumulate deltas between `.began` and `.ended`, ignore momentum and imprecise wheel input, set an `emitted` flag after the first action, and reset on end/cancel.

Normalize AppKit events at the boundary:

```swift
extension NotchScrollSample {
    init(event: NSEvent) {
        let direction: CGFloat = event.isDirectionInvertedFromDevice ? -1 : 1
        self.init(
            physicalDeltaX: event.scrollingDeltaX * direction,
            physicalDeltaY: event.scrollingDeltaY * direction,
            began: event.phase.contains(.began),
            ended: event.phase.contains(.ended) || event.phase.contains(.cancelled),
            momentum: !event.momentumPhase.isEmpty,
            precise: event.hasPreciseScrollingDeltas
        )
    }
}
```

- [ ] **Step 4: Run focused tests and verify pass**

Run: `swift test --filter NotchGestureInterpreterTests`

Expected: PASS.

- [ ] **Step 5: Commit the interpreter**

```bash
git add Sources/CodeIsland/NotchGesture.swift Tests/CodeIslandTests/NotchGestureInterpreterTests.swift
git commit -m "feat(gestures): interpret notch trackpad swipes"
```

### Task 3: State-aware Gesture Policy

**Files:**
- Modify: `Sources/CodeIsland/NotchGesture.swift`
- Create: `Tests/CodeIslandTests/NotchGesturePolicyTests.swift`

**Interfaces:**
- Produces: `NotchGesturePolicy.canOpen(surface:hasSessions:) -> Bool`.
- Produces: `NotchGesturePolicy.canClose(surface:) -> Bool`.
- Produces: `NotchGesturePolicy.filterMode(from:action:controlsVisible:) -> String?`.

- [ ] **Step 1: Write failing policy tests**

```swift
func testOnlyCollapsedNotchWithSessionsCanOpen() {
    XCTAssertTrue(NotchGesturePolicy.canOpen(surface: .collapsed, hasSessions: true))
    XCTAssertFalse(NotchGesturePolicy.canOpen(surface: .sessionList, hasSessions: true))
    XCTAssertFalse(NotchGesturePolicy.canOpen(surface: .collapsed, hasSessions: false))
}

func testCloseProtectsApprovalAndQuestionCards() {
    XCTAssertTrue(NotchGesturePolicy.canClose(surface: .sessionList))
    XCTAssertTrue(NotchGesturePolicy.canClose(surface: .completionCard(sessionId: "s")))
    XCTAssertFalse(NotchGesturePolicy.canClose(surface: .approvalCard(sessionId: "s")))
    XCTAssertFalse(NotchGesturePolicy.canClose(surface: .questionCard(sessionId: "s")))
    XCTAssertFalse(NotchGesturePolicy.canClose(surface: .collapsed))
}

func testFilterNavigationUsesNaturalDirectionAndClamps() {
    XCTAssertEqual(NotchGesturePolicy.filterMode(from: "all", action: .navigateNext, controlsVisible: true), "status")
    XCTAssertEqual(NotchGesturePolicy.filterMode(from: "status", action: .navigateNext, controlsVisible: true), "cli")
    XCTAssertEqual(NotchGesturePolicy.filterMode(from: "cli", action: .navigateNext, controlsVisible: true), "cli")
    XCTAssertEqual(NotchGesturePolicy.filterMode(from: "status", action: .navigatePrevious, controlsVisible: true), "all")
    XCTAssertEqual(NotchGesturePolicy.filterMode(from: "all", action: .navigatePrevious, controlsVisible: true), "all")
    XCTAssertNil(NotchGesturePolicy.filterMode(from: "all", action: .navigateNext, controlsVisible: false))
}
```

- [ ] **Step 2: Run focused tests and verify failure**

Run: `swift test --filter NotchGesturePolicyTests`

Expected: compilation fails because `NotchGesturePolicy` does not exist.

- [ ] **Step 3: Implement the policy**

Use a fixed mode order:

```swift
enum NotchGesturePolicy {
    private static let filterModes = ["all", "status", "cli"]

    static func canOpen(surface: IslandSurface, hasSessions: Bool) -> Bool {
        surface == .collapsed && hasSessions
    }

    static func canClose(surface: IslandSurface) -> Bool {
        switch surface {
        case .sessionList, .completionCard: return true
        case .collapsed, .approvalCard, .questionCard: return false
        }
    }
}
```

Implement `filterMode` with a clamped index and return `nil` when controls are hidden or the action is not horizontal.

- [ ] **Step 4: Run focused tests and verify pass**

Run: `swift test --filter NotchGesturePolicyTests`

Expected: PASS.

- [ ] **Step 5: Commit the policy**

```bash
git add Sources/CodeIsland/NotchGesture.swift Tests/CodeIslandTests/NotchGesturePolicyTests.swift
git commit -m "feat(gestures): add notch action policy"
```

### Task 4: Gestures Settings Page, Localization, and Diagnostics

**Files:**
- Modify: `Sources/CodeIsland/SettingsView.swift`
- Modify: `Sources/CodeIsland/L10n.swift`
- Modify: `Sources/CodeIsland/DiagnosticsExporter.swift`
- Modify: `Tests/CodeIslandTests/L10nTests.swift`

**Interfaces:**
- Produces: `SettingsPage.gestures` between Behavior and Appearance.
- Consumes: Task 1 settings and `HoverOpenDelay` constants.

- [ ] **Step 1: Add failing localization assertions**

Extend each existing translation-value test to assert that `L10n.shared["gestures"]` returns the expected localized page name. Add a test that every supported non-English dictionary contains all English keys, including `zh` and `zh-Hant`.

- [ ] **Step 2: Run localization tests and verify failure**

Run: `swift test --filter L10nTests`

Expected: FAIL because gesture keys and translations are missing.

- [ ] **Step 3: Add the Gestures page and localized copy**

Add `.gestures` to `SettingsPage`, its icon/color switch cases, the first sidebar group after `.behavior`, and the detail switch.

Create `GesturesPage` with:

```swift
@AppStorage(SettingsKey.openOnHover) private var openOnHover = SettingsDefaults.openOnHover
@AppStorage(SettingsKey.hoverOpenDelay) private var hoverOpenDelay = SettingsDefaults.hoverOpenDelay
@AppStorage(SettingsKey.hapticOnHover) private var hapticOnHover = SettingsDefaults.hapticOnHover
@AppStorage(SettingsKey.hapticIntensity) private var hapticIntensity = SettingsDefaults.hapticIntensity
```

The page uses a grouped `Form`, an Open on hover toggle, a slider bound to `HoverOpenDelay.minimum...maximum` with `step: HoverOpenDelay.step`, a formatted seconds label, moved haptic controls, and a four-row gesture reference. Remove only the moved haptic controls from `BehaviorPage`; leave all other behavior settings untouched.

Add these keys to every language dictionary with real localized strings:

```text
gestures
gesture_opening
open_on_hover
open_on_hover_desc
hover_open_delay
seconds_short
gesture_reference
gesture_click_open
gesture_swipe_down_open
gesture_swipe_up_close
gesture_swipe_horizontal_filter
```

- [ ] **Step 4: Export the settings in diagnostics**

Add `openOnHover` and the clamped `hoverOpenDelay` to the diagnostics metadata settings dictionary.

- [ ] **Step 5: Run localization and settings tests**

Run: `swift test --filter L10nTests`

Run: `swift test --filter NotchGestureSettingsTests`

Expected: PASS.

- [ ] **Step 6: Commit the settings UI**

```bash
git add Sources/CodeIsland/SettingsView.swift Sources/CodeIsland/L10n.swift Sources/CodeIsland/DiagnosticsExporter.swift Tests/CodeIslandTests/L10nTests.swift
git commit -m "feat(settings): add gesture controls"
```

### Task 5: Notch Event Monitor and View Integration

**Files:**
- Modify: `Sources/CodeIsland/NotchGesture.swift`
- Modify: `Sources/CodeIsland/NotchPanelView.swift`
- Modify: `Tests/CodeIslandTests/NotchPanelViewTests.swift`

**Interfaces:**
- Produces: lifecycle-owned `NotchGestureMonitor.start(onAction:)`, `.isEnabled`, and `.stop()`.
- Consumes: gesture interpreter, policy, settings, AppState surface, and session grouping preference.

- [ ] **Step 1: Add failing hover regression tests**

Extend `NotchHoverInteractionTests` to assert that `HoverOpenDelay.clamped` supplies the configurable open timer while `NotchHoverInteraction.collapseDelay` remains exactly `0.5`. Add a state-machine regression showing disabling hover while in prehover returns the visual phase to collapsed through a new `.hoverDisabled` event.

- [ ] **Step 2: Run the focused tests and verify failure**

Run: `swift test --filter NotchHoverInteractionTests`

Expected: FAIL because `.hoverDisabled` is not defined.

- [ ] **Step 3: Add the local AppKit monitor**

Implement a small `@MainActor` reference type in `NotchGesture.swift`:

```swift
final class NotchGestureMonitor {
    var isEnabled = false
    private var monitor: Any?
    private var interpreter = NotchGestureInterpreter()

    func start(onAction: @escaping (NotchGestureAction) -> Void) {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.isEnabled else { return event }
            guard let action = self.interpreter.consume(NotchScrollSample(event: event)) else { return event }
            onAction(action)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        interpreter.reset()
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}
```

If Swift concurrency rejects AppKit monitor removal from `deinit`, make `stop()` the lifecycle guarantee and omit only the `deinit` fallback rather than weakening actor isolation.

- [ ] **Step 4: Integrate the compact/header region**

In `NotchPanelView`:

- add AppStorage for `openOnHover`, `hoverOpenDelay`, and parent-level `sessionGroupingMode`;
- preserve a `NotchGestureMonitor` and `gestureRegionHovered` state;
- attach hover tracking and click-open to the compact/header strip, not the expanded card body;
- start/stop the monitor with view appearance;
- route semantic actions through small `openSessionList`, `closeForGesture`, and `handleGestureAction` methods using `NotchGesturePolicy`;
- make click open-only and require a collapsed surface with sessions;
- use the configured, clamped delay only when Open on hover is enabled;
- cancel pending prehover and timers when Open on hover becomes disabled;
- leave the existing mouse-leave collapse timer at `NotchHoverInteraction.collapseDelay`;
- preserve approval/question protection and completion-queue cancellation behavior.

- [ ] **Step 5: Run focused gesture and hover tests**

Run: `swift test --filter NotchGesture`

Run: `swift test --filter NotchHoverInteractionTests`

Expected: PASS.

- [ ] **Step 6: Run full verification**

Run: `swift test`

Run: `swift build`

Expected: both commands exit 0.

- [ ] **Step 7: Commit the integration**

```bash
git add Sources/CodeIsland/NotchGesture.swift Sources/CodeIsland/NotchPanelView.swift Tests/CodeIslandTests/NotchPanelViewTests.swift
git commit -m "feat(notch): add configurable trackpad gestures"
```

### Task 6: Final Diff Review and Draft PR

**Files:**
- Review all files changed from `upstream/main`.
- Update: `docs/superpowers/plans/2026-08-14-notch-gesture-support.md` checkboxes if tracked in the PR.

**Interfaces:**
- Consumes: all prior tasks.
- Produces: a pushed fork branch and draft PR targeting `wxtsky/CodeIsland:main`.

- [ ] **Step 1: Review scope and diff hygiene**

Run: `git status -sb`

Run: `git diff --check upstream/main...HEAD`

Run: `git diff --stat upstream/main...HEAD`

Run: `git log --oneline upstream/main..HEAD`

Expected: only the approved design, plan, settings, gesture implementation, localization, diagnostics, and tests are present.

- [ ] **Step 2: Re-run release-facing verification**

Run: `swift test`

Run: `swift build`

Expected: both commands exit 0 with fresh output.

- [ ] **Step 3: Push to the authenticated user's fork**

Ensure remotes are:

```text
origin   git@github.com:Mrjamedd/CodeIsland.git
upstream https://github.com/wxtsky/CodeIsland.git
```

Then run:

```bash
git push -u origin agent/notch-gesture-support
```

- [ ] **Step 4: Open the draft PR**

Create a draft PR against `wxtsky/CodeIsland:main` with title:

```text
feat(notch): add configurable trackpad gestures
```

The body must summarize settings, gestures, safety boundaries, user impact, and the exact verification commands. Use `Mrjamedd:agent/notch-gesture-support` as the cross-fork head.

- [ ] **Step 5: Report review handoff**

Provide the draft PR URL, branch, commits, tests, and any manual trackpad verification still recommended.
