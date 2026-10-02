# sleepi feature review: Sleep Cycle items (2 Oct 2026)

Every item from refs/10 except the AI coach, meditation, stories, relaxing sounds, and anything paid or that shares or sells data. Two items have their own threads and are left out here: training our own sound model, and whether a neural network can beat Apple's sleep staging. Snore statistics over time depend on the sound-model thread.

Randy's bar: researched, tested, survives falsification, and actually improves sleepi. Rules that still hold: free, no in-app alarm, nothing that fights Apple Health, no Health writes, no Watch workout session, no partners.

## Summary

| Item | Verdict |
|---|---|
| Sleep notes, morning rating and "linked" results | **Build** (slow payoff, see test) |
| Export of sleepi's own data | **Build** (small) |
| sleepi's data survives a phone change | **Build** (a check, maybe a one-line fix) |
| Weekly report | Discuss (leaning drop) |
| "Who's snoring" / partner link | Discuss (only matters if someone shares the room) |
| Overnight heart rate, breathing, wrist temp screens | Drop as screens; heart rate is used inside Notes |
| Wake-up light (Hue / HomeKit) | Drop: iOS Shortcuts already does it |
| Tracking without a Watch | Drop |
| Online backup to a server, Android | Drop |
| Ambient light, wake-up weather, cough radar | Drop |
| Sleep goal, bedtime routine, StandBy | Drop: Apple's Sleep schedule covers them |

## 1. Sleep notes and morning rating: BUILD

