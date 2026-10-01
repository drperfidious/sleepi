# sleepi reference: sleep science evidence review (opened 2026-10-01)

Research notes behind `01-sleepi-plan.md`.

Overall: Apple Watch sleep staging is about as good as consumer wearables get. Its weak points are wake detection and deep sleep, and that is where sleepi can add value. A smart alarm's benefit is a reasonable inference from lab studies, not a proven result. Regularity metrics have the strongest health evidence.

## 1. Apple Watch staging accuracy vs polysomnography (PSG, the lab sleep test)

**Apple's own data.** https://www.apple.com/healthcare/docs/site/Estimating_Sleep_Stages_from_Apple_Watch_Sept_2023.pdf (revised; now includes a 2025 algorithm update)
- Validation set: 166 people, 299 nights. Separate clinical set: 236 people, 390 sessions.
- Original algorithm: sleep sensitivity 97.9% (rarely misses real sleep); sleep specificity 75.0% (misses about a quarter of real wake); 4-stage kappa 0.63. Clinical population: kappa 0.55, specificity 72.5%.
- Most common error: deep sleep scored as Core.
- 2025 algorithm: specificity 78.9%, kappa 0.68, wake accuracy up from 70% to 79%.
- Apple's stated limits: not for clinical use; accuracy drops with fragmented sleep and with sleep apnea.

**Robbins et al. 2024, Sensors.** https://www.mdpi.com/1424-8220/24/20/6532
- 35 healthy adults, one PSG night; Oura Gen3, Fitbit Sense 2, Apple Watch S8.
- All three: sleep sensitivity 95% or higher.
- Per-stage sensitivity: Oura 76–79.5%, Fitbit 61.7–78%, Apple 50.5–86.1%.
- Apple underestimated deep sleep by about 43 minutes and overestimated light sleep by about 45 minutes. Oura showed no significant differences from PSG.
- 6 Apple Watch recordings failed.

**Schyvens et al. 2025, SLEEP Advances.** https://academic.oup.com/sleepadvances/article/6/2/zpaf021/8090472
- 62 adults; Fitbit Charge 5, Fitbit Sense, Withings, Garmin, Whoop 4.0, Apple Watch S8.
- Sleep sensitivity 91.7–96.3%, wake specificity only 29.4–52.2%.
- Apple had the best agreement (kappa 0.53).
- Most devices underestimated wake after sleep onset (WASO) and differed significantly from PSG on total sleep time, sleep efficiency and light sleep.
- Apple data loss was 37%.

**Schyvens et al. 2024 systematic review, JMIR mHealth.** https://doaj.org/article/e789b4be175943e5838b3e10cd73b785
- Whoop overestimated REM by 21 minutes. Fitbit Charge 4 deep sleep sensitivity 75%.

**Known weaknesses**
- Wearables almost always call sleep correctly but miss wake. Lying still and awake counts as asleep, so total sleep time and efficiency are inflated and WASO is undercounted.
- Deep sleep is underestimated (on Apple Watch, deep is scored as Core).
- Nights are often missing.
- Worse with fragmented sleep or sleep apnea.

**Design implications**
- Show stages with uncertainty ("estimated").
- Don't over-interpret night-to-night deep sleep changes; use 7–14 night trends.
- Treat Apple's "awake" as a lower bound.
- Handle missing nights gracefully.

## 2. Signals that could improve staging and wake detection

**Movement-only (actigraphy) algorithms.** https://www.dovepress.com/actigraphy-based-sleep-estimation-in-adolescents-and-adults-a-comparis-peer-reviewed-fulltext-article-NSS
- Adults: Cole-Kripke sensitivity 0.96, specificity 0.35; Sadeh 0.91 and 0.47. Movement alone won't beat Apple's model.

**Walch et al. 2019, Sleep.** https://academic.oup.com/sleep/article/42/12/zsz180/5549536 and https://physionet.org/content/sleep-accel/1.0.0/
- 31 people wore Apple Watches during PSG. Raw accelerometer, heart rate and step data with PSG labels are free on PhysioNet.
- Inputs: movement counts, HRV (local SD of heart rate), and a body-clock estimate from activity history.
- At 93% sleep sensitivity, wake specificity was 59.6%. Adding the body-clock estimate improved wake detection by about 14%.
- About 72% accuracy for three classes (wake / NREM / REM). Generalized to the MESA dataset.

**Heart rate + HRV + movement.** https://ar5iv.labs.arxiv.org/html/2308.05759
- MESA, 1,827 people, XGBoost: accuracy 77.6%, sensitivity 91.1%, specificity 53.7%. Wake detection is still the ceiling.

**Phone microphone.** https://doaj.org/article/57c881046b954de38b3de174d2f573a2
- Tran, Hong et al. (Asleep team), JMIR 2023, home smartphone audio: accuracy 76.2%, macro F1 0.714. Wake 63.4%, REM 64.9%, non-REM 83.6%. Held up across age, sex, BMI and apnea severity.

**Design implications**
- The realistic gain is a better wake call, not better staging. Combine Apple's stages, movement and HRV around the event, a body-clock prior, optional phone audio (rustling, talking), and a quick morning check-in ("were you awake around 3am?").
- Use the PhysioNet set to prototype and benchmark the model.
- Process audio on-device and keep features plus short event clips, not full recordings.
- Watch heart-rate sampling during sleep is sparse and raw accelerometer access is limited; confirm what HealthKit and CoreMotion expose on device (see `03-apple-platform-research.md`).

