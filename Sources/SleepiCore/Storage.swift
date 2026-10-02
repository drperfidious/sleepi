import Foundation

public struct RetentionPlan: Sendable {
    public var deleteIDs: Set<UUID>
    public var retainedBytes: Int
    public var canRecord: Bool
}

public enum ClipRetention {
    /// Starred clips count toward the hard cap; if they fill it, recording stops.
    public static func plan(events: [SoundEvent], now: Date, days: Int = 14, budget: Int = 300_000_000, reservation: Int = 160_000) -> RetentionPlan {
        let cutoff = now.addingTimeInterval(-Double(max(0, days)) * 86400)
        let files = events.filter { $0.fileName != nil }
        var removed = Set(files.filter { !$0.starred && $0.end < cutoff }.map(\.id))
        var bytes = files.filter { !removed.contains($0.id) }.reduce(0) { $0 + max(0, $1.byteCount) }
        for event in files.filter({ !$0.starred && !removed.contains($0.id) }).sorted(by: { $0.start < $1.start }) where bytes + reservation > budget {
            removed.insert(event.id); bytes -= max(0, event.byteCount)
        }
        return RetentionPlan(deleteIDs: removed, retainedBytes: bytes, canRecord: bytes + reservation <= budget)
    }
}

public enum StoreError: LocalizedError {
    case unsupportedVersion(Int), unsafeFileName
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "This library uses a newer format (\(version)). It was left unchanged."
        case .unsafeFileName: "The recording filename is invalid."
        }
    }
}

public actor LocalRepository {
    public let directory: URL
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.protect(directory)
        let clips = directory.appendingPathComponent("Clips", isDirectory: true)
        try FileManager.default.createDirectory(at: clips, withIntermediateDirectories: true)
        try Self.protect(clips)
    }
    public func load() throws -> LocalState {
        let url = directory.appendingPathComponent("library.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return LocalState() }
        let state = try JSONDecoder().decode(LocalState.self, from: Data(contentsOf: url))
        guard state.schemaVersion == 1 else { throw StoreError.unsupportedVersion(state.schemaVersion) }
        return state
    }
    public func save(_ state: LocalState) throws {
        let data = try JSONEncoder().encode(state)
        let url = directory.appendingPathComponent("library.json")
        #if os(iOS) || os(watchOS)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try data.write(to: url, options: .atomic)
        #endif
        try Self.protect(url)
    }
    public static func setExcludedFromBackup(_ url: URL, _ excluded: Bool) throws {
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = excluded
        try mutable.setResourceValues(values)
    }
    /// Starred clips are kept and backed up; others are excluded.
    public func setClipBackedUp(_ name: String, _ backedUp: Bool) throws {
        let url = try clipURL(name)
        if FileManager.default.fileExists(atPath: url.path) { try Self.setExcludedFromBackup(url, !backedUp) }
    }
    public func clipURL(_ name: String) throws -> URL {
        guard name == URL(fileURLWithPath: name).lastPathComponent, !name.hasPrefix("."), !name.contains("/"), name.hasSuffix(".m4a") else { throw StoreError.unsafeFileName }
        return directory.appendingPathComponent("Clips").appendingPathComponent(name)
    }
    public func deleteClip(_ name: String) throws {
        let url = try clipURL(name)
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public func removeOrphanClips(keeping names: Set<String>) throws {
        let clips = directory.appendingPathComponent("Clips")
        for file in try FileManager.default.contentsOfDirectory(at: clips, includingPropertiesForKeys: nil) where !names.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
    }
    public func deleteAll() throws {
        // Persist an empty state first. A failed deletion can safely be retried on next launch.
        try save(LocalState())
        try removeOrphanClips(keeping: [])
        let phone = directory.appendingPathComponent("PhoneNights")
        if FileManager.default.fileExists(atPath: phone.path) { try FileManager.default.removeItem(at: phone) }
    }
    /// Phone nights live in their own files (epochs make them larger than the rest of the library).
    public func savePhoneNight(_ night: PhoneNight) throws {
        let dir = directory.appendingPathComponent("PhoneNights", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true); try Self.protect(dir) }
        let url = dir.appendingPathComponent("\(night.id.uuidString).json")
        #if os(iOS) || os(watchOS)
        try JSONEncoder().encode(night).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        #else
        try JSONEncoder().encode(night).write(to: url, options: .atomic)
        #endif
        try Self.protect(url)
    }
    public func loadPhoneNights() throws -> [PhoneNight] {
        let dir = directory.appendingPathComponent("PhoneNights", isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(PhoneNight.self, from: Data(contentsOf: $0)) }
            .filter { $0.schemaVersion == 1 }.sorted { $0.start < $1.start }
    }
    /// Sets file protection. The library is included in iPhone/iCloud backups so notes and months of tags survive a
    /// phone change; only unstarred clips are excluded (`setExcludedFromBackup`), since they expire in 14 days anyway.
    public static func protect(_ url: URL) throws {
        try setExcludedFromBackup(url, false)
        #if os(iOS) || os(watchOS)
        // New files must be writable while locked during explicit overnight recording.
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #else
        try FileManager.default.setAttributes([.posixPermissions: url.hasDirectoryPath ? 0o700 : 0o600], ofItemAtPath: url.path)
        #endif
    }
}

