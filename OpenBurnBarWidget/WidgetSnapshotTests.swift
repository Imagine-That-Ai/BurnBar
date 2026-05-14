import SwiftUI
import WidgetKit
import OpenBurnBarCore

// MARK: - Widget Snapshot Tests
///
/// DEBUG-only inline previews that render every widget family to PNG.
/// Run from Xcode by selecting the widget extension scheme and pressing
/// the "Run" button with the preview canvas open, or export via
/// `ImageRenderer` in a small Swift script.
///

#if DEBUG
struct WidgetSnapshotSuite: View {
    var body: some View {
        let snapshot = BurnBarWidgetSnapshot(
            heroTotalCost: 4.86,
            heroTotalTokens: 28400,
            heroTotalRequests: 42,
            topProviders: ["Claude", "Codex", "Cursor"],
            topProviderTokens: [15200, 8100, 5100],
            topModels: ["claude-3.7-sonnet", "o3-mini", "gpt-4o"],
            dailyPoints: [0.3, 0.5, 0.8, 1.0, 0.6, 0.4, 0.2],
            windowKey: "today",
            lastSync: Date()
        )

        VStack(spacing: 20) {
            HStack(spacing: 20) {
                widgetBox(title: "Small") {
                    HeroSmallView(snap: snapshot)
                        .frame(width: 155, height: 155)
                }
                widgetBox(title: "Medium") {
                    CostSparklineMediumView(snap: snapshot)
                        .frame(width: 345, height: 155)
                }
            }
            HStack(spacing: 20) {
                widgetBox(title: "Large") {
                    DashboardLargeView(snap: snapshot)
                        .frame(width: 345, height: 345)
                }
                widgetBox(title: "Extra Large") {
                    DashboardExtraLargeView(snap: snapshot)
                        .frame(width: 700, height: 345)
                }
            }
            HStack(spacing: 20) {
                widgetBox(title: "Rectangular") {
                    RectangularLockScreenView(snap: snapshot)
                        .frame(width: 300, height: 80)
                }
                widgetBox(title: "Circular") {
                    CircularLockScreenView(snap: snapshot)
                        .frame(width: 80, height: 80)
                }
                widgetBox(title: "Inline") {
                    InlineLockScreenView(snap: snapshot)
                        .frame(width: 300, height: 40)
                }
            }
        }
        .padding()
        .background(Color.black)
    }

    private func widgetBox(title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
            content()
        }
    }
}

#Preview("Widget Snapshot Suite", traits: .sizeThatFitsLayout) {
    WidgetSnapshotSuite()
}
#endif
