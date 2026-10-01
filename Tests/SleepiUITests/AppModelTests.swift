import Foundation
import Testing
import SleepiCore
@testable import SleepiUI

@MainActor private final class FakeHealth: HealthReading {
    var requested = false
    var next = HealthSnapshot(samples: [])
    func requestAccess() async throws { requested = true }
    func fetch() async throws -> HealthSnapshot { next }
    func observe(_ update: @escaping @MainActor @Sendable () async -> Void) {}
}
@MainActor private final class FakeAudio: AudioCapturing {
    var isRecording = false
    var starts = 0
    var fail = false
    var eventCallback: (@MainActor @Sendable (SoundEvent) -> Void)?
    var playbackEnded: (@MainActor @Sendable () -> Void)?
    func start(directory: URL, remainingBytes: Int, onEvent: @escaping @MainActor @Sendable (SoundEvent) -> Void, onStatus: @escaping @MainActor @Sendable (String) -> Void) async throws {
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
