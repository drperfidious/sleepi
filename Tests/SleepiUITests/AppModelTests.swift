import Foundation
import Testing
import SleepiCore
@testable import SleepiUI

@MainActor private final class FakeHealth: HealthReading {
    var requested = false
    var next = HealthSnapshot(samples: [])
    var locked = false
    func requestAccess() async throws { requested = true }
    func fetch() async throws -> HealthSnapshot { if locked { throw HealthLocked() }; return next }
    func observe(_ update: @escaping @MainActor @Sendable () async -> Void) {}
}
@MainActor private final class FakeAudio: AudioCapturing {
    var isRecording = false
    var starts = 0
    var fail = false
    var eventCallback: (@MainActor @Sendable (SoundEvent) -> Void)?
    var playbackEnded: (@MainActor @Sendable () -> Void)?
    var statsCallback: (@MainActor @Sendable (SoundSessionStats) -> Void)?
    func start(directory: URL, remainingBytes: Int, onEvent: @escaping @MainActor @Sendable (SoundEvent) -> Void, onStats: @escaping @MainActor @Sendable (SoundSessionStats) -> Void, onStatus: @escaping @MainActor @Sendable (String) -> Void) async throws {
        statsCallback = onStats
        if fail { throw NSError(domain: "test", code: 1) }
        starts += 1; isRecording = true; eventCallback = onEvent
    }
    func stop() async { isRecording = false }
    func play(_ url: URL, onEnded: @escaping @MainActor @Sendable () -> Void) throws { playbackEnded = onEnded }
    func stopPlayback() {}
}

@Test @MainActor func markerDoesNotStartMicrophoneAndRepeatedStartsAreIdempotent() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = FakeAudio(), health = FakeHealth()
    let model = AppModel(health: health, audio: audio, directory: dir)
    await model.load()
    #expect(audio.starts == 0); #expect(!health.requested)
    await model.startTonight(sound: false); await model.startTonight(sound: true)
    #expect(model.state.sessions.count == 1); #expect(audio.starts == 0)
    await model.stopTonight(); #expect(model.activeSession == nil)
}
@Test @MainActor func deniedAudioDoesNotLeaveAnActiveNight() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = FakeAudio(); audio.fail = true
    let model = AppModel(audio: audio, directory: dir); await model.load(); await model.startTonight(sound: true)
    #expect(model.activeSession == nil); #expect(model.error != nil)
}
@Test @MainActor func deletedHealthSamplesDisappearOnRefresh() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let health = FakeHealth(); health.next = DemoData.snapshot()
    let model = AppModel(health: health, directory: dir); await model.load(); await model.connect()
    #expect(!model.nights.isEmpty)
    health.next = HealthSnapshot(samples: []); await model.refresh()
    #expect(model.nights.isEmpty); #expect(!model.healthStatus.contains("denied"))
}
@Test @MainActor func restartEndsUnverifiedActiveSession() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = AppModel(directory: dir); await first.load(); await first.startTonight(sound: false)
    let second = AppModel(directory: dir); await second.load()
    #expect(second.activeSession == nil)
    #expect(second.state.sessions.last?.status.contains("Interrupted") == true)
}
@Test @MainActor func deletionRejectsLateAudioEvents() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = FakeAudio()
    let active = AppModel(audio: audio, directory: dir); await active.load(); await active.startTonight(sound: true)
    await active.deleteLocalData()
    audio.eventCallback?(SoundEvent(start: .now, end: .now, kind: .speech, confidence: 1, levelDBFS: -10))
    #expect(active.state.sounds.isEmpty); #expect(!audio.isRecording)
}

@Test @MainActor func overnightVitalsExcludeDaytimeMeasurements() async throws {
    let model = AppModel(demo: true)
    let night = model.nights.last!
    model.snapshot.vitals = [VitalReading(kind: .heartRate, date: night.windowStart.addingTimeInterval(60), value: 150), VitalReading(kind: .heartRate, date: night.firstSleep!.addingTimeInterval(60), value: 50)]
    #expect(model.vital(.heartRate, night: night)?.value == 50)
    #expect(model.vital(.heartRate, night: night)?.count == 1)
}

@Test @MainActor func deletionRejectsOlderQueuedWatchTransfers() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = AppModel(directory: dir); await model.load()
    let start = Date.now.addingTimeInterval(-3600)
    await model.deleteLocalData()
    await model.importMotion(MotionRecording(id: UUID(), start: start, end: start.addingTimeInterval(600), epochs: []))
    await model.importWatchMarker(id: UUID(), start: start, end: start.addingTimeInterval(600))
    #expect(model.state.motionNights.isEmpty); #expect(model.state.sessions.isEmpty)
}