public struct PCMWindow: Sendable {
    public let capacity: Int
    private var storage: [Float]
    private var cursor = 0
    public private(set) var count = 0
    public init(capacity: Int) { self.capacity = max(1, capacity); storage = Array(repeating: 0, count: max(1, capacity)) }
    public mutating func append(_ samples: [Float]) {
        for sample in samples { storage[cursor] = sample; cursor = (cursor + 1) % capacity; count = min(capacity, count + 1) }
    }
    public var samples: [Float] {
        if count < capacity { return Array(storage.prefix(count)) }
        return Array(storage[cursor...]) + Array(storage[..<cursor])
    }
    public static func dbfs(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return -120 }
        let power = samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count)
        return max(-120, 10 * log10(max(1e-12, power)))
    }
}

/// Per-label confidence the on-device classifier must reach before a highlight is saved. The built-in classifier
/// spreads its confidence when a steady sound such as a fan is also present, so 0.8 for every label missed
/// masked snoring and speech. These are starting points to tune with the nightly listening summary.
public enum SoundThresholds {
    public static func confidence(for kind: SoundKind) -> Double {
        switch kind {
        case .snoring, .coughing: 0.5
        case .speech: 0.6
        case .environment: 0.7
        }
    }
    /// Below the bar but close: counted so a night with no highlights shows whether anything came near.
    public static func nearMiss(for kind: SoundKind) -> Double { confidence(for: kind) * 0.6 }
}

/// What one listening session heard, saved with the night so "no highlights" can be told apart from "nothing happened".
public struct SoundSessionStats: Codable, Equatable, Sendable {
    public var listenedSeconds: Double = 0
    /// Typical microphone level (median of 1-second readings). A fan or white noise raises it.
    public var roomLevelDBFS: Double?
    /// Highest classifier confidence per kind (SoundKind raw value), saved or not.
    public var best: [String: Double] = [:]
    public var nearMisses: Int = 0
    public var saved: Int = 0
    public init() {}
}

/// 1-dB bins from −120 to 0 dBFS, so a night's median level needs no stored audio.
public struct LevelHistogram: Sendable {
    private var bins = [Int](repeating: 0, count: 121)
    private(set) var count = 0
    public init() {}
    public mutating func add(_ dbfs: Double) {
        guard dbfs.isFinite else { return }
        bins[min(120, max(0, Int((dbfs + 120).rounded())))] += 1; count += 1
    }
    public var median: Double? {
        guard count > 0 else { return nil }
        var seen = 0
        for (i, n) in bins.enumerated() { seen += n; if seen * 2 >= count { return Double(i) - 120 } }
        return nil
    }
}
