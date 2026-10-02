import Foundation
import Combine
@preconcurrency import WatchKit
@preconcurrency import CoreMotion
@preconcurrency import WatchConnectivity
import SleepiCore

@MainActor final class WatchPilot: NSObject, ObservableObject, @preconcurrency WKExtendedRuntimeSessionDelegate, WCSessionDelegate {
    static let shared = WatchPilot()
    @Published var start: Date?
    @Published var summary = "Your nights, on iPhone"
    @Published var summaryDate: Date?
    @Published var status = "Apple’s sleep tracking stays in charge."
    @Published var alerting = false
    @Published var exporting = false
    /// Window and sensitivity, kept in sync with the iPhone (the newer edit wins).
    @Published private(set) var wakeSettings = GentleWakeSettings()
    private var detector: WakeWindowDetector?
    private var snoozing = false
    /// Snooze is offered while the planned wake time is still ahead; after it, Apple's alarm takes over.
    var canSnooze: Bool { alerting && state.latest.flatMap { SnoozePlan.plan(now: .now, latest: $0) } != nil }
    private var wakeLog: WakeLog?
    /// Usual wake-up per weekday from the iPhone's Apple Watch history, and the times you confirmed per weekday.
    /// Wake times only, kept on this Watch; Apple's sleep schedule itself isn't readable by apps.
    private var usualWake: [Int: Int] = [:]
    private var picked: [Int: (minutes: Int, at: Date)] = [:]
    private var state = PilotState()
    private var runtime: WKExtendedRuntimeSession?
    private var motion = CMMotionManager()
    private var timer: Timer?
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
        loadWakeTimes()
        if let data = UserDefaults.standard.data(forKey: "gentleWakeSettings"), let saved = try? JSONDecoder().decode(GentleWakeSettings.self, from: data) { wakeSettings = saved }
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }
    /// Re-read every time the start sheet opens, so a changed pick or a fresh iPhone history is used, not a stale value.
    func suggestedWake(now: Date = .now) -> WakeSuggestion? {
        GentleWakePolicy.suggestion(now: now, picked: picked, usual: usualWake)
    }
    /// An edit made on this Watch: saved here and queued for the iPhone.
    func updateWakeSettings(windowMinutes: Int, sensitivity: WakeSensitivity) {
        let edited = GentleWakeSettings(windowMinutes: windowMinutes, sensitivity: sensitivity, updatedAt: .now)
        guard edited.windowMinutes != wakeSettings.windowMinutes || edited.sensitivity != wakeSettings.sensitivity else { return }
        applyWakeSettings(edited)
        if WCSession.isSupported(), WCSession.default.activationState == .activated, let data = try? JSONEncoder().encode(edited) {
            WCSession.default.transferUserInfo(["schema": 1, "action": "gentleWakeSettings", "settings": data])
        }
    }
    private func applyWakeSettings(_ settings: GentleWakeSettings) {
        wakeSettings = settings
        if let data = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(data, forKey: "gentleWakeSettings") }
    }
    func rememberPick(_ date: Date) {
        let calendar = Calendar.current
        let minutes = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        picked[calendar.component(.weekday, from: date)] = (minutes, .now)
        let defaults = UserDefaults.standard
        defaults.set(Dictionary(uniqueKeysWithValues: picked.map { (String($0.key), $0.value.minutes) }), forKey: "pickedWakeMinutes")
        defaults.set(Dictionary(uniqueKeysWithValues: picked.map { (String($0.key), $0.value.at.timeIntervalSince1970) }), forKey: "pickedWakeAt")
    }
    private func loadWakeTimes() {
        let defaults = UserDefaults.standard
        usualWake = Self.weekdayMinutes(defaults.dictionary(forKey: "usualWake"))
        let at = defaults.dictionary(forKey: "pickedWakeAt") as? [String: Double] ?? [:]
        for (day, minutes) in Self.weekdayMinutes(defaults.dictionary(forKey: "pickedWakeMinutes")) {
            if let time = at[String(day)] { picked[day] = (minutes, Date(timeIntervalSince1970: time)) }
        }
    }
    nonisolated private static func weekdayMinutes(_ raw: [String: Any]?) -> [Int: Int] {
        var result: [Int: Int] = [:]
        for (key, value) in raw ?? [:] {
            guard let day = Int(key), (1...7).contains(day), let minutes = value as? Int, (0..<1440).contains(minutes) else { continue }
            result[day] = minutes
        }
        return result
    }
    /// Gentle wake and motion recording are per-night experiments: both are off unless switched on in the start sheet.
    @discardableResult func begin(latest: Date?, recordMotion: Bool) -> Bool {
        guard start == nil else { return false }
        guard WKApplication.shared().applicationState == .active else { status = "Open sleepi to confirm a night."; return false }
        let now = Date.now
        var scheduledStart: Date?
        if let latest {
            guard let scheduled = GentleWakePolicy.start(latest: latest, now: now, windowMinutes: wakeSettings.windowMinutes) else { status = "Choose a wake time at least a few minutes ahead and within 36 hours."; return false }
            scheduledStart = scheduled
        }
        state = PilotState(id: UUID(), markerStart: now, recordStart: recordMotion ? now : nil, latest: latest,
                           sensitivity: latest == nil ? nil : wakeSettings.sensitivity)
        guard save() else { return false }
        start = now
        if recordMotion, CMSensorRecorder.isAccelerometerRecordingAvailable() {
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
        if start != nil { state.lastEndedID = state.id }
        state.markerStart = nil; state.latest = nil; state.atWakeTimeOnly = nil; state.recordEnd = end; start = nil
        _ = save()
        status = orphanedWake ? "Night ended. If the gentle wake still taps, press Stop. Apple’s alarm is unchanged." : "Night ended. Apple’s alarm is unchanged."
        // CMSensorRecorder has no stop API. The requested capture expires by itself.
    }
    /// Wake Up: stops the taps and ends the night on both devices.
    func wakeUp() {
        end(notifyPhone: true)
        status = "Good morning. Night ended on Watch and iPhone."
    }
    /// Snooze: stops the taps now and schedules the next smart-alarm session 10 minutes out, or at the wake time if
    /// that's sooner. Needs the app open, which it is when this button is tapped.
    func snooze() {
        guard alerting, let latest = state.latest, let plan = SnoozePlan.plan(now: .now, latest: latest),
              WKApplication.shared().applicationState == .active else { return }
        wakeLog?.outcome = .snoozed
        snoozing = true
        runtime?.invalidate(); runtime = nil; timer?.invalidate(); timer = nil; motion.stopAccelerometerUpdates(); alerting = false
        state.atWakeTimeOnly = plan.atWakeTimeOnly; _ = save()
        let session = WKExtendedRuntimeSession(); session.delegate = self; runtime = session
        session.start(at: plan.resumeAt)
        status = plan.atWakeTimeOnly ? "Snoozed. Next tap at \(latest.formatted(date: .omitted, time: .shortened))." : "Snoozed until \(plan.resumeAt.formatted(date: .omitted, time: .shortened))."
    }
    func extendedRuntimeSessionDidStart(_ extendedRuntimeSession: WKExtendedRuntimeSession) {
        runtime = extendedRuntimeSession
        guard let latest = state.latest else {
            // The night was ended after the app was terminated, so end() had no session handle to cancel.
            // Previously this fell through to `.now` and buzzed 25 minutes early. Apple documents invalidate() on a
            // scheduled session as an active-app call; whether this background call is honoured is a device check.
            extendedRuntimeSession.invalidate(); status = "Night already ended; gentle wake cancelled."; return
        }
        let sensitivity = state.sensitivity ?? wakeSettings.sensitivity
        let windowStart = Date.now
        detector = state.atWakeTimeOnly == true ? nil : WakeWindowDetector(windowStart: windowStart, latest: latest, sensitivity: sensitivity)
        wakeLog = WakeLog(windowStart: windowStart, latest: latest, windowMinutes: Int((latest.timeIntervalSince(windowStart) / 60).rounded()), sensitivity: sensitivity)
        let deadline = min(latest, (extendedRuntimeSession.expirationDate ?? latest).addingTimeInterval(-5))
        timer?.invalidate()
        if deadline <= .now { alert(.deadline); return }
        timer = Timer.scheduledTimer(withTimeInterval: deadline.timeIntervalSinceNow, repeats: false) { [weak self] _ in Task { @MainActor in self?.alert(.deadline) } }
        if detector != nil, motion.isAccelerometerAvailable {
            // 10 Hz: enough to count movement per 30-second epoch; WakeWindowDetector decides when restlessness is sustained.
            motion.accelerometerUpdateInterval = 0.1
            motion.startAccelerometerUpdates(to: .main) { [weak self] data, _ in
                guard let data else { return }
                MainActor.assumeIsolated {
                    guard let self, !self.alerting else { return }
                    let a = data.acceleration
                    if self.detector?.add(magnitude: sqrt(a.x * a.x + a.y * a.y + a.z * a.z), at: .now) == true { self.alert(.movement) }
                }
            }
        }
    }
    func extendedRuntimeSessionWillExpire(_ extendedRuntimeSession: WKExtendedRuntimeSession) { alert(.deadline) }
    func extendedRuntimeSession(_ extendedRuntimeSession: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: (any Error)?) {
        finishWakeLog()
        // A snooze already scheduled the next session; this callback is for the one it replaced.
        if snoozing { snoozing = false; return }
        guard extendedRuntimeSession === runtime else { return } // ended by Wake Up or End tonight
        let wasAlerting = alerting
        timer?.invalidate(); timer = nil; motion.stopAccelerometerUpdates(); runtime = nil; alerting = false
        if wasAlerting, start != nil, error == nil {
            // Stop on the system alarm screen means the same as Wake Up: the night ends on both devices.
            wakeUp(); return
        }
        state.latest = nil; _ = save()
        status = error == nil ? "Gentle-wake session ended. Apple’s alarm is unchanged." : "Gentle wake was interrupted. Rely on your Clock alarm."
    }
    private func alert(_ outcome: WakeLog.Outcome) {
        guard let runtime, runtime.state == .running, !alerting else { return }
        alerting = true; motion.stopAccelerometerUpdates(); timer?.invalidate()
        wakeLog?.tappedAt = .now; wakeLog?.outcome = outcome
        // A nil handler repeats every 3 s until dismissed. Every 10 s keeps it a nudge; Apple's Clock alarm is the alarm.
        // @Sendable keeps the handler unisolated: WatchKit may call it off the main thread, where a main-actor
        // closure would trip Swift 6's isolation check (the same crash the iPhone audio tap had).
        runtime.notifyUser(hapticType: .notification) { @Sendable _ in 10 }
        status = "Gentle wake · Wake Up ends the night, Snooze waits 10 min."
    }
    /// Saves tonight's inputs and decision and queues them for the iPhone, where the log can be shared for tuning.
    private func finishWakeLog() {
        guard var log = wakeLog else { return }
        wakeLog = nil
        log.epochs = detector?.epochs ?? []; detector = nil
        if log.outcome == nil { log.outcome = .endedEarly }
        guard log.isValid, let data = try? JSONEncoder().encode(log) else { return }
        let url = recordURL.deletingLastPathComponent().appendingPathComponent("wake-\(log.id).json")
        do {
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try LocalRepository.protect(url)
            WCSession.default.transferFile(url, metadata: ["schema": 1, "kind": "wakeLog"])
        } catch { status = "Couldn’t save tonight’s gentle-wake log." }
    }
    func exportMotion() {
        guard !exporting, let from = state.recordStart else { return }
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
        // Queued delivery is guaranteed but can wait until iOS wakes sleepi; a live message reaches a reachable
        // iPhone right away. The iPhone ignores whichever copy arrives second.
        WCSession.default.transferUserInfo(info)
        if WCSession.default.isReachable { WCSession.default.sendMessage(info, replyHandler: nil, errorHandler: nil) }
    }
    @discardableResult private func save() -> Bool {
        do {
            try JSONEncoder().encode(state).write(to: recordURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try LocalRepository.protect(recordURL); return true
        } catch { status = "Watch state couldn’t be saved."; return false }
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) { receiveSummary(session.receivedApplicationContext) }
    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) { receiveSummary(applicationContext) }
    /// Brings the Watch up to date with the iPhone's latest state before choosing a screen, so a night already
    /// running on the iPhone opens on its timer instead of the setup sheet. Nothing is started here.
    func syncWithPhone() async {
        guard WCSession.isSupported() else { return }
        for _ in 0..<20 where WCSession.default.activationState != .activated { try? await Task.sleep(for: .milliseconds(100)) }
        guard WCSession.default.activationState == .activated else { return }
        applyPhoneNight(Self.phoneNight(WCSession.default.receivedApplicationContext))
    }
    private struct PhoneNight: Sendable { var known: Bool; var id: UUID?; var start: Date? }
    nonisolated private static func phoneNight(_ value: [String: Any]) -> PhoneNight {
        guard value["schema"] as? Int == 1, value["nightState"] as? Int == 1 else { return PhoneNight(known: false) }
        let night = value["activeNight"] as? [String: Any]
        return PhoneNight(known: true, id: (night?["id"] as? String).flatMap(UUID.init(uuidString:)),
                          start: (night?["start"] as? Double).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil })
    }
    private func applyPhoneNight(_ night: PhoneNight) {
        guard night.known else { return }
        if let id = night.id, let begun = night.start {
            if start == nil, id != state.lastEndedID { applyPhoneStart(id: id, start: begun) }
        } else if start != nil, state.startedOnPhone == true {
            end(notifyPhone: false); status = "Night ended on iPhone. Apple’s alarm is unchanged."
        }
    }
    nonisolated private func receiveSummary(_ value: [String: Any]) {
        guard value["schema"] as? Int == 1 else { return }
        let phoneNight = Self.phoneNight(value)
        let seconds = value["asleep"] as? Double; let date = value["date"] as? Double
        let usual = Self.weekdayMinutes(value["usualWake"] as? [String: Any])
        let settings = (value["gentleWake"] as? Data).flatMap { try? JSONDecoder().decode(GentleWakeSettings.self, from: $0) }
        Task { @MainActor in
            self.applyPhoneNight(phoneNight)
            if let settings, settings.updatedAt > self.wakeSettings.updatedAt { self.applyWakeSettings(GentleWakeSettings(windowMinutes: settings.windowMinutes, sensitivity: settings.sensitivity, updatedAt: settings.updatedAt)) }
            // A night without history (or a failed Health read) on iPhone keeps the last known times instead of erasing them.
            if !usual.isEmpty {
                self.usualWake = usual
                UserDefaults.standard.set(Dictionary(uniqueKeysWithValues: usual.map { (String($0.key), $0.value) }), forKey: "usualWake")
            }
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
    var sensitivity: WakeSensitivity?
    var startedOnPhone: Bool?
    /// After a snooze close to the wake time, the next taps come at the wake time only.
    var atWakeTimeOnly: Bool?
    /// The night ended here last, so a stale iPhone state can't bring it back.
    var lastEndedID: UUID?
}

/// CMSensorDataList only adopts NSFastEnumeration, which Swift's for-in can't use directly.
extension CMSensorDataList: @retroactive Sequence {
    public func makeIterator() -> NSFastEnumerationIterator { NSFastEnumerationIterator(self) }
}
