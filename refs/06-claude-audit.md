# Claude audit of the Astra build

2026-10-01 · Branch `claude/audit` · Baseline commit `e4a2f5e` is the build exactly as handed over.

Read this after `01-sleepi-plan.md` and `05-validation-and-decisions.md`. It covers the monitoring technology (Watch sensors and runtime, HealthKit reads, audio), what sleepi adds over Apple Health, and the plan's ground rules. Everything listed under fixes is already changed on this branch.

## Summary

- **The ground rules hold.** No workout session or Health write exists anywhere, the Watch's only background mode is `alarm`, the Clock alarm and Sleep Focus are untouched, and every entry point opens a choice. Evidence is in the ground-rules table below, checked against the built app bundles as well as the source.
- **The handed-over project did not compile.** One error on the Watch and one on the iPhone. Both are fixed, and all four targets now build with Xcode 27.2 beta for simulator and for an unsigned iOS device. The Watch target also builds with the pilot flag on.
- **Several monitoring paths were quietly inert.** Background Health delivery could not complete. Nightly-summary vitals usually showed "Unavailable". The wake-proposal engine had no usable second signal. One slow vital query blanked every night. All four are fixed.
- **Tests:** 25 became 29, all passing. Each new test guards one of the bugs above. The invariant script also passes.
- **Not done:** no real-device night. The do-no-harm milestone is still the first gate.

## Findings and fixes

| # | Severity | Area | Finding | Fix |
| --- | --- | --- | --- | --- |
| 1 | Build blocker | Watch motion | `for case let … in CMSensorDataList` cannot compile because the list only adopts `NSFastEnumeration`. The Watch app could never build, and the handoff's "parsed" check could not catch it. | `Sequence` conformance through `NSFastEnumerationIterator` (`Apps/Watch/WatchPilot.swift:195`). |
| 2 | Build blocker | iPhone audio | `AVAudioEngine.configurationChangeNotification` does not exist. The Swift name is `.AVAudioEngineConfigurationChange`. | Renamed (`Apps/iOS/AudioRecorder.swift:58`). |
| 3 | High | HealthKit delivery | Observer queries were registered only from the root view's `.task`. A HealthKit (or WatchConnectivity) background launch has no scene, so that never ran: no observers, no completion handlers, and no WCSession activation. The morning summary only worked if sleepi was opened. HealthKit expects observers set up at every launch. | The model loads from `App.init` (`Apps/iOS/SleepiApp.swift:40`). A failed library load, for example before first unlock, can now retry instead of staying broken until relaunch (`Apps/Shared/AppModel.swift:85-90`, test `failedLibraryLoadCanBeRetried`). |
| 4 | High | HealthKit vitals | Every refresh read 91 days of all-day Apple Watch heart rate (and six other types) with no limit, an 8 s timeout and a throwing task group. One slow or failed type failed the whole snapshot, which blanks every night with "Health is unavailable". The heart-rate observer's hourly background delivery reran all of it every hour. | Sleep is fetched first and is the only fatal query. Vitals are queried only inside padded sleep windows (HealthKit's default predicate matches overlap). Each type fails alone and shows as unavailable. Heart rate is no longer observed (`Apps/iOS/HealthKitReader.swift:40-88`). |
| 5 | High | Vitals display | Readings were matched by start date inside first-to-last asleep. Nightly summaries such as wrist temperature span the sleep session, which usually starts with an awake segment before the first asleep one, so they were excluded and shown as "Unavailable". | Readings now carry their end date and are matched by overlap (`Sources/SleepiCore/Models.swift:97`, `Apps/Shared/AppModel.swift:260`, test `nightlySummaryVitalStartingBeforeFirstSleepIsShown`). The sample span is inferred from HealthKit semantics, so confirm it on real records (handoff priority 2). |
| 6 | High | Wake fusion | `speechOrRustling` was never passed, so the only second signal was a heart-rate rise. That rise needs one reading within 90 s and another 90–300 s before it, which Apple's periodic overnight heart rate rarely provides. The engine would almost never propose a waking. | Speech or cough highlights near the epoch count as the second signal. Snoring and "not me" clips are excluded (`Apps/Shared/AppModel.swift:234-239`, test `heardSpeechCountsAsTheSecondWakeSignal`). |
| 7 | Medium-high | iPhone audio | Every route-change notification ended capture, including the `.categoryChange` caused by sleepi's own `setCategory`. That notification is delivered asynchronously and can land after the handlers are installed, which stops a fresh session with "Sound interrupted". Interruption *ended* notices also stopped it. | Capture ends only on interruption began, device added or removed, override, no suitable route, media reset, or when the engine has actually stopped (`AudioRecorder.swift:53-86`). Confirm on device with a locked phone on the charger. |
| 8 | Medium | iPhone audio | The first-run microphone alert leaves the app briefly `.inactive`. The foreground check after `await requestRecordPermission()` could therefore reject the very first start with "Open sleepi on the iPhone". | Only `.background` is rejected after the prompt (`AudioRecorder.swift:21`). |
| 9 | Medium | Sound pipeline | Backpressure allowed 4 buffers (about 0.34 s at 48 kHz) before ending the whole night. Clip encoding runs on the same queue, and a locked phone is throttled. | 32 buffers, about 2.7 s and 1.5 MB, still bounded (`Apps/Audio/SoundProcessor.swift:12`). |
| 10 | Medium | Gentle wake | If the Watch app had been terminated, ending the night left the scheduled session alive with no handle to cancel. When it started, `state.latest == nil` fell back to `.now` and buzzed 25 minutes early. | The session is invalidated without alerting when the night has ended (`WatchPilot.swift:82`). Apple documents `invalidate()` on scheduled sessions as an active-app call, so the device pilot must confirm watchOS honours it from the background. If not, the user taps Stop, and the end-of-night status says so. |
| 11 | Low (product) | Gentle wake | A `nil` repeat handler repeats the haptic every 3 s until dismissed, per Apple's docs. That is an alarm, not the plan's gentle nudge. | It now repeats every 10 s (`WatchPilot.swift:119`). Shorten it if it fails to wake; Apple's alarm remains the real alarm. |
| 12 | Low | Watch export | Up to 2.16M samples went through a dictionary while the app must stay in the foreground. | Fixed arrays. Empty slots are still omitted rather than exported as stillness (`WatchPilot.swift:128-146`). |

