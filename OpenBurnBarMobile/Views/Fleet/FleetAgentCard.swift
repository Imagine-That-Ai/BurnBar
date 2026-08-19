import SwiftUI
import OpenBurnBarKernel

// MARK: - Fleet Agent Card (iOS)
//
// One fixed-roster agent card: status dot, provider identity, current task,
// repo/model/last-activity rows, confidence badge, provenance caption, honest
// caveat note, and the evidence trail in a collapsed disclosure. Port of the
// Mac's `FleetAgentCard` with the mobile card chrome.
//
// Provider identity matches the usage surface: same display name, icon, and
// theme color (VAL-CROSS-003). The always-visible provenance carries the
// signal KIND only; the full evidence (kind + path + detail) is the user's
// own sealed data and appears only behind the explicit disclosure.

struct FleetAgentCard: View {
    let agent: BurnBarFleetAgent

    @State private var showsSignals = false

    private var statusColor: Color {
        FleetStatusPresentation.color(for: agent.status)
    }

    private var statusLabel: String {
        FleetStatusPresentation.label(for: agent.status)
    }

    var body: some View {
        AuroraGlassCard(variant: .standard, padding: MobileTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                summary
                if !agent.signals.isEmpty {
                    signalsDisclosure
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Summary
    //
    // Combined into one accessibility element (like the Mac card) — but only
    // the informational part, so the evidence disclosure below stays an
    // individually focusable button for VoiceOver.

    private var summary: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            headerRow

            if let task = agent.currentTask, !task.isEmpty {
                Text(task)
                    .font(MobileTheme.Typography.footnote)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(2)
            }

            VStack(alignment: .leading, spacing: MobileTheme.Spacing.xxs) {
                cardRow(label: "Repo", value: agent.projectName)
                cardRow(label: "Model", value: agent.model)
                cardRow(
                    label: "Last activity",
                    value: agent.lastActivityAt.map { MissionConsoleFormatting.relativeTime($0) }
                )
                if let process = agent.process {
                    cardRow(label: "PID", value: "\(process.pid)")
                }
            }

            HStack(spacing: MobileTheme.Spacing.sm) {
                confidenceBadge

                Spacer(minLength: 0)

                // Visible provenance (VAL-DASH-027): confidence label plus the
                // first non-secret signal kind — never color-only, never
                // secret-bearing (kind only, never path/detail).
                Text(FleetConfidencePresentation.provenanceLabel(for: agent))
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }

            if let note = agent.note, !note.isEmpty {
                Text(note)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var headerRow: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Circle()
                .fill(statusColor)
                .frame(width: 9, height: 9)

            Image(systemName: FleetProviderIdentity.iconName(for: agent.id))
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(FleetProviderIdentity.color(for: agent.id))
                .frame(width: 16)

            Text(FleetProviderIdentity.name(for: agent.id))
                .font(MobileTheme.Typography.headline)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .lineLimit(1)

            Spacer(minLength: MobileTheme.Spacing.sm)

            Text(statusLabel)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
        }
    }

    private var confidenceBadge: some View {
        Text(FleetConfidencePresentation.shortLabel(for: agent.confidence))
            .font(MobileTheme.Typography.tiny)
            .foregroundStyle(MobileTheme.Colors.textPrimary)
            .padding(.horizontal, MobileTheme.Spacing.sm)
            .padding(.vertical, MobileTheme.Spacing.xxs)
            .background(
                Capsule(style: .continuous)
                    .fill(confidenceColor.opacity(0.12))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(confidenceColor, lineWidth: 1)
            )
    }

    private var confidenceColor: Color {
        FleetConfidencePresentation.color(for: agent.confidence)
    }

    private func cardRow(label: String, value: String?) -> some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Text(label)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .frame(width: 84, alignment: .leading)

            Text(value ?? "—")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(
                    value == nil ? MobileTheme.Colors.textSecondary : MobileTheme.Colors.textPrimary
                )
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
    }

    // MARK: - Evidence disclosure
    //
    // Collapsed by default: the trail proves the row rather than decorates
    // it. Paths render in full only on request — the board is the user's own
    // sealed data, but a path is detail, not glanceable status.

    private var signalsDisclosure: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
            Button {
                withAnimation(AuroraDesign.Motion.auroraSnap) {
                    showsSignals.toggle()
                }
            } label: {
                HStack(spacing: MobileTheme.Spacing.xs) {
                    Image(systemName: showsSignals ? "chevron.down" : "chevron.right")
                        .font(MobileTheme.Typography.tiny)
                    Text("Evidence (\(agent.signals.count))")
                        .font(MobileTheme.Typography.tiny)
                }
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(
                showsSignals
                    ? "Collapse evidence for \(FleetProviderIdentity.name(for: agent.id))"
                    : "Expand evidence for \(FleetProviderIdentity.name(for: agent.id)), \(agent.signals.count) signal\(agent.signals.count == 1 ? "" : "s")"
            )

            if showsSignals {
                ForEach(Array(agent.signals.enumerated()), id: \.offset) { _, signal in
                    signalRow(signal)
                }
            }
        }
    }

    private func signalRow(_ signal: BurnBarFleetSignalSource) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(signal.kind)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textPrimary)

            Text(signal.path)
                .font(MobileTheme.Typography.monoTiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .lineLimit(1)
                .truncationMode(.middle)

            if let detail = signal.detail, !detail.isEmpty {
                Text(detail)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Accessibility

    private var accessibilityLabel: String {
        let provenance = FleetConfidencePresentation.provenanceLabel(for: agent)
        var parts = ["\(FleetProviderIdentity.name(for: agent.id)), \(statusLabel), \(provenance)"]
        if let task = agent.currentTask, !task.isEmpty {
            parts.append("task: \(task)")
        }
        if let repo = agent.projectName {
            parts.append("repo: \(repo)")
        }
        if let model = agent.model {
            parts.append("model: \(model)")
        }
        if let activity = agent.lastActivityAt {
            parts.append("last activity: \(MissionConsoleFormatting.relativeTime(activity))")
        }
        if let note = agent.note, !note.isEmpty {
            parts.append("note: \(note)")
        }
        return parts.joined(separator: ", ")
    }
}
