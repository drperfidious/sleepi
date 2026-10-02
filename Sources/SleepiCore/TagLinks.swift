import Foundation

/// What each tag is compared on (refs/11-feature-review.md §1).
public enum TagMeasure: String, CaseIterable, Codable, Sendable {
    case totalSleep, toFallAsleep, wakeUps, sleepingHeartRate, rating

    /// The smallest difference worth showing, in the measure's own units (seconds, count, bpm, points).
    public var minimumSize: Double {
        switch self {
        case .totalSleep: 20 * 60
        case .toFallAsleep: 5 * 60
        case .wakeUps: 1
        case .sleepingHeartRate: 1.5
        case .rating: 0.5
        }
    }

    /// "your sleeping heart rate was 3 bpm higher"
    public func phrase(_ difference: Double) -> String {
        let more = difference > 0
        switch self {
        case .totalSleep: return "you slept \(DurationText.hoursMinutes(abs(difference))) \(more ? "more" : "less")"
        case .toFallAsleep: return "you took \(Int((abs(difference) / 60).rounded())) min \(more ? "longer" : "less") to fall asleep"
        case .wakeUps: return "you woke \(String(format: "%.1f", abs(difference))) times \(more ? "more" : "less") in the night"
        case .sleepingHeartRate: return "your sleeping heart rate was \(String(format: "%.1f", abs(difference))) bpm \(more ? "higher" : "lower")"
        case .rating: return "you rated your sleep \(String(format: "%.1f", abs(difference))) points \(more ? "better" : "worse")"
        }
    }
}

/// One reviewed night: the tags saved that morning and whatever measures exist for it. Missing measures stay missing.
public struct TagNight: Sendable {
    public var weekend: Bool
    public var tags: Set<UUID>
    public var measures: [TagMeasure: Double]
    public init(weekend: Bool, tags: Set<UUID>, measures: [TagMeasure: Double]) {
        self.weekend = weekend; self.tags = tags; self.measures = measures
    }
}

public struct TagLink: Sendable, Equatable {
    public var measure: TagMeasure
    public var difference: Double
    public var taggedNights: Int
    public var untaggedNights: Int
}

public enum TagStatus: Sendable, Equatable {
    case notEnough(have: Int)
    case noClearLink(nights: Int)
    case linked([TagLink])
}

/// The "linked" rule. A link is shown only when all of this holds:
/// 1. at least 8 tagged and 8 untagged nights have the measure;
/// 2. the difference is tagged mean minus untagged mean;
/// 3. its p-value comes from shuffling the tag only among weekdays and only among weekends, so a tag logged mostly
///    on weekends can't borrow the weekend's longer sleep;
/// 4. Benjamini–Hochberg at 5% across every tag × measure pair;
/// 5. the difference is at least the measure's minimum size.
/// In simulation (analysis/tag-tests/sim.py) this rarely invents a link but needs two to four months of nights.
public enum TagLinks {
    public static let minimumNights = 8
    private struct Pair { var tag: UUID; var measure: TagMeasure; var p: Double; var link: TagLink? = nil }

    public static func evaluate<G: RandomNumberGenerator>(nights: [TagNight], tags: [UUID], permutations: Int = 2000,
                                                          generator: inout G) -> [UUID: TagStatus] {
        var pairs: [Pair] = []
        for tag in tags {
            for measure in TagMeasure.allCases {
                let rows = nights.compactMap { n in n.measures[measure].map { (value: $0, tagged: n.tags.contains(tag), weekend: n.weekend) } }
                let tagged = rows.filter(\.tagged).count, untagged = rows.count - tagged
                guard tagged >= minimumNights, untagged >= minimumNights else { pairs.append(Pair(tag: tag, measure: measure, p: 1)); continue }
                let values = rows.map(\.value), flags = rows.map(\.tagged), weekend = rows.map(\.weekend)
                let observed = difference(values, flags)
                let p = permutationP(values, flags, weekend, observed: observed, permutations: permutations, generator: &generator)
                pairs.append(Pair(tag: tag, measure: measure, p: p, link: TagLink(measure: measure, difference: observed, taggedNights: tagged, untaggedNights: untagged)))
            }
        }
        // The Benjamini–Hochberg family is every tag × measure pair that was tested (8+ nights both ways). Counting
        // untested pairs as p = 1 would make the bar depend on which measures happen to have data, not on the data.
        let tested = pairs.indices.filter { pairs[$0].link != nil }
        let testedPassed = benjaminiHochberg(tested.map { pairs[$0].p })
        var passed = [Bool](repeating: false, count: pairs.count)
        for (k, i) in tested.enumerated() { passed[i] = testedPassed[k] }
        var result: [UUID: TagStatus] = [:]
        for tag in tags {
            let tagged = nights.filter { $0.tags.contains(tag) }.count
            let untagged = nights.count - tagged
            let links = pairs.indices.filter { pairs[$0].tag == tag && passed[$0] }.compactMap { i -> TagLink? in
                guard let link = pairs[i].link, abs(link.difference) >= link.measure.minimumSize else { return nil }
                return link
            }
            if !links.isEmpty { result[tag] = .linked(links) }
            else if tagged < minimumNights || untagged < minimumNights { result[tag] = .notEnough(have: min(tagged, untagged)) }
            else { result[tag] = .noClearLink(nights: tagged) }
        }
        return result
    }

