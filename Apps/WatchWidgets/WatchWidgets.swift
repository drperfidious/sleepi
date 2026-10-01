import SwiftUI
import WidgetKit
import AppIntents

@main struct SleepiWatchWidgets: WidgetBundle {
    var body: some Widget { WatchTonightWidget(); WatchTonightControl() }
}
struct WatchEntry: TimelineEntry { let date: Date }
struct WatchProvider: TimelineProvider {
    func placeholder(in context: Context) -> WatchEntry { WatchEntry(date: .now) }
    func getSnapshot(in context: Context, completion: @escaping (WatchEntry) -> Void) { completion(WatchEntry(date: .now)) }
    func getTimeline(in context: Context, completion: @escaping (Timeline<WatchEntry>) -> Void) { completion(Timeline(entries: [WatchEntry(date: .now)], policy: .never)) }
}
struct WatchTonightWidget: Widget {
    @Environment(\.widgetFamily) private var family
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "sleepi.watch.tonight", provider: WatchProvider()) { _ in
            Group {
                if family == .accessoryCircular { Image(systemName: "moon.stars").widgetAccentable().font(.title3) }
                else if family == .accessoryInline { Label("sleepi · Tonight", systemImage: "moon.stars") }
                else { VStack(alignment: .leading) { Label("sleepi", systemImage: "moon.stars"); Text("Open Tonight").font(.caption) } }
            }.containerBackground(.fill.tertiary, for: .widget).widgetURL(URL(string: "sleepi://tonight"))
        }.configurationDisplayName("Open Tonight").description("Choose a night; never start one by accident.").supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}
struct WatchTonightControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(kind: "sleepi.watch.open-tonight") {
            ControlWidgetButton(action: OpenTonightIntent()) { Label("Open Tonight", systemImage: "moon.stars") }
        }.displayName("Open Tonight").description("Open sleepi’s confirmation screen.")
    }
}
