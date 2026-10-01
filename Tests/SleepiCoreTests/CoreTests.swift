import Foundation
import Testing
@testable import SleepiCore

private let origin = Date(timeIntervalSince1970: 1_780_358_400)
private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }
private func sample(_ a: Double, _ b: Double, _ stage: SleepStage = .core, source: String = "com.apple.health") -> SleepSample {
    SleepSample(start: origin.addingTimeInterval(a), end: origin.addingTimeInterval(b), stage: stage, source: source)
}

@Test func ignoresThirdPartyAndInBed() {
    #expect(NightBuilder.build(samples: [sample(0, 3600, .core, source: "app.other"), sample(0, 3600, .inBed)], calendar: utc).isEmpty)
}
@Test func deduplicatesOverlapsWithoutCountingTwice() {
    // Two overlapping writes from the Watch: sleepi counts each minute once and logs the merge; Apple's raw sum doesn't.
    let night = NightBuilder.build(samples: [sample(0, 3600), sample(1800, 5400)], calendar: utc)[0]
    #expect(night.asleepSeconds == 5400)
    #expect(night.overlapSeconds == 1800); #expect(night.rawAsleepSeconds == 7200)
}
@Test func conflictingSleepWakeRemainsUnknown() {
    let night = NightBuilder.build(samples: [sample(0, 3600), sample(600, 1200, .awake)], calendar: utc)[0]
    #expect(night.asleepSeconds == 3000)
    #expect(night.awakeSeconds == 0)
    #expect(night.conflictingSeconds == 600)
}
@Test func conflictingStagesLoseStageNotSleep() {
    let night = NightBuilder.build(samples: [sample(0, 3600), sample(600, 1200, .deep)], calendar: utc)[0]
    #expect(night.asleepSeconds == 3600)
    #expect(night.seconds(in: .unspecified) == 600)
}
@Test func gapsAreNotInventedWakeTime() {
    let night = NightBuilder.build(samples: [sample(0, 600), sample(3600, 4200)], calendar: utc)[0]
    #expect(night.recordedSeconds == 1200)
    #expect(night.awakeSeconds == 0)
}
@Test func springAndAutumnWindowsUseCalendarDays() {
    var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/Toronto")!
    for (month, day, hours) in [(3, 7, 23.0), (10, 31, 25.0)] {
        let date = c.date(from: DateComponents(year: 2026, month: month, day: day, hour: 22))!
        #expect(NightBuilder.window(containing: date, calendar: c).duration == hours * 3600)
    }
}
@Test func midnightCircularStatistics() {
    #expect(abs(Insights.circularDifference(10, 1430) - 20) < 0.001)
    let mean = Insights.circularMean([1430, 10])!
    #expect(min(abs(mean), abs(1440 - mean)) < 0.001)
    #expect(Insights.circularMean([0, 720]) == nil)
}
@Test func noMetricsFromInsufficientCoverage() {
    let nights = NightBuilder.build(samples: [sample(0, 3600)], calendar: utc)
    #expect(Insights.consistency(nights: nights) == nil)
    #expect(Insights.comparison(tagID: UUID(), nights: nights, journals: []) == nil)
    #expect(Insights.socialJetlag(nights: nights, journals: []) == nil)
    let shortfall = Insights.shortfall(nights: nights, targetHours: 8, now: origin.addingTimeInterval(7200), calendar: utc)
    #expect(shortfall.recordedNights == 1)
    #expect(shortfall.seconds == 7 * 3600) // No fabricated debt for thirteen missing nights.
}
@Test func retentionProtectsStarsButHonorsHardCap() {
    var star = SoundEvent(start: origin, end: origin, kind: .snoring, confidence: 0.9, levelDBFS: -25, fileName: "star.m4a", byteCount: 300)
    star.starred = true
    let old = SoundEvent(start: origin, end: origin, kind: .speech, confidence: 0.9, levelDBFS: -25, fileName: "old.m4a", byteCount: 50)
    let plan = ClipRetention.plan(events: [star, old], now: origin.addingTimeInterval(20 * 86400), budget: 300, reservation: 10)
    #expect(plan.deleteIDs == [old.id]); #expect(!plan.canRecord); #expect(plan.retainedBytes == 300)
}
@Test func boundedAudioRingAndDecibels() {
    var ring = PCMWindow(capacity: 4); ring.append([1, 2, 3]); ring.append([4, 5, 6])
    #expect(ring.samples == [3, 4, 5, 6]); #expect(ring.count == 4)
    #expect(abs(PCMWindow.dbfs([0.5, -0.5]) + 6.0206) < 0.001)
    #expect(PCMWindow.dbfs([0, 0]) == -120)
}
@Test func gentleWakeRejectsPastAndOverlongWindows() {
    #expect(GentleWakePolicy.start(latest: origin, now: origin) == nil)
    #expect(GentleWakePolicy.start(latest: origin.addingTimeInterval(3600), now: origin, windowMinutes: 31) == nil)
    #expect(GentleWakePolicy.start(latest: origin.addingTimeInterval(3600), now: origin, windowMinutes: 30) == origin.addingTimeInterval(1800))
    #expect(GentleWakePolicy.start(latest: origin.addingTimeInterval(40 * 3600), now: origin) == nil)
    #expect(GentleWakePolicy.start(latest: origin.addingTimeInterval(3600), now: origin) == origin.addingTimeInterval(2100))
}
@Test func repositoryRoundTripAndUnsafePaths() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repo = try LocalRepository(directory: directory)
    var state = LocalState(); state.settings.targetHours = 7.5
    try await repo.save(state)
    #expect(try await repo.load().settings.targetHours == 7.5)
    await #expect(throws: StoreError.self) { try await repo.clipURL("../secret.m4a") }
    try await repo.deleteAll()
    #expect(try await repo.load().settings.targetHours == 8)
}
@Test func unsupportedStoreNeverOverwrittenByLoad() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let repo = try LocalRepository(directory: directory)
    var state = LocalState(); state.schemaVersion = 99
    try await repo.save(state)
    await #expect(throws: StoreError.self) { try await repo.load() }
}

