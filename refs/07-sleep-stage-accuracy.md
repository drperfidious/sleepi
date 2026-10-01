# How accurate is Apple's sleep stage data, and can sleepi replace it in Health?

Written 2026-10-01 for Randy's question in the "sleep stage accuracy" thread. Builds on 04-sleep-science-research.md and 03-apple-platform-research.md.

## 1. What the studies say about Apple Watch sleep stages

The reference test is polysomnography (PSG): an overnight lab test with brain-wave (EEG) sensors. Every consumer device is graded against it.

- **Asleep vs awake.** Apple almost never misses real sleep (about 98% of sleep is caught). The weak spot is wake: in Apple's own data it catches about 75% of awake time with the original algorithm and about 79% after its 2025 update. Independent studies are harsher: across six wearables, wake was caught only 29% to 52% of the time (Schyvens 2025). Lying still and awake usually gets scored as sleep, so total sleep looks a bit longer and night wake-ups look shorter than they were.
- **Stages.** Agreement with the lab on four stages (awake, core/light, deep, REM) is "moderate": a kappa of 0.53 in an independent study (Schyvens 2025) and 0.63 to 0.68 in Apple's own validation. Kappa 1 is perfect, 0 is chance; lab technicians agree with each other at roughly 0.75 to 0.8.
- **Deep sleep specifically.** This is where Apple is weakest. Its most common mistake is scoring deep sleep as core. One study found it under-counted deep sleep by about 43 minutes and over-counted light sleep by about 45 minutes in a single night (Robbins 2024). Per-stage hit rates ranged from about 50% to 86%.
- **When it gets worse.** Broken-up nights, sleep apnea, and some missing nights (one study lost 37% of Apple recordings to data loss).
- **How to read it.** The trend over weeks and the total sleep time are reasonably trustworthy. Deep sleep minutes on any given night are an estimate, likely on the low side.

## 2. Does Sleep Cycle or anything else do better?

- **Sleep Cycle and other phone-only apps: no, worse.** Phone apps that listen or feel the mattress have not held up in lab tests. Fino et al. 2020 tested four phone sleep apps, Sleep Cycle among them, against PSG and found they could not reliably separate sleep stages and misjudged sleep and wake. An older test of a similar app (Bhat 2015) found no relation between its "deep sleep" and the lab's. Sleep Cycle's own accuracy claims are not independently published. Its strengths are the smart alarm and snore recording, not staging.
- **Best phone-sound research.** A dedicated sound model (Asleep, Tran 2023) reached about 76% accuracy on three classes (wake, REM, non-REM), with wake at 63%. That is roughly Apple-level overall, not better, and only with a purpose-built model.
- **Oura ring: slightly better on stages.** In the same lab study as Apple (Robbins 2024), Oura's per-stage hit rates were 76% to 80% and its deep sleep minutes were not significantly off. It is the one consumer device with a consistent edge, mostly on deep sleep. It costs $399 plus a subscription.
- **Fitbit, Garmin, Whoop, Withings: similar or worse than Apple.** In the six-device study Apple had the best agreement of the group. Whoop over-counted REM by about 21 minutes in a review.
- **Bottom line.** No phone app beats the Watch. The ring is a modest step up on deep sleep. Nothing consumer-grade matches a lab.

## 3. Can sleepi intercept Apple's write to Health?

No. This is unchanged in the current HealthKit SDK:

- An app can read Apple's sleep samples and can save its own, but it can only delete or change samples it saved itself. Apple's samples cannot be edited, blocked or replaced, and there is no hook into the Watch's write.
- If sleepi saved its own sleep samples, they would sit alongside Apple's. Health shows the source at the top of Health > Sleep > Data Sources & Access, and a newly added app goes above the Apple Watch by default, so sleepi's version would quietly take over the Sleep chart unless Randy reordered it. How Health merges overlapping sleep from two sources is undocumented (Apple Developer Forums thread 842919).
- Apple's Sleep Score and the Vitals app are computed by Apple from the Watch's own data, so a sleepi write would most likely not change them (inferred, not tested). Other apps that read sleep from Health would see whichever source they pick, and some prefer third-party sources over Apple's.

### Realistic options

1. **Keep corrections inside sleepi (current plan, recommended).** Health keeps Apple's data untouched; sleepi shows its corrected view (wake-ups, time to fall asleep, sound events) next to Apple's.
2. **Write alongside, user picks the priority.** An opt-in switch that saves sleepi's corrected night to Health, with Randy choosing in Data Sources whether Apple or sleepi wins. Risk: duplicated or conflicting sleep in other apps, which is the exact complaint users make about SleepWatch.

### Recommendation

Stay with option 1. sleepi has the same sensors as Apple's classifier (motion plus heart rate sampled every few minutes), and Apple's model is trained on hundreds of lab nights, so sleepi cannot produce more accurate deep or REM sleep. Where it can add real accuracy is wake: catching awake-but-still time with phone sound and a quick morning check-in. That is worth showing in sleepi, not worth risking the Health record over. If a few weeks of use show the wake corrections are consistently right, an opt-in write of just those can be revisited.

## Sources

- Apple, Estimating Sleep Stages from Apple Watch (2023, revised with 2025 update): https://www.apple.com/healthcare/docs/site/Estimating_Sleep_Stages_from_Apple_Watch_Sept_2023.pdf
- Robbins et al. 2024, Sensors (Oura Gen3, Fitbit Sense 2, Apple Watch S8 vs PSG): https://www.mdpi.com/1424-8220/24/20/6532
- Schyvens et al. 2025, SLEEP Advances (six wearables vs PSG): https://academic.oup.com/sleepadvances/article/6/2/zpaf021/8090472
- Schyvens et al. 2024, systematic review, JMIR mHealth: https://doaj.org/article/e789b4be175943e5838b3e10cd73b785
- Fino et al. 2020, J Sleep Res, "(Not so) Smart sleep tracking through the phone" (four phone apps incl. Sleep Cycle vs PSG): https://cris.unibo.it/handle/11585/752893
- Bhat et al. 2015, J Clin Sleep Med, smartphone sleep app vs PSG (from memory of the literature, not re-opened today)
- Tran, Hong et al. 2023, JMIR, phone-audio sleep staging (Asleep)
- HealthKit: HKHealthStore (apps delete only their own samples): https://developer.apple.com/documentation/healthkit/hkhealthstore
- HealthKit sleep analysis values: https://developer.apple.com/documentation/healthkit/hkcategoryvaluesleepanalysis
- Health data source priority: https://support.apple.com/HT204351
- Apple Developer Forums, overlapping sleep samples: https://developer.apple.com/forums/thread/842919
