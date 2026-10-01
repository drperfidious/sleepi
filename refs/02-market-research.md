# sleepi reference: iOS sleep-app market research (as of Oct 2026)

Research notes behind `01-sleepi-plan.md`. Prices are US App Store listings. Review complaints come from the visible App Store reviews, so they are indicative rather than exhaustive. Reddit was not reachable from the research environment.

**On "Sleep Smart":** no free iOS app called "Sleep Smart" with an Apple Watch component turned up. The closest matches are "SleepSmart: Your Sleep Coach" (Pressure Profile Systems), which only works with the SleepSmart Pillow hardware and is rated 2.2 from 5 ratings, and "Sleep Tracker & Snore Recorder" (Hyperday MB). No public report was found of Sleep Smart writing calories or breaking Vitals, so Randy's own experience is the evidence for that complaint. Apple's own sources do confirm the mechanism behind it (see Anti-patterns).

## Comparison

| App | Price | Data source | Key premium features | Top complaints |
|---|---|---|---|---|
| Apple Sleep (native) | Free | Watch accelerometer + HR; Sleep Focus | Stages, Sleep Score (watchOS 26: duration 50 pts, bedtime consistency 30, interruptions 20), apnea notifications, Vitals (HR, resp, SpO2, wrist temp, duration/HRV) | No nap tracking; "In Bed" has to be entered by hand; "alarm is not reliable… much more subtle alarm" |
| Sleep Cycle | Free tier; Premium about $39.99/yr (IAPs $2.99–$57.99) | iPhone mic (sound) or accelerometer; standalone Watch app with on-watch motion + HR | Smart alarm wake window and silent haptic wake (free); snore/sleep-talk detection, sleep notes, full stats/trends, weekly reports, HR, wake-up mood, online backup, Hue/HomeKit (Premium) | Bloat; sleep notes can't be renamed; graph redesign hid raw data; switch to subscription |
| AutoSleep (Tantsissa) | $5.99 one-time, no IAP | Passive: reads Watch HR/HRV and motion from HealthKit, nothing to start; optional watch app and smart alarm | Readiness, HRV "Sleep Rings," automatic sleep and nap detection, Health write | Dense UI; "no longer receiving HR data from my watch"; duplicates Apple sleep in Health (apps like Exist ignore extra sources) |
| Pillow | $19.99/mo, $59.99/qtr, $49.99/yr, or $49.99 lifetime | Auto mode reads Watch data; manual session for alarm and audio | Stages, snore/apnea/talk audio (on-device ML), smart alarm, HR | "Alarms and Audio recordings are currently not possible in Automatic mode"; battery drain; watch notification glitches |
| SleepWatch | $4.99/mo or $39.99/yr | Reads Apple Watch/Health automatically | Coaching, smart alarm, reports, snore, HR dip | "Adds its own inaccurate data" to Health; scores swing widely; snore detection picked up a pet; watch app needed reinstalling |
| Rise | $69.99/yr, 7-day trial | HealthKit/Watch, Oura, Fitbit, phone usage | Sleep debt, circadian energy schedule, melatonin window, smart alarm | Expensive; few hard complaints (4.7 from 71k ratings) |
| SleepSpace | $12.99/mo, $79/yr, $199.99 lifetime | iPhone, Watch, Oura, WHOOP | Smart alarm with Watch vibration, adaptive sound masking, CBT-I programs, AI coach | Bugs, notification glitches, no clear way to stop the alarm, paywall |
| ShutEye | $7.99/mo to $79.99/yr | iPhone mic; writes to Health | Snore/talk recordings, sounds, smart alarm, stories | Sleep-talk recordings behind the paywall; confusing tiers; date bugs; tracks users across apps |
| BetterSleep | Premium tiers $5–$99.99 | Mic recorder; optional HealthKit | 300+ sounds, meditations, snore/talk recorder | Heavy tracking/data collection; mostly a content app |
| NapBot | $4.99/mo or $29.99/yr | Passive HealthKit read with on-device CoreML; no watch app needed | Auto naps, sleep stages, HR summary, apnea monitoring (needs Sleep Mode) | False sleep when sitting still; uses Sleep Focus start as sleep onset; "all over the board" accuracy |
| Sleep++ | Free, $1.99 removes ads | Watch motion + HealthKit, auto or manual | Readiness (sleep + RHR + HRV), HR/SpO2/resp trends, widgets | Misdetection ("9p to 11p… Thirteen hours?!") |
| SnoreLab | Premium $5.99–$59.99/yr | iPhone mic only | Snore Score, BreathFlow, remedy/factor tracking, audio highlights | Not a medical device; 210 MB app. Audio stays on device by default; optional encrypted cloud backup, or stats only |
| Oura / Whoop / Eight Sleep (reference) | Oura $399 + $70/yr; Whoop subscription (about $717 over 3 yrs); Eight Sleep Pod 6 $1,999+ plus required $199/yr Autopilot | Ring / strap / bed sensors | Readiness/recovery from HRV, RHR, temperature, respiration; strain; bed temperature control | Subscriptions on top of hardware; scores "made up to some degree" |

