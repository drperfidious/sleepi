import Foundation

public struct ScheduleConsistency: Sendable {
    public var bedtimeSpreadMinutes: Double
    public var wakeSpreadMinutes: Double
    public var nights: Int
}

public struct Shortfall: Sendable {
    public var seconds: Double
    public var recordedNights: Int
    public var expectedNights: Int
}

public struct TagComparison: Sendable {
    public var withTagSeconds: Double
    public var withoutTagSeconds: Double
    public var withTagCount: Int
    public var withoutTagCount: Int
}

public enum Insights {
    public static func clockMinutes(_ date: Date, calendar: Calendar) -> Double {
        Double(calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date))
    }
    public static func circularDifference(_ a: Double, _ b: Double) -> Double {
        let d = (a - b).truncatingRemainder(dividingBy: 1440)
        return d > 720 ? d - 1440 : d < -720 ? d + 1440 : d
    }
    public static func circularMean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let x = values.reduce(0) { $0 + cos($1 * .pi / 720) }
        let y = values.reduce(0) { $0 + sin($1 * .pi / 720) }
        guard hypot(x, y) / Double(values.count) > 0.1 else { return nil }
        let angle = atan2(y, x) * 720 / .pi
        return angle < 0 ? angle + 1440 : angle
    }
    public static func consistency(nights: [SleepNight], calendar: Calendar = .current) -> ScheduleConsistency? {
        let valid = nights.suffix(14).filter { $0.firstSleep != nil && $0.lastSleep != nil }
        guard valid.count >= 7 else { return nil }
        let bed = valid.compactMap(\.firstSleep).map { clockMinutes($0, calendar: calendar) }
        let wake = valid.compactMap(\.lastSleep).map { clockMinutes($0, calendar: calendar) }
        guard let b = circularMean(bed), let w = circularMean(wake) else { return nil }
        func spread(_ values: [Double], around mean: Double) -> Double {
            sqrt(values.reduce(0) { $0 + pow(circularDifference($1, mean), 2) } / Double(values.count))
        }
        return ScheduleConsistency(bedtimeSpreadMinutes: spread(bed, around: b), wakeSpreadMinutes: spread(wake, around: w), nights: valid.count)
    }
    public static func shortfall(nights: [SleepNight], targetHours: Double, now: Date, days: Int = 14, calendar: Calendar = .current) -> Shortfall {
        guard targetHours.isFinite, targetHours > 0, days > 0 else { return Shortfall(seconds: 0, recordedNights: 0, expectedNights: max(0, days)) }
        let today = calendar.startOfDay(for: now)
        let oldest = calendar.date(byAdding: .day, value: 1 - days, to: today)!
        let recent = nights.filter { night in
            guard let wake = night.lastSleep else { return false }
            return wake >= oldest && wake <= now
        }
        return Shortfall(seconds: recent.reduce(0) { $0 + max(0, targetHours * 3600 - $1.asleepSeconds) }, recordedNights: recent.count, expectedNights: days)
    }
    public static func comparison(tagID: UUID, nights: [SleepNight], journals: [NightJournal]) -> TagComparison? {
        let journalMap = Dictionary(journals.map { ($0.nightID, $0) }, uniquingKeysWith: { _, newest in newest })
        // Unchecked nights aren't a control group. An explicitly saved journal is required.
        let reviewed = nights.filter { journalMap[$0.id] != nil }
        let with = reviewed.filter { journalMap[$0.id]!.tagIDs.contains(tagID) }
        let without = reviewed.filter { !journalMap[$0.id]!.tagIDs.contains(tagID) }
        guard with.count >= 10, without.count >= 10 else { return nil }
        return TagComparison(withTagSeconds: with.reduce(0) { $0 + $1.asleepSeconds } / Double(with.count),
                             withoutTagSeconds: without.reduce(0) { $0 + $1.asleepSeconds } / Double(without.count),
                             withTagCount: with.count, withoutTagCount: without.count)
    }
    public static func socialJetlag(nights: [SleepNight], journals: [NightJournal], calendar: Calendar = .current) -> Double? {
        let map = Dictionary(journals.map { ($0.nightID, $0) }, uniquingKeysWith: { _, new in new })
        var free: [Double] = [], work: [Double] = []
        for night in nights {
            guard let a = night.firstSleep, let b = night.lastSleep, let isFree = map[night.id]?.isFreeDay else { continue }
            let midpoint = clockMinutes(a.addingTimeInterval(b.timeIntervalSince(a) / 2), calendar: calendar)
            if isFree { free.append(midpoint) } else { work.append(midpoint) }
        }
        guard free.count >= 3, work.count >= 3, let f = circularMean(free), let w = circularMean(work) else { return nil }
        return abs(circularDifference(f, w))
    }
    public static func median(_ values: [Double]) -> Double? {
        let sorted = values.filter(\.isFinite).sorted()
        guard !sorted.isEmpty else { return nil }
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

public enum GentleWakePolicy {
    public static func start(latest: Date, now: Date, windowMinutes: Int = 25) -> Date? {
        guard (1...29).contains(windowMinutes), latest > now.addingTimeInterval(60) else { return nil }
        // A 25-minute window leaves scheduling / expiration margin inside Apple's 30m cap.
        let start = max(now.addingTimeInterval(5), latest.addingTimeInterval(-Double(windowMinutes) * 60))
        guard start.timeIntervalSince(now) <= 36 * 3600 else { return nil }
        return start
    }
}
