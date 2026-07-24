import SwiftUI
import OpenBurnBarCore

// MARK: - Calendar Page
//
// First-class Calendar analytics: a heat-mapped month grid on the left, a
// selection-driven gallery of analytics cards on the right. Click selects a
// day, ⇧-click extends a contiguous range, ⌘-click toggles days, and
// dragging paints a range — the selection drives every card.
//
// Layout persistence: `CalendarPageLayout` JSON under its storage key.
// Data: `CalendarDataService` — one fetch per (month, usagesVersion);
// selection changes re-aggregate the loaded rows without hitting the store.

/// Host for the parallel `DashboardDetailView` surface, which passes the time
/// range by value. The calendar navigates by month rather than the global
/// time range, so the range is accepted for signature parity and ignored.
struct CalendarPageDetailHost: View {
    let context: DashboardContext
    let selectedTimeRange: TimeRange

    var body: some View {
        CalendarView(dataStore: context.dataStore)
    }
}

struct CalendarView: View {
    @Bindable var dataStore: DataStore

    @State private var service = CalendarDataService()
    @State private var selection = CalendarSelectionModel()
    @State private var visibleMonth = Date()
    @State private var layout: CalendarPageLayout = .default
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var calendar: Calendar { selection.calendar }

    private var gridModel: CalendarMonthGridModel {
        CalendarMonthGridModel.make(for: visibleMonth, calendar: calendar)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            header

            HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                monthCard
                    .frame(width: 380)

                panelColumn
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .padding(DesignSystem.Spacing.xl)
        .frame(maxWidth: 1280, alignment: .leading)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear {
            restoreLayout()
            if selection.isEmpty {
                selection.select(Date())
            }
        }
        .task(id: monthRefreshKey) {
            service.refresh(
                dataStore: dataStore,
                model: gridModel,
                selectedDays: selection.selectedDays,
                calendar: calendar
            )
        }
        .task(id: selectionRefreshKey) {
            service.refreshSelection(selectedDays: selection.selectedDays, calendar: calendar)
        }
        .accessibilityIdentifier(OBBAccessibilityID.calendarPage)
    }

    private var monthRefreshKey: String {
        "\(gridModel.monthStart.timeIntervalSince1970)|\(dataStore.usagesVersion)"
    }

    private var selectionRefreshKey: String {
        selection.orderedDays.map { String($0.timeIntervalSince1970) }.joined(separator: ",")
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Calendar")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(headerSubtitle)
                    .font(.system(size: 11.5, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }

            Spacer()

            editMenu
        }
    }

    private var headerSubtitle: String {
        guard !selection.isEmpty else {
            return "Pick a day — ⇧ extends a range, ⌘ toggles days, drag paints."
        }
        guard let snapshot = service.selectionSnapshot, !snapshot.isEmpty else {
            return selectionSummaryText
        }
        return selectionSummaryText + " · "
            + snapshot.totalCost.formatAsCost() + " · "
            + snapshot.totalTokens.formatAsTokenVolume() + " tokens · "
            + "\(snapshot.sessionCount) sessions"
    }

    private var selectionSummaryText: String {
        let days = selection.orderedDays
        guard let first = days.first, let last = days.last else { return "No days selected" }
        if first == last {
            return first.formatted(date: .long, time: .omitted)
        }
        return "\(first.formatted(date: .abbreviated, time: .omitted)) – "
            + "\(last.formatted(date: .abbreviated, time: .omitted)) · \(days.count) days"
    }

    private var editMenu: some View {
        Menu {
            if !layout.hiddenConfigs.isEmpty {
                Section("Hidden Cards") {
                    ForEach(layout.hiddenConfigs) { config in
                        Button {
                            layout.setVisible(config.kind, true)
                            persistLayout()
                        } label: {
                            Label(config.kind.title, systemImage: config.kind.systemImage)
                        }
                    }
                }
            }
            Section {
                Button("Reset Layout") {
                    withAnimation(reduceMotion ? nil : DesignSystem.Animation.gentle) {
                        layout.reset()
                        persistLayout()
                    }
                }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .liquidGlassInteractive(in: Circle())
        .help("Show hidden cards or reset the layout")
        .accessibilityLabel("Edit cards")
    }

    // MARK: Month card

    private var monthCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(visibleMonth.formatted(.dateTime.year().month(.wide)))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    if let snapshot = service.monthSnapshot, snapshot.monthTotalCost > 0 {
                        Text("\(snapshot.monthTotalCost.formatAsCost()) this month")
                            .font(.system(size: 10, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }

                Spacer()

                monthNavButton("chevron.left") { shiftMonth(by: -1) }
                todayButton
                monthNavButton("chevron.right") { shiftMonth(by: 1) }
            }

            CalendarMonthGrid(
                model: gridModel,
                snapshot: service.monthSnapshot,
                selection: selection,
                accent: DesignSystem.Colors.ember
            )
        }
        .padding(DesignSystem.Spacing.lg)
        .chartGlassCard()
    }

    private func monthNavButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .liquidGlassInteractive(in: Circle())
    }

    private var todayButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : DesignSystem.Animation.standard) {
                visibleMonth = Date()
            }
            selection.select(Date())
        } label: {
            Text("Today")
                .font(.system(size: 9.5, weight: .bold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .liquidGlassInteractive(in: Capsule())
    }

    private func shiftMonth(by delta: Int) {
        guard let shifted = calendar.date(byAdding: .month, value: delta, to: visibleMonth) else { return }
        withAnimation(reduceMotion ? nil : DesignSystem.Animation.standard) {
            visibleMonth = shifted
        }
    }

    // MARK: Panel column

    @ViewBuilder
    private var panelColumn: some View {
        if selection.isEmpty {
            promptState
        } else if let snapshot = service.selectionSnapshot {
            if snapshot.isEmpty {
                emptyState
            } else {
                ScrollView {
                    CalendarAnalyticsPanel(
                        layout: layout,
                        snapshot: snapshot,
                        onMove: { dragged, target in
                            layout.move(dragged, toPositionOf: target)
                            persistLayout()
                        },
                        onHide: { kind in
                            layout.setVisible(kind, false)
                            persistLayout()
                        },
                        onSetSpan: { kind, span in
                            layout.setSpan(kind, span)
                            persistLayout()
                        }
                    )
                    .padding(.trailing, 2)
                }
                .scrollIndicators(.visible)
            }
        } else {
            loadingState
        }
    }

    // MARK: States

    private var loadingState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            ProgressView()
                .controlSize(.small)
            Text("Loading your month…")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 120)
    }

    private var promptState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(DesignSystem.Colors.ember.opacity(0.6))
            Text("Select days to analyze")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text("Click a day, ⇧-click to extend a range, ⌘-click to toggle days, or drag across the grid.")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 100)
    }

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Image(systemName: "calendar")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(DesignSystem.Colors.ember.opacity(0.6))
            Text("No usage on these days")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text("Run an agent or pick busier days — the cards draw themselves from every request you make.")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 100)
    }

    // MARK: Layout persistence

    private func restoreLayout() {
        if let data = UserDefaults.standard.data(forKey: CalendarPageLayout.storageKey) {
            layout = CalendarPageLayout.decode(from: data)
        }
    }

    private func persistLayout() {
        if let data = layout.encoded() {
            UserDefaults.standard.set(data, forKey: CalendarPageLayout.storageKey)
        }
    }
}
