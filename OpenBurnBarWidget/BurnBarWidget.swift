import SwiftUI
import WidgetKit

@main
struct BurnBarWidget: Widget {
    let kind: String = "com.burnbar.app.widget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: BurnBarProvider()) { entry in
            BurnBarWidgetView(entry: entry)
                .containerBackground(.fill, for: .widget)
        }
        .configurationDisplayName("BurnBar")
        .description("Track your AI token usage at a glance.")
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
