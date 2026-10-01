import Foundation
@preconcurrency import WatchConnectivity
import SleepiCore
import SleepiUI

@MainActor final class PhoneWatchBridge: NSObject, WCSessionDelegate {
    private weak var model: AppModel?
    init(model: AppModel) {
        self.model = model; super.init()
    }
    func activate() {
        if WCSession.isSupported() { WCSession.default.delegate = self; WCSession.default.activate() }
    }
    func sendSummary(_ night: SleepNight?) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        var value: [String: Any] = ["schema": 1]
        if let night { value["asleep"] = night.asleepSeconds; value["date"] = night.lastSleep?.timeIntervalSince1970 }
        try? WCSession.default.updateApplicationContext(value)
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in self.sendSummary(self.model?.nights.last) }
    }
    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}
    nonisolated func sessionDidDeactivate(_ session: WCSession) { session.activate() }
    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        guard let size = try? file.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 300_000,
              let data = try? Data(contentsOf: file.fileURL), let recording = try? JSONDecoder().decode(MotionRecording.self, from: data), recording.isValid else { return }
        Task { @MainActor in await self.model?.importMotion(recording) }
    }
    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        guard userInfo["schema"] as? Int == 1, userInfo["action"] as? String == "marker",
              let idString = userInfo["id"] as? String, let id = UUID(uuidString: idString), let start = userInfo["start"] as? Double, start.isFinite else { return }
        let end = (userInfo["end"] as? Double).flatMap { $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
        let date = Date(timeIntervalSince1970: start)
        Task { @MainActor in await self.model?.importWatchMarker(id: id, start: date, end: end) }
    }
}
