import SwiftUI

// MARK: - Dashboard Home rail
//
// The right-hand rail: an ordered, reorderable stack of panels split by
// draggable horizontal dividers. Fleet over quota by default.
//
// The split is stored as a **fraction**, not absolute heights. This overrides
// the menu bar popover's precedent on purpose: the popover stores absolute
// per-section heights, and that works only because the popover's own height is
// user-fixed and clamped. The dashboard window resizes freely, so an absolute
// 400pt fleet panel parked at an 820pt window height becomes the *entire* rail
// at the 650pt minimum and quota disappears. `PaneSplitContainer` uses a
// fraction for exactly this reason.

struct DashboardHomeRail<FleetContent: View, QuotaContent: View>: View {
    let ink: BackdropInk
    @Binding var fleetMode: DashboardHomeFleetMode
    @Binding var quotaMode: DashboardHomeQuotaMode
    /// Fleet modes that can be rendered truthfully right now.
    let availableFleetModes: [DashboardHomeFleetMode]
    let activeAgentCount: Int

    @ViewBuilder let fleetContent: () -> FleetContent
    @ViewBuilder let quotaContent: () -> QuotaContent

    @AppStorage(DashboardHomeRailPanel.orderStorageKey) private var panelOrderRaw = "fleet,quota"
    @AppStorage(DashboardHomeRailPanel.stateStorageKey) private var panelStateRaw = "{}"
    @AppStorage(DashboardHomeRailMetrics.splitStorageKey) private var splitFraction =
        DashboardHomeRailMetrics.defaultSplitFraction

    /// Live drag offset, applied on top of the stored fraction so a drag never
    /// writes to `@AppStorage` on every frame.
    @State private var dragFraction: Double?

    private var panels: [DashboardHomeRailPanel] {
        DashboardHomeRailPanel.ordered(from: panelOrderRaw)
    }

    private var panelState: [String: DashboardHomeRailPanelState] {
        DashboardHomeRailPanelState.decode(panelStateRaw)
    }

    private var expandedPanels: [DashboardHomeRailPanel] {
        panels.filter { panelState[$0.rawValue]?.collapsed != true }
    }

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                ForEach(Array(panels.enumerated()), id: \.element.id) { index, panel in
                    let isCollapsed = panelState[panel.rawValue]?.collapsed == true

                    panelHeader(panel, isCollapsed: isCollapsed)

                    if isCollapsed == false {
                        panelBody(panel)
                            .frame(height: height(for: panel, in: geo.size.height))
                            .clipped()
                    }

                    if index < panels.count - 1 {
                        if shouldShowDivider(after: index) {
                            ResizableSectionDivider(
                                axis: .horizontal,
                                onDrag: { delta in
                                    guard geo.size.height > 0 else { return }
                                    let base = dragFraction ?? splitFraction
                                    dragFraction = DashboardHomeRailMetrics.clampSplit(
                                        base + Double(delta / geo.size.height)
                                    )
                                },
                                onCommit: {
                                    if let dragFraction { splitFraction = dragFraction }
                                    dragFraction = nil
                                },
                                onReset: {
                                    dragFraction = nil
                                    splitFraction = DashboardHomeRailMetrics.defaultSplitFraction
                                }
                            )
                        } else {
                            Rectangle()
                                .fill(DesignSystem.Colors.borderSubtle.opacity(0.72))
                                .frame(height: 0.75)
                        }
                    }
                }