@Test func validatesMotionWithoutInventingMissingEpochs() {
    let empty = MotionRecording(id: UUID(), start: origin, end: origin.addingTimeInterval(3600), epochs: [])
    #expect(empty.isValid)
    let bad = MotionRecording(id: UUID(), start: origin, end: origin.addingTimeInterval(3600), epochs: [MotionEpoch(start: origin, meanMovement: .nan, sampleCount: 1500)])
    #expect(!bad.isValid)
    let unordered = MotionRecording(id: UUID(), start: origin, end: origin.addingTimeInterval(3600), epochs: [MotionEpoch(start: origin.addingTimeInterval(30), meanMovement: 0.1, sampleCount: 1500), MotionEpoch(start: origin, meanMovement: 0.1, sampleCount: 1500)])
    #expect(!unordered.isValid)
}

@Test func stageDurationsConserveUnionForManyOverlaps() {
    let samples = (0..<100).map { sample(Double($0 * 15), Double($0 * 15 + 30)) }
    let nights = NightBuilder.build(samples: samples + samples, calendar: utc)
    #expect(nights.reduce(0) { $0 + $1.asleepSeconds } == 1515)
    #expect(nights.allSatisfy { n in zip(n.segments, n.segments.dropFirst()).allSatisfy { $0.end <= $1.start } })
}

@Test func shortfallDoesNotUseOldOrFutureNights() {
    let nights = NightBuilder.build(samples: [sample(-30 * 86400, -30 * 86400 + 3600), sample(0, 3600), sample(86400, 90000)], calendar: utc)
    let value = Insights.shortfall(nights: nights, targetHours: 8, now: origin.addingTimeInterval(7200), calendar: utc)
    #expect(value.recordedNights == 1); #expect(value.seconds == 25200)
}

@Test func interruptionsCountOnlyRecordedWakeInsideSleep() {
    let night = NightBuilder.build(samples: [sample(0, 600, .awake), sample(600, 3600), sample(3600, 3900, .awake), sample(3900, 7200),
                                             sample(9000, 12000), sample(12000, 12600, .awake)], calendar: utc)[0]
    #expect(night.interruptions.count == 1) // Edge wake and the unknown 7200–9000 gap are not wakings.
    #expect(night.interruptions.seconds == 300)
}

