import ActivityKit
import Foundation

struct SleepActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var start: Date
        var soundRequested: Bool
    }
}
