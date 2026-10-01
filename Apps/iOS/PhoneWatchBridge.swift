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
    func sendSummary(_ night: SleepNight?, usualWake: [Int: Int]) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated else { return }
        var value: [String: Any] = ["schema": 1]
        if let night { value["asleep"] = night.asleepSeconds; value["date"] = night.lastSleep?.timeIntervalSince1970 }
        if !usualWake.isEmpty { value["usualWake"] = Dictionary(uniqueKeysWithValues: usualWake.map { (String($0.key), $0.value) }) }
        try? WCSession.default.updateApplicationContext(value)
    }
    /// Queued, guaranteed delivery: a night started or ended here starts or ends it on the Watch, even if the Watch
    /// app isn't running right now. The Watch never starts motion or a gentle wake from this message.
    func send(_ event: SessionSyncEvent) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated,
              WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }
        var info: [String: Any] = ["schema": 1]
        switch event {
        case .started(let night):
            info["action"] = "phoneStart"; info["id"] = night.id.uuidString; info["start"] = night.start.timeIntervalSince1970
        case .ended(let night):
            info["action"] = "phoneEnd"; info["id"] = night.id.uuidString
            if let watchID = night.watchID { info["watchID"] = watchID.uuidString }
        }
        WCSession.default.transferUserInfo(info)
    }
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in self.sendSummary(self.model?.nights.last, usualWake: self.model?.usualWake ?? [:]) }
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
