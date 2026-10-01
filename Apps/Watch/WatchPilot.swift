import Foundation
import Combine
@preconcurrency import WatchKit
@preconcurrency import CoreMotion
@preconcurrency import WatchConnectivity
import SleepiCore

@MainActor final class WatchPilot: NSObject, ObservableObject, @preconcurrency WKExtendedRuntimeSessionDelegate, WCSessionDelegate {
    static let shared = WatchPilot()
    #if SLEEPI_DEVICE_PILOT
    let pilotEnabled = true
    #else
    let pilotEnabled = false
    #endif
    @Published var start: Date?
    @Published var summary = "Your nights, on iPhone"
    @Published var summaryDate: Date?
    @Published var status = "Apple’s sleep tracking stays in charge."
    @Published var alerting = false
    @Published var exporting = false
    private var state = PilotState()
    private var runtime: WKExtendedRuntimeSession?
    private var motion = CMMotionManager()
    private var timer: Timer?
    private var previousAcceleration: CMAcceleration?
    private var movementHits = 0
    private var recordURL: URL
    var canExport: Bool { state.recordStart != nil }

    override private init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("sleepi-watch", isDirectory: true)
        recordURL = directory.appendingPathComponent("pilot.json")
        super.init()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try LocalRepository.protect(directory)
            if FileManager.default.fileExists(atPath: recordURL.path) { state = try JSONDecoder().decode(PilotState.self, from: Data(contentsOf: recordURL)) }
            start = state.markerStart
        } catch { status = "Watch storage unavailable. \(error.localizedDescription)" }
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }
    @discardableResult func begin(latest: Date?) -> Bool {
        guard start == nil else { return false }
        guard WKApplication.shared().applicationState == .active else { status = "Open sleepi to confirm a night."; return false }
        let now = Date.now
        var scheduledStart: Date?
        if let latest {
            guard pilotEnabled, let scheduled = GentleWakePolicy.start(latest: latest, now: now) else { status = "Choose a wake time within the next 36 hours."; return false }
            scheduledStart = scheduled
        }
        state = PilotState(id: UUID(), markerStart: now, recordStart: pilotEnabled ? now : nil, latest: latest)
        guard save() else { return false }
        start = now
        if pilotEnabled, CMSensorRecorder.isAccelerometerRecordingAvailable() {
            CMSensorRecorder().recordAccelerometer(forDuration: 12 * 3600)
            status = "Motion requested · coverage must be checked in the morning."
        } else { status = "In-bed marker saved. Start sound on your iPhone." }
        if let scheduledStart {
            let session = WKExtendedRuntimeSession(); session.delegate = self; runtime = session
            session.start(at: scheduledStart)
            status = "Gentle wake requested. Keep Apple’s alarm set."
        }
        sendMarker(end: nil)
        return true
    }
    func restore(_ session: WKExtendedRuntimeSession) {
        runtime = session; session.delegate = self
    }
    func end(notifyPhone: Bool = true) {
        let orphanedWake = runtime == nil && state.latest != nil
        runtime?.invalidate(); runtime = nil; timer?.invalidate(); timer = nil; motion.stopAccelerometerUpdates()
        alerting = false; let end = Date.now
        if notifyPhone { sendMarker(end: end) }
        state.markerStart = nil; state.latest = nil; state.recordEnd = end; start = nil
        _ = save()
        status = orphanedWake ? "Night ended. If the gentle wake still taps, press Stop. Apple’s alarm is unchanged." : "Night ended. Apple’s alarm is unchanged."
        // CMSensorRecorder has no stop API. The requested capture expires by itself.
    }
    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        runtime = extendedRuntimeSession
        guard pilotEnabled else { extendedRuntimeSession.invalidate(); status = "Pilot disabled; scheduled session cancelled."; return }
        guard let latest = state.latest else {
            // The night was ended after the app was terminated, so end() had no session handle to cancel.
            // Previously this fell through to `.now` and buzzed 25 minutes early. Apple documents invalidate() on a
            // scheduled session as an active-app call; whether this background call is honoured is a device check.
            extendedRuntimeSession.invalidate(); status = "Night already ended; gentle wake cancelled."; return
        }
        previousAcceleration = nil; movementHits = 0
        let deadline = min(latest, (extendedRuntimeSession.expirationDate ?? latest).addingTimeInterval(-5))
        timer?.invalidate()
        if deadline <= .now { alert(); return }
        timer = Timer.scheduledTimer(withTimeInterval: deadline.timeIntervalSinceNow, repeats: false) { [weak self] _ in Task { @MainActor in self?.alert() } }
        if motion.isAccelerometerAvailable {
            motion.accelerometerUpdateInterval = 0.5
            motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let a = data?.acceleration else { return }
                Task { @MainActor in
                    guard let self, !self.alerting else { return }
                    if let old = self.previousAcceleration {
                        let delta = sqrt(pow(a.x - old.x, 2) + pow(a.y - old.y, 2) + pow(a.z - old.z, 2))
                        self.movementHits = delta > 0.12 ? self.movementHits + 1 : 0
                        if self.movementHits >= 3 { self.alert() }
                    }
                    self.previousAcceleration = a
                }
            }
        }
    }
    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) { alert() }
    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: (any Error)?) {
        timer?.invalidate(); timer = nil; motion.stopAccelerometerUpdates(); runtime = nil; alerting = false
        state.latest = nil; _ = save()
        status = error == nil ? "Gentle-wake session ended. Apple’s alarm is unchanged." : "Gentle wake was interrupted. Rely on your Clock alarm."
    }
    private func alert() {
        guard let runtime, runtime.state == .running, !alerting else { return }
        alerting = true; motion.stopAccelerometerUpdates(); timer?.invalidate()
        // A nil handler repeats every 3 s until dismissed. Every 10 s keeps it a nudge; Apple's Clock alarm is the alarm.
        // @Sendable keeps the handler unisolated: WatchKit may call it off the main thread, where a main-actor
        // closure would trip Swift 6's isolation check (the same crash the iPhone audio tap had).
        runtime.notifyUser(hapticType: .notification) { @Sendable _ in 10 }
        status = "Gentle wake · tap Dismiss to stop."
    }
    func exportMotion() {
        guard pilotEnabled, !exporting, let from = state.recordStart else { return }
        let to = min(state.recordEnd ?? .now, from.addingTimeInterval(12 * 3600))
        guard to > from, Date.now.timeIntervalSince(from) < 3 * 86400 else { status = "This motion recording is no longer available."; return }
        exporting = true; let id = state.id
        Task {
            let recording = await Task.detached(priority: .utility) {
                // Up to 2.16M samples for 12 h at 50 Hz, reduced while the app must stay open: fixed arrays, not a dictionary.
                let slots = Int((to.timeIntervalSince(from) / 30).rounded(.up))
                var sums = [Double](repeating: 0, count: slots), counts = [Int](repeating: 0, count: slots)
                if let list = CMSensorRecorder().accelerometerData(from: from, to: to) {
                    for case let point as CMRecordedAccelerometerData in list {
                        let offset = point.startDate.timeIntervalSince(from)
                        guard offset >= 0, point.startDate < to else { continue }
                        let key = min(slots - 1, Int(offset / 30))
                        let a = point.acceleration
                        sums[key] += abs(sqrt(a.x * a.x + a.y * a.y + a.z * a.z) - 1); counts[key] += 1
                    }
                }
                // Empty slots stay absent: missing coverage is never exported as stillness.
                let epochs = counts.indices.filter { counts[$0] > 0 }.map { key in
                    MotionEpoch(start: from.addingTimeInterval(Double(key) * 30), meanMovement: sums[key] / Double(counts[key]), sampleCount: counts[key])
                }
                return MotionRecording(id: id, start: from, end: to, epochs: epochs)
            }.value
            defer { exporting = false }
            guard recording.isValid else { status = "Motion data failed validation; nothing sent."; return }
            do {
                let url = recordURL.deletingLastPathComponent().appendingPathComponent("motion-\(id).json")
                try JSONEncoder().encode(recording).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try LocalRepository.protect(url)
                WCSession.default.transferFile(url, metadata: ["schema": 1])
                status = "Queued \(recording.epochs.count) motion epochs. Empty coverage is possible."
            } catch { status = "Couldn’t prepare motion: \(error.localizedDescription)" }
        }
    }
    private func sendMarker(end: Date?) {
        guard let start = state.markerStart else { return }
        var info: [String: Any] = ["schema": 1, "action": "marker", "id": state.id.uuidString, "start": start.timeIntervalSince1970]
        if let end { info["end"] = end.timeIntervalSince1970 }
        WCSession.default.transferUserInfo(info)
    }
    @discardableResult private func save() -> Bool {
        do {
            try JSONEncoder().encode(state).write(to: recordURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try LocalRepository.protect(recordURL); return true
        } catch { status = "Watch state couldn’t be saved."; return false }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) { receiveSummary(session.receivedApplicationContext) }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) { receiveSummary(applicationContext) }
    nonisolated private func receiveSummary(_ value: [String: Any]) {
        guard value["schema"] as? Int == 1 else { return }
        let seconds = value["asleep"] as? Double; let date = value["date"] as? Double
        Task { @MainActor in
            if let seconds, seconds.isFinite, seconds >= 0, let date, date.isFinite {
                self.summary = DurationText.hoursMinutes(seconds) + " asleep"; self.summaryDate = Date(timeIntervalSince1970: date)
            } else { self.summary = "Your nights, on iPhone"; self.summaryDate = nil }
        }
    }
    /// Nights started or ended on iPhone. Starting one here is only an in-bed marker: motion recording and gentle wake
    /// need this Watch's own confirmation, so a phone message never turns them on.
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard userInfo["schema"] as? Int == 1, let action = userInfo["action"] as? String,
              let id = (userInfo["id"] as? String).flatMap(UUID.init(uuidString:)) else { return }
        let watchID = (userInfo["watchID"] as? String).flatMap(UUID.init(uuidString:))
        let start = (userInfo["start"] as? Double).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
        Task { @MainActor in
            if action == "phoneStart", let start { self.applyPhoneStart(id: id, start: start) }
            if action == "phoneEnd" { self.applyPhoneEnd([id, watchID].compactMap { $0 }) }
        }
    }
    private func applyPhoneStart(id: UUID, start: Date) {
        guard self.start == nil, start > Date.now.addingTimeInterval(-18 * 3600), start <= Date.now.addingTimeInterval(60) else { return }
        state = PilotState(id: id, markerStart: start, startedOnPhone: true)
        guard save() else { return }
        self.start = start; status = "Started on iPhone. Ending it here ends it there too."
    }
    private func applyPhoneEnd(_ ids: [UUID]) {
        guard start != nil, ids.contains(state.id) else { return }
        end(notifyPhone: false)
        status = "Night ended on iPhone. Apple’s alarm is unchanged."
    }
    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        if error == nil { try? FileManager.default.removeItem(at: fileTransfer.file.fileURL) }
    }
}

private struct PilotState: Codable {
    var id = UUID()
    var markerStart: Date?
    var recordStart: Date?
    var latest: Date?
    var recordEnd: Date?
    var startedOnPhone: Bool?
}

/// CMSensorDataList only adopts NSFastEnumeration, which Swift's for-in can't use directly.
extension CMSensorDataList: @retroactive Sequence {
    public func makeIterator() -> NSFastEnumerationIterator { NSFastEnumerationIterator(self) }
}
