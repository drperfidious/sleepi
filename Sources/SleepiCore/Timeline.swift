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
            var conflicts = 0.0
            for (start, end) in zip(boundaries, boundaries.dropFirst()) where end > start {
                let active = relevant.filter { $0.start < end && $0.end > start }
                guard !active.isEmpty else { continue } // Missing is unknown, never awake or asleep.
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
            return SleepNight(windowStart: w.start, windowEnd: w.end, segments: segments,
                              sourceCount: Set(relevant.map { $0.source + $0.product }).count, conflictingSeconds: conflicts)
        }.sorted { $0.windowStart < $1.windowStart }
    }
}

public struct WakeEvidence: Sendable {
    public var start: Date
    public var stage: SleepStage?
    public var movement: Double?
    public var heartRateRise: Double?
    public var speechOrRustling: Bool
    public init(start: Date, stage: SleepStage?, movement: Double?, heartRateRise: Double? = nil, speechOrRustling: Bool = false) {
        self.start = start; self.stage = stage; self.movement = movement
        self.heartRateRise = heartRateRise; self.speechOrRustling = speechOrRustling
    }
}

public struct WakeCandidate: Identifiable, Codable, Sendable {
    public var start: Date
    public var end: Date
    public var reason: String
    public var id: Date { start }
}

public enum WakeExperiment {
    /// Unvalidated proposal generator. Never subtracts from Apple's total or writes stages.
    /// Requires contiguous 30s movement epochs plus another signal. Missing is not zero.
    public static func candidates(_ epochs: [WakeEvidence], movementThreshold: Double = 0.12) -> [WakeCandidate] {
        var output: [WakeCandidate] = []
        var run: [WakeEvidence] = []
        func flush() {
            if run.count >= 2, let first = run.first, let last = run.last {
                output.append(WakeCandidate(start: first.start, end: last.start.addingTimeInterval(30), reason: "Movement with a second signal · unvalidated"))
            }
            run.removeAll()
        }
        for epoch in epochs.sorted(by: { $0.start < $1.start }) {
            let eligible = epoch.stage?.isAsleep == true && (epoch.movement ?? -.infinity) >= movementThreshold
                && ((epoch.heartRateRise ?? -.infinity) >= 8 || epoch.speechOrRustling)
            if let last = run.last, abs(epoch.start.timeIntervalSince(last.start) - 30) > 0.01 { flush() }
            if eligible { run.append(epoch) } else { flush() }
        }
        flush()
        return output
    }
}
