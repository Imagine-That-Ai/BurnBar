import SwiftUI
import OpenBurnBarKernel

// MARK: - Hermes Operating Strip

enum HermesOperatingStripPage: Int, CaseIterable {
    case mission
    case quotas

    var title: String {
        switch self {
        case .mission: return "Mission"
        case .quotas: return "Quotas"
        }
    }

    var next: Self {
        let all = Self.allCases
        guard let i = all.firstIndex(of: self) else { return self }
        return all[(i + 1) % all.count]
    }

    var previous: Self {
        let all = Self.allCases
        guard let i = all.firstIndex(of: self) else { return self }
        return all[(i + all.count - 1) % all.count]
    }
}

struct OpenBurnBarHermesOperatingStrip: View {
    @Bindable var layer: OpenBurnBarOperatingLayer
    @State private var isExpanded = false
    @State private var stripPage: HermesOperatingStripPage = .mission

    var body: some View {
        let snapshot = layer.snapshot

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            stripNavigationRow(snapshot: snapshot)

            if isExpanded {
                Group {
                    switch stripPage {
                    case .mission:
                        missionExpandedBody(snapshot: snapshot)
                    case .quotas:
                        quotasExpandedBody
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                Group {
                    switch stripPage {
                    case .mission:
                        missionCollapsedSummary(snapshot: snapshot)
                    case .quotas:
                        quotasCollapsedSummary(runtime: snapshot.controllerRuntime)
                    }
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.sm + 2)
        .padding(.vertical, DesignSystem.Spacing.xs + 2)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.7))
        .animation(.easeInOut(duration: 0.2), value: isExpanded)
        .animation(.easeInOut(duration: 0.2), value: stripPage)
    }

    // MARK: - Navigation

    private func stripNavigationRow(snapshot: OpenBurnBarOperatingSnapshot) -> some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.xs) {
            Button {
                stripPage = stripPage.previous
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel("Previous operating view")

            Text(stripPage.title)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .textCase(.uppercase)
                .lineLimit(1)

            Button {
                stripPage = stripPage.next
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.hermesAureate)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel("Next operating view")

            Spacer(minLength: 0)

            // Keep collapsed nav lightweight; expanded page already contains detailed badges.

            Button {
                isExpanded.toggle()
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel(isExpanded ? "Collapse mission panel" : "Expand mission panel")
        }
    }

    // MARK: - Mission

    private func missionCollapsedSummary(snapshot: OpenBurnBarOperatingSnapshot) -> some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(snapshot.projectName ?? "OpenBurnBar home")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)
                Text(snapshot.mission.title)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)

            Text(snapshot.burn.estimatedCostUSD.formatAsCost())
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(DesignSystem.Colors.hermesAureate)
        }
    }

    private func quotasCollapsedSummary(runtime: OpenBurnBarControllerRuntimeSnapshot) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            quotaChip(
                title: "Q",
                value: "\(runtime.pendingQuestions.count)",
                color: DesignSystem.Colors.amber
            )
            quotaChip(
                title: "F",
                value: "\(runtime.openFollowups.count)",
                color: DesignSystem.Colors.whimsy
            )
            if let mission = runtime.missions.first {
                quotaChip(
                    title: "M",
                    value: mission.state.label,
                    color: mission.state.color
                )
            }
            Spacer(minLength: 0)
            Text(runtime.source.label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
        }
    }

    private func quotaChip(title: String, value: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Text(title)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(color)
                .lineLimit(1)
        }
    }

    private func missionExpandedBody(snapshot: OpenBurnBarOperatingSnapshot) -> some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(snapshot.projectName ?? "OpenBurnBar home")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .textCase(.uppercase)
                    Text(snapshot.mission.title)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(2)
                    Text(snapshot.direction.summary)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(2)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 4) {
                    OpenBurnBarStatusBadge(title: snapshot.direction.status.label, color: snapshot.direction.status.color)
                    Text(snapshot.burn.estimatedCostUSD.formatAsCost())
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                }
            }

            OpenBurnBarOperatingFreshnessStrip(summary: snapshot.freshness, compact: true)
            OpenBurnBarOperatingActionBar(layer: layer, compact: true)
        }
    }

    // MARK: - Quotas

    private var quotasExpandedBody: some View {
        OpenBurnBarControllerCompactSummary(runtime: layer.snapshot.controllerRuntime, compact: true)
    }
}
