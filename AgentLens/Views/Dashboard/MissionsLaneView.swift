import AppKit
import SwiftUI
import OpenBurnBarCore

// MARK: - Missions Lane
//
// A dedicated "flight-ops" lane for starting and managing missions.
// Visual language: runway / gate board. Oversized monospaced header,
// state-filter chips with live counts, mission cards that carry a
// colored state stripe on the left edge, and a prominent "File new
// mission" CTA that opens an authoring sheet.

struct MissionsLaneView: View {
    @Bindable var operatingLayer: OpenBurnBarOperatingLayer
    var daemonManager: OpenBurnBarDaemonManager = .shared
    var onOpenSessionLogs: () -> Void

    @State private var stateFilter: MissionStateFilter = .all
    @State private var projectFilter: String? = nil
    @State private var expandedMissionID: String? = nil
    @State private var showingNewMissionSheet = false
    @State private var refreshing = false
    @State private var heroAppeared = false

    private var runtime: OpenBurnBarControllerRuntimeSnapshot {
        operatingLayer.snapshot.controllerRuntime
    }

    private var missions: [OpenBurnBarControllerMissionRecord] {
        runtime.missions
    }

    private var filteredMissions: [OpenBurnBarControllerMissionRecord] {
        missions
            .filter { stateFilter.matches($0) }
            .filter { projectFilter == nil || $0.projectName == projectFilter }
            .sorted { MissionSortRank.rank(for: $0) < MissionSortRank.rank(for: $1) }
    }

    private var knownProjects: [String] {
        Array(Set(missions.map(\.projectName))).sorted()
    }

