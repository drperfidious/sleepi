import Foundation
@preconcurrency import HealthKit
import SleepiCore
import SleepiUI

@MainActor final class HealthKitReader: HealthReading {
    private let store = HKHealthStore()
    private var observers: [HKObserverQuery] = []
    private var callback: (@MainActor @Sendable () async -> Void)?
    private let sleep = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    private static let quantities: [(VitalKind, HKQuantityTypeIdentifier, String)] = [
        (.heartRate, .heartRate, "count/min"), (.hrv, .heartRateVariabilitySDNN, "ms"),
        (.restingHeartRate, .restingHeartRate, "count/min"), (.respiratoryRate, .respiratoryRate, "count/min"),
        (.oxygen, .oxygenSaturation, "%"), (.wristTemperature, .appleSleepingWristTemperature, "degC"),
        (.breathingDisturbances, .appleSleepingBreathingDisturbances, "count")
    ]
    func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }
        var read: Set<HKObjectType> = [sleep]
        for (_, id, _) in Self.quantities { if let type = HKObjectType.quantityType(forIdentifier: id) { read.insert(type) } }
        // The only authorization request in the app. The share set is permanently empty.
        try await store.requestAuthorization(toShare: [], read: read)
        if let callback { observe(callback) }
    }
    func fetch() async throws -> HealthSnapshot {
        guard HKHealthStore.isHealthDataAvailable() else { throw HealthError.unavailable }
        let now = Date.now
        let from = Calendar.current.date(byAdding: .day, value: -91, to: now)!
        let predicate = HKQuery.predicateForSamples(withStart: from, end: now, options: [])
        // Sleep is the only stream whose failure fails the snapshot.
        let samples: [SleepSample] = try await query(type: sleep, predicate: predicate) { raw in
            raw.compactMap { value in
                guard let sample = value as? HKCategorySample, let stage = Self.stage(sample.value) else { return nil }
                return SleepSample(id: sample.uuid, start: sample.startDate, end: sample.endDate, stage: stage,
                                   source: sample.sourceRevision.source.bundleIdentifier, product: sample.sourceRevision.productType ?? "unknown")
            }
        }
        // Vitals are only shown overnight. Query the padded sleep windows instead of 91 days of all-day heart rate,
        // which is large enough to hit the timeout and is re-read on every observer wake.
        let windows = Self.overnightWindows(samples.filter(\.isAppleWatch))
        guard !windows.isEmpty else { return HealthSnapshot(samples: samples, vitals: [], fetchedAt: now) }
        let vitals = await withTaskGroup(of: [VitalReading].self) { group in
            for (kind, identifier, unitString) in Self.quantities {
                group.addTask { await self.overnightReadings(kind, identifier, unitString, windows: windows) }
            }
            var result: [VitalReading] = []
            for await values in group { result += values }
            return result
        }
        return HealthSnapshot(samples: samples, vitals: vitals, fetchedAt: now)
    }
    /// A slow or unreadable vital stays unavailable; it never hides the night.
    private func overnightReadings(_ kind: VitalKind, _ identifier: HKQuantityTypeIdentifier, _ unitString: String, windows: [DateInterval]) async -> [VitalReading] {
        guard let type = HKObjectType.quantityType(forIdentifier: identifier) else { return [] }
        let predicate = NSCompoundPredicate(orPredicateWithSubpredicates: windows.map {
            HKQuery.predicateForSamples(withStart: $0.start, end: $0.end, options: [])
        })
        return (try? await query(type: type, predicate: predicate) { raw in
            raw.compactMap { value in
                guard let sample = value as? HKQuantitySample,
                      sample.sourceRevision.source.bundleIdentifier.hasPrefix("com.apple."),
                      sample.sourceRevision.productType?.hasPrefix("Watch") == true else { return nil }
                let unit = HKUnit(from: unitString)
                guard sample.quantity.is(compatibleWith: unit) else { return nil }
                let measured = sample.quantity.doubleValue(for: unit)
                guard measured.isFinite else { return nil }
                // HK percent is a dimensionless fraction, presented here as 0–100.
                return VitalReading(kind: kind, date: sample.startDate, end: sample.endDate, value: kind == .oxygen ? measured * 100 : measured)
            }
        }) ?? []
    }
    nonisolated private static func overnightWindows(_ samples: [SleepSample]) -> [DateInterval] {
        var merged: [DateInterval] = []
        for sample in samples.sorted(by: { $0.start < $1.start }) where sample.end > sample.start {
            let padded = DateInterval(start: sample.start.addingTimeInterval(-3600), end: sample.end.addingTimeInterval(3600))
            if let last = merged.last, padded.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, padded.end))
            } else { merged.append(padded) }
        }
        return merged
    }
    func observe(_ update: @escaping @MainActor @Sendable () async -> Void) {
        callback = update
        guard HKHealthStore.isHealthDataAvailable() else { return }
        for query in observers { store.stop(query) }; observers.removeAll()
        // Vitals may sync after sleep. Refresh when any requested stream changes.
        // All-day heart rate is excluded: it changes every few minutes and would rebuild everything hourly.
        let types: [HKSampleType] = [sleep] + Self.quantities.filter { $0.1 != .heartRate }.compactMap { HKObjectType.quantityType(forIdentifier: $0.1) }
        for type in types {
            let observer = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                let finish = ObserverCompletion(completion)
                guard error == nil else { finish.call(); return }
                Task { @MainActor in
                    defer { finish.call() }
                    await update()
                }
            }
            observers.append(observer); store.execute(observer)
            // Best effort; no guaranteed wake time or notification schedule is claimed.
            store.enableBackgroundDelivery(for: type, frequency: type == sleep ? .immediate : .hourly) { _, _ in }
        }
    }
    private func query<T: Sendable>(type: HKSampleType, predicate: NSPredicate, map: @escaping @Sendable ([HKSample]) -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            let box = QueryCompletion(continuation)
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: HKObjectQueryNoLimit, sortDescriptors: nil) { _, values, error in
                if let error { box.finish(.failure(error)) } else { box.finish(.success(map(values ?? []))) }
            }
            store.execute(query)
            let healthStore = store
            DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
                if box.finish(.failure(HealthError.timedOut)) { healthStore.stop(query) }
            }
        }
    }
    nonisolated private static func stage(_ raw: Int) -> SleepStage? {
        switch raw {
        case HKCategoryValueSleepAnalysis.inBed.rawValue: .inBed
        case HKCategoryValueSleepAnalysis.awake.rawValue: .awake
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue: .rem
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue: .core
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue: .deep
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue: .unspecified
        default: nil
        }
    }
}

private enum HealthError: LocalizedError {
    case unavailable, timedOut
    var errorDescription: String? { self == .unavailable ? "Apple Health is unavailable on this device." : "Apple Health took too long to respond. Try again after unlocking." }
}

/// A query can race its timeout. Exactly one path resumes its continuation.
private final class QueryCompletion<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, any Error>?
    init(_ continuation: CheckedContinuation<T, any Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<T, any Error>) -> Bool {
        lock.lock(); let pending = continuation; continuation = nil; lock.unlock()
        pending?.resume(with: result); return pending != nil
    }
}
private final class ObserverCompletion: @unchecked Sendable {
    private let completion: () -> Void
    init(_ completion: @escaping () -> Void) { self.completion = completion }
    func call() { completion() }
}
