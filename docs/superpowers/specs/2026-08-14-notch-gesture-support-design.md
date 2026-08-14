# Notch Gesture Support Design

## Summary

Add a dedicated **Gestures** settings page and native trackpad gesture support to CodeIsland's notch header. Users can choose whether hovering opens the notch, adjust the hover-to-open delay, click or swipe down to open, swipe up to close eligible surfaces, and swipe horizontally to change the existing `ALL` / `STA` / `CLI` session filter.

The change stays limited to notch interaction behavior, settings, localization, diagnostics, and focused tests. It does not alter session processing, permission decisions, question answers, or terminal activation.

## Goals

- Let users disable hover-to-open without losing direct ways to open the notch.
- Make hover-to-open timing configurable from 0.1 to 1.5 seconds.
- Add reliable two-finger trackpad gestures scoped to the visible notch header.
- Preserve current safety rules for approval and question cards.
- Preserve existing defaults for current users.

## Non-goals

- Global gestures outside the notch header.
- Keyboard shortcut changes.
- Gesture customization or arbitrary gesture-to-action mapping.
- Changes to mouse-leave timing, permission handling, session data, or panel layout.
- Navigation between individual session cards.

## User Experience

### Gestures settings page

Add `Gestures` to the settings sidebar immediately after `Behavior`.

The page contains:

1. **Open on hover**, enabled by default to preserve current behavior.
2. **Hover delay**, visible or enabled only when Open on hover is enabled.
   - Range: 0.1 to 1.5 seconds.
   - Step: 0.1 seconds.
   - Default: 0.5 seconds, matching the current fixed delay.
3. The existing hover haptic toggle and intensity control, moved from Behavior to Gestures so all hover interaction preferences remain together.
4. A concise, localized gesture reference describing click, swipe down, swipe up, and horizontal filter navigation.

The existing `collapseOnMouseLeave` preference and its 0.5-second close delay remain unchanged.

### Opening

- When **Open on hover** is enabled, pointer entry keeps the current prehover animation and opens after the configured delay.
- When **Open on hover** is disabled, pointer entry does not start the prehover or opening timer.
- Clicking the collapsed compact notch opens the session list immediately. Clicking is open-only; it does not close an expanded notch.
- A two-finger swipe down over the notch header opens the session list immediately.
- Click and swipe-down are intentional actions, so they open regardless of Smart Suppress. Smart Suppress continues to affect hover-only opening.

### Closing

- Leaving an expanded view keeps the current mouse-leave behavior and 0.5-second grace delay.
- A two-finger swipe up over the notch header closes `.sessionList` and `.completionCard` immediately.
- Swipe up is ignored for `.approvalCard` and `.questionCard`. It never approves, denies, answers, skips, or dismisses a pending request.
- Swiping up while already collapsed is a no-op.

### Filter navigation

Horizontal two-finger swipes navigate the existing `ALL` / `STA` / `CLI` session filters when the expanded session-list header is showing those controls.

- A physical swipe left advances the selection visually to the right: `ALL` to `STA`, then `STA` to `CLI`.
- A physical swipe right moves the selection visually to the left.
- Navigation stops at `ALL` and `CLI`; it never wraps.
- Horizontal navigation is ignored when the filter controls are not visible.

### Gesture scope

Gestures are recognized only while the pointer is inside the visible compact/header strip of the notch. Transparent parts of the panel window and the scrollable session-card body do not participate. This prevents interference with ordinary scrolling elsewhere.

## Architecture

### Gesture interpreter

Add a small pure Swift gesture interpreter in the CodeIsland target. It consumes normalized AppKit scroll samples and emits semantic actions:

- `open`
- `close`
- `navigatePrevious`
- `navigateNext`

The interpreter:

- accumulates precise scroll deltas for one gesture sequence;
- locks to the dominant axis before emitting an action;
- normalizes device-direction metadata so physical finger movement follows the agreed natural direction;
- ignores momentum-only events;
- emits at most one action per gesture sequence;
- resets when the gesture ends or is cancelled;
- uses a small activation threshold to reject incidental trackpad noise.

All threshold, axis-locking, direction, and one-action behavior is unit-testable without creating an AppKit window.

### AppKit event monitor

Add a lifecycle-owned local `NSEvent` monitor for `.scrollWheel` events. The monitor forwards precise samples to the interpreter only while SwiftUI reports that the pointer is inside the notch header gesture region.

The monitor does not install a global listener and does not interpret events outside the region. It consumes a scroll sequence only after the interpreter recognizes a notch action, avoiding broad interference with regular scrolling.

The monitor exposes semantic actions to `NotchPanelView`; it does not mutate `AppState` or settings directly.

### SwiftUI action routing

`NotchPanelView` owns the interaction policy:

- open actions set the surface to `.sessionList` and preserve the existing active-session fallback;
- close actions check the current surface and preserve protected approval/question cards;
- filter actions update `sessionGroupingMode` using the fixed ordered list `all`, `status`, `cli` with clamped indices;
- header hover state enables or disables event interpretation;
- click-to-open attaches to the collapsed compact header without covering expanded buttons or cards;
- hover opening reads the new settings instead of the current fixed delay.

Keep the pure filter-step calculation separate from rendering so boundary behavior is unit-tested.

### Settings and localization

Add persisted settings with registered defaults:

- `openOnHover: Bool = true`
- `hoverOpenDelay: Double = 0.5`

Add a `.gestures` settings page, localized sidebar title, control labels, descriptions, and gesture reference strings for every localization dictionary already maintained in `L10n.swift`.

Include the new settings in diagnostics export alongside the existing interaction preferences.

## Error and Edge-case Handling

- A missing or malformed saved hover delay is clamped to the supported 0.1-to-1.5-second range before scheduling a timer.
- Disabling Open on hover cancels any pending hover-open timer and clears prehover state.
- Re-entering during the mouse-leave grace period cancels collapse exactly as it does today.
- Gesture actions are state-aware and become no-ops when the current surface cannot accept them.
- Momentum scrolling cannot trigger a second action after the user's fingers leave the trackpad.
- Filter navigation remains stable if session count changes during a gesture.

## Testing

Add focused unit tests for:

- gesture axis locking and activation threshold;
- physical swipe directions, including device-direction normalization;
- one action per gesture and momentum suppression;
- swipe-down open and swipe-up close action classification;
- filter movement in both directions and clamping at `ALL` / `CLI`;
- protected approval/question surfaces ignoring close actions;
- hover-delay clamping and default value;
- existing three-stage hover behavior using a configurable delay without changing the 0.5-second close delay;
- settings page registration and localization-key completeness where existing test patterns support it.

Validation will run the focused gesture/settings tests first, followed by the full Swift test suite and a debug build.

## Pull Request Shape

Use branch `agent/notch-gesture-support` and open a draft PR against `wxtsky/CodeIsland:main` from the user's fork. The PR will contain only the gesture implementation, settings/localization updates, diagnostics update, tests, and this design document.
