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
                    Button(pilot.alerting ? "Dismiss gentle wake" : "End tonight") { pilot.end() }.tint(.purple)
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
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Tonight, your way").font(.headline)
                    Toggle("Gentle wake", isOn: $gentle)
                    if gentle {
                        DatePicker("Latest tap", selection: $latest, displayedComponents: .hourAndMinute)
                        Text(wakeSourceText).font(.caption2).foregroundStyle(.secondary)
                        Text("Window: \(Int(windowMinutes)) min").font(.caption)
                        Slider(value: $windowMinutes, in: Double(GentleWakeSettings.windowRange.lowerBound)...Double(GentleWakeSettings.windowRange.upperBound), step: 5)
                        Text("Up to 30 min: Apple runs a Watch smart alarm for at most 30 minutes.").font(.caption2).foregroundStyle(.secondary)
                        Picker("Movement needed", selection: $sensitivity) {
                            ForEach(WakeSensitivity.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Text("Experiment: taps your wrist, with no sound, once you've been restless for about a minute in the window, or at this time. A twitch or a single roll-over doesn't count. Keep your Clock alarm set.").font(.caption2)
                    }
                    Toggle("Save overnight motion", isOn: $recordMotion)
                    if recordMotion {
                        Text("Keeps a whole-night motion record to send to iPhone in the morning and compare with Apple's sleep. Gentle wake doesn't need it: it measures your movement on its own during the window.").font(.caption2)
                    }
                    Text("Sound recording must be started on your iPhone.").font(.caption2).foregroundStyle(.secondary)
                    Button(gentle ? "Confirm time & start" : "Track only") {
                        let wake = gentle ? nextOccurrence(latest) : nil
                        if gentle { pilot.updateWakeSettings(windowMinutes: Int(windowMinutes), sensitivity: sensitivity) }
                        if pilot.begin(latest: wake, recordMotion: recordMotion) {
                            if let wake { pilot.rememberPick(wake) }
                            showStart = false
                        }
                    }.tint(.purple)
                }
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
        .onOpenURL { url in if url.scheme == "sleepi", url.host == "tonight" { showStart = pilot.start == nil } }
        .onAppear { if TonightRoute.consume() { showStart = pilot.start == nil } }
        .onReceive(NotificationCenter.default.publisher(for: .sleepiOpenTonight)) { _ in if TonightRoute.consume() { showStart = pilot.start == nil } }
    }
    private var wakeSourceText: String {
        let day = nextOccurrence(latest).formatted(.dateTime.weekday(.wide))
        guard let suggestion, Calendar.current.isDate(nextOccurrence(latest), equalTo: suggestion.date, toGranularity: .minute) else {
            return "Set tonight. sleepi will suggest it again next \(day)."
        }
        switch suggestion.source {
        case .lastPick: return "Your last \(day) time. Change it if your alarm changed."
        case .usualWake: return "Your usual \(day) wake-up from Apple Watch. Apple's alarm time isn't readable, so check it."
        }
    }
    private func nextOccurrence(_ date: Date) -> Date {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Calendar.current.nextDate(after: .now, matching: components, matchingPolicy: .nextTime) ?? date
    }
}
