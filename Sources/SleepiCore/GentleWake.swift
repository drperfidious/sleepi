import Foundation

/// How much sustained movement the Watch needs before a gentle-wake tap. Thresholds are starting points to tune
/// from the nightly logs, not validated values.
public enum WakeSensitivity: String, Codable, CaseIterable, Sendable {
    case moreMovement, standard, lessMovement
    public var title: String {
        switch self {
        case .moreMovement: "More movement"
        case .standard: "Standard"
        case .lessMovement: "Less movement"
        }
    }
    /// Weighted active-sample score an epoch must reach to count as restless.
    var threshold: Double {
        switch self {
        case .moreMovement: 40
        case .standard: 20
        case .lessMovement: 10
        }
    }
}

/// Window and sensitivity, shared by iPhone and Watch. The newer edit wins.
public struct GentleWakeSettings: Codable, Equatable, Sendable {
    /// Apple runs a smart-alarm session for at most 30 minutes, so the window can't be longer.
    public static let windowRange = 5...30
    public var windowMinutes: Int
    public var sensitivity: WakeSensitivity
    public var updatedAt: Date
    public init(windowMinutes: Int = 25, sensitivity: WakeSensitivity = .standard, updatedAt: Date = .distantPast) {
        self.windowMinutes = min(max(windowMinutes, Self.windowRange.lowerBound), Self.windowRange.upperBound)
        self.sensitivity = sensitivity; self.updatedAt = updatedAt
    }
    public func merged(with other: GentleWakeSettings) -> GentleWakeSettings { other.updatedAt > updatedAt ? other : self }
}

public struct WakeLogEpoch: Codable, Equatable, Sendable {
    public var start: Date
    /// Accelerometer samples in this 30-second epoch whose magnitude changed by more than 0.03 g from the previous one.
    public var activeSamples: Int
    /// Causal actigraphy-style score: this epoch plus decaying weights for the three before it.
    public var score: Double
    public var threshold: Double
    public var restless: Bool
}

/// One night's gentle-wake inputs and decision, written on the Watch and shared from the iPhone for tuning.
public struct WakeLog: Codable, Identifiable, Sendable {
    public enum Outcome: String, Codable, Sendable { case movement, deadline, endedEarly, snoozed }
    public var id: UUID
    public var windowStart: Date
    public var latest: Date
    public var windowMinutes: Int
    public var sensitivity: WakeSensitivity
    public var epochs: [WakeLogEpoch] = []
    public var tappedAt: Date?
    public var outcome: Outcome?
    public init(id: UUID = UUID(), windowStart: Date, latest: Date, windowMinutes: Int, sensitivity: WakeSensitivity) {
        self.id = id; self.windowStart = windowStart; self.latest = latest
        self.windowMinutes = windowMinutes; self.sensitivity = sensitivity
    }
    public var isValid: Bool {
        latest > windowStart && latest.timeIntervalSince(windowStart) <= 31 * 60 && epochs.count <= 64
            && epochs.allSatisfy { $0.score.isFinite && $0.score >= 0 && $0.activeSamples >= 0 }
    }
    public var csv: String {
        var lines = ["epoch_start,active_samples,score,threshold,restless"]
        let format = ISO8601DateFormatter()
        for e in epochs {
            lines.append("\(format.string(from: e.start)),\(e.activeSamples),\(String(format: "%.1f", e.score)),\(String(format: "%.1f", e.threshold)),\(e.restless)")
        }
        lines.append("# window \(windowMinutes) min, sensitivity \(sensitivity.rawValue), latest \(format.string(from: latest))")
        lines.append("# outcome \(outcome?.rawValue ?? "none"), tapped \(tappedAt.map(format.string(from:)) ?? "never")")
        return lines.joined(separator: "\n")
    }
}

/// Decides when a gentle-wake tap is due. Light sleep and brief arousals come with more body movement than deep sleep
/// (the basis of actigraphy scoring such as Cole–Kripke and Sadeh), so it scores movement in 30-second epochs over a
/// rolling window instead of reacting to one twitch. It taps only when at least 2 of the last 3 epochs are restless,
/// meaning movement kept up for about a minute. The bar drops linearly to half by the chosen time, because sleep
/// lightens toward morning. Heart rate isn't used: the Watch samples it only every few minutes during sleep, which is
/// too sparse inside a 30-minute window. Movement-only scoring is weak at telling quiet wake from sleep, so this is
/// a heuristic to tune from the logs.
public struct WakeWindowDetector: Sendable {
    public let windowStart: Date
    public let latest: Date
    public let sensitivity: WakeSensitivity
    public private(set) var epochs: [WakeLogEpoch] = []
    private let epochLength: TimeInterval = 30
    private var currentStart: Date
    private var currentActive = 0
    private var lastMagnitude: Double?
    private var activeHistory: [Int] = []

    public init(windowStart: Date, latest: Date, sensitivity: WakeSensitivity) {
        self.windowStart = windowStart; self.latest = latest; self.sensitivity = sensitivity
        currentStart = windowStart
    }

    /// Feed one accelerometer reading (vector magnitude in g). Returns true once a tap is due.
    public mutating func add(magnitude: Double, at time: Date) -> Bool {
        guard magnitude.isFinite else { return false }
        var due = false
        while time >= currentStart.addingTimeInterval(epochLength) {
            due = closeEpoch() || due
        }
        if let last = lastMagnitude, abs(magnitude - last) > 0.03 { currentActive += 1 }
        lastMagnitude = magnitude
        return due
    }

    private mutating func closeEpoch() -> Bool {
        activeHistory.append(currentActive)
        let weights = [1.0, 0.5, 0.25, 0.125]
        let score = zip(activeHistory.reversed(), weights).reduce(0) { $0 + Double($1.0) * $1.1 }
        let total = max(1, latest.timeIntervalSince(windowStart))
        let remaining = min(1, max(0, latest.timeIntervalSince(currentStart.addingTimeInterval(epochLength)) / total))
        let threshold = sensitivity.threshold * (0.5 + 0.5 * remaining)
        // An epoch counts only if it has movement of its own, so one big burst can't carry over into the next epoch.
        let restless = score >= threshold && Double(currentActive) >= threshold / 4
        epochs.append(WakeLogEpoch(start: currentStart, activeSamples: currentActive, score: score, threshold: threshold, restless: restless))
        currentStart = currentStart.addingTimeInterval(epochLength); currentActive = 0
        return epochs.suffix(3).filter(\.restless).count >= 2
    }
}

/// Snooze pauses the gentle-wake taps for 10 minutes without moving the planned wake time. If the wake time is less
/// than 10 minutes away, the next taps come at the wake time. Once it has passed there's no snooze: the other alarm
/// (Apple's Clock alarm) takes over.
public struct SnoozePlan: Equatable, Sendable {
    /// When the next smart-alarm session starts.
    public var resumeAt: Date
    /// True when the next taps come at the wake time only, without watching for restlessness first.
    public var atWakeTimeOnly: Bool

    public static func plan(now: Date, latest: Date, minutes: Double = 10) -> SnoozePlan? {
        guard latest.timeIntervalSince(now) > 30 else { return nil }
        let resume = now.addingTimeInterval(minutes * 60)
        if resume < latest.addingTimeInterval(-60) { return SnoozePlan(resumeAt: resume, atWakeTimeOnly: false) }
        return SnoozePlan(resumeAt: max(now.addingTimeInterval(5), latest.addingTimeInterval(-60)), atWakeTimeOnly: true)
    }
}
