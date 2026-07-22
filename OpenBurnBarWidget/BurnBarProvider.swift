import WidgetKit
import OpenBurnBarKernel

struct BurnBarProvider: TimelineProvider {
    func placeholder(in context: Context) -> BurnBarEntry {
        BurnBarEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (BurnBarEntry) -> Void) {
        completion(loadEntry() ?? placeholder(in: context))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<BurnBarEntry>) -> Void) {
        let loaded = loadEntry()
        let entry = loaded ?? placeholder(in: context)
        let nextUpdate = Calendar.current.date(byAdding: .minute, value: 15, to: Date())
            ?? Date().addingTimeInterval(900)
        let timeline = Timeline(entries: [entry], policy: .after(nextUpdate))

        // Render OUTCOME only (freshness), gated on host consent inside
        // WidgetAnalytics. No rendered values, costs, or content are read here.
        let freshness = loaded == nil ? "stale" : "fresh"
        Task { @MainActor in
            WidgetAnalytics.trackRender(family: "burnbar", freshness: freshness)
        }

        completion(timeline)
    }

    private func loadEntry() -> BurnBarEntry? {
        guard let snapshot = try? BurnBarWidgetShared.readSnapshot() else { return nil }
        return BurnBarEntry(date: snapshot.lastSync, snapshot: snapshot)
    }
}
