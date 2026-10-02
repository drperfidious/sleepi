import Foundation

/// Things the phone notices that mean someone is using it, or that recording stopped.
public struct PhoneEvent: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case unlocked, locked, pluggedIn, unplugged, appOpened, appClosed, phoneMoved, listeningStopped, listeningResumed
    }
    public var kind: Kind
    public var at: Date
    public init(_ kind: Kind, at: Date) { self.kind = kind; self.at = at }
}

/// One 30-second epoch. Nil means no data for that signal; an epoch with neither is "no data", never asleep.
public struct PhoneEpoch: Codable, Equatable, Sendable {
    public var start: Date
    /// Sum over the epoch of |‖a‖ − epoch mean| at 10 Hz, in g. Counts only, never raw samples.
    public var motion: Double?
    public var jerk: Double?
    /// Epoch RMS level and the room floor (rolling 10th percentile of the last 10 minutes), in dBFS.
    public var levelDB: Double?
    public var floorDB: Double?
    public var soundEvent: Bool
    public init(start: Date, motion: Double? = nil, jerk: Double? = nil, levelDB: Double? = nil, floorDB: Double? = nil, soundEvent: Bool = false) {
        self.start = start; self.motion = motion; self.jerk = jerk; self.levelDB = levelDB; self.floorDB = floorDB; self.soundEvent = soundEvent
    }
    public var hasData: Bool { motion != nil || levelDB != nil }
}

public struct PhoneWakeUp: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case phoneUse, restless }
    public var kind: Kind
    public var start: Date
    public var end: Date
}

/// The morning estimate. Every field is an estimate except the in-bed span itself.
public struct PhoneEstimate: Codable, Equatable, Sendable {
    public var fellAsleep: Date?
    public var wokeForGood: Date?
    public var wakeUps: [PhoneWakeUp]
    public var timeAsleep: TimeInterval?
    /// Share of epochs with mic or motion data.
    public var coverage: Double
    public var noDataSeconds: TimeInterval
}

/// A night recorded by the iPhone alone. Stored by sleepi only; nothing goes to Health.
public struct PhoneNight: Codable, Identifiable, Sendable {
    public static let ruleVersion = 1
    public var schemaVersion = 1
    public var id: UUID
    /// Same key as Watch nights and diary entries: the noon-to-noon window start.
    public var nightID: Date
    public var start: Date
    public var end: Date?
    public var epochs: [PhoneEpoch] = []
    public var events: [PhoneEvent] = []
    public var estimate: PhoneEstimate?
    public var estimateRuleVersion: Int?
    /// The phone is assumed to sit beside the bed: a phone on the mattress or under the pillow overstated sleep by
    /// about 100 minutes in every independent test, so there's no mattress mode (research note 2).
    public init(id: UUID = UUID(), start: Date, calendar: Calendar = .current) {
        self.id = id; self.start = start
        nightID = NightBuilder.window(containing: start, calendar: calendar).start
    }
    /// Motion and sound arrive separately; both land in the same 30-second slot counted from the night's start.
    public mutating func merge(_ incoming: PhoneEpoch) {
        let slot = Int((incoming.start.timeIntervalSince(start) / PhoneNightRule.epoch).rounded(.down))
        guard slot >= 0 else { return }
        let aligned = start.addingTimeInterval(Double(slot) * PhoneNightRule.epoch)
        var i = epochs.count - 1
        while i >= 0, epochs[i].start > aligned { i -= 1 }
        if i >= 0, epochs[i].start == aligned {
            var e = epochs[i]
            e.motion = e.motion ?? incoming.motion; e.jerk = e.jerk ?? incoming.jerk
            e.levelDB = e.levelDB ?? incoming.levelDB; e.floorDB = e.floorDB ?? incoming.floorDB
            e.soundEvent = e.soundEvent || incoming.soundEvent
            epochs[i] = e
        } else {
            var e = incoming; e.start = aligned
            epochs.insert(e, at: i + 1)
        }
    }
    /// Re-run the current rule, for instance after tuning ("Recalculate" in Settings).
    public mutating func recalculate() {
        guard let end else { return }
        estimate = PhoneNightRule.estimate(epochs: epochs, events: events, start: start, end: end)
        estimateRuleVersion = Self.ruleVersion
    }
}

