import BurnBarCore
import SwiftUI

// MARK: - Fleet View

/// The fleet dashboard (M3): running-count header, per-provider chips,
/// per-agent cards, per-repo grouping, machine status, and probe health —
/// all rendered from the daemon snapshot through `FleetViewModel`.
///
/// Honesty invariants: every count, status, and label derives from the
/// snapshot DTO; degraded/daemon-down states are typed and visible; no
/// fabricated liveness, process, or cost data is ever rendered.
struct FleetView: View {
    @State private var viewModel: FleetViewModel

    init(
        service: FleetService,
        tokenBurnProvider: @escaping (BurnBarFleetAgentID) -> Double? = { _ in nil }
    ) {
        _viewModel = State(initialValue: FleetViewModel(
            service: service,
            tokenBurnProvider: tokenBurnProvider
        ))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                fleetHeader
                staleBanner
                loadStateContent
            }
            .padding(DesignSystem.Spacing.xl)
        }
        .background(Color.clear)
        .scrollContentBackground(.hidden)
        .onAppear { viewModel.viewAppeared() }
        .onDisappear { viewModel.viewDisappeared() }
    }

    // MARK: - Header

    private var fleetHeader: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Live Agent Fleet")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text("Which agents are running right now, on which repos, at what machine cost.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
                if case .daemonDown = viewModel.loadState {
                    // No snapshot data is presented as current while the
                    // daemon is down (VAL-DASH-008): the header shows a
                    // neutral state instead of the last running count.
                    Text("Unavailable")
                        .font(DesignSystem.Typography.display)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .accessibilityLabel("Fleet data unavailable")
                } else {
                    Text("\(viewModel.runningCount) running")
                        .font(DesignSystem.Typography.display)
                        .foregroundStyle(DesignSystem.Colors.success)
                        .accessibilityLabel("\(viewModel.runningCount) agents running")
                }

                if let snapshot = viewModel.snapshot {
                    Text("Updated \(FleetFormatting.formatRelativeTime(snapshot.generatedAt))")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }
        }
    }

    // MARK: - Stale banner

    @ViewBuilder
    private var staleBanner: some View {
        if viewModel.isStale, let age = viewModel.snapshotAgeSeconds {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.blaze)

                Text(
                    "Snapshot is stale (\(FleetFormatting.formatAge(age)) old — the daemon has not refreshed within "
                        + "\(viewModel.cadenceSeconds * FleetService.stalenessThresholdMultiplier)s)."
                )
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.warning.opacity(0.08))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .stroke(DesignSystem.Colors.warning.opacity(0.3), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Fleet snapshot is stale")
        }
    }

    // MARK: - Load state content

    @ViewBuilder
    private var loadStateContent: some View {
        switch viewModel.loadState {
        case .loading:
            loadingView
        case .daemonDown(let reason):
            daemonDownView(reason: reason)
        case .ready, .empty:
            dashboardContent
        }
    }

    private var loadingView: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            ProgressView()
                .controlSize(.regular)
            Text("Loading fleet snapshot…")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.xxxl)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading fleet snapshot")
    }

    private func daemonDownView(reason: String) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "bolt.horizontal.circle.fill")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.error)

                    Text("BurnBar daemon unreachable")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                }

                Text(
                    "The fleet dashboard needs the local BurnBar daemon to report live agent state. "
                        + "No agent or machine data is shown because none is current."
                )
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(
                    "Recovery: the daemon restarts automatically (or run BurnBarDaemon manually). "
                        + "The dashboard reconnects on the next poll."
                )
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(reason)
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.lg)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("BurnBar daemon unreachable. No current fleet data.")
    }

    // MARK: - Dashboard content

    @ViewBuilder
    private var dashboardContent: some View {
        if case .empty = viewModel.loadState {
            emptyFleetState
        }

        if let snapshot = viewModel.snapshot {
            orchestratorSection
            providerChips(snapshot: snapshot)
            agentCards(snapshot: snapshot)
            repoGroups
            machinePanel
            resourceConsumers
            probeHealthSection(snapshot: snapshot)
        }
    }

    // MARK: - Orchestrator designation (M4)

    /// The daemon-authoritative designation control (VAL-ORCH-034): the user
    /// can select BurnBar-managed, any declared agent, or None. Each action
    /// sends the corresponding daemon set request; the control/badge changes
    /// only after daemon acknowledgement. A rejected or unavailable set
    /// preserves the prior acknowledged state and shows a typed error — no
    /// optimistic local state.
    private var orchestratorSection: some View {
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
                    .disabled(viewModel.isSettingDesignation || viewModel.orchestratorState == nil)
                    .accessibilityLabel("Orchestrator designation")

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
                                .font(.system(size: 10))
                                .foregroundStyle(DesignSystem.Colors.error)
                            Text("Designation update failed: \(error)")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.error)
                                .lineLimit(2)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("Designation update failed: \(error)")
                    }

                    if let state = viewModel.orchestratorState, let setAt = state.setAt {
                        Text("Set \(FleetFormatting.formatRelativeTime(setAt)) · \(state.pendingDirectives) pending directive\(state.pendingDirectives == 1 ? "" : "s")")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
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
        switch viewModel.designationKind {
        case .burnBarManaged:
            return "BurnBar-managed"
        case .agent(let id, _):
            return "Designated: \(viewModel.providerName(for: id))"
        case .none:
            return "No orchestrator designated"
        }
    }

    private var designationBinding: Binding<DesignationChoice> {
        Binding(
            get: {
                switch viewModel.designationKind {
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

    private var emptyFleetState: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text("No agents are currently running")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text(
                    "All ten declared agents are present but non-running. "
                        + "The dashboard checks again every \(viewModel.cadenceSeconds)s."
                )
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.lg)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No agents are currently running. Next check in \(viewModel.cadenceSeconds) seconds.")
    }

    // MARK: - Provider chips

    private func providerChips(snapshot: BurnBarFleetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Running by provider")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 120), spacing: DesignSystem.Spacing.sm)],
                spacing: DesignSystem.Spacing.sm
            ) {
                ForEach(viewModel.countsByProvider, id: \.agentID) { entry in
                    providerChip(agentID: entry.agentID, count: entry.count)
                }
            }
        }
    }

    private func providerChip(agentID: BurnBarFleetAgentID, count: Int) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Circle()
                .fill(viewModel.providerColor(for: agentID))
                .frame(width: 8, height: 8)

            Text(viewModel.providerName(for: agentID))
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)

            Spacer(minLength: 0)

            Text("\(count)")
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(count > 0 ? DesignSystem.Colors.success : DesignSystem.Colors.textSecondary)
        }
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
        .accessibilityLabel("\(viewModel.providerName(for: agentID)), \(count) running")
    }

    // MARK: - Agent cards

    private func agentCards(snapshot: BurnBarFleetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Agents")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 300), spacing: DesignSystem.Spacing.md)],
                spacing: DesignSystem.Spacing.md
            ) {
                ForEach(snapshot.agents, id: \.id) { agent in
                    FleetAgentCard(agent: agent, viewModel: viewModel)
                }
            }
        }
    }

    // MARK: - Repo groups

    private var repoGroups: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Repos")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            if viewModel.repoGroupRows.isEmpty {
                Text("No repo attribution available")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            } else {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(viewModel.repoGroupRows) { row in
                        FleetRepoGroupRow(row: row, viewModel: viewModel)
                    }
                }
            }
        }
    }

    // MARK: - Machine panel

    private var machinePanel: some View {
        FleetMachinePanel(rows: viewModel.machineRows)
    }

    // MARK: - Resource consumers

    private var resourceConsumers: some View {
        FleetResourceConsumersSection(
            consumers: viewModel.resourceConsumers,
            viewModel: viewModel
        )
    }

    // MARK: - Probe health

    private func probeHealthSection(snapshot: BurnBarFleetSnapshot) -> some View {
        FleetProbeHealthSection(health: snapshot.probeHealth, viewModel: viewModel)
    }
}
