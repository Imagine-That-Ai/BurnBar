import BurnBarCore
import SwiftUI

// MARK: - Agent Card

/// One fixed-roster agent card: status dot, name, task, repo, model, last
/// activity, confidence badge, and provenance (VAL-DASH-003/027).
struct FleetAgentCard: View {
    let agent: BurnBarFleetAgent
    let viewModel: FleetViewModel

    private var statusColor: Color {
        switch agent.status {
        case .running:
            return DesignSystem.Colors.success
        case .idle:
            return DesignSystem.Colors.textMuted
        case .stale:
            return DesignSystem.Colors.warning
        case .unknown:
            return DesignSystem.Colors.textSecondary
        }
    }

    private var statusLabel: String {
        switch agent.status {
        case .running:
            return "Running"
        case .idle:
            return "Idle"
        case .stale:
            return "Stale"
        case .unknown:
            return "Unknown"
        }
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 9, height: 9)

                    Text(agent.displayName)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)

                    Spacer()

                    Text(statusLabel)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(statusColor)
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
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                    }
                }
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
            .foregroundStyle(confidenceColor)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xxs)
            .background(
                Capsule()
                    .fill(confidenceColor.opacity(0.12))
            )
            .overlay(
                Capsule()
                    .stroke(confidenceColor.opacity(0.35), lineWidth: 1)
            )
    }

    private var confidenceColor: Color {
        switch agent.confidence {
        case .exactProcess:
            return DesignSystem.Colors.success
        case .activeSessionFile:
            return DesignSystem.Colors.whimsy
        case .logHeartbeat:
            return DesignSystem.Colors.amber
        case .estimated:
            return DesignSystem.Colors.warning
        case .unsupported:
            return DesignSystem.Colors.textMuted
        }
    }

    private func cardRow(label: String, value: String?) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 84, alignment: .leading)

            Text(value ?? "—")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(value == nil ? DesignSystem.Colors.textMuted : DesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)
        }
    }

    private var accessibilityLabel: String {
        let provenance = FleetConfidencePresentation.provenance(for: agent)
        var parts = ["\(agent.displayName), \(statusLabel), \(provenance)"]
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
struct FleetMachinePanel: View {
    let machine: BurnBarMachineStatus

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Machine")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    machineRow(
                        label: "CPU",
                        value: machine.cpuPercent.map { FleetFormatting.formatCPU($0) }
                    )
                    machineRow(
                        label: "Memory",
                        value: machine.memoryUsedBytes.map {
                            FleetFormatting.formatMemory(used: $0, total: machine.memoryTotalBytes)
                        }
                    )
                    machineRow(
                        label: "Load",
                        value: machine.loadAverage.map { FleetFormatting.formatLoadAverage($0) }
                    )
                    machineRow(
                        label: "Disk free",
                        value: machine.diskFreeBytes.map { FleetFormatting.formatDiskFree($0) }
                    )
                    machineRow(label: "Thermal", value: sensorText(machine.thermal))
                    machineRow(label: "Power", value: sensorText(machine.power))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignSystem.Spacing.lg)
            }
        }
    }

    private func sensorText(_ state: BurnBarSensorState) -> String? {
        switch state {
        case .available(let value):
            return String(format: "%.1f", value)
        case .unavailable(let reason):
            return "Unavailable (\(reason))"
        }
    }

    private func machineRow(label: String, value: String?) -> some View {
        HStack {
            Text(label)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            Spacer()

            Text(value ?? "—")
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(value == nil ? DesignSystem.Colors.textMuted : DesignSystem.Colors.textPrimary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            value.map { "\(label): \($0)" } ?? "\(label): unavailable"
        )
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
                .foregroundStyle(DesignSystem.Colors.textMuted)
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

/// One per-repo group: project name plus the agent ids attributed to it.
struct FleetRepoGroupRow: View {
    let group: BurnBarFleetRepoGroup
    let viewModel: FleetViewModel

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(group.projectName)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(group.agents.map { viewModel.providerName(for: $0) }.joined(separator: ", "))
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.md)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(group.projectName): \(group.agents.count) agent\(group.agents.count == 1 ? "" : "s")")
    }
}
