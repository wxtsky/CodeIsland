# CodeIsland Companion Prototype

This folder contains the first iPhone-side prototype for the Apple ecosystem
companion. It is intentionally source-first while the Apple Developer Program
enrollment is still pending.

## Current prototype

- Discovers the Mac app over MultipeerConnectivity service `codeisland`
- Connects to the Mac advertiser
- Decodes `AppleCompanionStatePayload` JSON updates
- Shows source, status, workspace, current tool, and message previews
- Sends approve / deny / skip commands back to the Mac

## Xcode setup

Generate the project with XcodeGen:

```bash
cd ios/CodeIslandCompanion
xcodegen generate
open CodeIslandCompanion.xcodeproj
```

The generated project includes:

- `CodeIslandCompanion` iPhone app
- `CodeIslandCompanionWidget` WidgetKit extension
- shared ActivityKit attributes in `Shared/`

The app `Info.plist` includes local-network discovery and Live Activity support:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>CodeIsland discovers your Mac on the local network to mirror agent status.</string>
<key>NSBonjourServices</key>
<array>
  <string>_codeisland._tcp</string>
</array>
```

When the paid Apple Developer Program account is active, set your team in Xcode
for both targets. The watchOS target is the next milestone after the iPhone Live
Activity path is stable.
