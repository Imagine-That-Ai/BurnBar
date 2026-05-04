import WidgetKit
import OpenBurnBarCore

struct BurnBarProvider: TimelineProvider {
    func placeholder(in context: Context) -> BurnBarEntry {
        BurnBarEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (BurnBarEntry) -> Void) {
        completion(loadEntry() ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BurnBarEntry>) -> Void) {
        let entry = loadEntry() ?? placeholder(in: context)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))
        completion(timeline)
    }

    private func loadEntry() -> BurnBarEntry? {
        guard let snapshot = try? BurnBarWidgetShared.readSnapshot() else { return nil }
        return BurnBarEntry(date: snapshot.lastSync, snapshot: snapshot)
    }
}
