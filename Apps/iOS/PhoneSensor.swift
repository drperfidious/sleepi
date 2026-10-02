import UIKit
@preconcurrency import CoreMotion
@preconcurrency import AVFoundation
import SleepiCore
import SleepiUI

/// The iPhone's own signals for phone-only nights. Motion is used only to notice the phone being picked up or moved
/// (it sits on the bed stand); unlock/lock, plug/unplug and opening sleepi mark phone use. Counts and events only.
@MainActor final class PhoneSensor: PhoneSensing {
    private let motion = CMMotionManager()
    private let queue: OperationQueue = { let q = OperationQueue(); q.maxConcurrentOperationCount = 1; q.qualityOfService = .utility; return q }()
    private var observers: [NSObjectProtocol] = []
    private var recorderFallback = false

    func start(onMotion: @escaping @MainActor @Sendable (PhoneEpoch) -> Void, onEvent: @escaping @MainActor @Sendable (PhoneEvent) -> Void) {
        stopObserving()
        UIDevice.current.isBatteryMonitoringEnabled = true
        let center = NotificationCenter.default
        // The kind is worked out before hopping onto the main actor, so the (non-Sendable) notification never crosses.
        func observe(_ name: Notification.Name, _ kind: @escaping @Sendable (Notification) -> PhoneEvent.Kind?) {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { note in
                let k = kind(note)
                MainActor.assumeIsolated { if let k { onEvent(PhoneEvent(k, at: .now)) } }
            })
        }
        // These fire only with a passcode set; without one, opening sleepi still counts as phone use.
        observe(UIApplication.protectedDataDidBecomeAvailableNotification) { _ in .unlocked }
        observe(UIApplication.protectedDataWillBecomeUnavailableNotification) { _ in .locked }
        observers.append(center.addObserver(forName: UIDevice.batteryStateDidChangeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated {
                switch UIDevice.current.batteryState {
                case .charging, .full: onEvent(PhoneEvent(.pluggedIn, at: .now))
                case .unplugged: onEvent(PhoneEvent(.unplugged, at: .now))
                default: break
                }
            }
        })
        observe(UIApplication.didBecomeActiveNotification) { _ in .appOpened }
        observe(UIApplication.willResignActiveNotification) { _ in .appClosed }
        observe(AVAudioSession.interruptionNotification) { note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            return type == .began ? .listeningStopped : .listeningResumed
        }
        if UIApplication.shared.applicationState == .active { onEvent(PhoneEvent(.appOpened, at: .now)) }
        if motion.isAccelerometerAvailable { Self.startMotion(motion, queue: queue, onMotion: onMotion) }
        // Backup if live motion updates stop while locked: the system recorder keeps 50 Hz samples (max 12 h).
        if CMSensorRecorder.isAccelerometerRecordingAvailable() {
            CMSensorRecorder().recordAccelerometer(forDuration: 12 * 3600); recorderFallback = true
        }
    }

    func stop(nightStart: Date) async -> [PhoneEpoch] {
        motion.stopAccelerometerUpdates(); stopObserving()
        UIDevice.current.isBatteryMonitoringEnabled = false
        guard recorderFallback else { return [] }
        recorderFallback = false
        let end = Date.now
        return await Task.detached(priority: .utility) { Self.recordedEpochs(from: nightStart, to: end) }.value
    }

    private func stopObserving() {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
    }

    /// Built outside the main actor: the handler runs on a background queue, where a main-actor closure would trip
    /// Swift 6's isolation check (the crash the audio tap had).
    nonisolated private static func startMotion(_ motion: CMMotionManager, queue: OperationQueue, onMotion: @escaping @MainActor @Sendable (PhoneEpoch) -> Void) {
        let box = AccumulatorBox()
        motion.accelerometerUpdateInterval = 0.1 // 10 Hz
        motion.startAccelerometerUpdates(to: queue) { data, _ in
            guard let a = data?.acceleration else { return }
            if let epoch = box.add(sqrt(a.x * a.x + a.y * a.y + a.z * a.z), at: .now) {
                Task { @MainActor in onMotion(epoch) }
            }
        }
    }

    nonisolated private static func recordedEpochs(from start: Date, to end: Date) -> [PhoneEpoch] {
        guard let list = CMSensorRecorder().accelerometerData(from: start, to: min(end, start.addingTimeInterval(12 * 3600))) else { return [] }
        var accumulator = MotionEpochAccumulator(), out: [PhoneEpoch] = []
        for case let point as CMRecordedAccelerometerData in list {
            let a = point.acceleration
            if let e = accumulator.add(magnitude: sqrt(a.x * a.x + a.y * a.y + a.z * a.z), at: point.startDate) {
                out.append(PhoneEpoch(start: e.start, motion: e.motion, jerk: e.jerk))
            }
        }
        return out
    }
}

private final class AccumulatorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var accumulator = MotionEpochAccumulator()
    func add(_ magnitude: Double, at time: Date) -> PhoneEpoch? {
        lock.lock(); defer { lock.unlock() }
        return accumulator.add(magnitude: magnitude, at: time).map { PhoneEpoch(start: $0.start, motion: $0.motion, jerk: $0.jerk) }
    }
}

/// CMSensorDataList only adopts NSFastEnumeration.
extension CMSensorDataList: @retroactive Sequence {
    public func makeIterator() -> NSFastEnumerationIterator { NSFastEnumerationIterator(self) }
}
