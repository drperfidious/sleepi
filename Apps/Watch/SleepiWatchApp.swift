import SwiftUI
import WatchKit
import SleepiCore

@main struct SleepiWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    var body: some Scene { WindowGroup { WatchHome(pilot: WatchPilot.shared) } }
}

@MainActor final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        // Attach synchronously on relaunch; otherwise watchOS cancels the scheduled session.
        WatchPilot.shared.restore(extendedRuntimeSession)
    }
}

struct WatchHome: View {
    @ObservedObject var pilot: WatchPilot
    @State private var showStart = false
    @State private var gentle = false
    @State private var recordMotion = false
    @State private var suggestion: WakeSuggestion?
    @State private var windowMinutes = 25.0
    @State private var sensitivity = WakeSensitivity.standard
    @State private var latest = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 7), matchingPolicy: .nextTime) ?? .now.addingTimeInterval(8 * 3600)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("sleepi", systemImage: "moon.stars").foregroundStyle(.purple.opacity(0.8)).font(.headline)
                if let start = pilot.start {
                    Text(start, style: .timer).font(.system(size: 36, weight: .light, design: .rounded)).monospacedDigit()
                    Text("Since your in-bed marker").font(.caption2).foregroundStyle(.secondary)
                    if let wake = pilot.pendingGentleWake, !pilot.alerting {
                        Button("Set gentle wake · \(wake.formatted(date: .omitted, time: .shortened))") { pilot.armPendingGentleWake() }.tint(.purple)
                    }
                    if pilot.alerting {
                        Button("Wake Up") { pilot.wakeUp() }.tint(.purple)
                        if pilot.canSnooze { Button("Snooze 10 min") { pilot.snooze() } }
                    } else {
                        Button("End tonight") { pilot.end() }.tint(.purple)
                    }
                    if pilot.canExport { Button(pilot.exporting ? "Preparing motion…" : "Send motion to iPhone") { pilot.exportMotion() }.disabled(pilot.exporting) }
                } else {
                    Text(pilot.summary).font(.title3)
                    if let date = pilot.summaryDate { Text(date, format: .dateTime.month(.abbreviated).day()).font(.caption2).foregroundStyle(.secondary) }
                    Button("Start Tonight") { showStart = true }.tint(.purple)
                }
                Text(pilot.status).font(.caption2).foregroundStyle(.secondary)
                if pilot.start == nil, pilot.canExport { Button(pilot.exporting ? "Preparing motion…" : "Send motion to iPhone") { pilot.exportMotion() }.disabled(pilot.exporting) }
            }.padding(.horizontal, 4)
        }
        .sheet(isPresented: $showStart) {
            NavigationStack {
                Form {
                    Toggle("Gentle wake", isOn: $gentle)
                    if gentle {
                        DatePicker("Wake by", selection: $latest, displayedComponents: .hourAndMinute)
                        Text(wakeSourceText).font(.caption2).foregroundStyle(.secondary)
                        // A row like the others (watchOS draws a Stepper's label very large).
                        Picker("Window", selection: $windowMinutes) {
                            ForEach(Array(stride(from: GentleWakeSettings.windowRange.lowerBound, through: GentleWakeSettings.windowRange.upperBound, by: 5)), id: \.self) { Text("\($0) min").tag(Double($0)) }
                        }.pickerStyle(.navigationLink)
                        Picker("Movement needed", selection: $sensitivity) {
                            ForEach(WakeSensitivity.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.pickerStyle(.navigationLink)
                    }
                    Toggle("Save overnight motion", isOn: $recordMotion)
                    Button(gentle ? "Start with gentle wake" : "Start tonight") {
                        let wake = gentle ? nextOccurrence(latest) : nil
                        if gentle { pilot.updateWakeSettings(windowMinutes: Int(windowMinutes), sensitivity: sensitivity) }
                        if pilot.begin(latest: wake, recordMotion: recordMotion) {
                            if let wake { pilot.rememberPick(wake) }
                            showStart = false
                        }
                    }.tint(.purple)
                    if gentle {
                        Text("A silent wrist tap once you've been restless for a minute in the window (max 30 min, Apple's limit), or at your time. Keep your Clock alarm.").font(.caption2).foregroundStyle(.secondary)
                    }
                }.navigationTitle("Tonight")
            }
        }
        // Experiments are chosen fresh each night: both switches start off every time the sheet opens.
        .onChange(of: showStart) { _, open in
            guard open else { return }
            gentle = false; recordMotion = false
            suggestion = pilot.suggestedWake()
            windowMinutes = Double(pilot.wakeSettings.windowMinutes); sensitivity = pilot.wakeSettings.sensitivity
            if let suggestion { latest = suggestion.date }
        }
        // A complication or control opens a choice, but only after catching up with the iPhone: a night already
        // running there opens on its timer instead of the setup sheet. Nothing starts on its own.
        .onOpenURL { url in if url.scheme == "sleepi", url.host == "tonight" { openTonight() } }
        .onAppear { if TonightRoute.consume() { openTonight() } }
        .onReceive(NotificationCenter.default.publisher(for: .sleepiOpenTonight)) { _ in if TonightRoute.consume() { openTonight() } }
    }
    private func openTonight() {
        Task { await pilot.syncWithPhone(); showStart = pilot.start == nil }
    }
    private var wakeSourceText: String {
        let day = nextOccurrence(latest).formatted(.dateTime.weekday(.wide))
        guard let suggestion, Calendar.current.isDate(nextOccurrence(latest), equalTo: suggestion.date, toGranularity: .minute) else {
            return "Remembered for \(day)s"
        }
        switch suggestion.source {
        case .lastPick: return "Your last \(day) time"
        case .usualWake: return "Your usual \(day) wake-up. Check it matches your alarm."
        }
    }
    private func nextOccurrence(_ date: Date) -> Date {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Calendar.current.nextDate(after: .now, matching: components, matchingPolicy: .nextTime) ?? date
    }
}
