import ActivityKit
import SwiftUI
import WidgetKit
import OpenBurnBarCore

// MARK: - Live Activity Widget

@available(iOS 16.1, *)
struct BurnBarLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: BurnBarLiveActivityAttributes.self) { context in
            BurnBarLiveActivityLockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    BurnBarLiveActivityExpandedLeading(context: context)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    BurnBarLiveActivityExpandedTrailing(context: context)
                }
                DynamicIslandExpandedRegion(.center) {
                    BurnBarLiveActivityExpandedCenter(context: context)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    BurnBarLiveActivityExpandedBottom(context: context)
                }
            } compactLeading: {
                Image(systemName: "flame.fill")
                    .foregroundStyle(.orange)
            } compactTrailing: {
                Text(context.state.heroCost.formatAsCost())
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
            } minimal: {
                Image(systemName: "flame.fill")
                    .foregroundStyle(.orange)
            }
        }
    }
}

// MARK: - Lock Screen / Banner View

@available(iOS 16.1, *)
struct BurnBarLiveActivityLockScreenView: View {
    let context: ActivityViewContext<BurnBarLiveActivityAttributes>

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color.gray.opacity(0.1), Color.orange.opacity(0.05)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(context.attributes.heroTitle)
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(.secondary)

                    Text(context.state.heroCost.formatAsCost())
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(.primary)
                        .widgetAccentable()
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 8) {
                    ProviderBadgeWidget(provider: context.state.topProvider)

                    HStack(spacing: 4) {
                        if context.state.sessionActive {
                            PulsingDotWidget()
                        }
                        Text("\(context.state.heroTokens.formatAsTokens()) tokens")
                            .font(.system(size: 13, weight: .medium, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(16)
        }
    }
}

// MARK: - Expanded Dynamic Island Regions

@available(iOS 16.1, *)
struct BurnBarLiveActivityExpandedLeading: View {
    let context: ActivityViewContext<BurnBarLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(context.attributes.heroTitle)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary)

            Text(context.state.heroCost.formatAsCost())
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .widgetAccentable()
        }
    }
}

@available(iOS 16.1, *)
struct BurnBarLiveActivityExpandedTrailing: View {
    let context: ActivityViewContext<BurnBarLiveActivityAttributes>

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            ProviderBadgeWidget(provider: context.state.topProvider)

            HStack(spacing: 4) {
                if context.state.sessionActive {
                    PulsingDotWidget()
                }
                Text("\(context.state.heroTokens.formatAsTokens()) tokens")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

@available(iOS 16.1, *)
struct BurnBarLiveActivityExpandedCenter: View {
    let context: ActivityViewContext<BurnBarLiveActivityAttributes>

    var providerEnum: AgentProvider? {
        AgentProvider.fromPersistedToken(context.state.topProvider)
    }

    var body: some View {
        if let providerEnum,
           UIImage(named: providerEnum.bundledLogoName) != nil {
            UnifiedProviderLogoView(provider: providerEnum, size: 20)
                .widgetAccentable()
        } else {
            Image(systemName: "flame.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.orange)
                .widgetAccentable()
        }
    }
}

@available(iOS 16.1, *)
struct BurnBarLiveActivityExpandedBottom: View {
    let context: ActivityViewContext<BurnBarLiveActivityAttributes>

    var body: some View {
        HStack {
            Spacer()
            SessionActivePillWidget(sessionActive: context.state.sessionActive)
            Spacer()
        }
    }
}

// MARK: - Shared Subviews (Widget-safe, no MobileTheme dependency)

@available(iOS 16.1, *)
struct ProviderBadgeWidget: View {
    let provider: String

    var providerEnum: AgentProvider? {
        AgentProvider.fromPersistedToken(provider)
    }

    var body: some View {
        if let providerEnum,
           UIImage(named: providerEnum.bundledLogoName) != nil {
            UnifiedProviderLogoView(provider: providerEnum, size: 16)
        } else {
            Text(provider)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(Color.gray.opacity(0.15))
                .clipShape(Capsule())
                .overlay(
                    Capsule()
                        .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                )
                .foregroundStyle(.secondary)
        }
    }
}

@available(iOS 16.1, *)
struct SessionActivePillWidget: View {
    let sessionActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            if sessionActive {
                PulsingDotWidget()
            }
            Text(sessionActive ? "Active" : "Idle")
                .font(.system(size: 11, weight: .medium, design: .rounded))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(sessionActive ? Color.green.opacity(0.15) : Color.gray.opacity(0.12))
        .clipShape(Capsule())
        .foregroundStyle(sessionActive ? .green : .secondary)
    }
}

@available(iOS 16.1, *)
struct PulsingDotWidget: View {
    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(Color.green)
            .frame(width: 8, height: 8)
            .scaleEffect(isPulsing ? 1.3 : 1.0)
            .opacity(isPulsing ? 0.6 : 1.0)
            .animation(
                .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
                value: isPulsing
            )
            .onAppear { isPulsing = true }
    }
}