                Spacer(minLength: 0)
            }
        }
        .accessibilityIdentifier(OBBAccessibilityID.dashboardHomeRail)
    }

    // MARK: - Header

    @ViewBuilder
    private func panelHeader(_ panel: DashboardHomeRailPanel, isCollapsed: Bool) -> some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            Button {
                toggleCollapsed(panel)
            } label: {
                HStack(spacing: DesignSystem.Spacing.xxs) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(ink.icon)
                    Text(panel.title)
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .tracking(0.8)
                        .foregroundStyle(ink.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isCollapsed ? "Show \(panel.accessibilityLabel)" : "Hide \(panel.accessibilityLabel)")

            if panel == .fleet, activeAgentCount > 0 {
                Text("\(activeAgentCount) active")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.success)
            }

            Spacer(minLength: 0)

            if isCollapsed == false {
                switcher(for: panel)
            }

            reorderControls(for: panel)
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.xs)
    }

    @ViewBuilder
    private func switcher(for panel: DashboardHomeRailPanel) -> some View {
        switch panel {
        case .fleet:
            GlassSegmentedSwitcher(
                selection: $fleetMode,
                options: availableFleetModes,
                iconOnly: true,
                accessibilityID: OBBAccessibilityID.dashboardHomeFleetSwitcher
            )
        case .quota:
            GlassSegmentedSwitcher(
                selection: $quotaMode,
                iconOnly: true,
                accessibilityID: OBBAccessibilityID.dashboardHomeQuotaSwitcher
            )
        }
    }

    /// Keyboard- and VoiceOver-reachable reorder, because drag-reorder is
    /// mouse-only. Ported in shape from the popover's tray controls.
    @ViewBuilder
    private func reorderControls(for panel: DashboardHomeRailPanel) -> some View {
        if panels.count > 1, let index = panels.firstIndex(of: panel) {
            Menu {
                Button("Move \(panel.accessibilityLabel) up") { move(panel, by: -1) }
                    .disabled(index == 0)
                Button("Move \(panel.accessibilityLabel) down") { move(panel, by: 1) }
                    .disabled(index == panels.count - 1)
                Divider()
                Button("Reset panel sizes") {
                    splitFraction = DashboardHomeRailMetrics.defaultSplitFraction
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(ink.icon)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Rearrange panels")
        }
    }

    @ViewBuilder
    private func panelBody(_ panel: DashboardHomeRailPanel) -> some View {
        switch panel {
        case .fleet: fleetContent()
        case .quota: quotaContent()
        }
    }

    // MARK: - Geometry

    /// A collapsed panel contributes only its header, and is excluded from the
    /// fraction split — the remaining expanded panels share what is left.
    private func height(for panel: DashboardHomeRailPanel, in total: CGFloat) -> CGFloat? {
        let expanded = expandedPanels
        guard expanded.count > 1 else { return nil }
        guard let first = expanded.first else { return nil }

        // Header + divider chrome, subtracted before splitting so the fraction
        // describes the *content* split rather than drifting as headers stack.
        let chrome = CGFloat(panels.count) * 26 + CGFloat(max(0, panels.count - 1)) * ResizableSectionDivider.thickness
        let available = max(0, total - chrome)
        let fraction = DashboardHomeRailMetrics.clampSplit(dragFraction ?? splitFraction)

        if panel == first { return available * fraction }
        return available * (1 - fraction) / CGFloat(expanded.count - 1)
    }

    /// Only draw a draggable divider between two *expanded* panels — dragging
    /// against a collapsed panel would move a boundary the user cannot see.
    private func shouldShowDivider(after index: Int) -> Bool {
        guard index + 1 < panels.count else { return false }
        let state = panelState
        return state[panels[index].rawValue]?.collapsed != true
            && state[panels[index + 1].rawValue]?.collapsed != true
    }

    // MARK: - Mutation

    private func toggleCollapsed(_ panel: DashboardHomeRailPanel) {
        var state = panelState
        var entry = state[panel.rawValue] ?? DashboardHomeRailPanelState()
        entry.collapsed.toggle()
        state[panel.rawValue] = entry
        withAnimation(DesignSystem.Animation.snappy) {
            panelStateRaw = DashboardHomeRailPanelState.encode(state)
        }
    }

    private func move(_ panel: DashboardHomeRailPanel, by offset: Int) {
        var order = panels
        guard let index = order.firstIndex(of: panel) else { return }
        let target = index + offset
        guard order.indices.contains(target) else { return }
        order.swapAt(index, target)
        withAnimation(DesignSystem.Animation.snappy) {
            panelOrderRaw = DashboardHomeRailPanel.encode(order)
        }
    }
}
