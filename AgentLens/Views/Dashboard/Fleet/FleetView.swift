import OpenBurnBarKernel
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
    /// Optional: dashboard wires this to the existing chat panel.
    private let onOpenOrchestratorChat: (() -> Void)?

    init(
        service: FleetService,
        tokenBurnProvider: @escaping (BurnBarFleetAgentID) -> Double? = { _ in nil },
        onOpenOrchestratorChat: (() -> Void)? = nil
    ) {
        _viewModel = State(initialValue: FleetViewModel(
            service: service,
            tokenBurnProvider: tokenBurnProvider
        ))
        self.onOpenOrchestratorChat = onOpenOrchestratorChat
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                fleetHeader
                if viewModel.isStale {
                    staleBanner
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.xl)
            .padding(.top, DesignSystem.Spacing.xl)
            .padding(.bottom, DesignSystem.Spacing.md)

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    loadStateContent
                }
                .padding(DesignSystem.Spacing.xl)
            }
            .scrollContentBackground(.hidden)
        }
        .background(Color.clear)
        .onAppear { viewModel.viewAppeared() }
        .onDisappear { viewModel.viewDisappeared() }
    }

    // MARK: - Header

    private var fleetHeader: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.lg) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Live Agent Fleet")
                        .font(DesignSystem.Typography.title)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text("Watch live agents and machine cost. Designate an orchestrator to propose work.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
                    switch viewModel.headerRunningReadout {
                    case .unavailable:
                        Text("Unavailable")
                            .font(DesignSystem.Typography.display)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .accessibilityLabel("Fleet data unavailable")
                    case .checking:
                        Text("Checking…")
                            .font(DesignSystem.Typography.display)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .accessibilityLabel("Checking fleet snapshot")
                    case .running(let count):
                        Text("\(count) running")
                            .font(DesignSystem.Typography.display)
                            .foregroundStyle(DesignSystem.Colors.success)
                            .accessibilityLabel("\(count) agents running")
                    }

                    if let snapshot = viewModel.snapshot {
                        Text("Updated \(FleetFormatting.formatRelativeTime(snapshot.generatedAt))")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }
            }

            if !viewModel.headerMachineMetrics.isEmpty {
                FleetMachineCostStrip(rows: viewModel.headerMachineMetrics)
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
        if let snapshot = viewModel.snapshot {
            watchAndControlBand
            if case .empty = viewModel.loadState {
                emptyFleetState
            }
            providerChips(snapshot: snapshot)
            agentCards(snapshot: snapshot)
            repoGroups
            probeHealthSection(snapshot: snapshot)
        }
    }

    private var watchAndControlBand: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            FleetOrchestratorSection(
                viewModel: viewModel,
                onOpenOrchestratorChat: onOpenOrchestratorChat
            )
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 280), spacing: DesignSystem.Spacing.md)],
                spacing: DesignSystem.Spacing.md
            ) {
                machinePanel
                resourceConsumers
            }
        }
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
