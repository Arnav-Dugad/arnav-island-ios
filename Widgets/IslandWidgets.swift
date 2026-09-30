import SwiftUI
import WidgetKit

@main
struct IslandWidgets: WidgetBundle {
    var body: some Widget { PlaceholderWidget() }
}
struct PlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "placeholder", provider: Provider()) { _ in Text("Arnav Island") }
    }
    struct Entry: TimelineEntry { let date: Date }
    struct Provider: TimelineProvider {
        func placeholder(in context: Context) -> Entry { Entry(date: .now) }
        func getSnapshot(in context: Context, completion: @escaping (Entry) -> Void) { completion(Entry(date: .now)) }
        func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) { completion(Timeline(entries: [Entry(date: .now)], policy: .never)) }
    }
}
