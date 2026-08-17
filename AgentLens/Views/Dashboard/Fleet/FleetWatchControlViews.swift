import OpenBurnBarKernel
import SwiftUI

// MARK: - Header machine-cost strip

/// Header cost chips. Absent values stay nil/`—`; thermal/power are omitted.
struct FleetMachineCostStrip: View {
    let rows: [FleetMachineRow]

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ForEach(rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.label)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    FleetMachineValueText(row: row)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.5))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .stroke(DesignSystem.Colors.border.opacity(0.35), lineWidth: 1)
                )
                .accessibilityElement(children: .combine)
                .accessibilityLabel(row.accessibilityLabel)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Machine cost")
    }
}

// MARK: - Orchestrator designation + chat entry

/// Designation control (VAL-ORCH-034): the picker and badge change only
/// after daemon acknowledgement. Approve-before-delivery is required.
struct FleetOrchestratorSection: View {
    let viewModel: FleetViewModel
    let onOpenOrchestratorChat: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Orchestrator")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            GlassCard {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Image(systemName: "network")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.whimsy)

                        Text(designationTitle)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        Spacer()

                        if viewModel.isSettingDesignation {
                            ProgressView()
                                .controlSize(.small)
                                .accessibilityLabel("Updating orchestrator designation")
                        }
                    }

                    if !viewModel.isDesignationUnavailable {
                        Picker("Designation", selection: designationBinding) {
                            Text("BurnBar-managed").tag(DesignationChoice.burnBarManaged)
                            ForEach(BurnBarFleetAgentID.declaredRoster, id: \.self) { agentID in
                                Text(viewModel.providerName(for: agentID))
                                    .tag(DesignationChoice.agent(agentID))
                            }
                            Text("None").tag(DesignationChoice.none)
                        }
                        .pickerStyle(.menu)
                        .labelsHidden()
                        .disabled(viewModel.isSettingDesignation)
                        .accessibilityLabel("Orchestrator designation")
                    }

                    if viewModel.orchestratorState == nil, viewModel.orchestratorStateError == nil {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("Loading designation…")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Loading orchestrator designation")
                    }

                    if let error = viewModel.orchestratorStateError {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.error)
                            Text("Designation unavailable: \(error)")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.error)
                                .lineLimit(2)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Designation unavailable: \(error)")
                    }

                    if let state = viewModel.orchestratorState, let setAt = state.setAt {
                        Text(
                            "\(viewModel.orchestratorStateError == nil ? "Set" : "Last acknowledged") "
                                + "\(FleetFormatting.formatRelativeTime(setAt)) · "
                                + "\(state.pendingDirectives) pending "
                                + "directive\(state.pendingDirectives == 1 ? "" : "s")"
                        )
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }

                    Text("Approve directives in chat before Hermes delivery. Nothing is sent until you approve.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if let onOpenOrchestratorChat {
                        Button(action: onOpenOrchestratorChat) {
                            HStack(spacing: DesignSystem.Spacing.xs) {
                                Image(systemName: "bubble.left.and.bubble.right")
                                    .font(DesignSystem.Typography.caption)
                                Text("Open orchestrator chat")
                                    .font(DesignSystem.Typography.caption)
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DesignSystem.Colors.whimsy)
                        .accessibilityLabel("Open orchestrator chat")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DesignSystem.Spacing.lg)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Orchestrator designation control")
        }
    }

    /// The designation choices offered by the control (VAL-ORCH-034):
    /// BurnBar-managed, any declared agent, or None.
    private enum DesignationChoice: Hashable {
        case burnBarManaged
        case agent(BurnBarFleetAgentID)
        case none
    }

    private var designationTitle: String {
        guard let designation = viewModel.designationKind else {
            return viewModel.orchestratorStateError == nil
                ? "Checking orchestrator…"
                : "Orchestrator unavailable"
        }
        let prefix = viewModel.orchestratorStateError == nil ? "" : "Last acknowledged: "
        switch designation {
        case .burnBarManaged:
            return prefix + "BurnBar-managed"
        case .agent(let id, _):
            return prefix + "Designated: \(viewModel.providerName(for: id))"
        case .none:
            return prefix + "No orchestrator designated"
        }
    }

    private var designationBinding: Binding<DesignationChoice> {
        Binding(
            get: {
                guard let designation = viewModel.designationKind else {
                    return .none
                }
                switch designation {
                case .burnBarManaged:
                    return .burnBarManaged
                case .agent(let id, _):
                    return .agent(id)
                case .none:
                    return .none
                }
            },
            set: { choice in
                let designation: BurnBarOrchestratorDesignation
                switch choice {
                case .burnBarManaged:
                    designation = .burnBarManaged
                case .agent(let agentID):
                    designation = .agent(id: agentID, sessionRef: .absent)
                case .none:
                    designation = .none
                }
                Task { await viewModel.setDesignation(designation) }
            }
        )
    }
}
