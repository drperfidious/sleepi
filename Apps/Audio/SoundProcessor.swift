import Foundation
@preconcurrency import AVFoundation
@preconcurrency import SoundAnalysis
import SleepiCore

/// All mutable audio state is confined to queue. Only immutable Float arrays cross the tap.
/// Backpressure is bounded; an overloaded classifier ends capture instead of accumulating RAM.
public final class SoundProcessor: NSObject, SNResultsObserving, @unchecked Sendable {
    private let queue = DispatchQueue(label: "sleepi.audio.analysis", qos: .utility)
    private let slots = DispatchSemaphore(value: 4)
    private let format: AVAudioFormat
    private let analyzer: SNAudioStreamAnalyzer
    private let request: SNClassifySoundRequest
    private let directory: URL
    private let started: Date
    private let onEvent: @MainActor @Sendable (SoundEvent) -> Void
    private let onFailure: @MainActor @Sendable (String) -> Void
    private var ring: PCMWindow
    private var position: Int64 = 0
    private var lastClipEnd: Int64 = 0
    private var bytesRemaining: Int
    private var running = true
    private var pending: Candidate?
    public let supportedLabels: [String]
    private struct Candidate {
        var start: Int64; var end: Int64; var kind: SoundKind; var confidence: Double
    }
    private static let labelMap: [String: SoundKind] = [
        "snoring": .snoring, "speech": .speech, "cough": .coughing, "coughing": .coughing,
        "dog_bark": .environment, "bark": .environment, "door_slam": .environment,
        "car_horn": .environment, "glass_breaking": .environment
    ]
    public init(sampleRate: Double, directory: URL, byteBudget: Int, started: Date = .now,
                onEvent: @escaping @MainActor @Sendable (SoundEvent) -> Void,
                onFailure: @escaping @MainActor @Sendable (String) -> Void) throws {
        guard sampleRate.isFinite, sampleRate >= 8000, sampleRate <= 192000,
              let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false) else { throw AudioProcessingError.unsupportedFormat }
        self.format = format; self.directory = directory; self.started = started; bytesRemaining = byteBudget
        self.onEvent = onEvent; self.onFailure = onFailure
        ring = PCMWindow(capacity: Int(sampleRate * 15))
        analyzer = SNAudioStreamAnalyzer(format: format)
        request = try SNClassifySoundRequest(classifierIdentifier: .version1)
        request.windowDuration = CMTime(value: 3, timescale: 2)
        request.overlapFactor = 0.5
        supportedLabels = request.knownClassifications.filter { Self.labelMap[$0] != nil }
        super.init()
        guard !supportedLabels.isEmpty else { throw AudioProcessingError.noLabels }
        try analyzer.add(request, withObserver: self)
    }
    public func ingest(_ samples: [Float]) {
        guard slots.wait(timeout: .now()) == .success else {
            queue.async { self.fail("Recording stopped: analysis couldn’t keep up.") }; return
        }
        queue.async {
            defer { self.slots.signal() }
            guard self.running else { return }
            guard !samples.isEmpty, samples.count <= Int(self.format.sampleRate * 2), samples.allSatisfy(\.isFinite) else {
                self.fail("Recording stopped: the microphone format changed."); return
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: self.format, frameCapacity: AVAudioFrameCount(samples.count)), let channel = buffer.floatChannelData?[0] else { return }
            buffer.frameLength = buffer.frameCapacity
            samples.withUnsafeBufferPointer { pointer in channel.update(from: pointer.baseAddress!, count: samples.count) }
            self.ring.append(samples)
            self.analyzer.analyze(buffer, atAudioFramePosition: self.position)
            self.position += Int64(samples.count)
            self.flushCandidate()
            if Double(self.position) / self.format.sampleRate >= 12 * 3600 { self.fail("Recording ended at the 12-hour limit.") }
        }
    }
    public func finish() async {
        await withCheckedContinuation { continuation in
            queue.async {
                // Pending incomplete highlights are discarded; no invented post-roll.
                self.running = false; self.pending = nil
                self.analyzer.removeAllRequests()
                self.ring = PCMWindow(capacity: 1)
                continuation.resume()
            }
        }
    }
    public func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let result = result as? SNClassificationResult else { return }
        let start = result.timeRange.start.seconds
        let end = CMTimeRangeGetEnd(result.timeRange).seconds
        guard start.isFinite, end.isFinite else { return }
        guard let match = result.classifications.first(where: { Self.labelMap[$0.identifier] != nil && $0.confidence >= 0.8 }), let kind = Self.labelMap[match.identifier] else { return }
        let confidence = match.confidence
        queue.async {
            guard self.running, self.pending == nil else { return }
            let a = Int64(start * self.format.sampleRate), b = Int64(end * self.format.sampleRate)
            guard a >= self.lastClipEnd, b > a else { return }
            self.pending = Candidate(start: a, end: b, kind: kind, confidence: confidence)
            self.flushCandidate()
        }
    }
    public func request(_ request: SNRequest, didFailWithError error: any Error) {
        queue.async { self.fail("Sound classification stopped. Open Tonight to start a new recording.") }
    }
    public func requestDidComplete(_ request: SNRequest) {}
    private func flushCandidate() {
        guard let candidate = pending else { return }
        let rate = format.sampleRate
        let a = max(lastClipEnd, candidate.start - Int64(2 * rate), 0)
        let b = min(candidate.end + Int64(3 * rate), a + Int64(10 * rate))
        guard b <= position else { return }
        pending = nil
        let available = ring.samples
        let base = position - Int64(available.count)
        guard a >= base, b > a else { return } // Classifier delay exceeded retained raw window.
        let frames = Array(available[Int(a - base)..<Int(b - base)])
        let level = PCMWindow.dbfs(frames)
        guard level >= -45 else { return }
        guard bytesRemaining >= 160_000 else { fail("Clip budget reached. Sound recording stopped."); return }
        let name = UUID().uuidString + ".m4a"
        let url = directory.appendingPathComponent(name)
        do {
            try write(frames, to: url)
            try LocalRepository.protect(url)
            let bytes = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
            guard bytes > 0, bytes <= bytesRemaining else {
                try FileManager.default.removeItem(at: url); fail("Clip budget reached. Sound recording stopped."); return
            }
            bytesRemaining -= bytes; lastClipEnd = b
            let event = SoundEvent(start: started.addingTimeInterval(Double(candidate.start) / rate), end: started.addingTimeInterval(Double(candidate.end) / rate), kind: candidate.kind, confidence: candidate.confidence, levelDBFS: level, fileName: name, byteCount: bytes)
            Task { @MainActor in self.onEvent(event) }
        } catch {
            try? FileManager.default.removeItem(at: url)
            fail("Recording stopped: a highlight couldn’t be saved.")
        }
    }
    private func write(_ frames: [Float], to url: URL) throws {
        guard let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames.count)), let channel = pcm.floatChannelData?[0] else { throw AudioProcessingError.unsupportedFormat }
        pcm.frameLength = pcm.frameCapacity
        frames.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: frames.count) }
        let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: format.sampleRate, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000], commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: pcm)
    }
    private func fail(_ message: String) {
        guard running else { return }; running = false
        Task { @MainActor in self.onFailure(message) }
    }
}

private enum AudioProcessingError: LocalizedError {
    case unsupportedFormat, noLabels
    var errorDescription: String? { self == .unsupportedFormat ? "This microphone format isn’t supported." : "The system classifier has no supported sound labels." }
}