Also: `@preconcurrency` removed from the two `WCSessionDelegate` conformances, where Xcode 27 reports it has no effect and every method is `nonisolated`. It stays on `AVAudioPlayerDelegate` for iOS 26 SDK compatibility.

## What sleepi adds over Apple Health

Apple (iOS/watchOS 26) already shows stages, time asleep and awake, the Sleep Score (duration, bedtime consistency, interruptions), Vitals with outlier flags, wrist temperature and respiratory rate.

| sleepi feature | Already in Apple? | Verdict on this build |
| --- | --- | --- |
| Sound highlights (snoring, speech, cough, room) on device | No | The clearest differentiator. It only exists on nights started from Tonight with sound on. |
| In-bed marker to first detected sleep | No | Genuine, but it was buried in the raw timeline sheet. **Now shown on Last Night.** |
| Interruptions (count and minutes awake) | Inside Sleep Score only | **Now a Last Night metric.** Unknown gaps are never counted as wakings. |
| Notes and tags with "with vs without" comparisons | No | Genuine. Needs 10 reviewed nights each way. |
| Free vs scheduled day mid-sleep | No | Genuine. Needs manual day labels, 3 of each. |
| 14-night shortfall against your own target | No | Genuine and honestly labeled. |
| Bed and wake time variation in minutes | Partly (Sleep Score consistency) | Useful as minutes, but overlaps Apple. |
| Overnight vitals vs your own baseline | Yes (Vitals app, better) | Low value-add. The plan wanted a pointer into Vitals rather than a copy; consider shrinking it. |
| Wake proposals | No | Experimental and pilot-only. They were inert (finding 6) and now work on nights with sound. |
| Gentle wake | No (Clock alarm only) | Pilot-only and off by default, per AGENTS.md. |
| Morning summary notification | No | Depended on finding 3. It still waits until waking is at least an hour old (`AppModel.refresh`), so it arrives on a later background wake. Tune after device nights. |

**Overall:** on passive nights, the default, sleepi mostly re-displays Apple's data. Its trend additions need 7–20 nights or manual notes before they show anything. The value on the night itself comes from the Tonight layer (sound and the marker), so include sound on early device nights once the passive do-no-harm nights pass. Still deferred from the plan: sound dots on the hypnogram, a "likely awake" lane, the Last Night complication and Smart Stack, the Focus filter, and nap handling.

## Monitoring technology notes

