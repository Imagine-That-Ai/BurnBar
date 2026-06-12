import SwiftUI

// MARK: - Widget design-system canary
//
// A build-time guard that fails the widget extension compile if any of
// the design-system primitives the dashboard surfaces depend on
// disappear or change shape. This caught us once already (the
// `a1f72dd42` redesign committed call sites without declarations — the
// device build was broken at HEAD). Keeping a single struct that
// references every shared primitive turns "ship a half-finished
// redesign" from a runtime regression into a compiler error.
//
// New primitives **must** be referenced here so the contract is
// preserved across rolling agent work.
#if DEBUG
@available(iOS 17, *)
private struct _WidgetDesignSystemContractCanary: View {
    var body: some View {
        VStack {
            // Eyebrow / sparkline / share bar — the three new editorial
            // primitives that landed alongside the dashboard redesign.
            WidgetEyebrow(text: "BurnBar", showLiveDot: true)
            WidgetMiniSparkline(data: [0.2, 0.3, 0.8, 0.6, 0.9], color: WidgetDesignSystem.Colors.amber, height: 32)
            WidgetCompactShareBar(value: 4, total: 10, color: WidgetDesignSystem.Colors.ember)

            // Pre-existing primitives. Keeping them referenced here
            // prevents accidental deletion during a future redesign.
            WidgetMetricBadge(icon: "flame.fill", value: "$12", label: "TODAY", color: WidgetDesignSystem.Colors.ember)
            WidgetProviderPill(name: "anthropic", tokens: 2_410, compact: false)
            WidgetProviderPill(name: "openai", tokens: nil, compact: true)
            WidgetProgressBar(value: 3, total: 5, color: WidgetDesignSystem.Colors.amber)
        }
        // Surface modifiers — `widgetGlassCard`, `widgetGlassCardElevated`,
        // `widgetAccentable`, plus the legacy `widgetCardBackground` /
        // `widgetGradientBackground` / `widgetHeaderBackground`.
        .widgetGlassCard()
        .widgetGlassCardElevated()
        .widgetAccentable()
        .widgetCardBackground()
        .widgetGradientBackground()
        .widgetHeaderBackground()
        // Color tokens that the widget chrome depends on.
        .foregroundStyle(WidgetDesignSystem.Colors.textPrimary)
        .background(WidgetDesignSystem.Colors.background)
        .overlay(
            RoundedRectangle(cornerRadius: WidgetDesignSystem.Radius.lg, style: .continuous)
                .stroke(WidgetDesignSystem.Colors.border, lineWidth: 0.5)
        )
        .overlay {
            // Mercury gradient must remain available for the Hermes
            // live-activity accent.
            Capsule().fill(WidgetDesignSystem.Colors.mercuryGradient).frame(width: 1, height: 1)
        }
    }
}
#endif
