import Foundation
import Testing
@testable import SleepiCore

// Ports cases A, D and E of analysis/tag-tests/sim.py with a fixed seed: one person's nights with AR(1) noise
// (phi 0.3), a weekend shift, and six tags, of which tag 0 may carry a real effect.
private struct Simulation {
    var generator = SplitMix64(seed: 20261002)
    mutating func normal() -> Double {
        let u1 = max(Double.ulpOfOne, Double(generator.next() >> 11) / Double(1 << 53)), u2 = Double(generator.next() >> 11) / Double(1 << 53)
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
    mutating func uniform() -> Double { Double(generator.next() >> 11) / Double(1 << 53) }

    /// Returns how often tag 0 and any other tag were shown as linked on total sleep.
    mutating func run(weeks: Int, sd: Double, effect: Double, rate: Double, weekendShift: Double = 30 * 60,
                      weekendTag: Bool = false, otherRate: Double? = nil, sims: Int) -> (real: Double, falseAny: Double) {
        let n = weeks * 7, tags = (0..<6).map { _ in UUID() }
        var real = 0, falseAny = 0
        for _ in 0..<sims {
            var noise = [Double](repeating: 0, count: n)
            noise[0] = normal() * sd
            for i in 1..<n { noise[i] = 0.3 * noise[i - 1] + normal() * sd * (1 - 0.09).squareRoot() }
            let weekend = (0..<n).map { $0 % 7 >= 5 }
            let tagged: [[Bool]] = (0..<6).map { k in (0..<n).map { i in weekendTag && k == 0 ? weekend[i] && uniform() < 0.8 : uniform() < (k == 0 ? rate : otherRate ?? rate) } }
            let nights = (0..<n).map { i in
                TagNight(weekend: weekend[i], tags: Set(tags.indices.filter { tagged[$0][i] }.map { tags[$0] }),
                         measures: [.totalSleep: 7 * 3600 + noise[i] + (weekend[i] ? weekendShift : 0) + (tagged[0][i] ? effect : 0)])
            }
            let status = TagLinks.evaluate(nights: nights, tags: tags, permutations: 400, generator: &generator)
            if case .linked = status[tags[0]] { real += 1 }
            if tags.dropFirst().contains(where: { if case .linked = status[$0] { true } else { false } }) { falseAny += 1 }
        }
        return (Double(real) / Double(sims), Double(falseAny) / Double(sims))
    }
}

@Test func caseANoEffectTagsStayQuietWhileARealEffectEmerges() {
    var sim = Simulation()
    let result = sim.run(weeks: 16, sd: 70 * 60, effect: -45 * 60, rate: 2.0 / 7, sims: 120)
    #expect(result.falseAny <= 0.10)
    #expect(result.real >= 0.35) // sim.py: 65% at 16 weeks
}

@Test func caseDWeekendLoggedTagIsNotLinkedOnceWeekdaysAndWeekendsAreMatched() {
    var sim = Simulation()
    // The other five tags are logged like everyday tags (2 nights a week), so the test family matches real use.
    let result = sim.run(weeks: 12, sd: 70 * 60, effect: 0, rate: 0, weekendTag: true, otherRate: 2.0 / 7, sims: 150)
    #expect(result.real <= 0.05)
}

@Test func caseEAllNoEffectTagsRarelyShowAnyLink() {
    var sim = Simulation()
    let result = sim.run(weeks: 12, sd: 70 * 60, effect: 0, rate: 2.0 / 7, sims: 150)
    #expect(max(result.real, result.falseAny) <= 0.10)
}

@Test func tagStatusWordingStatesAndCsvExport() {
    var generator = SplitMix64(seed: 1)
    let tag = UUID()
    let few = (0..<5).map { TagNight(weekend: false, tags: $0 < 3 ? [tag] : [], measures: [.totalSleep: 25000]) }
    #expect(TagLinks.evaluate(nights: few, tags: [tag], generator: &generator)[tag] == .notEnough(have: 2))
    #expect(TagMeasure.sleepingHeartRate.phrase(3) == "your sleeping heart rate was 3.0 bpm higher")
    var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(secondsFromGMT: 0)!
    let csv = NightExportRow.csv([NightExportRow(date: Date(timeIntervalSince1970: 1_780_358_400), appleTotalSleep: 25200, toFallAsleep: 600, wakeUps: 2,
                                                 sleepingHeartRate: 54.25, rating: 4, tags: ["Alcohol", "Late meal, big"], sounds: [.snoring: 3],
                                                 gentleWakeUsed: true, wakeDecision: Date(timeIntervalSince1970: 1_780_358_400 + 6.5 * 3600))], calendar: utc)
    #expect(csv.components(separatedBy: "\n")[1] == "2026-06-02,watch,420,10,2,54.2,4,\"Alcohol; Late meal, big\",3,0,0,0,yes,06:30,,,,")
}
