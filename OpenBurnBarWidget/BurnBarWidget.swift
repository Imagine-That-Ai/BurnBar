import SwiftUI
import WidgetKit

@main
struct BurnBarWidgets: WidgetBundle {
    var body: some Widget {
        BurnBarWidget()
        InsightTodayWidget()
        InsightSessionLiveActivityWidget()
    }
}

struct BurnBarWidget: Widget {
    let kind: String = "com.openburnbar.app.widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BurnBarProvider()) { entry in
            BurnBarWidgetView(entry: entry)
                .containerBackground(WidgetDesignSystem.Colors.background, for: .widget)
        }
        .configurationDisplayName("BurnBar")
        .description("Track your AI token usage at a glance.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .systemExtraLarge,
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular
        ])
    }
}

struct InsightTodayWidget: Widget {
    let kind: String = "com.openburnbar.app.insightstoday"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: InsightTodayWidgetProvider()) { entry in
            InsightTodayWidgetView(entry: entry)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Insights Today")
        .description("Your daily AI spend brief at a glance.")
        .supportedFamilies([
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .accessoryInline,
            .accessoryCircular,
            .accessoryRectangular
        ])
    }
}
