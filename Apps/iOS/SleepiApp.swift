import SwiftUI
import UserNotifications
import ActivityKit
import SleepiCore
import SleepiUI

@main struct SleepiApp: App {
    @State private var model: AppModel
    private let watchBridge: PhoneWatchBridge
    init() {
        let model = AppModel(health: HealthKitReader(), audio: AudioRecorder())
        let bridge = PhoneWatchBridge(model: model)
        watchBridge = bridge
        model.onLocalStoreReady = { [weak bridge] in bridge?.activate() }
        model.onSnapshot = { [weak bridge] night in bridge?.sendSummary(night) }
        model.requestNotifications = {
            (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
        }
        model.onMorning = { _ in
            let content = UNMutableNotificationContent()
            content.title = "A little perspective on your night"
            content.body = "Your sleep summary is ready in sleepi."
            do {
                try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "sleepi.morning", content: content, trigger: nil))
                return true
            } catch { return false }
        }
        model.onSessionChanged = { session in
            Task {
                for activity in Activity<SleepActivityAttributes>.activities { await activity.end(nil, dismissalPolicy: .immediate) }
                if let session, ActivityAuthorizationInfo().areActivitiesEnabled {
                    let state = SleepActivityAttributes.ContentState(start: session.start, soundRequested: session.requestedAudio)
                    _ = try? Activity.request(attributes: SleepActivityAttributes(), content: ActivityContent(state: state, staleDate: session.start.addingTimeInterval(8 * 3600)), pushType: nil)
                }
            }
        }
        _model = State(initialValue: model)
    }
    var body: some Scene {
        WindowGroup {
            SleepiRootView(model: model)
                .onReceive(NotificationCenter.default.publisher(for: .sleepiOpenTonight)) { _ in openPendingRoute() }
                .onAppear { openPendingRoute() }
        }
    }
    private func openPendingRoute() {
        if TonightRoute.consume() { model.selectedTab = 1; model.showStartSheet = model.state.settings.onboardingComplete && model.activeSession == nil }
    }
}