/// Section 2 of the phone-only spec: a transparent, tunable rule. Phones tell quiet from restless, not sleep stages.
public enum PhoneNightRule {
    public static let epoch: TimeInterval = 30
    /// 20 quiet minutes, allowing up to 2 active epochs.
    static let quietRun = 40, quietAllowance = 2
    /// A count above this is the phone being picked up or moved, treated like phone use.
    public static let phoneMovedBar = 3.0

    public static func estimate(epochs input: [PhoneEpoch], events: [PhoneEvent], start: Date, end: Date) -> PhoneEstimate {
        let count = max(0, Int((end.timeIntervalSince(start) / epoch).rounded(.up)))
        var epochs = [PhoneEpoch?](repeating: nil, count: count)
        for e in input {
            let i = Int(e.start.timeIntervalSince(start) / epoch)
            if i >= 0 && i < count { epochs[i] = e }
        }
        func index(_ date: Date) -> Int { Int((date.timeIntervalSince(start) / epoch).rounded(.down)) }
        let hasData = epochs.map { $0?.hasData == true }

        // Phone use: unlock→lock and open→close spans, plus "phone moved", each ±1 epoch.
        var certain = [Bool](repeating: false, count: count)
        var useSpans: [(Date, Date)] = []
        func spans(_ on: PhoneEvent.Kind, _ off: PhoneEvent.Kind) {
            var opened: Date?
            for e in events.sorted(by: { $0.at < $1.at }) {
                if e.kind == on, opened == nil { opened = e.at }
                if e.kind == off, let o = opened { useSpans.append((o, e.at)); opened = nil }
            }
            if let o = opened { useSpans.append((o, min(end, o.addingTimeInterval(5 * 60)))) }
        }
        spans(.unlocked, .locked); spans(.appOpened, .appClosed)
        var moved = events.filter { $0.kind == .phoneMoved }.map(\.at)
        moved += epochs.compactMap { e in e.flatMap { ($0.motion ?? 0) > phoneMovedBar ? $0.start : nil } }
        useSpans += moved.map { ($0, $0.addingTimeInterval(epoch)) }
        for (a, b) in useSpans where b > start && a < end {
            for i in max(0, index(a) - 1)...min(count - 1, index(b.addingTimeInterval(-0.001)) + 1) where count > 0 { certain[i] = true }
        }

        // Active: a sound event in the room.
        let active = epochs.map { $0?.soundEvent == true }

        func quiet(at i: Int) -> Bool {
            guard i + quietRun <= count else { return false }
            let window = i..<(i + quietRun)
            return !window.contains { certain[$0] } && window.filter { active[$0] }.count <= quietAllowance
                && window.filter { hasData[$0] }.count >= quietRun / 2
        }
        // Fell asleep: first quiet run after the last phone use that precedes it.
        var fell: Int?
        var i = 0
        while i + quietRun <= count {
            if quiet(at: i) { fell = i; break }
            i += 1
        }
        var woke: Int?
        if let f = fell {
            var j = count - quietRun
            while j >= f { if quiet(at: j) { woke = j + quietRun; break }; j -= 1 }
        }
        let coverage = count == 0 ? 0 : Double(hasData.filter { $0 }.count) / Double(count)
        guard let f = fell, let w = woke, w > f else {
            return PhoneEstimate(fellAsleep: nil, wokeForGood: nil, wakeUps: [], timeAsleep: nil, coverage: coverage,
                                 noDataSeconds: Double(hasData.filter { !$0 }.count) * epoch)
        }
        // Wake-ups between: phone use (certain) and restless patches (≥ 3 active epochs in any 5).
        var awake = [PhoneWakeUp.Kind?](repeating: nil, count: count)
        for k in f..<w where certain[k] { awake[k] = .phoneUse }
        if f + 5 <= w {
            for k in f...(w - 5) where (k..<(k + 5)).filter({ active[$0] }).count >= 3 {
                for m in k..<(k + 5) where awake[m] == nil { awake[m] = .restless }
            }
        }
        var wakeUps: [PhoneWakeUp] = []
        var k = f
        while k < w {
            guard let kind = awake[k] else { k += 1; continue }
            var e = k
            while e < w, awake[e] == kind { e += 1 }
            wakeUps.append(PhoneWakeUp(kind: kind, start: start.addingTimeInterval(Double(k) * epoch), end: start.addingTimeInterval(Double(e) * epoch)))
            k = e
        }
        let asleepEpochs = (f..<w).filter { awake[$0] == nil && hasData[$0] }.count
        return PhoneEstimate(fellAsleep: start.addingTimeInterval(Double(f) * epoch), wokeForGood: start.addingTimeInterval(Double(w) * epoch),
                             wakeUps: wakeUps, timeAsleep: Double(asleepEpochs) * epoch, coverage: coverage,
                             noDataSeconds: Double((f..<w).filter { !hasData[$0] }.count) * epoch)
    }
}