## 3. Smart alarm / wake window

- **Tassi & Muzet 2000, review.** https://pubmed.ncbi.nlm.nih.gov/12531174/ The stage you wake from is "one of the most critical factors" in sleep inertia. Slow-wave sleep is worst, REM intermediate, stages 1–2 least. Inertia rarely lasts more than 30 minutes unless sleep-deprived; worse near the body-temperature low point.
- **Sleep Research Society handout.** https://sleepresearchsociety.org/wp-content/uploads/2023/06/fighting-grogginess-after-sleep.pdf Waking from deep sleep worsens grogginess. Recommends bright light after waking and naps under 30 or about 90 minutes. Doesn't mention smart alarms.
- **Campanella et al. 2024, Clocks & Sleep.** https://doaj.org/article/8847be4046c14a38879119418a14ad24 A multimodal "smart" alarm in the lab had limited overall effect, with some benefit for evening chronotypes with longer light exposure.
- **Samsung smartwatch alarm.** https://developer.samsung.com/health/publications/4.html Engineering work only (66–70% four-stage accuracy); no outcome trial.

**Strength of evidence:** moderate (lab) that waking stage matters; weak or none that consumer stage-timed alarms reduce grogginess; real-time light-sleep detection on wearables is limited.

**Design implications:** 20–30 minute window preferring wake, movement or light sleep and avoiding flagged deep sleep; call it "gentler waking," not clinically proven; pair with gradual light or sound where possible.

## 4. Consistency metrics

- **Sleep Regularity Index (SRI): Phillips et al. 2017, Scientific Reports.** https://doaj.org/article/98978c03a4da4abb894c69dbfb834eb9 SRI is the probability of being in the same sleep/wake state at times 24 hours apart. 61 students over 30 days: SRI correlated with grades (r=0.37). Irregular sleepers had melatonin onset about 2.5 hours later.
- **Windred et al., Sleep 2023/24.** https://www.ukbiobank.ac.uk/publications/sleep-regularity-is-a-stronger-predictor-of-mortality-risk-than-sleep-duration-a-prospective-cohort-study/ About 61,000 UK Biobank participants with wrist accelerometers, median 6.3-year follow-up. Top four SRI quintiles had 20–48% lower all-cause mortality. Regularity predicted mortality better than duration.
- **Social jetlag: Roenneberg et al. 2012.** https://www.sciencedaily.com/releases/2012/05/120510122802.htm Gap between mid-sleep on free days and work days; associated with being overweight, smoking, alcohol and caffeine use.

**Design implications:** make SRI the headline metric (robust to staging errors, best outcome data), computed over at least 7 and ideally 14+ days. Show social jetlag in hours and estimate chronotype from mid-sleep on free days. Present sleep debt as a soft trend (rolling 14-day shortfall against a personal target); no source validated a specific debt formula.

## 5. Snoring and sleep apnea via phone audio

- **SnoreLab vs polygraphy.** https://www.mdpi.com/1660-4601/18/14/7326 19 adults. Sensitivity 100%, PPV 66.6%, specificity 94.1%. Good for heavy snoring, but overestimated total snoring and could not detect obstructive events. Small sample; sensitive to background noise.
- **SleepWatch snore detection.** https://formative.jmir.org/preprints/67861 Sensitivity 86.3%, specificity 99.5%, but tested only on simulated audio.
- **Apple's apnea notification.** https://apple.com/health/pdf/sleep-apnea/Sleep_Apnea_Notifications_on_Apple_Watch_September_2024.pdf and FDA 510(k) K240929 https://fda.innolitics.com/device/K240929 Regulated software medical device, accelerometer-based. 1,448 people, sensitivity 66.3%, specificity 98.5% for moderate-to-severe apnea. Needs elevated readings across 10+ nights in 30 days. Not for people already diagnosed. (Not available on Series 8.)

**Design implications:** snore minutes, intensity, trends and "what changed" correlations (alcohol, position). No apnea detection, risk scores or diagnosis. Point to a clinician when warning signs appear (loud snoring plus witnessed pauses, daytime sleepiness). Stay within FDA general-wellness framing (the FDA guidance document itself was not opened).

## 6. Sleep habit and insomnia interventions

- **AASM 2021 insomnia guideline.** https://aasm.org/new-guideline-supports-behavioral-psychological-treatments-for-insomnia/ Strong recommendation for multicomponent CBT-I; conditional for stimulus control, sleep restriction and relaxation; sleep hygiene alone is not effective as a stand-alone treatment.
- **Sleep restriction side effects (Kyle et al.).** https://www.phc.ox.ac.uk/publications/387400 At the start, fatigue was universal and 94% reported extreme sleepiness; participants averaged about 7 side effects.
- **Caffeine: Drake et al. 2013.** https://sleepeducation.org/late-afternoon-and-early-evening-caffeine-can-disrupt-sleep/ 400 mg even 6 hours before bed cut total sleep by more than an hour.

**Design implications:** support a consistent wake-time anchor (also raises SRI), stimulus-control coaching ("out of bed if awake about 20 minutes"), a caffeine cutoff nudge at least 6 hours before bed, wind-down and morning light. Don't present hygiene tips as treatment. Don't offer self-guided sleep restriction. Because wearables undercount wake, don't compute CBT-I sleep efficiency from watch data alone.

PMC and PubMed pages hit a CAPTCHA during research, so several studies are cited via publisher, DOAJ, UK Biobank or AASM pages.
