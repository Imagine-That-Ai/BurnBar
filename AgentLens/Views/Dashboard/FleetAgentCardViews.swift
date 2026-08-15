import BurnBarCore
import SwiftUI

// MARK: - Agent Card

/// One fixed-roster agent card: status dot, name, task, repo, model, last
/// activity, confidence badge, and provenance (VAL-DASH-003/027).
struct FleetAgentCard: View {
    let agent: BurnBarFleetAgent
    let viewModel: FleetViewModel

    private var statusColor: Color {
        FleetStatusPresentation.color(for: agent.status)
    }

    private var statusLabel: String {
        FleetStatusPresentation.label(for: agent.status)
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)

                    // Provider identity matches the usage surface: same
                    // display name, icon, and theme color (VAL-CROSS-003).
                    Image(systemName: viewModel.providerIconName(for: agent.id))
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(viewModel.providerColor(for: agent.id))
                        .frame(width: 16)

                    Text(viewModel.providerName(for: agent.id))
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)

                    // Orchestrator badge (VAL-ORCH-005): marks the designated
                    // agent's card. Derives from the daemon-owned designation
                    // — never optimistic local state.
                    if viewModel.isDesignatedAgent(agent.id) {
                        Text("Orchestrator")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.whimsy)
                            .padding(.horizontal, DesignSystem.Spacing.sm)
                            .padding(.vertical, DesignSystem.Spacing.xxs)
                            .background(
                                Capsule()
                                    .fill(DesignSystem.Colors.whimsy.opacity(0.12))
                            )
                            .overlay(
                                Capsule()
                                    .stroke(DesignSystem.Colors.whimsy.opacity(0.5), lineWidth: 1)
                            )
                            .accessibilityLabel("Orchestrator")
                    }

                    Spacer()

                    Text(statusLabel)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }

                if let task = agent.currentTask, !task.isEmpty {
                    Text(task)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(2)
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                    cardRow(label: "Repo", value: agent.projectName)
                    cardRow(label: "Model", value: agent.model)
                    cardRow(
                        label: "Last activity",
                        value: agent.lastActivityAt.map { FleetFormatting.formatRelativeTime($0) }
                    )
                    if let process = agent.process {
                        cardRow(label: "PID", value: "\(process.pid)")
                    }
                }

                HStack(spacing: DesignSystem.Spacing.sm) {
                    confidenceBadge
                    Spacer()
                    if let note = agent.note, !note.isEmpty {
                        Text(note)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .lineLimit(1)
                    }
                }

                // Visible provenance (VAL-DASH-027): the confidence label plus
                // the first non-secret signal kind — never color-only, never
                // secret-bearing (kind only, never path/detail).
                Text(FleetConfidencePresentation.provenanceLabel(for: agent))
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.md)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private var confidenceBadge: some View {
        Text(FleetConfidencePresentation.shortLabel(for: agent.confidence))
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xxs)
            .background(
                Capsule()
                    .fill(confidenceColor.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .stroke(confidenceColor, lineWidth: 1)
            )
    }

    private var confidenceColor: Color {
        FleetConfidencePresentation.color(for: agent.confidence)
    }

    private func cardRow(label: String, value: String?) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 84, alignment: .leading)

            Text(value ?? "—")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(value == nil ? DesignSystem.Colors.textSecondary : DesignSystem.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
    }

    private var accessibilityLabel: String {
        let provenance = FleetConfidencePresentation.provenanceLabel(for: agent)
        var parts = ["\(viewModel.providerName(for: agent.id)), \(statusLabel), \(provenance)"]
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
            parts.append("last activity: \(FleetFormatting.formatRelativeTime(activity))")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Machine Panel

/// Machine status panel: CPU, memory, load, disk free, thermal, power — with
/// honest per-field unavailability (never fabricated values, VAL-DASH-011).
/// Absent optional metrics render "—" with an accessible "unavailable" label
/// (VAL-DASH-030); populated metrics render with units (VAL-DASH-022).
struct FleetMachinePanel: View {
    let rows: [FleetMachineRow]

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Machine")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    ForEach(rows) { metricRow in
                        machineRow(metricRow)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }

    private func machineRow(_ metricRow: FleetMachineRow) -> some View {
        HStack {
            Text(metricRow.label)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            Spacer()

            Text(metricRow.value ?? "—")
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(
                    metricRow.isUnavailable
                        ? DesignSystem.Colors.textSecondary
                        : DesignSystem.Colors.textPrimary
                )
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(metricRow.accessibilityLabel)
    }
}

// MARK: - Probe Health Section

/// Probe health list: one typed row per declared agent (ok/degraded/failed
/// with reason — VAL-DASH-013).
struct FleetProbeHealthSection: View {
    let health: [BurnBarFleetProbeHealth]
    let viewModel: FleetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Probe health")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            VStack(spacing: DesignSystem.Spacing.xs) {
                ForEach(health, id: \.agent) { entry in
                    probeHealthRow(entry)
                }
            }
        }
    }

    private func probeHealthRow(_ entry: BurnBarFleetProbeHealth) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Circle()
                .fill(probeHealthColor(entry.state))
                .frame(width: 7, height: 7)

            Text(viewModel.providerName(for: entry.agent))
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            Spacer()

            Text(probeHealthText(entry.state))
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(viewModel.providerName(for: entry.agent)): \(probeHealthText(entry.state))"
        )
    }

    private func probeHealthColor(_ state: BurnBarFleetProbeHealthState) -> Color {
        switch state {
        case .ok:
            return DesignSystem.Colors.success
        case .degraded:
            return DesignSystem.Colors.warning
        case .failed:
            return DesignSystem.Colors.error
        }
    }

    private func probeHealthText(_ state: BurnBarFleetProbeHealthState) -> String {
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

// MARK: - Repo Group Row

/// One per-repo group (VAL-DASH-010/019): project name, member count badge,
/// and collapse/expand toggle. Collapse hides the member list but never the
/// count; the count always reflects the latest snapshot. Long project names
/// ellipsize (middle truncation) without pushing the toggle off-card
/// (VAL-DASH-020).
struct FleetRepoGroupRow: View {
    let row: FleetRepoGroupRowModel
    let viewModel: FleetViewModel

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Button {
                        viewModel.toggleRepoCollapse(row.projectName)
                    } label: {
                        Image(systemName: row.isCollapsed ? "chevron.right" : "chevron.down")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .frame(width: 12)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(row.isCollapsed ? "Expand \(row.projectName)" : "Collapse \(row.projectName)")

                    Text(row.projectName)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: DesignSystem.Spacing.sm)

                    Text("\(row.count)")
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, DesignSystem.Spacing.xxs)
                        .background(
                            Capsule()
                                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                        )
                        .overlay(
                            Capsule()
                                .stroke(DesignSystem.Colors.border.opacity(0.4), lineWidth: 1)
                        )
                        .accessibilityLabel("\(row.count) agent\(row.count == 1 ? "" : "s")")
                }

                if !row.isCollapsed {
                    Text(row.agentIDs.map { viewModel.providerName(for: $0) }.joined(separator: ", "))
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.md)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(row.projectName): \(row.count) agent\(row.count == 1 ? "" : "s")"
                + (row.isCollapsed ? ", collapsed" : "")
        )
    }
}