@Test func usualWakeUsesEachWeekdayThenItsDayTypeAndNeverGuesses() {
    // origin is Tuesday 2 June 2026, 00:00 UTC (weekday 3). Wake-ups: Tue 06:30 and 06:40, Wed 07:00, Sat 09:00.
    let day = 86400.0
    let nights = NightBuilder.build(samples: [
        sample(-7 * day + 3600, -7 * day + 6.5 * 3600), sample(3600, 6 * 3600 + 40 * 60),
        sample(-6 * day + 3600, -6 * day + 7 * 3600), sample(-3 * day + 3600, -3 * day + 9 * 3600)
    ], calendar: utc)
    let usual = UsualWake.byWeekday(nights: nights, now: origin.addingTimeInterval(12 * 3600), calendar: utc)
    #expect(usual[3] == 6 * 60 + 35)  // Tuesday: its own two mornings
    #expect(usual[2] == 6 * 60 + 40)  // Monday: no mornings of its own, so the three weekday mornings
    #expect(usual[7] == nil)          // Saturday: one weekend morning isn't enough to suggest anything
    #expect(usual[1] == nil)
}

@Test func wakeSuggestionPrefersRecentPickAndSkipsTimesAlreadyPassed() {
    let evening = origin.addingTimeInterval(22 * 3600) // Tuesday 22:00 UTC; the next morning is Wednesday (weekday 4)
    let wednesday0615 = origin.addingTimeInterval(86400 + 6 * 3600 + 15 * 60)
    let pick = GentleWakePolicy.suggestion(now: evening, picked: [4: (6 * 60 + 15, origin.addingTimeInterval(-6 * 86400))], usual: [4: 6 * 60 + 45], calendar: utc)
    #expect(pick == WakeSuggestion(date: wednesday0615, source: .lastPick))
    let stale = GentleWakePolicy.suggestion(now: evening, picked: [4: (6 * 60 + 15, origin.addingTimeInterval(-40 * 86400))], usual: [4: 6 * 60 + 45], calendar: utc)
    #expect(stale?.source == .usualWake)
    // At 02:00 Wednesday the same morning still counts; with nothing known there is no suggestion.
    let early = GentleWakePolicy.suggestion(now: origin.addingTimeInterval(86400 + 2 * 3600), picked: [:], usual: [4: 6 * 60 + 45], calendar: utc)
    #expect(early?.date == origin.addingTimeInterval(86400 + 6 * 3600 + 45 * 60))
    #expect(GentleWakePolicy.suggestion(now: evening, picked: [:], usual: [:], calendar: utc) == nil)
}

private func detect(_ sensitivity: WakeSensitivity = .standard, movingSeconds: [ClosedRange<Double>], until: Double = 1500) -> (due: Double?, detector: WakeWindowDetector) {
    // 10 Hz readings over a 25-minute window. "Moving" alternates the magnitude by 0.1 g on every reading.
    var detector = WakeWindowDetector(windowStart: origin, latest: origin.addingTimeInterval(1500), sensitivity: sensitivity)
    var t = 0.0, flip = false
    while t < until {
        let moving = movingSeconds.contains { $0.contains(t) }
        flip.toggle()
        if detector.add(magnitude: moving ? (flip ? 1.1 : 1.0) : 1.0, at: origin.addingTimeInterval(t)) { return (t, detector) }
        t += 0.1
    }
    return (nil, detector)
}

@Test func gentleWakeIgnoresStillnessAndOneTwitchOrRollOver() {
    #expect(detect(movingSeconds: []).due == nil)
    #expect(detect(movingSeconds: [60...61]).due == nil)          // a twitch
    #expect(detect(movingSeconds: [60...68]).due == nil)          // one roll-over, even a big one
    #expect(detect(.lessMovement, movingSeconds: [60...68]).due == nil)
}

@Test func gentleWakeTapsOnSustainedRestlessnessAndLogsEveryEpoch() {
    let rolling = detect(movingSeconds: [600...720])                // two minutes of tossing from minute 10
    #expect(rolling.due != nil); #expect(rolling.due! < 700)       // within about a minute and a half
    #expect(rolling.detector.epochs.count >= 20); #expect(rolling.detector.epochs.contains { $0.restless })
    // Short movements in two consecutive epochs count for "less movement" but not for "more movement".
    let bursts: [ClosedRange<Double>] = [600...601.5, 630...631.5, 660...661.5]
    #expect(detect(.lessMovement, movingSeconds: bursts).due != nil)
    #expect(detect(.moreMovement, movingSeconds: bursts).due == nil)
}