@Test @MainActor func playbackCompletionClearsSelectedClip() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = FakeAudio(); let model = AppModel(audio: audio, directory: dir); await model.load()
    let event = SoundEvent(start: .now, end: .now, kind: .snoring, confidence: 1, levelDBFS: -20, fileName: "test.m4a", byteCount: 10)
    await model.play(event); #expect(model.playingID == event.id)
    audio.playbackEnded?(); #expect(model.playingID == nil)
}

@Test @MainActor func nightlySummaryVitalStartingBeforeFirstSleepIsShown() async throws {
    // Apple's wrist temperature sample spans the sleep session, which usually begins before the first asleep segment.
    let model = AppModel(demo: true)
    let night = model.nights.last!
    let start = night.firstSleep!.addingTimeInterval(-600), end = night.lastSleep!
    model.snapshot.vitals = [VitalReading(kind: .wristTemperature, date: start, end: end, value: 35.6),
                             VitalReading(kind: .wristTemperature, date: night.windowStart, end: night.windowStart.addingTimeInterval(60), value: 34)]
    #expect(model.vital(.wristTemperature, night: night)?.value == 35.6)
    #expect(model.vital(.wristTemperature, night: night)?.count == 1)
}

@Test @MainActor func failedLibraryLoadCanBeRetried() async throws {
    // A launch without a scene can run before first unlock; the scene's later load() must be able to recover.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = AppModel(directory: dir)
    let library = dir.appendingPathComponent("library.json")
    try Data("unreadable".utf8).write(to: library)
    await model.load()
    #expect(model.error != nil)
    var saved = LocalState(); saved.settings.targetHours = 7
    try JSONEncoder().encode(saved).write(to: library)
    await model.load()
    #expect(model.error == nil); #expect(model.state.settings.targetHours == 7)
}

@MainActor private final class SyncLog { var events: [SessionSyncEvent] = [] }

@Test @MainActor func nightStartedOnWatchIsActiveOnIPhoneWithoutMicrophone() async throws {
    // Regression: a Watch start used to arrive as an already-ended marker, so the two devices disagreed.
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = FakeAudio(); let model = AppModel(audio: audio, directory: dir); await model.load()
    let id = UUID(), start = Date.now.addingTimeInterval(-600)
    await model.importWatchMarker(id: id, start: start, end: nil)
    await model.importWatchMarker(id: id, start: start, end: nil)
    #expect(model.state.sessions.count == 1); #expect(model.activeSession?.id == id)
    #expect(model.activeSession?.origin == .watch); #expect(audio.starts == 0)
    await model.addSoundToTonight()
    #expect(audio.starts == 1); #expect(model.activeSession?.requestedAudio == true)
    await model.importWatchMarker(id: id, start: start, end: .now)
    #expect(model.activeSession == nil); #expect(!audio.isRecording)
}

@Test @MainActor func endingOnIPhoneEndsTheWatchNightAndWatchNightsSurviveRestart() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let first = AppModel(directory: dir); await first.load()
    let id = UUID()
    await first.importWatchMarker(id: id, start: .now.addingTimeInterval(-600), end: nil)
    let restarted = AppModel(directory: dir); await restarted.load()
    #expect(restarted.activeSession?.id == id) // still running on the Watch
    let log = SyncLog(); restarted.onSessionSync = { log.events.append($0) }
    await restarted.stopTonight()
    #expect(restarted.activeSession == nil)
    guard case .ended(let night)? = log.events.last else { Issue.record("Watch was not told the night ended"); return }
    #expect(night.id == id)
}

@Test @MainActor func nightsStartedOnBothDevicesStayOneNight() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = FakeAudio(); let model = AppModel(audio: audio, directory: dir); await model.load()
    let log = SyncLog(); model.onSessionSync = { log.events.append($0) }
    await model.startTonight(sound: true)
    guard case .started? = log.events.last else { Issue.record("Watch was not told the night started"); return }
    let watchID = UUID(), start = Date.now.addingTimeInterval(-60)
    await model.importWatchMarker(id: watchID, start: start, end: nil)
    #expect(model.state.sessions.count == 1); #expect(model.activeSession?.watchID == watchID)
    await model.importWatchMarker(id: watchID, start: start, end: .now)
    #expect(model.activeSession == nil); #expect(!audio.isRecording)
}

@Test @MainActor func gentleWakeSettingsSyncNewerEditWinsAndLogsAreKept() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = AppModel(directory: dir); await model.load()
    var sent = 0; model.onGentleWakeChanged = { sent += 1 }
    await model.setGentleWake(windowMinutes: 15, sensitivity: .lessMovement)
    #expect(model.gentleWake.windowMinutes == 15); #expect(sent == 1)
    await model.importGentleWake(GentleWakeSettings(windowMinutes: 30, updatedAt: .now.addingTimeInterval(-3600)))
    #expect(model.gentleWake.windowMinutes == 15) // an older Watch edit can't undo a newer iPhone one
    await model.importGentleWake(GentleWakeSettings(windowMinutes: 20, updatedAt: .now))
    #expect(model.gentleWake.windowMinutes == 20)
    var log = WakeLog(windowStart: .now.addingTimeInterval(-1500), latest: .now, windowMinutes: 25, sensitivity: .standard)
    log.outcome = .deadline
    await model.importWakeLog(log); await model.importWakeLog(log)
    #expect(model.wakeLogs.count == 1)
    let reopened = AppModel(directory: dir); await reopened.load()
    #expect(reopened.wakeLogs.count == 1); #expect(reopened.gentleWake.windowMinutes == 20)
}

