import Foundation
import UIKit
import UserNotifications
@preconcurrency import AVFoundation
import SleepiCore
import SleepiUI
import SleepiAudio

@MainActor final class AudioRecorder: NSObject, AudioCapturing, @preconcurrency AVAudioPlayerDelegate {
    private var engine: AVAudioEngine?
    private var processor: SoundProcessor?
    private var player: AVAudioPlayer?
    private var playbackEnded: (@MainActor @Sendable () -> Void)?
    private var observations: [NSObjectProtocol] = []
    private var onStatus: (@MainActor @Sendable (String) -> Void)?
    var isRecording: Bool { engine?.isRunning == true }
    func start(directory: URL, remainingBytes: Int, onEvent: @escaping @MainActor @Sendable (SoundEvent) -> Void,
               onStats: @escaping @MainActor @Sendable (SoundSessionStats) -> Void,
               saveClips: Bool,
               onEpoch: @escaping @MainActor @Sendable (PhoneEpoch) -> Void,
               onStatus: @escaping @MainActor @Sendable (String) -> Void) async throws {
        guard UIApplication.shared.applicationState == .active else { throw RecordingError.foregroundRequired }
        guard await AVAudioApplication.requestRecordPermission() else { throw RecordingError.permissionDenied }
        // The first-run permission alert leaves the app briefly .inactive; only a move to the background revokes consent.
        guard UIApplication.shared.applicationState != .background else { throw RecordingError.foregroundRequired }
        await stop(); stopPlayback(); self.onStatus = onStatus
        let session = AVAudioSession.sharedInstance()
        do {
            // Mix with other apps so sleep sounds (white noise, rain) keep playing; .record would stop them.
            // Apple documents mixWithOthers for play-and-record in the default mode, so .measurement is dropped:
            // input may get system gain processing, which makes dBFS levels and the -45 dBFS gate less comparable.
            // defaultToSpeaker keeps other apps on the speaker instead of the receiver; A2DP keeps Bluetooth speakers.
            try session.setCategory(.playAndRecord, mode: .default, options: [.mixWithOthers, .defaultToSpeaker, .allowBluetoothA2DP])
            // An incoming-call banner shouldn't interrupt listening; the call itself still does.
            try? session.setPrefersNoInterruptionsFromSystemAlerts(true)
            try session.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0, !format.isInterleaved, format.commonFormat == .pcmFormatFloat32 else { throw RecordingError.format }
            let processor = try SoundProcessor(sampleRate: format.sampleRate, directory: directory, byteBudget: remainingBytes, onEvent: onEvent, onStats: onStats, saveClips: saveClips, onEpoch: onEpoch, onFailure: { [weak self] message in
                Task { @MainActor in await self?.stop(); self?.onStatus?(message) }
            })
            Self.installTap(on: input, format: format, feeding: processor)
            self.engine = engine; self.processor = processor
            engine.prepare(); try engine.start()
            onStatus("Listening · short highlights stay on this iPhone")
            installInterruptionHandlers()
        } catch { await stop(); throw error }
    }
    /// The tap runs on Core Audio's real-time thread. A closure written inside this @MainActor class inherits main-actor
    /// isolation, and Swift 6 asserts that isolation on entry, which crashed the app on the first buffer of every
    /// recording. Building the closure in a nonisolated context leaves it unisolated; it only touches the Sendable processor.
    nonisolated private static func installTap(on input: AVAudioInputNode, format: AVAudioFormat, feeding processor: SoundProcessor) {
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            guard let data = buffer.floatChannelData?[0] else { return }
            // Copy one microphone channel; the real-time callback does no file I/O or inference.
            processor.ingest(Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))))
        }
    }
    func stop() async {
        for observer in observations { NotificationCenter.default.removeObserver(observer) }; observations.removeAll()
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        engine = nil
        let oldProcessor = processor; processor = nil
        await oldProcessor?.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private var interrupted = false
    private func installInterruptionHandlers() {
        // A call, Clock or Calendar alarm, or Siri pauses capture; when it ends, listening resumes. If resuming fails
        // (iOS can refuse in the background), capture stops and one notification asks for a tap to resume.
        // A lost input device or a media-services reset ends capture. setCategory's own .categoryChange route
        // notification is delivered asynchronously and is ignored, since it ended fresh sessions before.
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification, .AVAudioEngineConfigurationChange] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let interruption = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
                let ends = Self.endsCapture(note)
                let isInterruption = note.name == AVAudioSession.interruptionNotification
                Task { @MainActor in
                    guard let self, let engine = self.engine else { return }
                    if isInterruption {
                        if interruption == .began { self.interrupted = true; self.onStatus?("Paused by a call or alarm · resumes when it ends") }
                        else { await self.resumeAfterInterruption() }
                        return
                    }
                    guard !self.interrupted else { return }
                    guard ends || !engine.isRunning else { return }
                    await self.stop()
                    self.onStatus?("Sound interrupted · end this session and start again to resume")
                }
            }
            observations.append(token)
        }
    }
    private func resumeAfterInterruption() async {
        interrupted = false
        guard let engine else { return }
        do {
            try AVAudioSession.sharedInstance().setActive(true)
            if !engine.isRunning { engine.prepare(); try engine.start() }
            onStatus?("Listening again · short highlights stay on this iPhone")
        } catch {
            await stop()
            onStatus?("sleepi stopped listening · open Tonight to resume")
            let content = UNMutableNotificationContent()
            content.title = "sleepi stopped listening"; content.body = "Tap to resume."
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "sleepi.listening", content: content, trigger: nil))
        }
    }
    nonisolated private static func endsCapture(_ note: Notification) -> Bool {
        switch note.name {
        case AVAudioSession.interruptionNotification:
            let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            return raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
        case AVAudioSession.routeChangeNotification:
            let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            switch raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:)) {
            // .override is excluded: only this app can override its own route, so it is never an outside interruption.
            case .newDeviceAvailable, .oldDeviceUnavailable, .noSuitableRouteForCategory: return true
            default: return false
            }
        case AVAudioSession.mediaServicesWereResetNotification: return true
        default: return false // Engine configuration changes are judged by whether the engine is still running.
        }
    }
    func play(_ url: URL, onEnded: @escaping @MainActor @Sendable () -> Void) throws {
        guard !isRecording else { return }
        stopPlayback()
        try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try AVAudioSession.sharedInstance().setActive(true)
        player = try AVAudioPlayer(contentsOf: url)
        playbackEnded = onEnded; player?.delegate = self
        player?.play()
    }
    func stopPlayback() { player?.stop(); player = nil; playbackEnded = nil; if !isRecording { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) } }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        let completion = playbackEnded; stopPlayback(); completion?()
    }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: (any Error)?) {
        let completion = playbackEnded; stopPlayback(); completion?()
    }
}
private enum RecordingError: LocalizedError {
    case permissionDenied, foregroundRequired, format
    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Microphone access is off. Enable it for sleepi in Settings to record highlights."
        case .foregroundRequired: "Open sleepi on the iPhone and confirm recording there."
        case .format: "This microphone route is not supported. Use your iPhone microphone."
        }
    }
}
