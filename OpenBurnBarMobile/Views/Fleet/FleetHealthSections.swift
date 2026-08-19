import SwiftUI
import OpenBurnBarKernel

// MARK: - Fleet health & grouping sections (iOS)
//
// The board's supporting sections: per-repo grouping, probe-health caveats,
// and the persistence-degraded banner. Ports of the Mac's
// `FleetRepoGroupRow` / `FleetProbeHealthSection` honesty rules — reasons are
// always shown in full, counts always reflect the latest snapshot, and the
// "No repo" bucket never drops an agent.

// MARK: - Persistence banner

/// Shown when the snapshot reports its own persistence as degraded: the board
/// is still live, but the Mac's fleet history may be incomplete. The reason
/// comes from the daemon and is non-secret by contract.
struct FleetPersistenceBanner: View {
    let reason: String

    var body: some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
            Image(systemName: "externaldrive.badge.exclamationmark")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.warning)

            Text("Fleet history on your Mac is degraded: \(reason)")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, MobileTheme.Spacing.md)
        .padding(.vertical, MobileTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: AuroraDesign.Shape.chipCorner, style: .continuous)
                .fill(MobileTheme.warning.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: AuroraDesign.Shape.chipCorner, style: .continuous)
                .stroke(MobileTheme.warning.opacity(0.3), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Fleet persistence degraded: \(reason)")
    }
}

// MARK: - Repo groups

/// Per-repo grouping (VAL-DASH-010/019): one row per project plus the
/// explicit "No repo" bucket. Collapse hides the member list but never the
/// count; the count always reflects the latest snapshot. Collapse state is
/// keyed by project name so it survives snapshot updates.
struct FleetRepoGroupsSection: View {
    let rows: [FleetRepoGroupRowModel]

    @State private var collapsedRepos: Set<String> = []

    var body: some View {
        if rows.isEmpty {
            Text("No repo attribution available")
                .font(MobileTheme.Typography.footnote)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
        } else {
            AuroraGlassCard(variant: .standard, padding: MobileTheme.Spacing.md) {
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                    ForEach(rows) { row in
                        groupRow(row)
                        if row.id != rows.last?.id {
                            Divider()
                                .background(MobileTheme.Colors.borderSubtle.opacity(0.5))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func groupRow(_ row: FleetRepoGroupRowModel) -> some View {
        let isCollapsed = collapsedRepos.contains(row.projectName)
        return VStack(alignment: .leading, spacing: MobileTheme.Spacing.xxs) {
            Button {
                withAnimation(AuroraDesign.Motion.auroraSnap) {
                    if isCollapsed {
                        collapsedRepos.remove(row.projectName)
                    } else {
                        collapsedRepos.insert(row.projectName)
                    }
                }
            } label: {
                HStack(spacing: MobileTheme.Spacing.sm) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .frame(width: 12)

                    Text(row.projectName)
                        .font(MobileTheme.Typography.footnote)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: MobileTheme.Spacing.sm)

                    Text("\(row.count)")
                        .font(MobileTheme.Typography.monoTiny)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .padding(.horizontal, MobileTheme.Spacing.sm)
                        .padding(.vertical, MobileTheme.Spacing.xxs)
                        .background(
                            Capsule(style: .continuous)
                                .fill(MobileTheme.Colors.surfaceElevated.opacity(0.6))
                        )
                        .overlay(
                            Capsule(style: .continuous)
                                .stroke(MobileTheme.Colors.border.opacity(0.4), lineWidth: 1)
                        )
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                "\(row.projectName): \(row.count) agent\(row.count == 1 ? "" : "s")"
                    + (isCollapsed ? ", collapsed" : "")
            )
            .accessibilityHint(isCollapsed ? "Expands the member list" : "Collapses the member list")

            if !isCollapsed {
                Text(row.agentIDs.map { FleetProviderIdentity.name(for: $0) }.joined(separator: ", "))
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(2)
                    .padding(.leading, 12 + MobileTheme.Spacing.sm)
            }
        }
    }
}

// MARK: - Probe issues

/// Bottom caveat list: only the probes that are degraded or failed, each with
/// its full reason (VAL-DASH-013). The screen omits the whole section when
/// every probe is ok.
struct FleetProbeHealthSection: View {
    let issues: [BurnBarFleetProbeHealth]

    var body: some View {
        AuroraGlassCard(variant: .standard, padding: MobileTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                ForEach(issues, id: \.agent) { entry in
                    issueRow(entry)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func issueRow(_ entry: BurnBarFleetProbeHealth) -> some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
            Circle()
                .fill(issueColor(entry.state))
                .frame(width: 7, height: 7)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                Text(FleetProviderIdentity.name(for: entry.agent))
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                Text(issueText(entry.state))
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(FleetProviderIdentity.name(for: entry.agent)): \(issueText(entry.state))")
    }

    private func issueColor(_ state: BurnBarFleetProbeHealthState) -> Color {
        switch state {
        case .ok:
            return MobileTheme.success
        case .degraded:
            return MobileTheme.warning
        case .failed:
            return MobileTheme.error
        }
    }

    private func issueText(_ state: BurnBarFleetProbeHealthState) -> String {
        switch state {
        case .ok:
            return "ok"
        case .degraded(let reason):
            return "degraded: \(reason)"
        case .failed(let reason):
            return "failed: \(reason)"
        }
    }
}
