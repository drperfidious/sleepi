import Foundation

public enum SleepStage: String, Codable, CaseIterable, Sendable {
    case awake, rem, core, deep, unspecified, inBed
    public var isAsleep: Bool { self != .awake && self != .inBed }
    public var title: String {
        switch self {
        case .awake: "Awake"
        case .rem: "REM"
        case .core: "Core"
        case .deep: "Deep"
        case .unspecified: "Asleep"
        case .inBed: "In bed"
        }
    }
}

public struct SleepSample: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID
    public var start: Date
    public var end: Date
    public var stage: SleepStage
    public var source: String
    public var product: String
    public init(id: UUID = UUID(), start: Date, end: Date, stage: SleepStage,
                source: String = "com.apple.health", product: String = "Watch") {
        self.id = id; self.start = start; self.end = end; self.stage = stage
        self.source = source; self.product = product
    }
    public var isAppleWatch: Bool { source.hasPrefix("com.apple.") && product.hasPrefix("Watch") }
}

public struct StageSegment: Codable, Equatable, Identifiable, Sendable {
    public var start: Date
    public var end: Date
    public var stage: SleepStage
    public var id: Date { start }
    public var seconds: Double { end.timeIntervalSince(start) }
}

public struct SleepNight: Identifiable, Codable, Equatable, Sendable {
    /// A calendar-noon window, not a fixed 24-hour bucket. Midnight crossings stay together.
    public var windowStart: Date
    public var windowEnd: Date
    public var segments: [StageSegment]
    public var sourceCount: Int
    public var conflictingSeconds: Double
    public var id: Date { windowStart }
    public var firstSleep: Date? { segments.first(where: { $0.stage.isAsleep })?.start }
    public var lastSleep: Date? { segments.last(where: { $0.stage.isAsleep })?.end }
    public var asleepSeconds: Double { segments.filter { $0.stage.isAsleep }.reduce(0) { $0 + $1.seconds } }
    public var awakeSeconds: Double { segments.filter { $0.stage == .awake }.reduce(0) { $0 + $1.seconds } }
    public var recordedSeconds: Double { segments.reduce(0) { $0 + $1.seconds } }
    /// Recorded awake segments between first and last sleep. Unknown gaps are not counted as wakings.
    public var interruptions: (count: Int, seconds: Double) {
        guard let first = firstSleep, let last = lastSleep else { return (0, 0) }
        let inside = segments.filter { $0.stage == .awake && $0.start >= first && $0.end <= last }
        return (inside.count, inside.reduce(0) { $0 + $1.seconds })
    }
    public func seconds(in stage: SleepStage) -> Double { segments.filter { $0.stage == stage }.reduce(0) { $0 + $1.seconds } }
}

public enum VitalKind: String, Codable, CaseIterable, Sendable {
    case heartRate, hrv, restingHeartRate, respiratoryRate, oxygen, wristTemperature, breathingDisturbances
    public var title: String {
        switch self {
        case .heartRate: "Heart rate"
        case .hrv: "HRV · SDNN"
        case .restingHeartRate: "Resting heart rate"
        case .respiratoryRate: "Breathing rate"
        case .oxygen: "Blood oxygen"
        case .wristTemperature: "Wrist temperature"
        case .breathingDisturbances: "Breathing disturbances"
        }
    }
    public var unit: String {
        switch self {
        case .heartRate, .restingHeartRate: "bpm"
        case .hrv: "ms"
        case .respiratoryRate: "/min"
        case .oxygen: "%"
        case .wristTemperature: "°C"
        case .breathingDisturbances: "count"
        }
    }
}

public struct VitalReading: Codable, Sendable {
    public var kind: VitalKind
    public var date: Date
    /// Nightly summaries (wrist temperature, breathing disturbances) span the sleep session; point readings end where they start.
    public var end: Date
    public var value: Double
    public init(kind: VitalKind, date: Date, end: Date? = nil, value: Double) {
        self.kind = kind; self.date = date; self.end = max(date, end ?? date); self.value = value
    }
    public func overlaps(_ start: Date, _ finish: Date) -> Bool { end >= start && date <= finish }
}

public struct HealthSnapshot: Sendable {
    public var samples: [SleepSample]
    public var vitals: [VitalReading]
    public var fetchedAt: Date
    public init(samples: [SleepSample], vitals: [VitalReading] = [], fetchedAt: Date = .now) {
        self.samples = samples; self.vitals = vitals; self.fetchedAt = fetchedAt
    }
}