/// Turns 1-second sound levels into epoch level, room floor and a sound-event flag. The floor is the 10th percentile
/// of the previous 10 minutes, so a steady fan raises the floor instead of creating events. An event is a second at
/// least 6 dB above that floor, or a speech-like classification in the epoch.
public struct SoundActivityTracker: Sendable {
    private var history: [Double] = []   // last 600 one-second levels
    private var epochSeconds: [Double] = []
    private var epochStart: Date?
    private var classified = false
    public init() {}
    public mutating func markClassifiedActivity() { classified = true }
    /// Feed one second's level (dBFS). Returns a finished epoch every 30 seconds.
    public mutating func add(secondLevel: Double, at time: Date) -> PhoneEpoch? {
        guard secondLevel.isFinite else { return nil }
        if epochStart == nil { epochStart = time }
        epochSeconds.append(secondLevel)
        guard epochSeconds.count >= 30, let begun = epochStart else { return nil }
        let floor = history.count >= 30 ? Self.percentile(history, 0.1) : nil
        let power = epochSeconds.map { pow(10, $0 / 10) }.reduce(0, +) / Double(epochSeconds.count)
        let level = 10 * log10(max(1e-12, power))
        let loud = floor.map { f in epochSeconds.contains { $0 >= f + 6 } } ?? false
        let epoch = PhoneEpoch(start: begun, levelDB: level, floorDB: floor, soundEvent: loud || classified)
        history += epochSeconds
        if history.count > 600 { history.removeFirst(history.count - 600) }
        epochSeconds = []; epochStart = nil; classified = false
        return epoch
    }
    static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))]
    }
}

/// 10 Hz accelerometer magnitudes into a 30-second activity count and max jerk, counts only.
public struct MotionEpochAccumulator: Sendable {
    private var samples: [Double] = []
    private var epochStart: Date?
    public init() {}
    public mutating func add(magnitude: Double, at time: Date) -> (start: Date, motion: Double, jerk: Double)? {
        guard magnitude.isFinite else { return nil }
        if let begun = epochStart, time.timeIntervalSince(begun) >= PhoneNightRule.epoch {
            let result = summary(begun)
            samples = [magnitude]; epochStart = time
            return result
        }
        if epochStart == nil { epochStart = time }
        samples.append(magnitude)
        return nil
    }
    private func summary(_ begun: Date) -> (start: Date, motion: Double, jerk: Double)? {
        guard samples.count >= 10 else { return nil }
        let mean = samples.reduce(0, +) / Double(samples.count)
        let motion = samples.reduce(0) { $0 + abs($1 - mean) }
        let jerk = zip(samples, samples.dropFirst()).map { abs($1 - $0) }.max() ?? 0
        return (begun, motion, jerk)
    }
}
