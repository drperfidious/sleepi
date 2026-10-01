import Foundation
import UIKit
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
               onStatus: @escaping @MainActor @Sendable (String) -> Void) async throws {
        guard UIApplication.shared.applicationState == .active else { throw RecordingError.foregroundRequired }
        guard await AVAudioApplication.requestRecordPermission() else { throw RecordingError.permissionDenied }
        guard UIApplication.shared.applicationState == .active else { throw RecordingError.foregroundRequired }
        await stop(); stopPlayback(); self.onStatus = onStatus
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.record, mode: .measurement, options: [])
            try session.setActive(true)
            let engine = AVAudioEngine()
            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard format.channelCount > 0, format.sampleRate > 0, !format.isInterleaved, format.commonFormat == .pcmFormatFloat32 else { throw RecordingError.format }
            let processor = try SoundProcessor(sampleRate: format.sampleRate, directory: directory, byteBudget: remainingBytes, onEvent: onEvent, onFailure: { [weak self] message in
                Task { @MainActor in await self?.stop(); self?.onStatus?(message) }
            })
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                guard let data = buffer.floatChannelData?[0] else { return }
                // Copy one microphone channel; the real-time callback does no file I/O or inference.
                processor.ingest(Array(UnsafeBufferPointer(start: data, count: Int(buffer.frameLength))))
            }
            self.engine = engine; self.processor = processor
            engine.prepare(); try engine.start()
            onStatus("Listening · short highlights stay on this iPhone")
            installInterruptionHandlers()
        } catch { await stop(); throw error }
    }
    func stop() async {
        for observer in observations { NotificationCenter.default.removeObserver(observer) }; observations.removeAll()
        if let engine { engine.inputNode.removeTap(onBus: 0); engine.stop() }
        engine = nil
        let oldProcessor = processor; processor = nil
        await oldProcessor?.finish()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    private func installInterruptionHandlers() {
        // A call, alarm, Siri, route change or reset ends capture. Resumption needs a new foreground action.
        // This conservative policy avoids a reassuring 'recording' state after the engine has stopped.
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification, AVAudioSession.mediaServicesWereResetNotification, AVAudioEngine.configurationChangeNotification] {
            let token = NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.engine != nil else { return }
                    await self.stop()
                    self.onStatus?("Sound interrupted · end this session and start again to resume")
                }
            }
            observations.append(token)
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
