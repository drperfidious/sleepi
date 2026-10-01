# Can sleepi correct Apple's sleep data? Evidence and our own tests

Written 2026-10-01 for Randy's follow-up in the sleep stage accuracy thread. Builds on `07-sleep-stage-accuracy.md`. Scripts and raw outputs for section 3 are in `/mnt/project-files/sleepi/analysis/correction-tests/`.

Randy's bar: build an in-app corrected version only where it provably makes the data more accurate, preferably shown on real data; theory counts only if it survives falsification and audit.

## The answer

- **No correction to Apple's sleep stages or wake times passes that bar today.** Nothing published does it, and every version we tested on real Apple Watch lab data either lost to Apple or made individual nights worse.
- **sleepi's own planned "likely awake" overlay fails the same tests** and should stop being shown as a correction.
- **Fixes to how a night is recorded and averaged do pass**, because each one is a checkable fact rather than a guess about physiology: overlapping duplicate records, nights the Watch stopped recording, the in-bed time Apple no longer records, and trend breaks when Apple changes its algorithm. These go into sleepi's corrected history, with the difference from Apple's raw record shown night by night.
- **The only route to an empirical stage correction** is reference nights from a lab-validated EEG headband (section 6). Not recommended now.

## 1. What Apple's sleep data gets wrong

| Problem | Evidence | Can sleepi provably fix it? |
|---|---|---|
| Lying still while awake is scored as sleep | Wake caught: 52% (Schyvens 2025, independent); Apple's own figures 75% (2022 algorithm) and 79% (2025). Time awake in the night under-counted by about 21 min; total sleep over-counted by about 20 min (Schyvens). | No (section 3) |
| Deep sleep scored as Core | Apple: "the most common misclassification overall was true Deep sleep being classified as Core sleep." Robbins 2024: Deep 94 → 51 min (−43), only 50.5% of real Deep found, but 87.8% of Apple's Deep calls are right. Schyvens: −25 min, individual nights from −87 to +36. Apple's Deep minutes barely track who really gets more deep sleep (ICC 0.13). | No |
| Core/Light over-counted | +45 min (Robbins), +59 min (Schyvens), but −74 min in a 2026 home-PSG study on Series 7 (Alhejaili, abstract only). Studies disagree on direction. | No |
| Worse on broken-up nights and sleep apnea | Apple: stage changes and apnea severity lower agreement most. Sleep-clinic patients: 4-stage agreement κ 0.30 (Lee 2023; authors work for a competitor, Asleep). | No |
| Apple changed the algorithm in 2025 (watchOS 26) | 4-stage κ 0.63 → 0.68, wake correctly found 70% → 79%, retested on the same 2022 data. Every independent study tested the old algorithm. | Yes: mark the break in trends |
| No in-bed time since watchOS 11 / iOS 18 | Apple engineer: "We stopped recording the inBed samples … the system doesn't provide a replacement," and suggests apps ask the user or build their own. So Health has no time in bed, time to fall asleep or sleep efficiency. | Yes, on nights started from Tonight |
| Awake is only recorded between two sleep segments | Apple's HealthKit docs. No awake before first sleep or after final waking. | Partly (time to fall asleep from the Tonight start) |
| Short sessions | Under 1 h of sleep: nothing written. 1 to 3 h: asleep/awake only, no stages. | Label only |
| The Watch sometimes writes a night twice | Apple Developer Forums 842919: two overlapping writes from the Watch itself; Health quietly dropped some Deep, REM and awake segments when reconciling, by undocumented rules. | Yes: never count a minute twice |
| Lost or partial nights | 6 of 35 (Robbins) and 15 of 35 (Schyvens) Apple recordings missing or partial in lab studies. A night the Watch stops at 4 a.m. looks like a 4-hour night in averages. | Yes: flag and keep out of averages |

Apple's sleep staging uses the accelerometer only, in both versions (Apple's October 2025 white paper).

## 2. What others have tried

