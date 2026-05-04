import SwiftUI
import WidgetKit
import OpenBurnBarCore

struct BurnBarWidgetView: View {
    var entry: BurnBarEntry

    @Environment(\.widgetFamily) private var family
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        Group {
            switch family {
            case .systemSmall:
                HeroSmallView(snap: entry.snapshot)
            case .systemMedium:
                CostSparklineMediumView(snap: entry.snapshot)
            case .systemLarge:
                DashboardLargeView(snap: entry.snapshot)
            case .systemExtraLarge:
                DashboardExtraLargeView(snap: entry.snapshot)
            case .accessoryRectangular:
                RectangularLockScreenView(snap: entry.snapshot)
            case .accessoryCircular:
                CircularLockScreenView(snap: entry.snapshot)
            case .accessoryInline:
                InlineLockScreenView(snap: entry.snapshot)
            default:
                HeroSmallView(snap: entry.snapshot)
            }
        }
        .widgetURL(URL(string: "burnbar://dashboard"))
    }
}