- **Watch:** no HealthKit and no workout APIs; `WKBackgroundModes` is `["alarm"]` in the built bundle. `CMSensorRecorder` records 50 Hz for 12 h and cannot be stopped early. The morning export reduces it to 30 s epochs with sample counts and needs the app open while it reads. The gentle-wake trigger is three consecutive 0.5 s readings changing by more than 0.12 g, so a single roll-over can trigger it. Test that awake first.
- **HealthKit:** read-only, with an empty share set. Apple Watch source filter is `com.apple.*` plus a `Watch*` product type. Delivery is best effort, with observers now on sleep and the nightly vitals. Resting heart rate is a daily sample, so its overlap with a night can include two days; it is only shown in the raw sheet.
- **Audio:** built-in SoundAnalysis v1 with a label allowlist, 0.8 confidence, a −45 dBFS gate, a 15 s raw ring, clips of 10 s or less as AAC at 32 kbps, 20 MB per session, 300 MB total and 14-day expiry at the next cleanup.
- **Other apps' audio (decided: Randy chose keep-playing, 2026-10-01):** recording now keeps other apps' audio playing, so white-noise or rain sounds don't go silent. The baseline's `.record` category stopped them. The session is `.playAndRecord` in the default mode with `.mixWithOthers`, `.defaultToSpeaker` (other apps stay on the speaker, not the receiver) and `.allowBluetoothA2DP` (Bluetooth speakers keep working). Apple documents mixing for play-and-record in the default mode, so `.measurement` was dropped. The costs, to check on device: input may now get system gain processing, which makes dBFS levels and the −45 dBFS gate less comparable, and the mic hears the sleep sounds, which can mask snoring. The Start sheet says other apps keep playing. This is its own commit (`Keep other apps' audio playing while recording`); reverting it restores silencing.
- **Thresholds that are guesses:** 0.8 confidence, −45 dBFS, 0.12 g (both the haptic trigger and fusion), and an 8 bpm heart-rate rise within 90 s. Calibrate them from the first exported pilot nights.

## Ground rules

| Rule (plan) | Status | Evidence |
| --- | --- | --- |
| No `HKWorkoutSession` or other overnight session that alters rings or blocks Apple's tracking | Holds | No HealthKit in the Watch target; only an `alarm` extended runtime session; `scripts/check_invariants.py`; built Watch `Info.plist` |
| Never writes energy or vitals; corrections stay in the app | Holds | `requestAuthorization(toShare: [], …)` is the only Health request; no `save` or `delete` on `HKHealthStore`; no `NSHealthUpdateUsageDescription` |
| Clock alarm and Sleep Focus untouched; gentle haptic picked fresh nightly | Holds | No AlarmKit; the Watch sheet requires confirming a time each night; the pilot is off in every configuration |
| Complication never auto-starts; always opens a choice | Holds | Widgets use `sleepi://tonight`, which opens the start sheet; controls use a shared `OpenIntent`. Cold-launch routing for controls is still a device check. |
| Audio on device; event clips only; deleted after 14 days unless starred | Holds | Deletion happens at the next app open or recording start, not at exactly 14 days |
| watchOS 26 floor (Series 8) | Holds | Deployment targets are 26.0; built against the 27.2 SDKs |
| Do-no-harm: three nights matching a night without sleepi | Not run | Needs Randy's iPhone and Series 8 without a debugger attached |

## Build and test evidence

- **Toolchain:** Xcode 27.2 beta (27B5028f) at `~/Downloads/Xcode-beta.app`, used through `DEVELOPER_DIR`. `xcode-select` still points at the Command Line Tools.
- **`DEVELOPER_DIR=…/Xcode-beta.app/Contents/Developer scripts/build.sh`** (new): the iOS app, its widgets and the embedded Watch app with its widgets, the Watch scheme alone, and the Watch scheme with `SLEEPI_DEVICE_PILOT` all succeed. A generic iOS device build (unsigned) also succeeds. The baseline fails this build with findings 1 and 2.
- **`scripts/test.sh`:** 29 tests pass and the architecture checks pass.
- **Simulator:** installed on the iPhone 17 simulator (iOS 27.2); it launches to onboarding without crashing. The UI wasn't driven further, and unsigned builds carry no HealthKit entitlement, so this isn't a Health test.

## Next steps

1. **Signing:** Randy's team is set in the Xcode project, but `project.yml` still has `DEVELOPMENT_TEAM: ""`, so `scripts/generate_project.sh` would erase it. Add the team to `project.yml`. Those Xcode edits were left uncommitted in the working tree.
2. **Device order (unchanged from `docs/PLAN.md`):** baseline nights, then passive nights (no sound, pilot off), then sound, then the Watch pilot. For the pilot, add `SLEEPI_DEVICE_PILOT` to the SleepiWatch Debug "Active Compilation Conditions" locally and don't commit it.
3. **Device checks this audit added:**
   - whether background `invalidate()` cancels a stale gentle wake (finding 10);
   - whether recording survives lock, charger and Bluetooth changes (finding 7);
   - the wrist-temperature sample span against first sleep (finding 5);
   - the overnight heart-rate cadence, to tune fusion;
   - whether a 10 s haptic interval wakes Randy;
   - when the morning notification arrives;
   - how highlights and dBFS levels behave with sleep sounds playing in the default audio mode.