public enum SoundKind: String, CaseIterable, Codable, Sendable {
    case snoring, speech, coughing, environment
    public var title: String {
        switch self { case .snoring: "Possible snoring"; case .speech: "Speech"; case .coughing: "Coughing"; case .environment: "Room sound" }
    }
    public var symbol: String {
        switch self { case .snoring: "waveform"; case .speech: "bubble.left"; case .coughing: "lungs"; case .environment: "leaf" }
    }
}

public struct SoundEvent: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var start: Date
    public var end: Date
    public var kind: SoundKind
    public var confidence: Double
    public var levelDBFS: Double
    public var fileName: String?
    public var byteCount: Int
    public var starred: Bool = false
    public var notMe: Bool = false
    public init(start: Date, end: Date, kind: SoundKind, confidence: Double, levelDBFS: Double, fileName: String? = nil, byteCount: Int = 0) {
        self.start = start; self.end = end; self.kind = kind; self.confidence = confidence
        self.levelDBFS = levelDBFS; self.fileName = fileName; self.byteCount = byteCount
    }
}

public enum SessionOrigin: String, Codable, Sendable { case phone, watch }

public struct TonightSession: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var start: Date
    public var end: Date?
    public var requestedAudio: Bool
    public var status: String
    /// Where the night was started. Nil in libraries written before iPhone–Watch sync.
    public var origin: SessionOrigin?
    /// The Watch's id for this night when both devices started one before hearing from each other.
    public var watchID: UUID?
    public init(start: Date = .now, requestedAudio: Bool, status: String = "In bed") {
        self.start = start; self.requestedAudio = requestedAudio; self.status = status
    }
}

public struct NightJournal: Codable, Identifiable, Sendable {
    public var nightID: Date
    public var tagIDs: Set<UUID> = []
    public var note: String = ""
    public var isFreeDay: Bool?
    public var id: Date { nightID }
    public init(nightID: Date) { self.nightID = nightID }
}

public struct JournalTag: Codable, Identifiable, Sendable {
    public var id: UUID = UUID()
    public var name: String
    public init(name: String) { self.name = name }
}

public struct AppSettings: Codable, Sendable {
    public var targetHours: Double = 8
    public var retentionDays: Int = 14
    public var clipBudgetBytes: Int = 300_000_000
    public var morningNotifications: Bool = false
    public var onboardingComplete: Bool = false
    /// Optional so libraries written before this field still load. Nil means the defaults.
    public var gentleWake: GentleWakeSettings?
    public init() {}
}

public struct LocalState: Codable, Sendable {
    public var schemaVersion = 1
    public var settings = AppSettings()
    public var sessions: [TonightSession] = []
    public var sounds: [SoundEvent] = []
    public var journals: [NightJournal] = []
    public var tags: [JournalTag] = ["Late caffeine", "Alcohol", "Late meal", "Movement", "Stress", "Reading"].map(JournalTag.init)
    public var lastNotifiedNight: Date?
    public var motionNights: [MotionRecording] = []
    public var wakeReviews: [WakeReview] = []
    public var ignoreWatchRecordsBefore: Date?
    /// Gentle-wake decision logs from the Watch, newest last. Optional so older libraries still load.
    public var wakeLogs: [WakeLog]?
    public init() {}
}

public struct MotionEpoch: Codable, Sendable {
    public var start: Date
    public var meanMovement: Double
    public var sampleCount: Int
    public init(start: Date, meanMovement: Double, sampleCount: Int) { self.start = start; self.meanMovement = meanMovement; self.sampleCount = sampleCount }
}
public struct MotionRecording: Codable, Identifiable, Sendable {
    public var schemaVersion = 1
    public var id: UUID
    public var start: Date
    public var end: Date
    public var epochs: [MotionEpoch]
    public init(id: UUID, start: Date, end: Date, epochs: [MotionEpoch]) { self.id = id; self.start = start; self.end = end; self.epochs = epochs }
    public var isValid: Bool {
        guard schemaVersion == 1, end > start, end.timeIntervalSince(start) <= 12 * 3600 + 30, epochs.count <= 1441 else { return false }
        return epochs.allSatisfy { $0.start >= start && $0.start < end && $0.meanMovement.isFinite && $0.meanMovement >= 0 && $0.sampleCount > 0 && $0.sampleCount <= 2000 }
            && zip(epochs, epochs.dropFirst()).allSatisfy { $0.start < $1.start }
    }
}
public struct WakeReview: Codable, Sendable {
    public var start: Date
    public var end: Date
    public var confirmed: Bool
    public init(start: Date, end: Date, confirmed: Bool) { self.start = start; self.end = end; self.confirmed = confirmed }
}

public enum DurationText {
    public static func hoursMinutes(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "—" }
        let minutes = Int(max(0, seconds) / 60)
        return "\(minutes / 60)h \(minutes % 60)m"
    }
}
