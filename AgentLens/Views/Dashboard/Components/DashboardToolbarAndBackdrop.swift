import AppKit
import OpenBurnBarCore
import SwiftUI
import WebKit

struct UsageModeToolbarPicker: View {
    @Binding var selection: UsageDisplayMode

    var body: some View {
        Menu {
            ForEach(UsageDisplayMode.allCases) { mode in
                Button {
                    selection = mode
                } label: {
                    HStack {
                        Text(mode.label)
                        if selection == mode {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: leadingSymbol(for: selection))
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(selection.label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(.leading, 1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .toolbarPill()
        }
        .menuStyle(.borderlessButton)
        .help("Show totals in USD or token volume")
    }

    private func leadingSymbol(for mode: UsageDisplayMode) -> String {
        switch mode.label.lowercased() {
        case let l where l.contains("usd") || l.contains("$") || l.contains("cost"):
            return "dollarsign"
        default:
            return "number"
        }
    }
}

struct DashboardBackdrop: View {
    let moodBand: MoodBand
    @Environment(SettingsManager.self) private var settingsManager
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @AppStorage(LiquidGlassTransparency.storageKey) private var rawGlassTransparency: Double = 0

    /// Clear-side adjustment (0…1). Toward 1 the window's own plates fade so
    /// the blurred desktop shows through — the felt payoff of the preference
    /// on a window whose content is otherwise dark-on-dark.
    private var clarity: Double {
        max(0, LiquidGlassTransparency.effective(rawGlassTransparency, reduceTransparency: reduceTransparency))
    }

    var body: some View {
        ZStack {
            // cov:ignore-start -- decorative background composition is smoke-tested but not line-attributed by ViewInspector
            if clarity > 0 {
                LiquidGlassWindowBlend()
                    .ignoresSafeArea()
            }
            if settingsManager.appearanceSkin == .editorial {
                // Editorial / Paper skin: the light dot-crest (provider logos
                // drifting from coloured dots on paper), like app.burnbar.ai.
                WebsiteBackgroundView(accent: DesignSystem.Colors.ember)
            } else if settingsManager.useWebsiteBackground {
                Group {
                    if settingsManager.useConstellationBackground {
                        ConstellationBackgroundView(accent: DesignSystem.Colors.ember)
                    } else {
                        WebsiteBackgroundView(accent: DesignSystem.Colors.ember)
                    }
                }
                .opacity(1 - 0.82 * clarity)
            } else {
                DesignSystem.Colors.background
                    .ignoresSafeArea()
                    .opacity(1 - 0.82 * clarity)

                DesignSystem.Colors.ember
                    .opacity(0.035)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .mask(alignment: .topLeading) {
                        Rectangle()
                            .frame(width: 520)
                            .rotationEffect(.degrees(-11))
                            .offset(x: -260, y: -80)
                    }

                DesignSystem.Colors.whimsy
                    .opacity(0.025)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .mask(alignment: .bottomTrailing) {
                        Rectangle()
                            .frame(width: 460)
                            .rotationEffect(.degrees(15))
                            .offset(x: 220, y: 110)
                    }
            }
            // cov:ignore-end
        }
    }
}

/// A breathtakingly premium replication of the official OpenBurnBar website background for macOS.
/// Renders a deep space canvas, shifting organic cosmic mesh gradients, and a highly
/// precise technical 3D perspective grid fading out toward a high horizon vanishing point.
/// Active, reconverging token-ember swarm pulled directly from burnbar.ai.
///
/// Hundreds of particles murmurate across the screen, periodically
/// reconverging into "$", "</>", concentric quota rings, and a router
/// failover S-curve — then breaking apart again. Reduce Motion locks the
/// pace and pauses the shape cycle.
struct WebsiteBackgroundView: View {
    let accent: Color
    @Environment(SettingsManager.self) private var settingsManager

    var body: some View {
        // cov:ignore-start -- decorative background composition is smoke-tested but not line-attributed by ViewInspector
        if settingsManager.appearanceSkin == .editorial {
            // Light dot-crest: paper field with a transparent, slow, sparkle-free
            // swarm on top. Provider logos render in their real brand colours, so
            // they read crisply on paper (no glyph filter → the full roster).
            ZStack {
                DesignSystem.Colors.background
                    .ignoresSafeArea()
                SwarmCanvasView(
                    accent: accent,
                    pace: .cinematic,
                    isTransparent: true,
                    motionSpeedMultiplier: 0.7,
                    enableSwarmSparkles: false,
                    rendersAsynchronously: true
                )
                .ignoresSafeArea()
                .opacity(0.85)
            }
        } else {
            SwarmCanvasView(accent: accent, pace: .energetic, rendersAsynchronously: true)
                .ignoresSafeArea()
        }
        // cov:ignore-end
    }
}