@Test func gentleWakeSettingsClampToApplesSessionCapAndNewerEditWins() {
    #expect(GentleWakeSettings(windowMinutes: 45).windowMinutes == 30)
    #expect(GentleWakeSettings(windowMinutes: 1).windowMinutes == 5)
    let old = GentleWakeSettings(windowMinutes: 20, updatedAt: origin), new = GentleWakeSettings(windowMinutes: 10, updatedAt: origin.addingTimeInterval(5))
    #expect(old.merged(with: new) == new); #expect(new.merged(with: old) == new)
}

@Test func librariesWrittenBeforeNewOptionalFieldsStillLoad() throws {
    // Regression guard: adding non-optional fields to LocalState would make existing libraries unreadable.
    var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalState())) as! [String: Any]
    legacy.removeValue(forKey: "wakeLogs")
    var settings = legacy["settings"] as! [String: Any]; settings.removeValue(forKey: "gentleWake"); legacy["settings"] = settings
    let decoded = try JSONDecoder().decode(LocalState.self, from: JSONSerialization.data(withJSONObject: legacy))
    #expect(decoded.wakeLogs == nil); #expect(decoded.settings.gentleWake == nil)
}

private func versioned(_ a: Double, _ b: Double, _ os: String) -> SleepSample {
    SleepSample(start: origin.addingTimeInterval(a), end: origin.addingTimeInterval(b), stage: .core, osVersion: os)
}

@Test func watchStopIsFlaggedOnlyWhenSleepAndHeartRateEndTogetherWhileTheNightIsOpen() {
    // Sleep 00:30–04:12; heart rate also ends at 04:10.
    let night = NightBuilder.build(samples: [sample(1800, 4 * 3600 + 720)], calendar: utc)[0]
    let stopped = [origin.addingTimeInterval(4 * 3600 + 600)]
    let tonight = DateInterval(start: origin.addingTimeInterval(1200), end: origin.addingTimeInterval(7 * 3600))
    let stop = NightCorrections.watchStop(night: night, heartRateTimes: stopped, session: tonight, usualWakeMinutes: nil, calendar: utc)
    #expect(stop == WatchStop(at: origin.addingTimeInterval(4 * 3600 + 720), excludesFromAverages: true))
    // Heart rate carried on after the last sleep (a real wake-up): not flagged.
    #expect(NightCorrections.watchStop(night: night, heartRateTimes: stopped + [origin.addingTimeInterval(5 * 3600)], session: tonight, usualWakeMinutes: nil, calendar: utc) == nil)
    // Ended Tonight soon after: not open long enough.
    #expect(NightCorrections.watchStop(night: night, heartRateTimes: stopped, session: DateInterval(start: tonight.start, end: origin.addingTimeInterval(4 * 3600 + 1800)), usualWakeMinutes: nil, calendar: utc) == nil)
    // No Tonight session: a note only, and only when the stop is well before the usual wake-up.
    #expect(NightCorrections.watchStop(night: night, heartRateTimes: stopped, session: nil, usualWakeMinutes: 7 * 60, calendar: utc)?.excludesFromAverages == false)
    #expect(NightCorrections.watchStop(night: night, heartRateTimes: stopped, session: nil, usualWakeMinutes: nil, calendar: utc) == nil)
}

@Test func versionChangeBreaksTrendsAndInBedEstimatesUseTonight() {
    let nights = NightBuilder.build(samples: [versioned(3600, 7200, "26.6.0"), versioned(86400 + 3600, 86400 + 7200, "27.0.1")], calendar: utc)
    #expect(NightCorrections.versionBreaks(nights) == [nights[1].windowStart])
    let night = NightBuilder.build(samples: [sample(1800, 7200)], calendar: utc)[0]
    let bed = InBedEstimate(night: night, session: DateInterval(start: origin, end: origin.addingTimeInterval(9000)))
    #expect(bed?.timeInBed == 9000); #expect(bed?.toFallAsleep == 1800); #expect(bed?.efficiency == 5400.0 / 9000)
}

@Test func correctedSummaryNamesEveryDifferenceFromApple() {
    let nights = NightBuilder.build(samples: [sample(0, 3600), sample(1800, 5400), sample(86400, 86400 + 3600)], calendar: utc)
    let summary = CorrectedSummary(nights: nights, leftOut: [nights[1].id])!
    #expect(summary.nights == 1); #expect(summary.leftOut == [nights[1].id]); #expect(summary.merged == [nights[0].id])
    #expect(summary.averageAsleep == 5400); #expect(summary.appleRawAverage == (7200 + 3600) / 2)
}