- **Only one peer-reviewed study post-processed a consumer device's own stages and tested on new people** (Liang & Chapa-Martell 2021: Fitbit Charge 2, 23 adults, single-channel EEG as reference). Overall agreement rose (κ 0.37 → 0.43), but deep sleep found fell from 61% to 9% and wake from 35% to 20%. The headline gain hid worse results for exactly the stages people care about. This is the trap any correction must avoid.
- **Nobody has corrected Apple Watch's stages**, and no public dataset pairs Apple's stage output with lab-measured sleep (Robbins and Schyvens share data only on request).
- **Bias correction, smoothing, per-person calibration, combining devices, phone-audio fusion and diary fusion: none tested against lab sleep studies.**
- **Real gains come only from device makers re-modelling raw sensors they control** (Apple's 2025 update, Oura's Gen3 algorithm, Google's 2026 Fitbit model). An App Store app can't do this: dense overnight heart rate needs a workout session (ruled out: fake calories, blocked Vitals), and raw PPG is research-only.
- **Phone audio** (Asleep's SleepRoutine) beat Apple Watch 8 in one 11-tracker study, but 9 of 13 authors work for Asleep, it tested Apple's old algorithm, no open model exists, and Asleep's SDK uploads audio to its servers, which conflicts with sleepi's on-device design.
- **Morning self-report is not ground truth.** Sleep diaries missed about 30 min of awake time a night against PSG in midlife women (SWAN), and brief awakenings are mostly forgotten. It can anchor bed and rise times, not correct stages.

## 3. Our own tests on Apple Watch lab data

**Data:** Walch et al. 2019 (PhysioNet sleep-accel): 31 adults, one night each in a sleep lab with full polysomnography, Apple Watch accelerometer at 50 Hz (the same raw signal sleepi records with CMSensorRecorder) and heart rate every 5 seconds. Every test is subject-independent: the person being scored was never in the training data. Heart rate was also thinned to one reading every 5 minutes, which is roughly what Apple writes to HealthKit overnight on a Series 8.

### 3.1 Can sleepi re-stage the night better than Apple?

| Inputs (gradient-boosted model, 30-s epochs) | 4-stage agreement (κ) | Awake time found | Deep found |
|---|---|---|---|
| Time of night only | 0.14 | 29% | 27% |
| Wrist motion only | 0.27 | 59% | 44% |
| **Motion + heart rate every 5 min (what sleepi has)** | **0.39** | 56% | 52% |
| Motion + heart rate every 5 s (needs a workout session, ruled out) | 0.45 | 57% | 56% |
| Apple, independent lab studies (old algorithm) | 0.53–0.60 | 52% | 50.5% |
| Apple, own validation (2025 algorithm) | 0.68 | 79% | not stated |

Per-night agreement for the realistic model ranged from 0.05 to 0.63 (median 0.41). Published models on the same data reach 3-stage κ 0.39 to 0.52, so this is in line with the literature, not a weak attempt. **Verdict: re-staging loses to Apple. Rejected.**

### 3.2 sleepi's planned "likely awake" rule

The rule in the plan and the current build: flag "likely awake" when movement lasts 2+ epochs together with a heart-rate rise (a reading within 90 s above the readings 90 to 300 s earlier; we tried rises of 5, 10 and 15 bpm and two movement thresholds) or a rustling/speech sound.

| Heart rate | Flags that were truly awake (during the night) | Awake time found |
|---|---|---|
| Every 5 s (best case, not available to sleepi) | 31% to 54% | 20% to 31% |
| Every 5 min (what sleepi has) | 36% to 54%; the heart-rate check could only run 29% of the time | 2% to 3% |

- A flag has to be right more than half the time just to break even: each wrong flag adds as much error as each right one removes. In the real app the rule only overrules epochs Apple already called asleep, and Apple catches most awake-and-moving time itself, so the hit rate there can only be lower than the figures above (as long as Apple's call is better than chance on those epochs).
- **Sound doesn't rescue it.** In a lab study of frequent sleep talkers, 51 of 68 verbal episodes happened in N2 sleep and 1 in wake. Healthy sleepers move about 10 times an hour, and only about 15% of movements come with even a brief arousal; about a third coincide with a bed partner's movements.
- **Quiet wake is invisible at the wrist.** 57% of awake epochs during these lab nights had no wrist posture change of more than 5 degrees, so no motion-based rule can see them.

**Verdict: fails. Stop showing it as a correction.** Sound events stay on the timeline as facts ("speech at 3:12"), not as proof of being awake.

### 3.3 Correcting a night with published error statistics

Setup: a stand-in watch model trained on half the people, its "validation study" on the other half, and corrections applied to each held-out night, repeated over 5 random splits both ways. This is the best case: the bias is measured on the same kind of people with the same algorithm.

| Stage (true average) | Average error per night, raw | After subtracting the average bias | After confusion-matrix correction | Nights made worse by bias correction |
|---|---|---|---|---|
| Deep (59 min) | 33 min | 30 min | 51 min | 40% |
| Light (238 min) | 58 min | 39 min | 98 min | 29% |
| REM (95 min) | 37 min | 32 min | 74 min | 34% |
| Awake (39 min) | 19 min | 18 min | 24 min | 43% |

- Even in the best case, bias correction helps the average night a little and makes 30% to 43% of individual nights worse. Confusion-matrix correction makes most nights worse.
- For Apple the best case doesn't hold: nobody has measured the 2025 algorithm's bias in minutes, and studies of the old algorithm disagree even on direction (Light +45 and +59 vs −74 min). **Verdict: rejected.**

### 3.4 Limits of these tests

31 healthy-ish adults, one lab night each, on 2017–2019 Apple Watch hardware; the stand-in model is not Apple's; Apple's own output can't be tested because no public dataset has it.

## 4. Audit of every candidate

| Candidate | Evidence | Our test | Verdict |
|---|---|---|---|
| Re-stage nights from sleepi's signals | Walch-data models: 3-stage κ 0.39–0.52 | κ 0.39 vs Apple 0.53–0.68 | Reject |
| "Likely awake" overlay | Sleep talking mostly in N2; most movement has no arousal | Hit rate ≤ ~54%; finds 2–3% of awake time with real heart rate | Reject; remove from display |
| Add back missing Deep (bias correction) | Studies disagree; 2025 algorithm unmeasured | Worsens 30–43% of nights even in the best case | Reject |
| Confusion-matrix correction | None | Worsens most nights | Reject |
| Second-stage model on Apple's labels plus heart rate | One Fitbit study: overall up, Deep and wake down | Can't be trained without Apple-labelled reference nights | Not now (section 6) |
| Phone-audio staging | Asleep (conflict of interest) beat Apple's old algorithm | No open model; server upload | Park |
| Reconcile overlapping Apple records | Apple forum 842919 | Logic check | **Build** |
| Flag nights the Watch stopped recording | 17–43% lost or partial in lab studies | Logic check | **Build** |
| In-bed time, time to fall asleep, sleep efficiency from Tonight | Apple stopped writing in-bed; Apple's sleep onset is within about 2 min on average in three lab studies (individual nights off by up to about 48 min) | — | **Build as estimates** (partly exists) |
| Mark trend breaks when Apple's algorithm changes | Apple's 2025 white paper | Logic check | **Build** (small) |
| Show Deep as an estimate with a 7–14 night trend | Apple's most common error is Deep → Core | — | Keep (already planned) |

## 5. What sleepi builds (handed to the build thread)

1. **Reconcile overlapping Apple Watch sleep records before any total.** Never count a minute twice. Where two records give different stages for the same minute, pick one documented, deterministic rule (for example, the later-saved record wins) and log each reconciled night. Unit test with two overlapping writes. Check first whether today's code sums raw samples.
2. **Incomplete nights.** On a night started from Tonight, if the Watch's last sleep and heart-rate samples stop together (within about 10 minutes) and nothing more arrives from the Watch for at least 45 minutes while the night is still open, mark it "Watch stopped recording at 4:12" and leave it out of averages and trends (still visible, with an "Include anyway" switch). On nights without a Tonight session, show the gap as a note only and don't exclude, because a real early wake looks the same.
3. **In-bed figures from Tonight sessions**, labelled estimates: time in bed (start to end), time to fall asleep (start to Apple's first sleep), sleep efficiency (Apple's sleep ÷ time in bed). Note that Apple counts some still-awake time as sleep.
4. **Algorithm version per night** from each sample's source revision (watchOS version). When trends span a version change, draw a break line and don't compare across it.
5. **Turn off "likely awake" proposals** wherever they show. Keep sound events as plain events on the timeline.
6. **Corrected history with the difference from Apple.** sleepi keeps its own nightly record: Apple's data plus items 1 to 4 only. A "vs Apple" line lists what changed and why, for example "30-night average 7 h 05 m vs Apple's raw record 6 h 52 m: 2 nights the Watch stopped recording left out, 1 duplicate write merged." Every difference traces to a named night.
7. **Deep sleep info line:** "Apple's own testing says its most common mistake is calling deep sleep core sleep. Trust the trend over any one night."

## 6. The only route to an empirical stage correction

- **Reference nights from a lab-validated EEG headband**, worn alongside the Watch: Muse S Athena ($475; κ 0.76 vs lab PSG in 47 people, 80% poor sleepers; the maker supplied devices) or FRENZ Brainband ($680; κ 0.83 in 155 people; press coverage ties an author to the maker). Dreem is now prescription-only.
- **Plan if chosen:** about 14 nights wearing both; sleepi measures Apple's actual error on Randy, fits any correction on some nights and scores it on the others, and ships it only if it beats Apple on the held-out nights for Deep and wake separately (the Liang trap).
- **Unknowns:** whether one person's Apple error is consistent from night to night (no published Apple data). A public dataset could test this first (BIDSleep: 47 adults, 253 nights, Apple Watch raw signals with Dreem labels), but this cloud environment can't download from physionet.org.
- **Cost:** about $475 and a headband at bedtime for two weeks, which goes against zero extra steps at bedtime. **Recommendation: skip for now.**

## Sources

- Apple, Estimating Sleep Stages from Apple Watch (updated October 2025): https://www.apple.com/health/pdf/Estimating_Sleep_Stages_from_Apple_Watch_Oct_2025.pdf
- Apple Developer Forums, inBed no longer recorded: https://developer.apple.com/forums/thread/766977
- Apple Developer Forums, overlapping writes from the Watch: https://developer.apple.com/forums/thread/842919
- HealthKit sleep analysis values: https://developer.apple.com/documentation/healthkit/hkcategoryvaluesleepanalysis
- Robbins et al. 2024, Sensors (Oura-funded): https://www.mdpi.com/1424-8220/24/20/6532
- Schyvens et al. 2025, SLEEP Advances: https://academic.oup.com/sleepadvances/article/6/2/zpaf021/8090472
- Lee et al. 2023, JMIR mHealth and uHealth, 11 consumer trackers (Asleep authors): https://mhealth.jmir.org/2023/1/e50983
- Alhejaili et al. 2026, Sleep Medicine (abstract only): https://doi.org/10.1016/j.sleep.2026.109059
- Liang & Chapa-Martell 2021, Frontiers in Digital Health: https://www.frontiersin.org/journals/digital-health/articles/10.3389/fdgth.2021.665946/full
- Walch et al. 2019, SLEEP, and dataset: https://academic.oup.com/sleep/article/42/12/zsz180/5549536 , https://physionet.org/content/sleep-accel/1.0.0/
- Zhai et al. 2021, Ubi-SleepNet (Walch data): https://arxiv.org/abs/2111.10245
- Hong et al. 2022, Nature and Science of Sleep (Asleep audio staging): https://www.dovepress.com/end-to-end-sleep-staging-using-nocturnal-sounds-from-microphone-chips--peer-reviewed-fulltext-article-NSS
- Sleep talking by stage (frequent sleep talkers): https://academic.oup.com/sleep/article/45/5/zsab284/6453478
- Movement and arousal in healthy sleepers: https://scholars.duke.edu/publication/1600698 ; https://academic.oup.com/sleep/article/47/9/zsae138/7697844
- SWAN diary vs PSG: https://academic.oup.com/sleepadvances/article/3/1/zpac001/6532495
- Muse S validation (Lanthier 2026): https://espace2.etsmtl.ca/33349/1/Lina-JM-2026-33349.pdf ; FRENZ (Nguyen 2023): https://www.nature.com/articles/s41598-023-43975-1
- BIDSleep dataset: https://physionet.org/content/bidsleep-dataset/1.0.1/
- Overnight heart-rate cadence (Series 12 "60x" claim, implying about 5 min before): https://www.macobserver.com/news/apple-watch-series-12-60x-24x-heart-rate-hrv-frequency/
