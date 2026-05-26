# Code Island App Store Release Checklist

This checklist covers the iPhone, Live Activity, Dynamic Island, StandBy, Apple Watch app, and watchOS widget companion for Code Island.

## Before Uploading a Build

1. Confirm Apple Developer signing is selected for every target:
   - `CodeIslandCompanion`
   - `CodeIslandCompanionWidget`
   - `CodeIslandWatchApp`
   - `CodeIslandWatchWidget`

2. Confirm the app can be reviewed without a Mac:
   - Launch the iPhone app.
   - Tap `进入演示模式`.
   - Tap `开启实时活动` to show the Live Activity / Dynamic Island preview.
   - Open the Apple Watch app and confirm it receives the demo state.

3. Confirm the real Mac path still works:
   - Run the matching Code Island Mac build from this branch.
   - Open Code Island Settings -> Buddy.
   - Enable Apple Companion advertising.
   - Connect from iPhone and verify state updates.

4. Run local verification:

```bash
scripts/check-companion-ui-regressions.sh
scripts/smoke-companion-ui.sh
scripts/smoke-companion-watch-ui.sh
swift test --filter AppleCompanionPayloadTests
```

5. Archive from Xcode:
   - Select `Any iOS Device (arm64)` or a connected iPhone.
   - Choose `Product -> Archive`.
   - In Organizer, choose `Distribute App -> App Store Connect -> Upload`.

## App Store Connect Metadata

Suggested app name:

```text
Code Island
```

Suggested subtitle:

```text
AI agent status on iPhone and Watch
```

Suggested Chinese subtitle:

```text
把 Mac 上的 AI 会话带到 iPhone 和手表
```

Suggested short description:

```text
Code Island mirrors the current Code Island session from your Mac to iPhone Dynamic Island, Lock Screen, StandBy, and Apple Watch. It helps you keep an eye on agent state, recent messages, tool use, and questions that need attention.
```

Suggested Chinese description:

```text
Code Island 是 Mac 端 Code Island 的 iPhone 与 Apple Watch 伴随应用。

它可以把 Mac 上当前 AI agent 的状态同步到 iPhone、灵动岛、锁屏、StandBy 和 Apple Watch。你可以查看当前会话、工具调用、最近动态，以及需要回答的问题；需要处理时，再回到 Mac 继续操作。

应用支持本地网络发现 Mac，并提供演示模式，方便在没有 Mac companion 的情况下预览完整体验。
```

Suggested keywords:

```text
AI,agent,developer,Mac,Dynamic Island,StandBy,Apple Watch,productivity
```

Suggested support URL:

```text
https://github.com/fengye404/CodeIsland/issues
```

Suggested marketing URL:

```text
https://github.com/fengye404/CodeIsland
```

Privacy policy:

Publish `apple-companion/PRIVACY_POLICY.md` somewhere public, for example GitHub Pages, and use that public URL in App Store Connect.

## App Privacy Answers

Current intended privacy posture:

- Data collection: no data collected by the developer.
- Tracking: no tracking.
- Third-party advertising: none.
- Account creation: none.
- Local network: used only to discover and communicate with the user's own Mac running Code Island.
- Bluetooth: used only as a lightweight local companion signal between the user's own devices.

If new analytics, crash reporting, cloud sync, or third-party SDKs are added later, update these answers before submission.

## Export Compliance

The app uses Apple's local networking and platform security APIs. It does not implement custom encryption. When App Store Connect asks export compliance questions, answer based on the final binary and Apple's current wording. If the app only uses standard Apple-provided encryption, it usually falls under the platform-provided encryption path rather than a custom cryptography product.

## Review Notes

Use the template in `apple-companion/APP_REVIEW_NOTES.md`.

Important: tell reviewers about `进入演示模式`, because reviewers may not have the matching Mac companion available.

## Final Manual Test Matrix

| Area | Test |
| --- | --- |
| iPhone app | Launch, enter demo mode, switch demo state, exit demo mode |
| Local network | Connect to Mac, receive idle/running/question/interrupted state |
| Live Activity | Start, update, stop, verify Dynamic Island and Lock Screen |
| Background | Put iPhone app in background, trigger Mac state update, verify Live Activity update if system schedules it |
| Watch app | Install, launch, receive state from iPhone, scroll status/message/actions/activity pages |
| Watch widget | Add widget / Smart Stack item, verify latest state appears |
| Permissions | Local Network, Bluetooth, Notifications |
| Failure modes | Mac not found, Mac disconnected, iPhone app relaunched, Watch launched before iPhone sync |
