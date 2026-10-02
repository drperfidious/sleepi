# sleepi

A calm sleep app for iPhone and Apple Watch. sleepi works with Apple Health and the Watch's own sleep tracking instead of replacing them: Apple keeps measuring your sleep stages, your Clock alarm and Sleep Focus stay as they are, and sleepi adds what Apple doesn't.

**Free forever. No ads, no subscription, no account, no server.** Nothing leaves your phone except an export you choose to share. sleepi never writes to Health and never starts a workout on the Watch.

## What it does

- **Last Night and Trends** from Apple Watch sleep: stages, wake-ups, in-bed estimates from your Tonight start and end, schedule consistency, a shortfall against your own target, and a "vs Apple" line that names every night sleepi counted differently (overlapping records merged, nights the Watch stopped recording left out).
- **Sound highlights** from the iPhone's microphone, classified on the device by Apple's built-in sound classifier (snoring, talking, coughing, room sounds). Short clips only, deleted after 14 days unless starred.
- **Phone-only nights** without a Watch: the iPhone listens for sound levels and notices phone use to estimate when you fell asleep, when you woke for good and when you were up. Estimates are labelled as estimates; phones can't tell sleep stages.
- **Gentle wake** on Apple Watch: a silent wrist tap in a window before your chosen time once you've been restless for about a minute, with Snooze and Wake Up. Your Clock alarm stays the real alarm.
- **Morning sleep diary**: a 1–5 rating and tags for the evening before, with "linked" results that only appear when a weekday/weekend-matched permutation test with multiple-comparison control holds up.
- **Export** of sleepi's own per-night data as CSV.

## Build

Open `Sleepi.xcodeproj` in Xcode 26 or newer (iOS 26 and watchOS 26 minimums). Set your own signing team in `project.yml` (`DEVELOPMENT_TEAM`), run `scripts/generate_project.sh` (XcodeGen), and enable HealthKit for your App ID. Run the **Sleepi** scheme on an iPhone and the **SleepiWatch** scheme on an Apple Watch.

```sh
./scripts/test.sh                                                     # unit tests and architecture checks
DEVELOPER_DIR=/path/to/Xcode.app/Contents/Developer ./scripts/build.sh  # all native targets, unsigned
./scripts/preview.sh                                                  # Mac preview with synthetic data
```

No third-party runtime dependencies. Design notes and the research behind each feature are in `docs/` and `refs/` (start with `refs/06-claude-audit.md`).

## License

GPL-3.0. Copyright (C) 2026 Randy Duquette. See [LICENSE](LICENSE).
