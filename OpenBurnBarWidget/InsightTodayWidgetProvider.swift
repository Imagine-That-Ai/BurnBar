import WidgetKit
import OpenBurnBarCore

struct InsightTodayWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: InsightVerdictWidgetSnapshot?
}

struct InsightTodayWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> InsightTodayWidgetEntry {
        InsightTodayWidgetEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (InsightTodayWidgetEntry) -> Void) {
        completion(loadEntry() ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<InsightTodayWidgetEntry>) -> Void) {
        let entry = loadEntry() ?? placeholder(in: context)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func loadEntry() -> InsightTodayWidgetEntry? {
        guard let snapshot = try? InsightWidgetShared.readVerdictSnapshot() else { return nil }
        return InsightTodayWidgetEntry(date: snapshot.lastSync, snapshot: snapshot)
    }
}