    static func difference(_ values: [Double], _ flags: [Bool]) -> Double {
        var sumT = 0.0, nT = 0, sumU = 0.0, nU = 0
        for (v, f) in zip(values, flags) { if f { sumT += v; nT += 1 } else { sumU += v; nU += 1 } }
        guard nT > 0, nU > 0 else { return 0 }
        return sumT / Double(nT) - sumU / Double(nU)
    }

    static func permutationP<G: RandomNumberGenerator>(_ values: [Double], _ flags: [Bool], _ weekend: [Bool], observed: Double,
                                                       permutations: Int, generator: inout G) -> Double {
        let groups = [weekend.indices.filter { weekend[$0] }, weekend.indices.filter { !weekend[$0] }]
        var shuffled = flags, count = 0
        for _ in 0..<permutations {
            for group in groups {
                var labels = group.map { flags[$0] }
                labels.shuffle(using: &generator)
                for (i, index) in group.enumerated() { shuffled[index] = labels[i] }
            }
            if abs(difference(values, shuffled)) >= abs(observed) { count += 1 }
        }
        return Double(count + 1) / Double(permutations + 1)
    }

    static func benjaminiHochberg(_ p: [Double], q: Double = 0.05) -> [Bool] {
        let order = p.indices.sorted { p[$0] < p[$1] }
        let m = Double(p.count)
        var cutoff = -1
        for (rank, index) in order.enumerated() where p[index] <= q * Double(rank + 1) / m { cutoff = rank }
        var passed = [Bool](repeating: false, count: p.count)
        if cutoff >= 0 { for rank in 0...cutoff { passed[order[rank]] = true } }
        return passed
    }
}

/// A small fast generator so results are the same each time the same nights are analysed (and in tests).
public struct SplitMix64: RandomNumberGenerator, Sendable {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

/// One CSV row per night of sleepi's own data, for export through the share sheet. No audio, nothing uploaded.
public struct NightExportRow: Sendable {
    public var date: Date
    public var appleTotalSleep: Double
    public var toFallAsleep: Double?
    public var wakeUps: Int
    public var sleepingHeartRate: Double?
    public var rating: Int?
    public var tags: [String]
    public var sounds: [SoundKind: Int]
    public var gentleWakeUsed: Bool
    public var wakeDecision: Date?
    /// "watch" (Apple's sleep) or "phone" (sleepi's estimate from the iPhone alone).
    public var source: String
    public var inBedStart: Date?
    public var inBedEnd: Date?
    public var fellAsleep: Date?
    public var wokeForGood: Date?
    public init(date: Date, appleTotalSleep: Double, toFallAsleep: Double?, wakeUps: Int, sleepingHeartRate: Double?, rating: Int?,
                tags: [String], sounds: [SoundKind: Int], gentleWakeUsed: Bool, wakeDecision: Date?, source: String = "watch",
                inBedStart: Date? = nil, inBedEnd: Date? = nil, fellAsleep: Date? = nil, wokeForGood: Date? = nil) {
        self.date = date; self.appleTotalSleep = appleTotalSleep; self.toFallAsleep = toFallAsleep; self.wakeUps = wakeUps
        self.sleepingHeartRate = sleepingHeartRate; self.rating = rating; self.tags = tags; self.sounds = sounds
        self.gentleWakeUsed = gentleWakeUsed; self.wakeDecision = wakeDecision; self.source = source
        self.inBedStart = inBedStart; self.inBedEnd = inBedEnd; self.fellAsleep = fellAsleep; self.wokeForGood = wokeForGood
    }

    public static func csv(_ rows: [NightExportRow], calendar: Calendar = .current) -> String {
        let day = DateFormatter(); day.calendar = calendar; day.timeZone = calendar.timeZone; day.dateFormat = "yyyy-MM-dd"
        let time = DateFormatter(); time.calendar = calendar; time.timeZone = calendar.timeZone; time.dateFormat = "HH:mm"
        func cell(_ s: String) -> String { s.contains(where: { ",\"\n".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        var lines = ["date,source,total_sleep_min,bed_to_first_sleep_min,wake_ups,sleeping_heart_rate_bpm,rating_1_to_5,tags,snoring_events,speech_events,cough_events,room_sound_events,gentle_wake_used,wake_decision_time,in_bed_start,in_bed_end,fell_asleep_estimate,woke_for_good_estimate"]
        for r in rows.sorted(by: { $0.date < $1.date }) {
            var cells: [String] = [day.string(from: r.date), r.source, String(Int((r.appleTotalSleep / 60).rounded()))]
            cells.append(r.toFallAsleep.map { String(Int(($0 / 60).rounded())) } ?? "")
            cells.append(String(r.wakeUps))
            cells.append(r.sleepingHeartRate.map { String(format: "%.1f", $0) } ?? "")
            cells.append(r.rating.map { String($0) } ?? "")
            cells.append(cell(r.tags.joined(separator: "; ")))
            for kind in [SoundKind.snoring, .speech, .coughing, .environment] { cells.append(String(r.sounds[kind] ?? 0)) }
            cells.append(r.gentleWakeUsed ? "yes" : "no")
            cells.append(r.wakeDecision.map { time.string(from: $0) } ?? "")
            for d in [r.inBedStart, r.inBedEnd, r.fellAsleep, r.wokeForGood] { cells.append(d.map { time.string(from: $0) } ?? "") }
            lines.append(cells.joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }
}
