# Revised build plan

The original product intent is retained: a local, calm companion to Apple's sleep stack. The implementation is a personal development build, not a validated sleep detector or dependable alarm. See `refs/05-validation-and-decisions.md` for claim-level evidence.

## Implementation delivered

| Layer | Implementation |
| --- | --- |
| Core | Swift 6 package; source provenance; overlap normalization; unknown gaps; calendar-noon grouping; DST-aware boundaries; circular schedule statistics; coverage-bearing target shortfall; reviewed-night tag comparisons; manually labeled free/scheduled-day midpoint comparison; gated wake proposal engine; retention and bounded PCM ring. |
| iPhone | SwiftUI Last Night, raw timeline, vitals, Tonight consent/start/stop, Sounds, Trends, journal and renameable tags, onboarding, Settings, deletion and empty/error states. Real HealthKit reader with no share types, observer queries, concurrent timeout-bounded refresh and foreground refresh. |
| Sound | Foreground microphone permission; audio engine; bounded serial analysis; built-in SoundAnalysis allowlist; 15 seconds of raw audio in RAM; short AAC highlights with pre/post roll; loudness/confidence gates; 20 MB per-session limit and 300 MB total budget; 14-day expiration; stars, playback, deletion, manual attribution. Interruption or route change ends capture. |
| Watch | Confirmed in-bed markers, paired-phone summary, explicit fresh gentle-wake selection, relaunch delegate, movement-triggered / deadline haptic, dismissal, recorded-motion reduction and queued WatchConnectivity file transfer. Motion and gentle wake require `SLEEPI_DEVICE_PILOT`, absent by default. |
| Entry points | iPhone and Watch widgets / controls open a choice. Shared OpenIntent also supports Shortcuts. Lock Screen / Dynamic Island session marker links into Tonight. |
| Storage | Versioned atomic Codable repository. Protected app-private library excluded from backups. No CloudKit, App Group health cache, network stack, or third-party runtime SDK. Raw HealthKit samples are refreshed in memory, not copied into a second persistent health database. |

## Deliberate changes from the refs

- No Health writer of any kind, including Labs, confirmed awake samples, or gap fills.
- Read a fresh rolling 91-day HealthKit snapshot on updates rather than persist query anchors. This naturally reflects edits/deletions and avoids anchor/store split-brain bugs in an initial personal app. Fetches run concurrently, have an 8-second per-query timeout, and always complete observer callbacks. Measure performance before introducing an anchored store.
- Use an atomic versioned local JSON repository instead of SwiftData/CloudKit. The state size is modest (event metadata and notes); no database migrations or cloud classification ambiguities are needed yet. Unexpected schema/corruption is an error, never a reset-and-overwrite.
- No generic SRI, recovery score, biological sleep debt, chronotype, calibrated sound pressure, speaker recognition or trained wake model. The implemented replacements state what they actually measure.
- Watch start does not start the phone microphone or schedule a Watch session from a suspended phone message. Phone recording is a separate foreground action. A Watch marker is imported as a journal entry.
- Interrupted audio does not automatically resume. Current coverage limitations remain visible, and a new explicit session is required.
- Native compilation and hardware gates remain separate from source implementation. Independent UI/core work continued while the three-night experimental gate stays closed.

## Gates before device use / promotion

1. **Build gate:** with Xcode 26+ selected, compile iPhone app + widgets and Watch app + widgets, validate icons, App Intent metadata, signing, paired installation and extension embedding. The current host has only Command Line Tools; these targets have not been compiled for their destination SDKs.
2. **Read-only gate:** grant a subset of Health types; deny/revoke others; lock/unlock; edit/delete a Health sample; verify new / deleted records reflect on foreground; observe late vitals; test sparse and absent nights. Check that sleepi contributed no samples. Appearance in Health's Sources is allowed.
3. **Baseline:** three ordinary Series 8 nights with the same watchOS version and comparable settings; record charging level, morning battery, usable sleep coverage, Vitals availability and alarm delivery. Do not change native sleep settings for the experiment.
4. **Passive companion:** three nights with no sound or pilot. Require no contributed Health data, no sleepi energy/workouts, native alarm delivery and ordinary Vitals/sleep availability. Investigate regressions; don't assert two nights must have identical stage durations.
5. **Sound:** test permission denial, locked recording, interruptions, route changes, low disk, playback, crash recovery, retention and saved-clip cap; then three nights on charger. Measure CPU, battery, RAM, clipping quality and storage. No continuous snore-minute metric until coverage/classifier validation exists.
6. **Watch motion pilot:** enable the compile flag only for controlled testing. Start on Watch, detach debugger, export in morning. Record actual count/coverage and battery difference. Empty intervals never get interpolated into stillness. Apple may continue sensor capture until its requested 12-hour expiry even after ending a marker; there is no recorder stop API in this implementation.
7. **Gentle-wake pilot:** first test awake and supervised. Check relaunch, airplane mode, interrupted/invalidated session, watch reboot, deadline fallback, haptic dismissal and Apple's alarm. Only then use overnight with Apple's alarm retained. No promotion based solely on a successful haptic.
8. **Wake proposals:** require a separate labeled validation set and false-positive review before claiming improved detection. The current rule is a tunable experimental proposal generator; check-ins don't adapt it automatically.

## Deferred, not disguised as complete

True SRI with defensible full-day coverage; trained wake models and personalization; a validated recovery score; continuous snore duration / calibrated noise; iCloud preferences; Focus-filter integration; RelevanceKit promotion; summary/elapsed-time complications; automatic motion export; richer nap/session partitioning; cloud backup/export; all Health writes; wind-down audio. The current noon grouping can combine multiple sleep bouts and is not a shift-work session classifier. Historical wall-clock comparisons use the current timezone; travel handling needs a dedicated design.