**Evidence.** Some habits clearly change sleep. A 2023 meta-analysis found caffeine cuts sleep by about 45 min, adds 9 min to falling asleep and 12 min of night waking, and says coffee should be at least 8.8 h before bed ([Gardiner et al., Sleep Med Rev 2023](https://doi.org/10.1016/j.smrv.2023.101764)). Alcohol raises how hard the heart works in the first hours of sleep, and the more you drink the bigger the effect, in a repeated-measures study of 4,098 people ([Pietilä et al., JMIR Ment Health 2018](https://mental.jmir.org/2018/1/e23)). A morning "how well did you sleep" rating is part of the standard sleep diary sleep clinics use ([Carney et al., Sleep 2012, Consensus Sleep Diary](https://doi.org/10.5665/sleep.1642)).

**The catch, which the test below confirms.** One person's sleep swings a lot from night to night. The typical night-to-night spread in sleep time is 67 to 77 min ([Messman et al. 2022](https://experts.arizona.edu/en/publications/how-much-does-sleep-vary-from-night-to-night-a-quantitative-summa/)). So even a real 45-min effect is hard to see in one person, and an app that says "caffeine costs you 23 minutes" after a couple of weeks is mostly reporting noise. sleepi should only claim a link when the numbers hold up.

**Test** (`/mnt/project-files/sleepi/analysis/tag-tests/sim.py`, output in `sim_results.txt`). Simulated nights include realistic night-to-night noise (each night slightly like the one before), longer weekend sleep, and six tags of which one has a real effect. The rule tested is the one specced below.

| Case | Shown as "linked" |
|---|---|
| Caffeine-like tag, 2 nights/week, −45 min sleep | 7% at 4 weeks, 24% at 8, 44% at 12, 65% at 16 |
| Alcohol-like tag, 1 night/week, sleeping heart rate +3 bpm | 21% at 8 weeks, 37% at 12, 49% at 16 |
| Same alcohol tag judged on sleep time instead | 2 to 5%. Sleep time is too noisy; heart rate is the better measure |
| A tag with no effect at all (5 such tags) | 2 to 7% |
| **Falsification:** no-effect tag logged mostly on weekends | Naive comparison says "linked" 11% of the time. Comparing weekdays with weekdays and weekends with weekends: 1% |

Assumptions: sleeping heart rate spread 3 bpm and an alcohol effect of 2 to 4 bpm. These are inferred, not from a source with bpm numbers; the Pietilä abstract reports heart-work and HRV, not bpm.

**Conclusion.** The rule rarely invents a link (about 5%) and passes the weekend-confound test, which a naive version fails. But it needs two to four months of tagging before it says much. So the feature is worth building as an honest sleep diary, not as the quick insight feed Sleep Cycle sells.

**Spec for the build thread**
- **Where:** iPhone only, in the morning. Nothing at bedtime, no reminder, no Watch screen. An optional card at the top of the night's page, opened from the existing morning summary. Skipping it is fine.
- **Card:** "How did you sleep?" with five choices (Very poor / Poor / Fair / Good / Very good, as in the Consensus Sleep Diary), plus chips for the evening before. Default chips:
  - Caffeine after 2 pm
  - Alcohol
  - Late meal (within 3 h of bed)
  - Hard exercise late
  - Nap
  - Stressed
  - Unwell
  - Custom
  
  Chips can be renamed, merged, hidden and reordered, and a rename keeps the tag's history. Inability to rename sleep notes is a known Sleep Cycle complaint (refs/02).
- **Storage:** in sleepi only, next to the night record. Never written to Health, not even State of Mind (no Health writes).
- **What each tag is compared on:**
  - Apple's total sleep
  - Bed-to-first-sleep
  - Night wake-ups
  - Average sleeping heart rate: Apple's heart-rate samples inside Apple's asleep intervals for the main sleep. This needs Health read access to heart rate; check whether sleepi already asks for it, and add the read if not. Read only.
  - Morning rating
- **Nights left out:** nights marked "Watch stopped recording" (same switch as averages), and nights with no rating for the rating comparison.
- **Rule, recomputed each morning on the device:**
  1. Need at least 8 tagged and 8 untagged nights with data.
  2. Difference = tagged mean − untagged mean.
  3. p-value: shuffle the tag 2,000 times, only among weekdays and only among weekends (Fri/Sat nights count as weekend), and count how often a shuffled difference is at least as large.
  4. Benjamini-Hochberg at 5% across every tag × measure pair.
  5. Minimum size to show: sleep 20 min, bed-to-first-sleep 5 min, wake-ups 1, sleeping heart rate 1.5 bpm, rating 0.5 points.
- **Wording:**
  - When it passes: "On nights after *Alcohol*, your sleeping heart rate was 3 bpm higher (9 nights vs 41)." Never "causes".
  - Before 8 nights: "Not enough nights yet (3 of 8)."
  - After that with no pass: "No clear link so far (12 nights)."
  - One line on the screen explains that a single person's sleep varies a lot, so links usually take two months or more.
- **Tests:** port `sim.py`'s cases A, D and E as unit tests with a fixed seed. A no-effect tag must show as linked in ≤10% of runs. The weekend-confounded tag must be ≤5% with matching on, which proves the matching works.

## 2. Export sleepi's own data: BUILD (small)

Sleep Cycle includes data export in its free tier. Apple's Health export already covers Apple's data. sleepi's own data is not covered: tags, ratings, bed-to-first-sleep, wake-ups, sound event list, gentle-wake decisions. Exporting it lets us check features like the one above against Randy's real nights instead of simulations.

**Spec:** Settings > Export. One CSV with a row per night: date, Apple total sleep, sleepi bed-to-first-sleep, wake-ups, sleeping heart rate, rating, tags, number of sound events by type, gentle wake used (yes/no) and wake decision time. Shared through the system share sheet, the same way as the tuning logs. No audio. Nothing is uploaded anywhere.

## 3. Keep sleepi's data through a phone change: BUILD (a check)

Sleep Cycle sells online backup. sleepi doesn't need a server, because a normal iPhone or iCloud backup includes an app's Documents and Application Support folders, unless the app marks them excluded or keeps them in Caches or tmp. Once tags need months of history, losing them would hurt.

**Spec:** confirm the night records, tags, ratings and starred clips sit in Application Support or Documents, not in Caches or tmp, and are not marked `isExcludedFromBackup`. Unstarred clips can stay excluded, since they delete after 14 days anyway. Fix if not. Inferred from Apple's backup rules, not yet checked in sleepi's code.

## Discuss

- **Weekly report.** Sleep Cycle sends a weekly summary. sleepi already has Trends, a morning summary and soon Notes. A weekly digest would mostly repeat Trends, and one week is too short to judge anything given the night-to-night spread above. Leaning drop unless you want a Sunday line in the morning summary.
- **"Who's snoring" / partner link.** This only helps when two people share the room and both use the app. Drop unless that's your setup.

## Dropped, with why

- **Overnight heart rate, breathing rate, wrist temperature screens.** Vitals already shows these against your own baseline and flags outliers ([Apple](https://support.apple.com/en-us/120142)). Copying them adds nothing. Sleeping heart rate is still used in Notes, where it adds something.
- **Wake-up light.** iOS Shortcuts has built-in "Waking Up", "Bedtime Begins" and "Wind Down Begins" triggers from the Sleep schedule, plus alarm "Is Stopped" ([Apple](https://support.apple.com/guide/shortcuts/apd932ff833f/ios)). These can run any Home or Hue scene, and Hue's own app does gradual wake routines. sleepi would only be a middleman.
- **Tracking without a Watch.** Phone-only apps can't tell sleep stages apart (refs/07), and you wear a Watch.
- **Server backup, Android.** Section 3 covers backup at no cost. Android is out of scope.
- **Ambient light.** iOS gives apps no access to the light sensor, as far as Apple's public frameworks show (inferred). Room noise is already in the nightly listening summary.
- **Wake-up weather.** Not sleep data.
- **Cough radar.** Built from many users' pooled data, which is the sharing we rule out.
- **Sleep goal, bedtime routine, StandBy.** Apple's Sleep schedule, Wind Down and Clock already do these, and sleepi defers to them.
- **Smart snooze.** Already built: gentle wake's 10-min snooze.