## Features worth copying

1. **Passive, zero-setup tracking from HealthKit** (AutoSleep, NapBot, Sleep++). Read Apple's sleep stages, HR, HRV, respiratory rate, SpO2 and wrist temperature after the fact. No battery cost, no session to start, and Vitals stays intact.
2. **A smart alarm through `WKExtendedRuntimeSession` (.smartAlarm)**, not a workout. Apple documents it as "Schedule a window of time to monitor the user's heart rate and motion… to determine the optimal time to play an alarm." It runs in the background for up to 30 minutes, can be scheduled up to 36 hours ahead, and supports a silent haptic wake (Sleep Cycle, SleepSpace).
3. **AlarmKit (iOS 26) for an iPhone alarm, if one is ever needed.** Apple's FAQ says these alarms "can break through all focus modes" and survive reboots and force-quits. The sleepi plan does not use it by default, because Apple's Clock alarm stays the alarm.
4. **A readiness score built on Apple's data:** HRV vs. baseline, RHR, wrist-temperature deviation and respiratory rate (Oura, AutoSleep, Sleep++). Add sleep debt and a circadian energy curve (Rise).
5. **Sleep notes and tags with correlations** (caffeine, alcohol, late workout), which the user can rename and group.
6. **Snore and sleep-talk audio on iPhone, processed on device**, with audio kept local and a stats-only option (SnoreLab model). Filter out pets and partners.
7. **Nap detection**, which Apple doesn't do.
8. **One-time purchase or free.** Reddit favours AutoSleep largely for "$4.99 one time… no developer tracking."
9. **Raw data shown alongside scores.** Scores that swing without explanation draw complaints (SleepWatch, Sleevi).

## Anti-patterns to avoid

1. **Running an `HKWorkoutSession` overnight.** Apps do this because it is the only general-purpose way to keep a watch app alive in the background with continuous HR. The extended-runtime alternatives are time-capped: self-care 10 min, mindfulness/physical therapy 1 h, smart alarm 30 min. HKObserverQuery background delivery gives only about 4 updates per hour (Apple Dev Forums 810690). Side effects:
   - A workout session affects Activity rings and logs active energy. The developer in thread 810690 found rings were affected "even when HKLiveWorkoutBuilder isn't used or finishWorkout() isn't called." Apple's docs say to use a separate non-workout session type to keep activity "from impacting the user's Move and Exercise rings."
   - Vitals needs "Track Sleep with Apple Watch and Sleep Focus enabled" and 7 nights of baseline. Anything that displaces native sleep tracking, or makes users turn it off to save battery, starves Vitals and Sleep Score.
   - CPU-heavy background sessions get suspended (Dev Forums 723786). Battery is already the top Apple Watch sleep complaint (TechRadar).
