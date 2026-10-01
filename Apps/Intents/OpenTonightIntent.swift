import AppIntents
import Foundation

extension Notification.Name { static let sleepiOpenTonight = Notification.Name("sleepi.openTonight") }
@MainActor enum TonightRoute {
    // OpenIntent runs in the foreground host. Retain the route until a cold-launch scene exists.
    static var pending = false
    static func request() { pending = true; NotificationCenter.default.post(name: .sleepiOpenTonight, object: nil) }
    static func consume() -> Bool { let value = pending; pending = false; return value }
}
enum SleepiDestination: String, AppEnum {
    case tonight
    static let typeDisplayRepresentation = TypeDisplayRepresentation("sleepi screen")
    static let caseDisplayRepresentations: [SleepiDestination: DisplayRepresentation] = [.tonight: "Tonight"]
}
struct OpenTonightIntent: OpenIntent {
    static let title: LocalizedStringResource = "Open Tonight in sleepi"
    static let description = IntentDescription("Opens the Tonight choice screen. Recording requires confirmation in the app.")
    static let openAppWhenRun = true
    @Parameter(title: "Screen", default: .tonight) var target: SleepiDestination
    @MainActor func perform() async throws -> some IntentResult { TonightRoute.request(); return .result() }
}
