# sleepi reference: Apple platform research (checked 2026-10-01)

Research notes behind `01-sleepi-plan.md`. Items marked **Unverified** must be confirmed on device before relying on them.

**Read this first:** watchOS 27 shipped this fall and dropped the Apple Watch Series 8, the original Ultra and the SE 2. Only Series 9 and later, Ultra 2 and later, and SE 3 get it. Randy's Series 8 stays on watchOS 26, so the Watch app's minimum target is watchOS 26. iOS 27 compatibility for the iPhone was not checked. Sources: https://www.macrumors.com/2026/06/08/watchos-27-drops-support-for-apple-watch-series-9-ultra-se-2/ and https://developer.apple.com/watchos/whats-new

## 1. Apple's own sleep features

- **Sleep stages and tracking requirements.** The watch records Awake, REM, Core and Deep sleep. Tracking needs a sleep schedule or Sleep Focus, the watch worn at least 1 hour, and at least 30% charge before bed. The user can change "Next Wake Up Only" or the full schedule, and the change shows in both Health and Clock. https://support.apple.com/en-us/108906
- **Sleep Score (new in watchOS 26).**
  - 0–100: duration 50 points, bedtime consistency over the last 13 nights 30 points, interruptions 20 points.
  - Appears after waking, in the watch Sleep app and in Health on iPhone.
  - watchOS 26.2 raised the band thresholds: Very Low 0–40 up to Very High 96–100 (previously "Excellent").
  - Works on Series 6 and later, so the Series 8 is supported.
  - Sources: https://support.apple.com/guide/watch/view-your-sleep-score-apded441a669/watchos, https://9to5mac.com/2025/11/04/watchos-26-2-sleep-score-changes-apple-watch/, https://appleinsider.com/articles/25/09/12/how-sleep-score-works-on-apple-watch-with-watchos-26
  - **Unverified:** no HealthKit type exposing Sleep Score was found. Treat it as not available to apps.
- **Vitals app.**
  - Overnight heart rate, respiratory rate, blood oxygen, wrist temperature and sleep duration.
  - Needs sleep tracking with Sleep Focus on, and 7 nights of wear to establish a typical range.
  - If several readings fall outside the range, the user is notified the next morning.
  - Wrist temperature needs Series 8 or later. Blood oxygen is unavailable on some recent US units (LW/A and LS/A models process it on the iPhone only).
  - Daytime resting heart rate and HRV in Vitals are limited to Series 12 / Ultra 4.
  - Source: https://support.apple.com/120142
- **Wrist temperature.** Series 8 and Ultra sample every 5 seconds during sleep and save one corrected value per night. Needs Sleep Focus on. Health shows it as a relative value only after about 5 nights, but apps can read it from the first night. Read-only: apps cannot write it. https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/applesleepingwristtemperature
- **Breathing Disturbances and sleep apnea notifications.**
  - The watch accelerometer measures breathing disturbances, rated Elevated or Not Elevated, shown under Respiratory in Health.
  - Apple evaluates them every 30 days and needs at least 10 nights in that window.
  - Apnea notifications need Series 9 or later, Ultra 2 or later, or SE 3, and age 18+. **The Series 8 is not eligible.**
  - **Unverified:** whether a Series 8 still records Breathing Disturbances on its own.
  - Source: https://support.apple.com/en-gb/120031
- **Schedule, Wind Down, alarms and battery.** Multiple schedules allowed. Sleep Focus is triggered by the Wind Down period. Alarms break through silent mode, and a single alarm can be skipped. The watch prompts a charge below 30%. https://support.apple.com/guide/watch/apd830528336

## 2. HealthKit

- **Sleep values.** `inBed`, `awake`, `asleepCore`, `asleepDeep`, `asleepREM`, `asleepUnspecified`; the old `asleep` value is deprecated. Apps can create and save sleep samples. Stage samples overlap the `inBed` sample but not each other. Apple Watch only records `awake` segments that fall between two sleep segments. https://developer.apple.com/documentation/healthkit/hkcategoryvaluesleepanalysis
- **Telling Apple's samples from sleepi's.** Every sample carries a source revision (source, version, productType, OS version). Filter on bundle ID and on productType "Watch…". https://developer.apple.com/documentation/healthkit/hksourcerevision
- **Deleting.** Apps can only delete objects they saved themselves; deleting Apple's samples is not possible. https://developer.apple.com/documentation/healthkit/hkhealthstore
- **Data source priority.**
  - Health's default order: manual entries first, then iPhone/iPad/Watch, then apps and Bluetooth devices.
  - Users can reorder sources under Data Sources & Access; the top source wins.
  - A newly added app or device is placed at the top, above built-in Apple devices. **So if sleepi wrote sleep samples, Health could prefer them over the Apple Watch by default.** This is why the plan keeps corrections inside sleepi in v1.
  - Source: https://support.apple.com/HT204351
- **Breathing disturbances type** available since iOS 18 / watchOS 11. https://developer.apple.com/documentation/healthkit/hkquantitytypeidentifier/applesleepingbreathingdisturbances
- **Other read types.** Heart rate, HRV (SDNN), respiratory rate, oxygen saturation and resting heart rate are standard types (individual pages not opened).
- **Live queries.** `HKAnchoredObjectQuery` returns a snapshot plus later changes, including deletions, and can keep running. https://developer.apple.com/documentation/healthkit/hkanchoredobjectquery
- **Background delivery.**
  - Needs the HealthKit background-delivery entitlement, plus observer queries registered at app launch.
  - The app must call the completion handler; after 3 misses, delivery stops.
  - On watchOS most types update at most hourly, and background updates share a budget of 4 per hour with app refresh tasks, and only if a complication is on the active watch face.
  - Source: https://developer.apple.com/documentation/healthkit/hkhealthstore/enablebackgrounddelivery(for:frequency:withcompletion:)
