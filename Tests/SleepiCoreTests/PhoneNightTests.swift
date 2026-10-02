import Foundation
import Testing
@testable import SleepiCore

private let bed = Date(timeIntervalSince1970: 1_780_354_800) // 23:00 UTC
private func night(hours: Double = 8, placement: PhonePlacement = .bedStand, epochs build: (Int) -> PhoneEpoch?) -> PhoneNight {
    var n = PhoneNight(start: bed, placement: placement)
    n.end = bed.addingTimeInterval(hours * 3600)
    for i in 0..<Int(hours * 120) { if let e = build(i) { n.merge(e) } }
    return n
}
private func quietEpoch(_ i: Int) -> PhoneEpoch { PhoneEpoch(start: bed.addingTimeInterval(Double(i) * 30), motion: 0.05, levelDB: -60, floorDB: -61) }

@Test func quietNightIsAsleepFromSoonAfterBedToTheEnd() {
    var n = night(epochs: quietEpoch); n.recalculate()
    let e = try! #require(n.estimate)
    #expect(e.fellAsleep == bed); #expect(e.wokeForGood == bed.addingTimeInterval(8 * 3600))
    #expect(e.wakeUps.isEmpty); #expect(e.timeAsleep == Double(8 * 3600)); #expect(e.coverage == 1)
}

@Test func phoneUseIsACertainWakeUpAndDelaysFallingAsleep() {
    var n = night(epochs: quietEpoch)
    n.events = [PhoneEvent(.unlocked, at: bed.addingTimeInterval(60)), PhoneEvent(.locked, at: bed.addingTimeInterval(20 * 60)),
                PhoneEvent(.unlocked, at: bed.addingTimeInterval(3 * 3600)), PhoneEvent(.locked, at: bed.addingTimeInterval(3 * 3600 + 360))]
    n.recalculate()
    let e = try! #require(n.estimate)
    #expect(e.fellAsleep! >= bed.addingTimeInterval(20 * 60))
    #expect(e.wakeUps.contains { $0.kind == .phoneUse && $0.start <= bed.addingTimeInterval(3 * 3600) && $0.end >= bed.addingTimeInterval(3 * 3600 + 360) })
}

@Test func restlessPatchOnTheMattressIsAMaybeAwake() {
    var n = night(placement: .mattress) { i in
        var e = quietEpoch(i); if (240..<246).contains(i) { e.motion = 4 } // 01:00–01:03 tossing
        return e
    }
    n.recalculate()
    #expect(n.estimate!.wakeUps.contains { $0.kind == .restless && $0.start <= bed.addingTimeInterval(7200) && $0.end > bed.addingTimeInterval(7200) })
}

@Test func steadyFanSetsTheFloorInsteadOfCreatingSoundEvents() {
    // A fan at about −30 dBFS with 4 dB swings (peak to peak): the floor rises to it and no epoch is flagged.
    var tracker = SoundActivityTracker()
    var events = 0, epochs = 0
    for s in 0..<(2 * 3600) {
        let level = -30 + 2 * sin(Double(s) / 7)
        if let e = tracker.add(secondLevel: level, at: bed.addingTimeInterval(Double(s))) { epochs += 1; if e.soundEvent { events += 1 } }
    }
    #expect(epochs == 240); #expect(events == 0)
    // A cough 10 dB above the fan is an event.
    for s in 0..<29 { _ = tracker.add(secondLevel: -30, at: bed.addingTimeInterval(Double(7200 + s))) }
    #expect(tracker.add(secondLevel: -18, at: bed.addingTimeInterval(7229))?.soundEvent == true)
}

@Test func gapsWithNoMicAndNoMotionAreNoDataNotSleep() {
    var n = night { i in (300..<420).contains(i) ? nil : quietEpoch(i) } // one hour with nothing
    n.recalculate()
    let e = n.estimate!
    #expect(e.noDataSeconds == 3600); #expect(e.timeAsleep == Double(7 * 3600)); #expect(e.coverage == 0.875)
}

@Test func noQuietRunMeansNoEstimateRatherThanAGuess() {
    var n = night(hours: 1) { i in var e = quietEpoch(i); e.soundEvent = true; return e }
    n.recalculate()
    #expect(n.estimate?.fellAsleep == nil); #expect(n.estimate?.timeAsleep == nil)
}

@Test func motionCountsAndSlotsMerge() {
    var acc = MotionEpochAccumulator()
    var out: (start: Date, motion: Double, jerk: Double)?
    for k in 0...300 { if let r = acc.add(magnitude: k % 2 == 0 ? 1.0 : 1.2, at: bed.addingTimeInterval(Double(k) * 0.1)) { out = r } }
    #expect(out != nil); #expect(abs(out!.motion - 30) < 0.5)
    var n = PhoneNight(start: bed, placement: .bedStand)
    n.merge(PhoneEpoch(start: bed.addingTimeInterval(31), motion: 1)); n.merge(PhoneEpoch(start: bed.addingTimeInterval(45), levelDB: -50))
    #expect(n.epochs.count == 1); #expect(n.epochs[0].motion == 1); #expect(n.epochs[0].levelDB == -50)
}