// MARK: - Resource Consumers Section

/// Resource consumers list (VAL-DASH-012/023): exact per-pid CPU/memory rows
/// for agents whose snapshot rows carry `process` info, and token-burn proxy
/// rows explicitly labeled "Proxy" — never formatted identically to exact
/// numbers without the label. Ordering is deterministic and documented:
/// exact rows first (CPU desc, ties by pid asc), then proxy rows (tokens/min
/// desc, ties by agent id asc).
struct FleetResourceConsumersSection: View {
    let consumers: [FleetResourceConsumer]
    let viewModel: FleetViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Resource consumers")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            if consumers.isEmpty {
                Text("No per-process or token-burn data available")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            } else {
                GlassCard {
                    VStack(spacing: DesignSystem.Spacing.xs) {
                        ForEach(consumers) { consumer in
                            consumerRow(consumer)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(DesignSystem.Spacing.md)
                }
            }
        }
    }

    private func consumerRow(_ consumer: FleetResourceConsumer) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Circle()
                .fill(viewModel.providerColor(for: consumer.agentID))
                .frame(width: 7, height: 7)

            Text(viewModel.providerName(for: consumer.agentID))
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)

            Spacer(minLength: DesignSystem.Spacing.sm)

            if consumer.isProxy {
                Text("Proxy")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .padding(.horizontal, DesignSystem.Spacing.xs)
                    .padding(.vertical, 1)
                    .background(
                        Capsule()
                            .fill(DesignSystem.Colors.warning.opacity(0.12))
                    )
                    .overlay(
                        Capsule()
                            .stroke(DesignSystem.Colors.warning.opacity(0.4), lineWidth: 1)
                    )
            }

            if let pid = consumer.pid {
                Text("PID \(pid)")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            if let cpu = consumer.cpuPercent {
                Text(FleetFormatting.formatCPU(cpu))
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }

            if let memory = consumer.memoryBytes {
                Text(FleetFormatting.formatBytes(memory))
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }

            if let burn = consumer.tokensPerMinute {
                Text(FleetFormatting.formatTokensPerMinute(burn))
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: consumer))
    }

    private func accessibilityLabel(for consumer: FleetResourceConsumer) -> String {
        let name = viewModel.providerName(for: consumer.agentID)
        if consumer.isProxy {
            let burn = consumer.tokensPerMinute.map { FleetFormatting.formatTokensPerMinute($0) } ?? "unavailable"
            return "\(name), proxy, \(burn)"
        }
        var parts = [name, "exact"]
        if let pid = consumer.pid {
            parts.append("pid \(pid)")
        }
        if let cpu = consumer.cpuPercent {
            parts.append("cpu \(FleetFormatting.formatCPU(cpu))")
        }
        if let memory = consumer.memoryBytes {
            parts.append("memory \(FleetFormatting.formatBytes(memory))")
        }
        return parts.joined(separator: ", ")
    }
}
