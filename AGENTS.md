# Working on sleepi

Read `docs/HANDOFF.md`, `docs/PLAN.md` and `refs/05-validation-and-decisions.md` before changing the design. Preserve original references as historical inputs, not as stronger evidence than their validation supplement.

- No Health writes or share types, workout sessions/builders, energy writes, AlarmKit replacement alarm, network upload, analytics, or CloudKit health/notes. These are product boundaries.
- Unknown data is unknown. Don't fill missing sleep or sensor data with sleep, wake or zero activity. Never interpret HealthKit empty results as definitive read denial.
- Complications, controls and Shortcuts open a choice; microphone consent occurs on the foreground iPhone. Watch gentle-wake scheduling is confirmed on foreground Watch.
- Keep the motion/gentle-wake pilot off by default. Real-device gates cannot be passed by mocks, a simulator or a debugger-attached session.
- App destinations are iOS/watchOS 26; Swift 6 strict concurrency. No third-party runtime dependencies.
- `project.yml` is the Xcode project source. Regenerate the checked-in project after target/config changes. Do not claim iOS/watchOS build success from a Mac typecheck.
- Run `scripts/test.sh` for appropriate changed logic. Tests cover meaningful safety/data invariants; add a regression test for an actual bug, not a mirror of implementation.
- Do not persist real health/audio data in fixtures, logs or review artifacts. The Mac preview is explicitly synthetic.

There is no automatic publish, messaging, or Fable dispatch step. The user will handle their next review handoff.