@Test @MainActor func nightTheWatchStoppedIsLeftOutOfTrendsUnlessIncluded() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = AppModel(directory: dir); await model.load()
    let bed = Calendar.current.startOfDay(for: .now).addingTimeInterval(-2 * 3600), stop = bed.addingTimeInterval(4 * 3600) // 22:00 to 02:00
    model.nights = NightBuilder.build(samples: [SleepSample(start: bed.addingTimeInterval(600), end: stop, stage: .core)])
    model.snapshot.vitals = [VitalReading(kind: .heartRate, date: stop.addingTimeInterval(-120), value: 55)]
    var night = TonightSession(start: bed, requestedAudio: false); night.end = bed.addingTimeInterval(9 * 3600); model.state.sessions = [night]
    let stopped = try #require(model.nights.last)
    #expect(model.watchStop(for: stopped)?.excludesFromAverages == true)
    #expect(model.trendNights.isEmpty)
    await model.setIncludedAnyway(stopped, true)
    #expect(model.trendNights.count == 1)
}

@Test @MainActor func lockedHealthAfterUnlockKeepsNightsAndShowsNoAlert() async throws {
    // Regression: unlocking the iPhone refreshed before Health was readable and popped "Protected health data is inaccessible".
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let health = FakeHealth(); health.next = DemoData.snapshot()
    let model = AppModel(health: health, directory: dir); await model.load(); await model.connect()
    let count = model.nights.count
    health.locked = true; await model.refresh()
    #expect(model.error == nil); #expect(model.nights.count == count)
}

@Test @MainActor func gentleWakeChosenOnIPhoneTravelsWithTheNightOnlyWhenAWatchIsThere() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = AppModel(directory: dir); await model.load()
    let log = SyncLog(); model.onSessionSync = { log.events.append($0) }
    let wake = Date.now.addingTimeInterval(8 * 3600)
    await model.startTonight(sound: false, gentleWake: wake)
    #expect(model.activeSession?.gentleWakeRequested == nil) // no Watch paired
    await model.stopTonight()
    model.watchAvailable = true
    await model.startTonight(sound: false, gentleWake: wake)
    guard case .started(let night)? = log.events.last else { Issue.record("Watch not told"); return }
    #expect(night.gentleWakeRequested == wake)
}

@Test @MainActor func listeningSummaryIsKeptWithTheNightAfterItEnds() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let audio = FakeAudio(); let model = AppModel(audio: audio, directory: dir); await model.load()
    await model.startTonight(sound: true); await model.stopTonight()
    var heard = SoundSessionStats(); heard.listenedSeconds = 7 * 3600; heard.nearMisses = 3
    audio.statsCallback?(heard) // the final summary arrives just after stopping
    #expect(model.state.sessions.last?.soundStats == heard)
}

@Test @MainActor func oldDefaultTagsMigrateKeepingHistoryAndMergeMovesNights() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    var legacy = LocalState()
    legacy.tags = ["Late caffeine", "Alcohol", "Late meal", "Movement", "Stress", "Reading"].map(JournalTag.init)
    var entry = NightJournal(nightID: .now); entry.tagIDs = [legacy.tags[0].id]; legacy.journals = [entry]
    try await LocalRepository(directory: dir).save(legacy)
    let model = AppModel(directory: dir); await model.load()
    #expect(model.state.tags[0].id == legacy.tags[0].id); #expect(model.state.tags[0].name == "Caffeine after 2 pm")
    #expect(model.visibleTags.contains { $0.name == "Unwell" }); #expect(!model.visibleTags.contains { $0.name == "Reading" })
    await model.merge(model.state.tags[0], into: model.state.tags[1])
    #expect(model.state.journals[0].tagIDs == [legacy.tags[1].id])
}

@Test @MainActor func libraryIsBackedUpAndOnlyUnstarredClipsAreLeftOut() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = AppModel(directory: dir); await model.load(); await model.persist()
    let library = dir.appendingPathComponent("library.json")
    #expect(try library.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == false)
    let clip = dir.appendingPathComponent("Clips/test.m4a")
    try Data([1]).write(to: clip); try LocalRepository.setExcludedFromBackup(clip, true)
    model.state.sounds = [SoundEvent(start: .now, end: .now, kind: .snoring, confidence: 1, levelDBFS: -20, fileName: "test.m4a", byteCount: 1)]
    await model.toggleStar(model.state.sounds[0])
    #expect(try clip.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == false)
}
