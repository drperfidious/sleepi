import Foundation

public enum NightBuilder {
    /// Noon-to-noon is a display grouping, not an assertion that daytime is awake.
    public static func window(containing date: Date, calendar: Calendar) -> DateInterval {
        let day = calendar.startOfDay(for: date)
        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day)!
        let start = date < noon ? calendar.date(byAdding: .day, value: -1, to: noon)! : noon
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start)!)
    }

    public static func build(samples: [SleepSample], calendar: Calendar = .current) -> [SleepNight] {
        let accepted = samples.filter { $0.isAppleWatch && $0.end > $0.start && $0.end.timeIntervalSince($0.start) <= 48 * 3600 && $0.stage != .inBed }
        var windows: [Date: DateInterval] = [:]
        for sample in accepted {
            var cursor = sample.start
            while cursor < sample.end {
                let w = window(containing: cursor, calendar: calendar)
                windows[w.start] = w
                cursor = w.end
            }
        }
        return windows.values.compactMap { w in
            let relevant = accepted.filter { $0.start < w.end && $0.end > w.start }
            let boundaries = Set(relevant.flatMap { [max($0.start, w.start), min($0.end, w.end)] }).sorted()
            var segments: [StageSegment] = []
            var conflicts = 0.0, overlap = 0.0
            // Reconciliation rule (deterministic): each instant is counted once. Records that agree merge; records
            // that disagree between asleep stages become "Asleep" without a stage; asleep vs awake stays unknown.
            // There's no public save time for "latest record wins", so no record is preferred over another.
            for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
                let active = relevant.filter { $0.start < end && $0.end > start }
                guard !active.isEmpty else { continue } // Missing is unknown, never awake or asleep.
                if active.count > 1 { overlap += end.timeIntervalSince(start) }
                let stages = Set(active.map(\.stage))
                let selected: SleepStage
                if stages.count == 1 { selected = active[0].stage }
                else {
                    conflicts += end.timeIntervalSince(start)
                    // Preserve sleep/wake conflicts as unknown gaps. No invented source priority.
                    if stages.contains(.awake) { continue }
                    selected = .unspecified
                }
                if let last = segments.last, last.end == start, last.stage == selected {
                    segments[segments.count - 1].end = end
                } else { segments.append(StageSegment(start: start, end: end, stage: selected)) }
            }
            guard segments.contains(where: { $0.stage.isAsleep }) else { return nil }
            let raw = relevant.filter(\.stage.isAsleep).reduce(0.0) { $0 + min($1.end, w.end).timeIntervalSince(max($1.start, w.start)) }
            let majors = relevant.compactMap { $0.osVersion?.split(separator: ".").first.flatMap { Int($0) } }
            let major = Dictionary(grouping: majors, by: { $0 }).max { ($0.value.count, $0.key) < ($1.value.count, $1.key) }?.key
            return SleepNight(windowStart: w.start, windowEnd: w.end, segments: segments,
                              sourceCount: Set(relevant.map { $0.source + $0.product }).count, conflictingSeconds: conflicts,
                              overlapSeconds: overlap, rawAsleepSeconds: raw, osMajor: major)
        }.sorted { $0.windowStart < $1.windowStart }
    }
}
