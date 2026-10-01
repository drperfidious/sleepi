import Foundation

public enum DemoData {
    /// Synthetic fixtures are deliberately opt-in and never mixed into HealthKit results.
    public static func snapshot(now: Date = .now, calendar: Calendar = .current) -> HealthSnapshot {
        let today = calendar.startOfDay(for: now)
        var samples: [SleepSample] = []
        var vitals: [VitalReading] = []
        for offset in 0..<30 {
            let wakeDay = calendar.date(byAdding: .day, value: -offset, to: today)!
            let wake = calendar.date(bySettingHour: 7, minute: 12 + (offset % 4) * 4, second: 0, of: wakeDay)!
            var cursor = wake.addingTimeInterval(-Double(8 * 60 + (offset % 3) * 9) * 60)
            let parts: [(SleepStage, Double)] = [(.core, 26), (.deep, 42), (.core, 53), (.rem, 24), (.awake, 8), (.core, 38), (.deep, 27), (.core, 48), (.rem, 39), (.awake, 12), (.core, 51), (.rem, 49), (.core, 38), (.rem, 25)]
            let scale = wake.timeIntervalSince(cursor) / (parts.reduce(0) { $0 + $1.1 } * 60)
            for (stage, minutes) in parts {
                let end = cursor.addingTimeInterval(minutes * 60 * scale)
                samples.append(SleepSample(start: cursor, end: end, stage: stage)); cursor = end
            }
            for (kind, value) in [(VitalKind.heartRate, 54.0), (.hrv, 62), (.respiratoryRate, 14.2), (.oxygen, 97.8), (.wristTemperature, 35.7)] {
                vitals.append(VitalReading(kind: kind, date: wake.addingTimeInterval(-3600), value: value + Double(offset % 3) * 0.1))
            }
        }
        return HealthSnapshot(samples: samples, vitals: vitals, fetchedAt: now)
    }
}
