import SwiftUI
import WidgetKit
import AppIntents
import ActivityKit

@main struct SleepiWidgetBundle: WidgetBundle {
    var body: some Widget {
        TonightWidget()
        TonightControl()
        SleepiLiveActivity()
    }
}

struct TonightEntry: TimelineEntry { let date: Date }
struct TonightProvider: TimelineProvider {
    func placeholder(in context: Context) -> TonightEntry { TonightEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (TonightEntry) -> Void) { completion(TonightEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<TonightEntry>) -> Void) { completion(Timeline(entries: [TonightEntry(date: .now)], policy: .never)) }
}
struct TonightWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "sleepi.tonight", provider: TonightProvider()) { _ in
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: "moon.stars").font(.title).foregroundStyle(.purple.opacity(0.8))
                Text("sleepi").font(.headline)
                Text("Make room for rest").font(.caption)
            }.frame(maxWidth: .infinity, alignment: .leading).containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "sleepi://tonight"))
        }.configurationDisplayName("Tonight").description("Open Tonight and choose whether to record.").supportedFamilies([.systemSmall])
    }
}
struct TonightControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "sleepi.open-tonight") {
            ControlWidgetButton(action: OpenTonightIntent()) { Label("Open Tonight", systemImage: "moon.stars") }
        }.displayName("Open Tonight").description("Open the choice screen. Nothing starts automatically.")
    }
}
struct SleepiLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: SleepActivityAttributes.self) { context in
            HStack {
                Image(systemName: "moon.stars").foregroundStyle(.purple)
                VStack(alignment: .leading) {
                    Text("sleepi · Tonight").font(.headline)
                    Text(context.state.soundRequested ? "Sound requested · open to check status" : "In-bed marker · microphone off").font(.caption)
                }
                Spacer()
                Text(context.state.start, style: .timer).monospacedDigit()
            }.padding().widgetURL(URL(string: "sleepi://tonight"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Label("sleepi", systemImage: "moon.stars") }
                DynamicIslandExpandedRegion(.trailing) { Text(context.state.start, style: .timer).monospacedDigit() }
                DynamicIslandExpandedRegion(.bottom) { Link("Open Tonight to check or end", destination: URL(string: "sleepi://tonight")!) }
            } compactLeading: { Image(systemName: "moon.stars") } compactTrailing: { Text(context.state.start, style: .timer).monospacedDigit().frame(width: 48) } minimal: { Image(systemName: "moon") }
                .widgetURL(URL(string: "sleepi://tonight"))
        }
    }
}