2. **Writing duplicate or low-quality sleep to Health.** SleepWatch users say it "adds its own inaccurate data." Exist.io reads only one sleep source per day and prefers third-party sources over Apple's, and tells users to "only have a single app… syncing sleep." Health's merge rules for overlapping sleep samples are undocumented (Dev Forums 842919). Default to read-only, or write only what Apple doesn't record, and make writing a clear opt-in.
3. **Writing active energy or workouts for sleep.** Never.
4. **Hiding recordings behind the paywall after collecting them** (ShutEye sleep-talk audio), and confusing multi-tier pricing.
5. **Bloat and features that can't be turned off** (Sleep Cycle voice feature), and redesigns that remove raw graphs.
6. **Sloppy sleep-onset detection:** treating Focus start or sitting still as sleep (NapBot, Sleep++).
7. **Replacing the alarm without reliability guarantees,** or without an obvious stop control (SleepSpace complaint).
8. **Ad and cross-app tracking SDKs in a health app** (ShutEye, BetterSleep privacy labels).

## Sources opened

- https://apps.apple.com/us/app/sleep-cycle-tracker-sounds/id320606217
- https://support.sleepcycle.com/hc/en-us/articles/206704909-Sleep-Cycle-Freemium-vs-Premium-Features
- https://www.garagegymreviews.com/equipment/sleep-cycle
- https://www.businesswire.com/news/home/20200513005755/en/Independent-Sleep-Tracking-and-Silent-Wake-Up-Prime-Features-of-Brand-New-Sleep-Cycle-Apple-Watch-App
- https://apps.apple.com/us/app/autosleep-track-sleep-on-watch/id1164801111
- https://kimola.com/reports/unlock-sleep-tracking-insights-with-our-in-depth-report-app-store-us-147275
- https://gummysearch.com/tools/best-products/sleep-tracking-app/
- https://apps.apple.com/us/app/id1438013403 (SleepSmart)
- https://apps.apple.com/us/app/id6443941868 (Sleep Tracker & Snore Recorder)
- https://apps.apple.com/us/app/pillow-smart-sleep-cycle-alarm/id878691772
- https://pillow.app/automatic-sleep-tracking-for-the-apple-watch
- https://apps.apple.com/us/app/sleepwatch-top-sleep-tracker/id1138066420
- https://apps.apple.com/us/app/rise-sleep-tracker/id1453884781
- https://apps.apple.com/app/id1193763939 (SleepSpace)
- https://apps.apple.com/US/app/id1490078804 (ShutEye)
- https://apps.apple.com/us/app/id314498713 (BetterSleep)
- https://apps.apple.com/us/app/id1476436116 (NapBot)
- https://www.macstories.net/reviews/napbot-simple-sleep-tracking-powered-by-coreml/
- https://apps.apple.com/us/app/sleep/id1038440371 (Sleep++)
- https://apps.apple.com/us/app/snorelab-record-your-snoring/id529443604
- https://snorelab.com/snorelab-app-privacy-policy/
- https://apps.apple.com/us/app/id1505627600 (Apple Sleep)
- https://apps.apple.com/us/app/id6446651812 (Sleevi)
- https://appleinsider.com/articles/25/09/12/how-sleep-score-works-on-apple-watch-with-watchos-26
- https://support.apple.com/en-us/120142 (Vitals requirements)
- https://developer.apple.com/documentation/watchkit/using-extended-runtime-sessions
- https://developer.apple.com/forums/thread/810690
- https://developer.apple.com/forums/thread/130287
- https://developer.apple.com/forums/thread/723786
- https://developer.apple.com/forums/thread/842919
- https://developer.apple.com/forums/thread/797158 (AlarmKit FAQ)
- https://kb.exist.io/article/42-why-is-my-sleep-data-incorrect
- https://discussions.apple.com/thread/255325271
- https://discussions.apple.com/thread/251544186
- https://www.techradar.com/opinion/the-biggest-problem-with-apple-watch-sleep-tracking
- https://www.asianefficiency.com/technology/whoop-vs-oura-ring/
- https://the5krunner.com/2026/09/23/8sleep-eightsleep-pod-6-review/
