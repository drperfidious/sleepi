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
    @State private var latest = Calendar.current.nextDate(after: .now, matching: DateComponents(hour: 7), matchingPolicy: .nextTime) ?? .now.addingTimeInterval(8 * 3600)
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Label("sleepi", systemImage: "moon.stars").foregroundStyle(.purple.opacity(0.8)).font(.headline)
                if let start = pilot.start {
                    Text(start, style: .timer).font(.system(size: 36, weight: .light, design: .rounded)).monospacedDigit()
                    Text("Since your in-bed marker").font(.caption2).foregroundStyle(.secondary)
                    Button(pilot.alerting ? "Dismiss gentle wake" : "End tonight") { pilot.end() }.tint(.purple)
                    if pilot.pilotEnabled { Button(pilot.exporting ? "Preparing motion…" : "Send motion to iPhone") { pilot.exportMotion() }.disabled(pilot.exporting) }
                } else {
                    Text(pilot.summary).font(.title3)
                    if let date = pilot.summaryDate { Text(date, format: .dateTime.month(.abbreviated).day()).font(.caption2).foregroundStyle(.secondary) }
                    Button("Start Tonight") { showStart = true }.tint(.purple)
                }
                Text(pilot.status).font(.caption2).foregroundStyle(.secondary)
                if !pilot.pilotEnabled { Text("Motion & gentle wake await device validation.").font(.caption2).foregroundStyle(.secondary) }
                if pilot.start == nil, pilot.canExport, pilot.pilotEnabled { Button("Send motion to iPhone") { pilot.exportMotion() }.disabled(pilot.exporting) }
            }.padding(.horizontal, 4)
        }
        .sheet(isPresented: $showStart) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Tonight, your way").font(.headline)
                    Toggle("Gentle wake", isOn: $gentle).disabled(!pilot.pilotEnabled)
                    if gentle {
                        DatePicker("Latest tap", selection: $latest, displayedComponents: .hourAndMinute)
                        Text("Up to 25 minutes early, based on movement. Keep your Clock alarm set.").font(.caption2)
                    }
                    Text("Sound recording must be started on your iPhone.").font(.caption2).foregroundStyle(.secondary)
                    Button(gentle ? "Confirm time & start" : "Track only") {
                        if pilot.begin(latest: gentle ? nextOccurrence(latest) : nil) { showStart = false }
                    }.tint(.purple)
                }
            }
        }
        .onOpenURL { url in if url.scheme == "sleepi", url.host == "tonight" { showStart = pilot.start == nil } }
        .onAppear { if TonightRoute.consume() { showStart = pilot.start == nil } }
        .onReceive(NotificationCenter.default.publisher(for: .sleepiOpenTonight)) { _ in if TonightRoute.consume() { showStart = pilot.start == nil } }
    }
    private func nextOccurrence(_ date: Date) -> Date {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return Calendar.current.nextDate(after: .now, matching: components, matchingPolicy: .nextTime) ?? date
    }
}
