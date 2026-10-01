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
    let night = NightBuilder.build(samples: [sample(0, 3600), sample(1800, 5400)], calendar: utc)[0]
    #expect(night.asleepSeconds == 5400)
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
@Test func wakeExperimentNeedsContiguousIndependentEvidence() {
    func epoch(_ offset: Double, movement: Double? = 0.2, hr: Double? = 12) -> WakeEvidence {
        WakeEvidence(start: origin.addingTimeInterval(offset), stage: .core, movement: movement, heartRateRise: hr)
    }
    #expect(WakeExperiment.candidates([epoch(0), epoch(30)]).count == 1)
    #expect(WakeExperiment.candidates([epoch(0), epoch(60)]).isEmpty)
    #expect(WakeExperiment.candidates([epoch(0, movement: nil), epoch(30)]).isEmpty)
    #expect(WakeExperiment.candidates([epoch(0, hr: nil), epoch(30, hr: nil)]).isEmpty)
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
    #expect(GentleWakePolicy.start(latest: origin.addingTimeInterval(3600), now: origin, windowMinutes: 30) == nil)
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