    private var totalBurnUSD: Double {
        missions.reduce(0) { $0 + $1.burnCostUSD }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                heroHeader
                runwayStrip
                stateChipRail

                if missions.isEmpty {
                    emptyLaneView
                } else if filteredMissions.isEmpty {
                    filteredEmptyView
                } else {
                    missionGrid
                }
            }
            .padding(DesignSystem.Spacing.xl)
            .opacity(heroAppeared ? 1 : 0)
            .offset(y: heroAppeared ? 0 : 14)
            .animation(DesignSystem.Animation.standard, value: heroAppeared)
        }
        .background(laneBackdrop)
        .scrollContentBackground(.hidden)
        .onAppear {
            heroAppeared = true
            Task { await operatingLayer.refreshControllerRuntime() }
        }
        .sheet(isPresented: $showingNewMissionSheet) {
            NewMissionSheet(
                operatingLayer: operatingLayer,
                daemonManager: daemonManager,
                defaultProjectSlug: projectFilter ?? knownProjects.first,
                onDismiss: { showingNewMissionSheet = false }
            )
        }
    }

    // MARK: - Hero Header

    private var heroHeader: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.xl) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    RunwayInsignia()
                        .frame(width: 28, height: 28)
                    Text("MISSION · CONTROL")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .tracking(2.8)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                Text("Missions Lane")
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .kerning(-0.6)

                Text(heroSubtitle)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 560, alignment: .leading)
            }

            Spacer(minLength: DesignSystem.Spacing.lg)

            VStack(alignment: .trailing, spacing: DesignSystem.Spacing.sm) {
                newMissionButton
                refreshButton
            }
        }
    }

    private var heroSubtitle: String {
        let inFlight = missions.filter { $0.state == .running || $0.state == .partial }.count
        let awaiting = missions.filter { $0.approval == .pending }.count
        let blocked = missions.filter { $0.state == .blocked }.count

        if missions.isEmpty {
            return "This is the dedicated lane for every mission. File a new one to get a runway assigned — state, approval, burn, and PR linkage will live here in one place."
        }

        var parts: [String] = []
        parts.append("\(inFlight) in-flight")
        if awaiting > 0 { parts.append("\(awaiting) awaiting approval") }
        if blocked > 0 { parts.append("\(blocked) blocked") }
        parts.append("\(totalBurnUSD.formatAsCost()) burned across the lane")
        return parts.joined(separator: " · ")
    }

    private var newMissionButton: some View {
        Button {
            showingNewMissionSheet = true
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("File New Mission")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, DesignSystem.Spacing.lg)
            .padding(.vertical, DesignSystem.Spacing.md)
            .background {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.primaryGradient)
                    .shadow(color: DesignSystem.Colors.blaze.opacity(0.35), radius: 12, y: 4)
            }
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.75)
            )
        }
        .buttonStyle(.plain)
        .help("Start authoring a new mission (project, title, summary, recommendation).")
        .keyboardShortcut("n", modifiers: [.command])
    }

    private var refreshButton: some View {
        Button {
            guard !refreshing else { return }
            refreshing = true
            Task {
                await operatingLayer.refreshControllerRuntime()
                await MainActor.run { refreshing = false }
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: refreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .rotationEffect(.degrees(refreshing ? 360 : 0))
                    .animation(
                        refreshing
                            ? .linear(duration: 0.9).repeatForever(autoreverses: false)
                            : .default,
                        value: refreshing
                    )
                Text("Refresh runtime")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.7))
            )
            .overlay(
                Capsule().stroke(DesignSystem.Colors.borderSubtle.opacity(0.6), lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
        .disabled(refreshing)
    }

    // MARK: - Runway Strip (metrics)

    private var runwayStrip: some View {
        HStack(spacing: 0) {
            runwayCell(
                label: "IN FLIGHT",
                value: "\(missions.filter { $0.state == .running || $0.state == .partial }.count)",
                accent: DesignSystem.Colors.blaze,
                icon: "airplane"
            )
            runwayDivider
            runwayCell(
                label: "PLANNED",
                value: "\(missions.filter { $0.state == .planned }.count)",
                accent: DesignSystem.Colors.amber,
                icon: "list.bullet.rectangle.portrait"
            )
            runwayDivider
            runwayCell(
                label: "BLOCKED",
                value: "\(missions.filter { $0.state == .blocked }.count)",
                accent: DesignSystem.Colors.error,
                icon: "exclamationmark.octagon"
            )
            runwayDivider
            runwayCell(
                label: "COMPLETED",
                value: "\(missions.filter { $0.state == .completed }.count)",
                accent: DesignSystem.Colors.success,
                icon: "checkmark.seal"
            )
            runwayDivider
            runwayCell(
                label: "TOTAL BURN",
                value: totalBurnUSD.formatAsCost(),
                accent: DesignSystem.Colors.hermesAureate,
                icon: "flame"
            )
        }
        .padding(.vertical, DesignSystem.Spacing.md)
        .padding(.horizontal, DesignSystem.Spacing.lg)
        .background {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.78))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                        .strokeBorder(DesignSystem.Colors.borderSubtle.opacity(0.8), lineWidth: 0.6)
                )
        }
    }

    private func runwayCell(label: String, value: String, accent: Color, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(accent)
                Text(label)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.4)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .monospaced))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var runwayDivider: some View {
        Rectangle()
            .fill(DesignSystem.Colors.borderSubtle.opacity(0.7))
            .frame(width: 0.8)
            .frame(maxHeight: .infinity)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, 2)
    }

    // MARK: - State filter chips

    private var stateChipRail: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack {
                Text("FILTER")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(1.6)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Spacer()
                if knownProjects.count > 1 {
                    Menu {
                        Button("All projects") { projectFilter = nil }
                        Divider()
                        ForEach(knownProjects, id: \.self) { project in
                            Button(project) { projectFilter = project }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "folder")
                                .font(.system(size: 10, weight: .medium))
                            Text(projectFilter ?? "All projects")
                                .font(DesignSystem.Typography.tiny)
                            Image(systemName: "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                                .opacity(0.6)
                        }
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.6)))
                        .overlay(Capsule().stroke(DesignSystem.Colors.borderSubtle.opacity(0.55), lineWidth: 0.6))
                    }
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(MissionStateFilter.allCases) { filter in
                        let count = missions.filter { filter.matches($0) }.count
                        MissionStateChip(
                            filter: filter,
                            count: count,
                            isActive: stateFilter == filter
                        ) {
                            withAnimation(DesignSystem.Animation.snappy) {
                                stateFilter = filter
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Mission grid

    private var missionGrid: some View {
        let columns = [
            GridItem(.adaptive(minimum: 420, maximum: 640), spacing: DesignSystem.Spacing.lg, alignment: .top)
        ]

        return LazyVGrid(columns: columns, alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            ForEach(Array(filteredMissions.enumerated()), id: \.element.id) { index, mission in
                MissionGateCard(
                    mission: mission,
                    isExpanded: expandedMissionID == mission.id,
                    onToggleExpand: {
                        withAnimation(DesignSystem.Animation.standard) {
                            expandedMissionID = expandedMissionID == mission.id ? nil : mission.id
                        }
                    },
                    onApprove: {
                        Task {
                            operatingLayer.approveMission(
                                id: mission.id,
                                projectName: mission.projectName
                            )
                            await operatingLayer.refreshControllerRuntime()
                        }
                    },
                    onInspect: onOpenSessionLogs,
                    onOpenPR: { linkage in
                        if let url = URL(string: linkage.url) {
                            NSWorkspace.shared.open(url)
                        }
                    }
                )
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.97).combined(with: .opacity),
                    removal: .opacity
                ))
                .animation(
                    DesignSystem.Animation.standard.delay(Double(min(index, 6)) * 0.04),
                    value: heroAppeared
                )
            }
        }
    }

    // MARK: - Empty states

    private var emptyLaneView: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            RunwayArcsGraphic()
                .frame(width: 160, height: 160)
                .opacity(0.88)

            VStack(spacing: DesignSystem.Spacing.xs) {
                Text("Runway is clear.")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Missions you file will land here — each one with its own state, approval, burn, and PR linkage.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 460)
            }

            Button {
                showingNewMissionSheet = true
            } label: {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                    Text("File First Mission")
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, DesignSystem.Spacing.xl)
                .padding(.vertical, DesignSystem.Spacing.md)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(DesignSystem.Colors.primaryGradient)
                )
                .shadow(color: DesignSystem.Colors.blaze.opacity(0.3), radius: 10, y: 3)
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.xxxl)
    }

    private var filteredEmptyView: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "line.3.horizontal.decrease.circle")
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text("No missions match the current filter.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Spacer()
            Button("Clear filter") {
                withAnimation(DesignSystem.Animation.snappy) {
                    stateFilter = .all
                    projectFilter = nil
                }
            }
            .buttonStyle(.borderless)
            .font(DesignSystem.Typography.caption)
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(DesignSystem.Colors.borderSubtle, lineWidth: 0.6)
        )
    }

    // MARK: - Backdrop

    private var laneBackdrop: some View {
        ZStack {
            DesignSystem.Colors.background

            // Subtle diagonal runway stripes in the far background.
            GeometryReader { geo in
                Path { path in
                    let spacing: CGFloat = 40
                    let diag = geo.size.width + geo.size.height
                    var x: CGFloat = -geo.size.height
                    while x < diag {
                        path.move(to: CGPoint(x: x, y: 0))
                        path.addLine(to: CGPoint(x: x + geo.size.height, y: geo.size.height))
                        x += spacing
                    }
                }
                .stroke(DesignSystem.Colors.borderSubtle.opacity(0.35), lineWidth: 0.4)
            }
            .allowsHitTesting(false)

            // A warm glow in the top-right corner.
            RadialGradient(
                colors: [
                    DesignSystem.Colors.blaze.opacity(0.10),
                    Color.clear
                ],
                center: .init(x: 0.92, y: 0.08),
                startRadius: 20,
                endRadius: 420
            )
            .blendMode(.plusLighter)
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Mission State Filter

private enum MissionStateFilter: String, Identifiable, CaseIterable {
    case all
    case planned
    case running
    case partial
    case blocked
    case completed
    case awaitingApproval

    var id: String { rawValue }

    var label: String {
        switch self {
        case .all: return "All"
        case .planned: return "Planned"
        case .running: return "Running"
        case .partial: return "Partial"
        case .blocked: return "Blocked"
        case .completed: return "Completed"
        case .awaitingApproval: return "Needs Approval"
        }
    }

    var icon: String {
        switch self {
        case .all: return "square.grid.2x2"
        case .planned: return "flag"
        case .running: return "airplane.departure"
        case .partial: return "clock.badge.exclamationmark"
        case .blocked: return "exclamationmark.octagon"
        case .completed: return "checkmark.seal"
        case .awaitingApproval: return "hand.raised"
        }
    }

    var accent: Color {
        switch self {
        case .all: return DesignSystem.Colors.textSecondary
        case .planned: return DesignSystem.Colors.textSecondary
        case .running: return DesignSystem.Colors.blaze
        case .partial: return DesignSystem.Colors.amber
        case .blocked: return DesignSystem.Colors.error
        case .completed: return DesignSystem.Colors.success
        case .awaitingApproval: return DesignSystem.Colors.amber
        }
    }

    func matches(_ mission: OpenBurnBarControllerMissionRecord) -> Bool {
        switch self {
        case .all: return true
        case .planned: return mission.state == .planned
        case .running: return mission.state == .running
        case .partial: return mission.state == .partial
        case .blocked: return mission.state == .blocked
        case .completed: return mission.state == .completed
        case .awaitingApproval: return mission.approval == .pending
        }
    }
}

// MARK: - Mission sort rank

private enum MissionSortRank {
    static func rank(for mission: OpenBurnBarControllerMissionRecord) -> Int {
        // Higher priority = lower rank (sorts first).
        if mission.approval == .pending { return 0 }
        switch mission.state {
        case .blocked:   return 1
        case .partial:   return 2
        case .running:   return 3
        case .planned:   return 4
        case .completed: return 5
        }
    }
}

// MARK: - Mission State Chip

private struct MissionStateChip: View {
    let filter: MissionStateFilter
    let count: Int
    let isActive: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: filter.icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(filter.label)
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                Text("\(count)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(isActive ? .white.opacity(0.9) : filter.accent)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        Capsule().fill(
                            isActive
                                ? Color.white.opacity(0.25)
                                : filter.accent.opacity(0.14)
                        )
                    )
            }
            .foregroundStyle(isActive ? .white : DesignSystem.Colors.textSecondary)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background {
                if isActive {
                    Capsule().fill(filter.accent)
                } else {
                    Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.7))
                }
            }
            .overlay(
                Capsule()
                    .strokeBorder(
                        isActive ? Color.clear : filter.accent.opacity(0.25),
                        lineWidth: 0.75
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Mission Gate Card

private struct MissionGateCard: View {
    let mission: OpenBurnBarControllerMissionRecord
    let isExpanded: Bool
    let onToggleExpand: () -> Void
    let onApprove: () -> Void
    let onInspect: () -> Void
    let onOpenPR: (OpenBurnBarControllerMissionPRLinkage) -> Void

    @State private var isHovered = false

    private var packetSummary: String {
        let trimmed = (mission.packetSummary ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return mission.summary
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            stateStripe
            cardBody
        }
        .background {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                        .fill(DesignSystem.Colors.surface.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    mission.state.color.opacity(isHovered ? 0.10 : 0.06),
                                    Color.clear,
                                    mission.state.color.opacity(0.025)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                )
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            mission.state.color.opacity(isHovered ? 0.45 : 0.28),
                            DesignSystem.Colors.borderSubtle.opacity(0.6)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        )
        .shadow(
            color: mission.state.color.opacity(isHovered ? 0.16 : 0.06),
            radius: isHovered ? 14 : 6,
            y: isHovered ? 5 : 2
        )
        .scaleEffect(isHovered ? 1.005 : 1.0)
        .animation(DesignSystem.Animation.hover, value: isHovered)
        .onHover { isHovered = $0 }
    }

    private var stateStripe: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(mission.state.color.opacity(0.85))

            // Gate number.
            VStack(spacing: 2) {
                Text("GATE")
                    .font(.system(size: 7, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(.white.opacity(0.75))
                Text(gateCode)
                    .font(.system(size: 13, weight: .heavy, design: .monospaced))
                    .foregroundStyle(.white)
            }
            .padding(.top, 14)
            .frame(maxWidth: .infinity)
        }
        .frame(width: 36)
    }

    private var gateCode: String {
        let suffix = mission.id.suffix(3).uppercased()
        if suffix.isEmpty { return "—" }
        return String(suffix)
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            header
            summaryBlock
            metricsRow
            if isExpanded { expandedDetails }
            actionRow
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(mission.projectName)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text(relativeTimeString(since: mission.updatedAt))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Text(mission.title)
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 6) {
                OpenBurnBarStatusBadge(title: mission.state.label, color: mission.state.color)
                OpenBurnBarStatusBadge(title: mission.approval.label, color: mission.approval.color)
                if let takeover = mission.latestTakeoverState {
                    OpenBurnBarStatusBadge(title: takeover.label, color: takeover.color)
                }
            }
        }
    }

    private var summaryBlock: some View {
        Text(packetSummary)
            .font(DesignSystem.Typography.body)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .lineLimit(isExpanded ? nil : 2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var metricsRow: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            metricTile(
                label: "BURN",
                value: mission.burnCostUSD.formatAsCost(),
                accent: DesignSystem.Colors.hermesAureate
            )
            metricTile(
                label: "TOKENS",
                value: compactNumber(mission.burnTokens),
                accent: DesignSystem.Colors.textSecondary
            )
            metricTile(
                label: "RUNS",
                value: "\(mission.packetRunCount)",
                accent: DesignSystem.Colors.blaze
            )
            if mission.takeoverCount > 0 {
                metricTile(
                    label: "TAKEOVERS",
                    value: "\(mission.takeoverCount)",
                    accent: mission.latestTakeoverState?.color ?? DesignSystem.Colors.amber
                )
            }
        }
    }

    private func metricTile(label: String, value: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 8, weight: .bold, design: .monospaced))
                .tracking(1.2)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .monospaced))
                .foregroundStyle(accent)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .strokeBorder(accent.opacity(0.14), lineWidth: 0.6)
        )
    }

    @ViewBuilder
    private var expandedDetails: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Divider().background(DesignSystem.Colors.borderSubtle.opacity(0.5))

            if let runID = mission.activeRunID?.trimmed, !runID.isEmpty {
                detailRow(icon: "point.3.filled.connected.trianglepath.dotted", label: "Active run", value: runID)
            }
            if let worker = mission.activeWorkerName?.trimmed, !worker.isEmpty {
                detailRow(icon: "person.crop.circle.badge.clock", label: "Worker", value: worker)
            }
            if let result = mission.latestResultSummary?.trimmed, !result.isEmpty {
                detailRow(icon: "checklist", label: "Latest result", value: result)
            }
            if let detail = mission.latestResultDetail?.trimmed, !detail.isEmpty {
                detailRow(icon: "text.alignleft", label: "Result detail", value: detail)
            }
            if let takeoverReason = mission.latestTakeoverReason?.trimmed, !takeoverReason.isEmpty {
                detailRow(
                    icon: "arrow.triangle.branch",
                    label: "Takeover",
                    value: takeoverReason,
                    accent: mission.latestTakeoverState?.color ?? DesignSystem.Colors.blaze
                )
            }
            if let linkage = mission.prLinkage {
                detailRow(
                    icon: "link",
                    label: "Pull request",
                    value: "\(linkage.repository) #\(linkage.prNumberOrID) • \(linkage.state.label)"
                )
            }
        }
    }

    private func detailRow(icon: String, label: String, value: String, accent: Color = DesignSystem.Colors.textPrimary) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
                .frame(width: 14, alignment: .center)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(label.uppercased())
                    .font(.system(size: 8, weight: .bold, design: .monospaced))
                    .tracking(1.2)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(value)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            if mission.approval == .pending {
                primaryActionButton(
                    title: "Approve",
                    icon: "checkmark.seal.fill",
                    tint: DesignSystem.Colors.success,
                    action: onApprove
                )
            } else if mission.state == .planned {
                primaryActionButton(
                    title: "Start Mission",
                    icon: "play.fill",
                    tint: DesignSystem.Colors.blaze,
                    action: onApprove
                )
            } else if mission.state == .blocked || mission.state == .partial {
                primaryActionButton(
                    title: "Resume",
                    icon: "arrow.forward.circle.fill",
                    tint: DesignSystem.Colors.amber,
                    action: onApprove
                )
            }

            secondaryActionButton(
                title: "Inspect Logs",
                icon: "doc.text.magnifyingglass",
                action: onInspect
            )

            if let linkage = mission.prLinkage {
                secondaryActionButton(
                    title: "Open PR",
                    icon: "arrow.up.forward.square",
                    action: { onOpenPR(linkage) }
                )
            }

            Spacer(minLength: 0)

            Button(action: onToggleExpand) {
                HStack(spacing: 4) {
                    Text(isExpanded ? "Less" : "Details")
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                }
                .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 2)
    }

    private func primaryActionButton(title: String, icon: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, 7)
            .background(Capsule().fill(tint))
            .shadow(color: tint.opacity(0.35), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
    }

    private func secondaryActionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 10, weight: .semibold))
                Text(title).font(.system(size: 11, weight: .medium, design: .rounded))
            }
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, 7)
            .background(
                Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
            )
            .overlay(
                Capsule().stroke(DesignSystem.Colors.borderSubtle.opacity(0.7), lineWidth: 0.6)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - New Mission Sheet

private struct NewMissionSheet: View {
    @Bindable var operatingLayer: OpenBurnBarOperatingLayer
    var daemonManager: OpenBurnBarDaemonManager
    var defaultProjectSlug: String?
    var onDismiss: () -> Void

    @State private var projectSlug: String = ""
    @State private var title: String = ""
    @State private var summary: String = ""
    @State private var recommendation: BurnBarMissionRecommendation = .proceed
    @State private var isSubmitting = false
    @State private var errorMessage: String?

    private var registeredProjects: [String] {
        daemonManager.controllerProjects.map(\.projectSlug).sorted()
    }

    private var canSubmit: Bool {
        !projectSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !isSubmitting
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            sheetHeader

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                    projectField
                    titleField
                    summaryField
                    recommendationField

                    if let errorMessage {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(DesignSystem.Colors.error)
                            Text(errorMessage)
                                .font(DesignSystem.Typography.caption)
                                .foregroundStyle(DesignSystem.Colors.error)
                        }
                        .padding(DesignSystem.Spacing.md)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                                .fill(DesignSystem.Colors.error.opacity(0.08))
                        )
                    }
                }
                .padding(DesignSystem.Spacing.xl)
            }

            Divider()

            sheetFooter
        }
        .frame(minWidth: 540, idealWidth: 620, minHeight: 520, idealHeight: 560)
        .background(DesignSystem.Colors.background)
        .onAppear {
            if projectSlug.isEmpty, let defaultProjectSlug {
                projectSlug = defaultProjectSlug
            } else if projectSlug.isEmpty, let first = registeredProjects.first {
                projectSlug = first
            }
        }
    }

    private var sheetHeader: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            RunwayInsignia()
                .frame(width: 34, height: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text("NEW MISSION")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .tracking(2.4)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text("File a new mission")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("The daemon registers the mission and puts it on the runway awaiting approval.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            Spacer()
            Button(action: onDismiss) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(DesignSystem.Spacing.xl)
        .background(DesignSystem.Colors.surface.opacity(0.9))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignSystem.Colors.borderSubtle)
                .frame(height: 0.6)
        }
    }

    private var projectField: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            fieldLabel("Project", required: true)
            HStack(spacing: DesignSystem.Spacing.sm) {
                TextField("project-slug", text: $projectSlug)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.7))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                            .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.6)
                    )

                if !registeredProjects.isEmpty {
                    Menu {
                        ForEach(registeredProjects, id: \.self) { slug in
                            Button(slug) { projectSlug = slug }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "list.bullet")
                            Text("Choose")
                        }
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.6)))
                        .overlay(Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.6))
                    }
                    .menuIndicator(.hidden)
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            fieldLabel("Mission title", required: true)
            TextField("Ship pilot preview", text: $title)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.7))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                        .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.6)
                )
        }
    }

    private var summaryField: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            fieldLabel("Summary", required: true)
            TextEditor(text: $summary)
                .font(DesignSystem.Typography.body)
                .frame(minHeight: 120)
                .padding(DesignSystem.Spacing.sm)
                .scrollContentBackground(.hidden)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                        .fill(DesignSystem.Colors.surfaceElevated.opacity(0.7))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                        .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 0.6)
                )
        }
    }

    private var recommendationField: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            fieldLabel("Recommendation", required: false)
            HStack(spacing: DesignSystem.Spacing.sm) {
                ForEach(BurnBarMissionRecommendation.allCases, id: \.self) { option in
                    recommendationChip(option: option)
                }
            }
        }
    }

    private func recommendationChip(option: BurnBarMissionRecommendation) -> some View {
        let isSelected = recommendation == option
        return Button {
            recommendation = option
        } label: {
            Text(recommendationLabel(option))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(isSelected ? .white : DesignSystem.Colors.textSecondary)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, 7)
                .background(
                    Capsule().fill(
                        isSelected
                            ? recommendationColor(option)
                            : DesignSystem.Colors.surfaceElevated.opacity(0.6)
                    )
                )
                .overlay(
                    Capsule()
                        .stroke(
                            isSelected ? Color.clear : DesignSystem.Colors.borderSubtle,
                            lineWidth: 0.6
                        )
                )
        }
        .buttonStyle(.plain)
    }

    private func recommendationLabel(_ option: BurnBarMissionRecommendation) -> String {
        switch option {
        case .proceed: return "Proceed"
        case .review: return "Review"
        case .pause: return "Pause"
        case .escalate: return "Escalate"
        }
    }

    private func recommendationColor(_ option: BurnBarMissionRecommendation) -> Color {
        switch option {
        case .proceed: return DesignSystem.Colors.success
        case .review: return DesignSystem.Colors.amber
        case .pause: return DesignSystem.Colors.textSecondary
        case .escalate: return DesignSystem.Colors.error
        }
    }

    private func fieldLabel(_ text: String, required: Bool) -> some View {
        HStack(spacing: 4) {
            Text(text.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .tracking(1.6)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            if required {
                Text("*")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.blaze)
            }
        }
    }

    private var sheetFooter: some View {
        HStack {
            if isSubmitting {
                HStack(spacing: 6) {
                    ProgressView().scaleEffect(0.7)
                    Text("Filing mission with daemon…")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            Spacer()
            Button("Cancel", action: onDismiss)
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)

            Button(action: submit) {
                HStack(spacing: 6) {
                    Image(systemName: "paperplane.fill")
                    Text("File Mission")
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                        .fill(DesignSystem.Colors.primaryGradient)
                )
                .opacity(canSubmit ? 1 : 0.45)
            }
            .buttonStyle(.plain)
            .disabled(!canSubmit)
            .keyboardShortcut(.defaultAction)
        }
        .padding(DesignSystem.Spacing.xl)
        .background(DesignSystem.Colors.surface.opacity(0.9))
    }

    private func submit() {
        guard canSubmit else { return }
        errorMessage = nil
        isSubmitting = true
        Task {
            do {
                _ = try await operatingLayer.createMission(
                    projectSlug: projectSlug,
                    title: title,
                    summary: summary,
                    recommendation: recommendation
                )
                await operatingLayer.refreshControllerRuntime()
                await MainActor.run {
                    isSubmitting = false
                    onDismiss()
                }
            } catch {
                await MainActor.run {
                    isSubmitting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Runway Insignia (logo-mark)

private struct RunwayInsignia: View {
    var body: some View {
        ZStack {
            Circle()
                .fill(DesignSystem.Colors.surfaceElevated)
                .overlay(
                    Circle().strokeBorder(DesignSystem.Colors.blaze.opacity(0.45), lineWidth: 0.8)
                )

            // Runway stripe.
            Capsule()
                .fill(DesignSystem.Colors.blaze)
                .frame(width: 3, height: 18)
                .rotationEffect(.degrees(35))

            // Tiny dashes indicating runway markings.
            HStack(spacing: 2) {
                ForEach(0..<3, id: \.self) { _ in
                    Rectangle()
                        .fill(DesignSystem.Colors.amber)
                        .frame(width: 1.5, height: 3)
                }
            }
            .rotationEffect(.degrees(35))
            .offset(y: -8)
        }
    }
}

// MARK: - Runway Arcs (empty-state graphic)

private struct RunwayArcsGraphic: View {
    var body: some View {
        ZStack {
            // Three concentric arcs evoking radar sweep / runway approach.
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .trim(from: 0.1, to: 0.9)
                    .stroke(
                        DesignSystem.Colors.blaze.opacity(0.22 - Double(i) * 0.05),
                        style: StrokeStyle(lineWidth: 1.2, lineCap: .round, dash: [4, 6])
                    )
                    .scaleEffect(0.45 + CGFloat(i) * 0.25)
                    .rotationEffect(.degrees(200))
            }

            // Central runway / chevron.
            VStack(spacing: 3) {
                Image(systemName: "airplane.departure")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.primaryGradient)
                Rectangle()
                    .fill(DesignSystem.Colors.amber.opacity(0.7))
                    .frame(width: 34, height: 2)
                Rectangle()
                    .fill(DesignSystem.Colors.amber.opacity(0.35))
                    .frame(width: 22, height: 1.5)
            }
        }
    }
}

// MARK: - Helpers

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private func compactNumber(_ value: Int) -> String {
    let absValue = abs(value)
    switch absValue {
    case 1_000_000_000...:
        return String(format: "%.1fB", Double(value) / 1_000_000_000)
    case 1_000_000...:
        return String(format: "%.1fM", Double(value) / 1_000_000)
    case 10_000...:
        return String(format: "%.1fK", Double(value) / 1_000)
    case 1_000...:
        return String(format: "%.2fK", Double(value) / 1_000)
    default:
        return "\(value)"
    }
}

private func relativeTimeString(since date: Date) -> String {
    let interval = Date().timeIntervalSince(date)
    if interval < 60 { return "just now" }
    if interval < 3_600 { return "\(Int(interval / 60))m ago" }
    if interval < 86_400 { return "\(Int(interval / 3_600))h ago" }
    let days = Int(interval / 86_400)
    if days < 30 { return "\(days)d ago" }
    return date.formatted(date: .abbreviated, time: .omitted)
}
