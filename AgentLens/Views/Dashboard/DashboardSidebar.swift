import AppKit
import SwiftUI

struct DashboardSidebar: View {
    let viewMode: DashboardViewMode
    let mainRoute: DashboardMainRoute
    let providerSummaries: [ProviderSummary]
    let modelSummaries: [ModelSummary]
    let totalCost: Double
    let totalTokens: Int
    let filteredUsagesCount: Int
    let activeProviderCount: Int
    let selectedTimeRange: TimeRange
    let context: DashboardContext
    let sidebarAppeared: Bool
    let onNavigate: (DashboardMainRoute) -> Void
    let onBack: () -> Void
    let onOpenCursorExtension: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                headerSection

                VStack(spacing: DesignSystem.Spacing.sm) {
                    SidebarItem(
                        provider: nil,
                        isSelected: mainRoute == .overview,
                        primaryMetric: context.settingsManager.formatUsageMetric(cost: totalCost, tokens: totalTokens),
                        totalCost: totalCost,
                        sessionCount: filteredUsagesCount
                    ) {
                        withAnimation(DesignSystem.Animation.standard) {
                            onNavigate(.overview)
                        }
                    }

                    if viewMode == .agents {
                        ForEach(Array(providerSummaries.enumerated()), id: \.element.id) { index, summary in
                            SidebarItem(
                                provider: summary.provider,
                                isSelected: mainRoute == .provider(summary.provider),
                                primaryMetric: context.settingsManager.formatUsageMetric(cost: summary.totalCost, tokens: summary.totalTokens),
                                totalCost: summary.totalCost,
                                sessionCount: summary.sessionCount
                            ) {
                                withAnimation(DesignSystem.Animation.standard) {
                                    onNavigate(.provider(summary.provider))
                                }
                            }
                            .opacity(sidebarAppeared ? 1 : 0)
                            .offset(y: sidebarAppeared ? 0 : 8)
                            .animation(
                                DesignSystem.Animation.standard.delay(Double(index) * 0.06),
                                value: sidebarAppeared
                            )
                        }
                    } else {
                        ForEach(Array(modelSummaries.enumerated()), id: \.element.id) { index, summary in
                            ModelSidebarItem(
                                summary: summary,
                                isSelected: mainRoute == .model(summary.modelName)
                            ) {
                                withAnimation(DesignSystem.Animation.standard) {
                                    onNavigate(.model(summary.modelName))
                                }
                            }
                            .opacity(sidebarAppeared ? 1 : 0)
                            .offset(y: sidebarAppeared ? 0 : 8)
                            .animation(
                                DesignSystem.Animation.standard.delay(Double(index) * 0.06),
                                value: sidebarAppeared
                            )
                        }
                    }
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Window")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .textCase(.uppercase)

                        Text(selectedTimeRange.displayName)
                            .font(DesignSystem.Typography.headline)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        Text("\(activeProviderCount) active providers")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                }

                GlassCard {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        Text("Cursor")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .textCase(.uppercase)

                        Button(action: onOpenCursorExtension) {
                            HStack(spacing: DesignSystem.Spacing.md) {
                                ZStack {
                                    Circle()
                                        .fill(DesignSystem.Colors.surfaceElevated)
                                        .frame(width: 36, height: 36)

                                    ProviderLogoView(provider: .cursor, size: 24, useFallbackColor: false)
                                }

                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Add OpenBurnBar to Cursor")
                                        .font(DesignSystem.Typography.body)
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                        .multilineTextAlignment(.leading)

                                    Text("Opens the extension install page")
                                        .font(DesignSystem.Typography.tiny)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }

                                Spacer(minLength: 0)

                                Image(systemName: "arrow.up.forward.circle.fill")
                                    .font(.system(size: 20))
                                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Install OpenBurnBar in Cursor (openburnbar.openburnbar)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                }

                if context.accountManager.isSignedIn {
                    DeviceBreakdownCard(
                        dataStore: context.dataStore,
                        isSyncing: context.cloudSyncService?.isSyncing ?? false
                    )
                }

                if viewMode == .agents ? providerSummaries.isEmpty : modelSummaries.isEmpty {
                    Text(viewMode == .agents ? "No providers in this window" : "No models in this window")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, DesignSystem.Spacing.xl)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .background {
            ZStack {
                DesignSystem.Colors.surface.opacity(0.92)

                LinearGradient(
                    colors: [
                        DesignSystem.Colors.textPrimary.opacity(0.02),
                        Color.clear
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .scrollContentBackground(.hidden)
        .onMoveCommand { direction in
            let order = sidebarRouteOrder
            guard let idx = order.firstIndex(of: mainRoute) else { return }
            switch direction {
            case .up, .left:
                if idx > 0 { onNavigate(order[idx - 1]) }
            case .down, .right:
                if idx + 1 < order.count { onNavigate(order[idx + 1]) }
            default:
                break
            }
        }
        .onKeyPress(.escape) {
            withAnimation(DesignSystem.Animation.standard) {
                onBack()
            }
            return .handled
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Command")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .textCase(.uppercase)

            Text(viewMode == .agents ? "Agent providers" : "LLM Models")
                .font(DesignSystem.Typography.title)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text(viewMode == .agents
                ? "Scan, compare spend, and drill into model behavior from one workspace."
                : "Track spend and token volume across every model your agents use.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var sidebarRouteOrder: [DashboardMainRoute] {
        var routes: [DashboardMainRoute] = [.overview]
        if viewMode == .agents {
            routes.append(contentsOf: providerSummaries.map { .provider($0.provider) })
        } else {
            routes.append(contentsOf: modelSummaries.map { .model($0.modelName) })
        }
        return routes
    }
}
