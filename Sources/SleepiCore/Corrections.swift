import Foundation

/// Record-keeping corrections that passed the evidence audit (refs/08-sleep-corrections-evidence.md, section 5).
/// None of them re-stages Apple's sleep: each is a checkable fact about how a night was recorded.
public struct WatchStop: Equatable, Sendable {
    /// When the Watch's sleep and heart-rate records both ended.
    public var at: Date
    /// True on a night started from Tonight, where the night was still open: the night is left out of averages.
    /// False means a note only, because a real early wake looks the same.
    public var excludesFromAverages: Bool
}

public enum NightCorrections {
    /// A night whose Apple Watch sleep and heart-rate records stop together (within 10 minutes) and then nothing more
    /// arrives for at least 45 minutes while the night is still open: the Watch probably stopped recording.
    /// With a Tonight session the "still open" part is known. Without one it can't be, so this is only reported when
    /// the stop is at least 45 minutes before the usual wake-up for that weekday.
    public static func watchStop(night: SleepNight, heartRateTimes: [Date], session: DateInterval?, usualWakeMinutes: Int?,
                                 calendar: Calendar = .current) -> WatchStop? {
        guard let lastSleep = night.lastSleep,
              let lastHeart = heartRateTimes.filter({ $0 >= night.windowStart && $0 < night.windowEnd }).max(),
              abs(lastHeart.timeIntervalSince(lastSleep)) <= 10 * 60 else { return nil }
        let stop = max(lastSleep, lastHeart)
        if let session {
            guard session.start < stop, session.end.timeIntervalSince(stop) >= 45 * 60 else { return nil }
            return WatchStop(at: stop, excludesFromAverages: true)
        }
        guard let usualWakeMinutes,
              let usual = calendar.date(bySettingHour: usualWakeMinutes / 60, minute: usualWakeMinutes % 60, second: 0, of: stop),
              usual.timeIntervalSince(stop) >= 45 * 60 else { return nil }
        return WatchStop(at: stop, excludesFromAverages: false)
    }

    /// Nights where Apple's staging algorithm may have changed: the first night on a new major watchOS version.
    public static func versionBreaks(_ nights: [SleepNight]) -> [Date] {
        var breaks: [Date] = [], previous: Int?
        for night in nights.sorted(by: { $0.windowStart < $1.windowStart }) {
            guard let major = night.osMajor else { continue }
            if let previous, previous != major { breaks.append(night.windowStart) }
            previous = major
        }
        return breaks
    }
}

/// Estimates from a Tonight session's start and end. Apple stopped writing in-bed time with watchOS 11 / iOS 18.
public struct InBedEstimate: Equatable, Sendable {
    public var timeInBed: TimeInterval
    public var toFallAsleep: TimeInterval
    /// Apple's sleep ÷ time in bed. Apple counts some still-awake time as sleep, so this leans high.
    public var efficiency: Double

    public init?(night: SleepNight, session: DateInterval) {
        guard let first = night.firstSleep, session.start <= first, session.duration > 0 else { return nil }
        timeInBed = session.duration
        toFallAsleep = first.timeIntervalSince(session.start)
        let asleepInBed = night.segments.filter(\.stage.isAsleep).reduce(0.0) { total, s in
            total + max(0, min(s.end, session.end).timeIntervalSince(max(s.start, session.start)))
        }
        efficiency = min(1, asleepInBed / session.duration)
    }
}

/// sleepi's corrected history next to Apple's raw record. Every difference traces to a named night.
public struct CorrectedSummary: Sendable {
    public var averageAsleep: Double
    public var appleRawAverage: Double
    public var nights: Int
    public var leftOut: [Date]
    public var merged: [Date]

    public init?(nights all: [SleepNight], leftOut: Set<Date>) {
        guard !all.isEmpty else { return nil }
        let kept = all.filter { !leftOut.contains($0.id) }
        guard !kept.isEmpty else { return nil }
        averageAsleep = kept.reduce(0) { $0 + $1.asleepSeconds } / Double(kept.count)
        appleRawAverage = all.reduce(0) { $0 + $1.rawAsleepSeconds } / Double(all.count)
        nights = kept.count
        self.leftOut = all.map(\.id).filter(leftOut.contains)
        merged = kept.filter { $0.overlapSeconds > 0 }.map(\.id)
    }
}
