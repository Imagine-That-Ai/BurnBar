import SwiftUI
import OpenBurnBarKernel

// MARK: - Fleet Dashboard (iOS)
//
// Mobile port of the Mac fleet dashboard (`AgentLens/Views/Dashboard/Fleet/
// FleetView.swift`): running-count header, per-agent cards, machine strip,
// per-repo grouping, and probe/persistence health — rendered from the sealed
// Firestore mirror through `MobileFleetStore`.
//
// Honesty invariants carried over from the Mac: every count, status, and
// label derives from the snapshot DTO; degraded/offline states are typed and
// visible; no fabricated liveness, process, or machine data is ever rendered.
// Read-only on mobile (v1): watching, not steering — orchestration stays on
// the Mac.
//
// Carries no navigation chrome of its own; the host that mounts it owns the
// title and the stack (same convention as `AIInboxView`).

struct FleetDashboardScreen: View {
    let store: MobileFleetStore

    /// Width at which the dashboard becomes two columns (agents + rail) —
    /// the same threshold `AIInboxSplitLayout` uses, so the app's wide
    /// layouts all break at one width.
    private static let wideLayoutMinimumWidth: CGFloat = 720

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                    header

                    if let lastError = store.lastError {
                        errorBanner(lastError)
                    }

                    content(width: geometry.size.width)
                }
                .padding(.vertical, MobileTheme.Spacing.md)
            }
            .scrollContentBackground(.hidden)
        }
        .accessibilityIdentifier("screen.fleet")
        .onAppear { store.loadIfNeeded() }
        .onDisappear { store.stopListening() }
    }

    // MARK: - Header

    private var header: some View {
        let readout = FleetHeaderCopy.readout(for: store.state)
        return VStack(alignment: .leading, spacing: MobileTheme.Spacing.xxs) {
            Text("AGENT FLEET")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .tracking(1.6)
                .foregroundStyle(MobileTheme.Colors.textMuted)

            Text(FleetHeaderCopy.runningReadout(readout))
                .font(MobileTheme.Typography.display)
                .foregroundStyle(
                    readout == .unavailable || readout == .checking
                        ? MobileTheme.Colors.textSecondary
                        : MobileTheme.success
                )
                .contentTransition(.numericText())
                .accessibilityLabel(FleetHeaderCopy.runningAccessibility(readout))

            if let subtitle = subtitleText {
                Text(subtitle)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, AuroraDesign.Layout.cardInset)
    }

    /// Says where the board came from and when. The dashboard is written by
    /// another machine, so provenance is load-bearing rather than decoration:
    /// without it a quiet board is indistinguishable from a broken one.
    private var subtitleText: String? {
        guard store.hasLoadedOnce, let updatedAt = store.lastUpdatedAt else { return nil }
        return "Synced from your Mac \(MissionConsoleFormatting.relativeTime(updatedAt))"
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(MobileTheme.warning)
            Text(message)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, AuroraDesign.Layout.cardInset)
        .padding(.vertical, MobileTheme.Spacing.sm)
        .background(MobileTheme.warning.opacity(0.08))
    }

    // MARK: - Content states

    @ViewBuilder
    private func content(width: CGFloat) -> some View {
        switch store.state {
        case .loading:
            loadingState
        case .macOffline(let lastUpdatedAt):
            macOfflinePane(lastUpdatedAt: lastUpdatedAt)
        case .empty(nil):
            unreadablePane
        case .empty(let snapshot?):
            board(snapshot: snapshot, width: width, showsEmptyNote: true)
        case .ready(let snapshot):
            board(snapshot: snapshot, width: width, showsEmptyNote: false)
        }
    }

    private var loadingState: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            AuroraLoadingShimmer(height: 116, cornerRadius: AuroraDesign.Shape.heroCorner)
            ForEach(0..<4, id: \.self) { _ in
                AuroraLoadingShimmer(height: 132, cornerRadius: AuroraDesign.Shape.standardCorner)
            }
        }
        .padding(.horizontal, AuroraDesign.Layout.cardInset)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Loading fleet snapshot")
    }

    private func macOfflinePane(lastUpdatedAt: Date?) -> some View {
        AuroraStatePane(
            kind: .empty,
            icon: "desktopcomputer",
            title: "Your Mac looks offline",
            message: macOfflineMessage(lastUpdatedAt: lastUpdatedAt)
        )
        .padding(.horizontal, AuroraDesign.Layout.cardInset)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 360)
    }

    private func macOfflineMessage(lastUpdatedAt: Date?) -> String {
        guard let lastUpdatedAt else {
            return "OpenBurnBar on your Mac publishes this dashboard, and nothing has arrived yet. "
                + "Make sure the Mac is awake and its fleet mirror is on."
        }
        return "OpenBurnBar on your Mac publishes this dashboard. The last update arrived "
            + "\(MissionConsoleFormatting.relativeTime(lastUpdatedAt)) — the Mac may be asleep, "
            + "offline, or have the fleet mirror turned off."
    }

    /// `empty(nil)`: the mirror document exists (the Mac IS publishing) but
    /// could not be opened on this device. The error banner above carries the
    /// reason; no agent data is invented in the meantime.
    private var unreadablePane: some View {
        AuroraStatePane(
            kind: .empty,
            icon: "circle.hexagongrid",
            title: "No fleet data yet",
            message: "Your Mac is publishing its fleet snapshot, but this device can't open it yet. "
                + "Once a readable update arrives, your agents appear here automatically."
        )
        .padding(.horizontal, AuroraDesign.Layout.cardInset)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 360)
    }

    // MARK: - Board

    @ViewBuilder
    private func board(snapshot: BurnBarFleetSnapshot, width: CGFloat, showsEmptyNote: Bool) -> some View {
        if case .degraded(let reason) = snapshot.persistenceHealth {
            FleetPersistenceBanner(reason: reason)
                .padding(.horizontal, AuroraDesign.Layout.cardInset)
        }

        if showsEmptyNote {
            emptyFleetNote(cadenceSeconds: snapshot.cadenceSeconds)
                .padding(.horizontal, AuroraDesign.Layout.cardInset)
        }

        if width >= Self.wideLayoutMinimumWidth {
            wideBoard(snapshot: snapshot)
        } else {
            compactBoard(snapshot: snapshot)
        }
    }

    private func compactBoard(snapshot: BurnBarFleetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
            machineSection(snapshot: snapshot)
            agentsSection(snapshot: snapshot)
            reposSection(snapshot: snapshot)
            probeIssuesSection(snapshot: snapshot)
        }
        .padding(.horizontal, AuroraDesign.Layout.cardInset)
    }

    /// Wide layouts (≥720pt): the agent cards keep the reading column on the
    /// left; machine, repos, and health form a fixed rail on the right.
    private func wideBoard(snapshot: BurnBarFleetSnapshot) -> some View {
        HStack(alignment: .top, spacing: MobileTheme.Spacing.lg) {
            agentsSection(snapshot: snapshot)
                .frame(maxWidth: .infinity, alignment: .topLeading)

            VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                machineSection(snapshot: snapshot)
                reposSection(snapshot: snapshot)
                probeIssuesSection(snapshot: snapshot)
            }
            .frame(width: 340)
        }
        .padding(.horizontal, AuroraDesign.Layout.cardInset)
    }

    private func emptyFleetNote(cadenceSeconds: Int) -> some View {
        AuroraGlassCard(variant: .standard, padding: MobileTheme.Spacing.md) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                Text("No agents are currently running")
                    .font(MobileTheme.Typography.headline)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text(
                    "Your Mac reports every declared agent as present but non-running. "
                        + "It refreshes this snapshot about every \(cadenceSeconds)s."
                )
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("No agents are currently running. The Mac refreshes about every \(cadenceSeconds) seconds.")
    }

    // MARK: - Sections

    private func machineSection(snapshot: BurnBarFleetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            sectionHeader("Machine")
            FleetMachineStrip(machine: snapshot.machine)
        }
    }

    private func agentsSection(snapshot: BurnBarFleetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            sectionHeader("Agents")
            ForEach(FleetAgentOrdering.runningFirst(snapshot.agents), id: \.id) { agent in
                FleetAgentCard(agent: agent)
            }
        }
    }

    private func reposSection(snapshot: BurnBarFleetSnapshot) -> some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            sectionHeader("Repos")
            FleetRepoGroupsSection(rows: FleetRepoGroupRowModel.rows(for: snapshot))
        }
    }

    /// Bottom caveat section: only the probes that need attention. A fully
    /// healthy probe plane renders nothing — silence is the good outcome.
    @ViewBuilder
    private func probeIssuesSection(snapshot: BurnBarFleetSnapshot) -> some View {
        let issues = snapshot.probeHealth.filter { $0.state != .ok }
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                sectionHeader("Probe issues")
                FleetProbeHealthSection(issues: issues)
            }
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(MobileTheme.Typography.tiny)
            .fontWeight(.semibold)
            .tracking(1.1)
            .foregroundStyle(MobileTheme.Colors.textMuted)
    }
}