- **No live sleep stages.** Apple DTS says stage data is written only after the fact, there is no real-time stage API, and Apple's classifier is private. https://developer.apple.com/forums/thread/804512 and https://developer.apple.com/forums/thread/827920

## 3. Sleep schedule, alarms and Focus

- **No public API reads or sets the sleep schedule or Clock alarms.** The nearest thing is RelevanceKit's sleep context on watchOS, which only hints the Smart Stack around the user's "typical bedtime or wakeup time." https://developer.apple.com/documentation/relevancekit/relevantcontext
- **AlarmKit.**
  - iOS, iPadOS and Mac Catalyst 26 only, not watchOS.
  - Schedules the app's own one-time or weekly alarms and countdowns. Needs user permission and a usage-description key. Overrides Focus and silent mode.
  - Stop and secondary buttons can run App Intents. The alert is forwarded to the paired watch. A widget extension is required if countdowns are used.
  - The docs never mention the system sleep schedule or Wake Up alarm, so it is separate from them.
  - Sources: https://developer.apple.com/documentation/alarmkit and https://developer.apple.com/documentation/alarmkit/scheduling-an-alarm-with-alarmkit
- **Focus filters.** Available on iOS 16+ and watchOS 9+ via an App Intent (`SetFocusFilterIntent`). The intent runs when a Focus the user configured with sleepi's filter turns on or off, so sleepi can react to Sleep Focus if the user adds the filter there. https://developer.apple.com/documentation/appintents/setfocusfilterintent
- **Shortcuts automations.** Sleep triggers ("Wind Down Begins", "Bedtime Begins", "Waking Up" when the Wake Up alarm goes off; these need a schedule in Health), Alarm triggers ("Is Stopped" / "Is Snoozed"), and a Focus on/off trigger. Any of these can run sleepi's App Intents. **The user has to create the automation in Shortcuts;** the app cannot create it. https://support.apple.com/guide/shortcuts/apd932ff833f/ios and https://support.apple.com/guide/shortcuts/apde31e9638b/ios

## 4. watchOS overnight execution without a workout session

- **Extended runtime sessions.**
  - Session types and limits: self care, foreground, 10 minutes; mindfulness, foreground, 1 hour; physical therapy, background, 1 hour; smart alarm, background, 30 minutes.
  - **Only smart alarm can be scheduled ahead,** up to 36 hours out and one at a time. It is described as monitoring heart rate and motion.
  - The session must play an alarm haptic, or the system warns the user and offers to disable future sessions.
  - Each app supports one session type. Sustained high CPU use can get the session cancelled.
  - Sources: https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions and https://developer.apple.com/documentation/watchkit/wkextendedruntimesession
- **Accelerometer recorder (`CMSensorRecorder`).**
  - Records the accelerometer at 50 Hz for up to 12 hours, even while the app is suspended or terminated. Data is kept up to 3 days. Needs the motion-usage key. https://developer.apple.com/documentation/coremotion/cmsensorrecorder/recordaccelerometer(forduration:)
  - **Caveat:** one developer saw zero samples during the watch's own auto-detected sleep. Apple DTS said this is likely power management and undocumented. https://developer.apple.com/forums/thread/827920
- **High-rate batched sensors** (`CMBatchedSensorManager`, 800 Hz accelerometer) require an active workout session, so sleepi cannot use them. https://wwdcnotes.com/documentation/wwdc23-10179-whats-new-in-core-motion/
- **Running a workout session overnight.** Apple DTS's personal view is that using a workout session for sleep tracking is "most likely not appropriate" for App Review. https://developer.apple.com/forums/thread/827920
  - **Unverified by official docs:** that this logs active energy, conflicts with Apple's sleep or Vitals tracking, or drains the battery. The forum thread 810690 (in `02-market-research.md`) reports ring effects.
- **Recommended design:** start the sensor recorder at bedtime, schedule a smart alarm session for the wake window, and read Apple's samples the next morning.

## 5. Widgets, complications and controls on watchOS 26

- **Controls are new in watchOS 26.** They appear in Control Center, the Smart Stack and the Ultra's Action button. They can come from the iPhone app even without a watch app, and are configurable through App Intents.
- **Smart Stack** shows controls, widgets and Live Activities. RelevanceKit relevant widgets can key off the sleep schedule. Widgets can be updated by push.
- Source: https://developer.apple.com/videos/play/wwdc2025/334/

## 6. iOS overnight audio

- **Background mode.** The `audio` background mode is documented for playing audible content in the background; recording isn't described separately. https://developer.apple.com/documentation/xcode/configuring-background-execution-modes
- **App Review rules.** 2.5.4: background services only for their intended purposes. 2.5.14: explicit consent plus a clear visual or audible indication while recording. 5.1.3(ii): no false data written to HealthKit, and no health data in iCloud. https://developer.apple.com/app-store/review/guidelines/
- **Mic indicator.** iOS shows an orange indicator whenever an app uses the mic. https://support.apple.com/HT211876
- **SoundAnalysis.** The built-in classifier recognises 300+ sound types, lists its labels at runtime, and works on live mic audio. https://developer.apple.com/documentation/soundanalysis/snclassifysoundrequest and https://wwdcnotes.com/documentation/wwdc21-10036-discover-builtin-sound-classification-in-soundanalysis/
- **Unverified:** that "snoring" and "cough" are among the labels (print the label list on device), that processing is fully on-device (very likely), and storage sizes (estimate: AAC at about 32 kbps is roughly 115 MB per 8 hours).
