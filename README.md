# sleepi

A calm iPhone and Apple Watch sleep companion. Apple supplies the estimated sleep stages. sleepi adds local notes, understandable trends and optional sound highlights, without writing to Health or replacing Clock alarms.

**Status:** initial native implementation and runnable Mac UI preview. All four targets compile with Xcode 27.2 beta (simulator and unsigned device builds, see the audit); signed installation and every overnight trial remain unverified. Watch motion and gentle wake default off.

## Start here

- [Claude audit](refs/06-claude-audit.md): findings, fixes and build evidence from the 2026-10-01 audit.
- [Fable handoff](docs/HANDOFF.md): evidence, limitations and review priorities.
- [Validated findings](refs/05-validation-and-decisions.md): confirmed, qualified and falsified reference claims.
- [Revised plan](docs/PLAN.md): implementation boundaries and device gates.
- Original product/research material is preserved in `refs/01`–`04` and `refs/architecture.png`.

## Run the preview and checks

```sh
./scripts/test.sh
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer ./scripts/build.sh  # all four native targets, unsigned
./scripts/preview.sh
```

The Mac preview uses clearly labeled synthetic data. It never reads your Health records or microphone and never saves its demo state. It exercises the same SwiftUI screens and shared model used by the iPhone app.

## Build for iPhone and Watch

Open `Sleepi.xcodeproj` in Xcode 26 or newer with the iOS/watchOS SDKs installed. Choose a signing team for each target. Replace the `app.sleepi.ios` bundle-ID family in `project.yml` if necessary for your account, regenerate, and enable the corresponding HealthKit capability. Select **Sleepi** for iPhone or **SleepiWatch** for Watch. Deployment minimums are iOS 26 and watchOS 26 (Series 8).

```sh
xcodebuild -project Sleepi.xcodeproj -scheme Sleepi \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Sleepi.xcodeproj -scheme SleepiWatch \
  -destination 'generic/platform=watchOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

The project is generated from `project.yml` with XcodeGen 2.46.0. It is included so XcodeGen isn't required merely to open/build it. After changing the spec, run `scripts/generate_project.sh`. The generator is a development tool, not an app dependency.

Watch gentle wake and motion recording are per-night experiments: switches in the Watch start sheet that are off every time it opens. Never disable Apple's tracking or alarm to accommodate sleepi.

## Layout

`Sources/SleepiCore` contains deterministic models, algorithms and storage. `Apps/Shared` holds SwiftUI and the observable application model. `Apps/Audio` holds the queue-confined SoundAnalysis/AAC pipeline. `Apps/iOS` and `Apps/Watch` provide platform adapters. Widget/control targets and shared intents are separate. `Tests` exercises algorithms and lifecycle boundaries.

There are no accounts, subscriptions, analytics, ad SDKs, servers, Health write permissions, workout sessions, or CloudKit containers. Personal sleep notes and clips live only on-device and are excluded from backups. See the handoff for the locked-recording protection tradeoff and remaining device risks.
