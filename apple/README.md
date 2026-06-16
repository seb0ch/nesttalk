# NestTalk Apple Client

Native Swift/SwiftUI client for iOS, iPadOS, and macOS. Replaces the retired Flutter client (`../client/` — removed in v0.4.0).

## Requirements

- Xcode 16+ (tested with 26.4.1)
- `xcodegen` — `brew install xcodegen`
- Apple Developer Program account (for signed builds)

## First-time setup

```bash
# 1. Install xcodegen if you haven't
brew install xcodegen

# 2. Generate the Xcode project from project.yml
cd apple
xcodegen generate

# 3. Open in Xcode
open NestTalk.xcodeproj
```

The `NestTalk.xcodeproj` is gitignored and regenerated from `project.yml`. Edit `project.yml` rather than the project file.

## Build

```bash
# macOS (no code signing needed for debug)
xcodebuild -scheme NestTalk-macOS -destination 'platform=macOS' build

# iOS simulator
xcodebuild -scheme NestTalk-iOS -destination 'platform=iOS Simulator,name=iPhone 15' build

# iOS device (needs DEVELOPMENT_TEAM set in project.yml)
xcodebuild -scheme NestTalk-iOS -destination 'generic/platform=iOS' -allowProvisioningUpdates build
```

## Test

```bash
xcodebuild test -scheme NestTalkTests -destination 'platform=macOS'
```

## Layout

```
apple/
  project.yml              # xcodegen source of truth
  README.md
  .gitignore
  NestTalk/
    Shared/                # code shared across iOS + iPadOS + macOS
      App/                 # @main, WindowGroup
      Transport/           # REALITY via Libbox + URLSession APIClient
      Identity/            # CryptoKit Ed25519 + Keychain + enroll/connect
      Messaging/           # GRDB-backed local history, hybrid-PQC crypto
      Calls/               # WebRTC peer + CallKit + PushKit
      UI/
        Theme/             # HearthPalette, Typography
        Onboarding/        # WelcomeView, InviteScanView
        ChatList/          # ChatListView, FamilyCircleShelfView
        ChatThread/        # ChatThreadView, MessageBubble
        Call/              # CallView
        Settings/          # SettingsView
      Resources/
        Fonts/             # Fraunces, Inter, JetBrainsMono TTFs
        Assets.xcassets/   # AppIcon, LoginHero
    iOS/                   # iOS-only (URL scheme, Info.plist, PushKit registration)
    macOS/                 # macOS-only
  NestTalkTests/           # XCTest
  ThirdParty/
    Libbox.xcframework     # sing-box / REALITY transport
    libbox-version.txt     # pinned upstream commits
```

## Distribution

See `../CLAUDE.md` § Distribution. Short version: sideload / TestFlight / Developer-signed. No App Store.

## Status

v0.4.0 is in **spike phase**. Current authoritative plan:

- `../docs/superpowers/specs/2026-04-24-v0.4.0-swift-native-rewrite-design.md`
- `../docs/superpowers/plans/2026-04-24-v0.4.0-spike-plan.md`

After the 5-day spike, a full implementation plan will be drafted.
