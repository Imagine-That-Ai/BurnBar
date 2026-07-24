import SwiftUI
import OpenBurnBarCore

// MARK: - Calendar View
//
// First-class Calendar analytics for iOS: a heat-mapped month grid above a
// selection-driven gallery of analytics cards. Tap toggles days into a
// multi-selection, long-press + drag paints a contiguous range, and the
// selection drives every card. Card order/visibility/span persist as JSON in
// UserDefaults (`CalendarPageLayout.storageKey`).
//
// Data: `CalendarStore` (hoisted by the tab root). One fetch per visible
// month; selection changes re-aggregate the loaded rows without network.

struct CalendarView: View {
    let store: CalendarStore

    @State private var selection = CalendarSelectionModel()
    @State private var visibleMonth = Date()
    @State private var layout: CalendarPageLayout = .default
    @State private var showLayoutEditor = false

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var calendar: Calendar { selection.calendar }
    private var accent: Color { MobileTheme.ember }

    private var gridModel: CalendarMonthGridModel {
        CalendarMonthGridModel.make(for: visibleMonth, calendar: calendar)
    }

    var body: some View {
        ZStack {
            AuroraBackdrop()
                .ignoresSafeArea()
            adaptiveContent
        }
        .navigationTitle("Calendar")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    showLayoutEditor = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .accessibilityLabel("Edit cards")
            }
        }
        .sheet(isPresented: $showLayoutEditor) {
            CalendarLayoutEditor(
                layout: $layout,
                onMutate: persistLayout
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            restoreLayout()
            if selection.isEmpty {
                selection.select(Date())
            }
        }
        .task(id: gridModel.monthStart) {
            await store.load(
                gridModel: gridModel,
                selectedDays: selection.selectedDays,
                calendar: calendar
            )
            // Re-aggregate with the CURRENT selection — taps that landed
            // while the load was in flight must win over the task's capture.
            store.refreshSelection(selectedDays: selection.selectedDays, calendar: calendar)
        }
        .onChange(of: selection.selectedDays) { _, days in
            store.refreshSelection(selectedDays: days, calendar: calendar)
        }
        .accessibilityIdentifier("calendar.page")
    }

    @ViewBuilder
    private var adaptiveContent: some View {
        if horizontalSizeClass == .regular {
            // iPad / wide: month rail on the left, panel column on the right —
            // mirrors the macOS side-by-side layout.
            HStack(alignment: .top, spacing: MobileTheme.Spacing.lg) {
                monthCard
                    .frame(width: 400)
                ScrollView {
                    VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                        selectionHeader
                        panelSection
                    }
                    .padding(.bottom, 120)
                }
                .scrollIndicators(.visible)
            }
            .padding(.horizontal, MobileTheme.Spacing.lg)
            .padding(.top, MobileTheme.Spacing.md)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                    monthCard
                    selectionHeader
                    panelSection
                }
                .padding(.horizontal, MobileTheme.Spacing.md)
                .padding(.top, MobileTheme.Spacing.sm)
                .padding(.bottom, 120)
            }
        }
    }

    // MARK: - Month card

    private var monthCard: some View {
        AuroraGlassCard(
            variant: .standard,
            cornerRadius: AuroraDesign.Shape.standardCorner,
            padding: MobileTheme.Spacing.lg
        ) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack(alignment: .center, spacing: MobileTheme.Spacing.sm) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(visibleMonth.formatted(.dateTime.year().month(.wide)))
                            .font(.system(size: 15, weight: .bold, design: .rounded))
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        if let snapshot = store.monthSnapshot, snapshot.monthTotalCost > 0 {
                            Text("\(snapshot.monthTotalCost.formatAsCost()) this month")
                                .font(.system(size: 10, design: .rounded))
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                        }
                    }

                    Spacer()

                    monthNavButton("chevron.left") { shiftMonth(by: -1) }
                    todayButton
                    monthNavButton("chevron.right") { shiftMonth(by: 1) }
                }

                CalendarMonthGrid(
                    model: gridModel,
                    snapshot: store.monthSnapshot,
                    selection: selection,
                    accent: accent
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func monthNavButton(_ systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .auroraGlass(.compact, cornerRadius: 15)
        .accessibilityLabel(systemImage == "chevron.left" ? "Previous month" : "Next month")
    }

    private var todayButton: some View {
        Button {
            withAnimation(reduceMotion ? nil : MobileTheme.Animation.standard) {
                visibleMonth = Date()
            }
            selection.select(Date())
            HapticBus.chipChange()
        } label: {
            Text("Today")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .auroraGlass(.compact, cornerRadius: 14)
    }

    private func shiftMonth(by delta: Int) {
        guard let shifted = calendar.date(byAdding: .month, value: delta, to: visibleMonth) else { return }
        withAnimation(reduceMotion ? nil : MobileTheme.Animation.standard) {
            visibleMonth = shifted
        }
        HapticBus.chipChange()
    }

    // MARK: - Selection header

    private var selectionHeader: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(headerSubtitle)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Spacer(minLength: 4)
            if !selection.isEmpty {
                Button("Clear") {
                    selection.clear()
                    HapticBus.chipChange()
                }
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(accent)
            }
        }
        .padding(.horizontal, 4)
    }

    private var headerSubtitle: String {
        guard !selection.isEmpty else {
            return "Tap days to analyze — long-press and drag for a range."
        }
        guard let snapshot = store.selectionSnapshot, !snapshot.isEmpty else {
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

    // MARK: - Panel

    @ViewBuilder
    private var panelSection: some View {
        if selection.isEmpty {
            promptState
        } else if let error = store.error, store.selectionSnapshot == nil {
            errorState(error)
        } else if let snapshot = store.selectionSnapshot {
            if snapshot.isEmpty {
                emptyState
            } else {
                CalendarAnalyticsPanel(
                    layout: layout,
                    snapshot: snapshot,
                    accent: accent,
                    onSetSpan: { kind, span in
                        layout.setSpan(kind, span)
                        persistLayout()
                    },
                    onHide: { kind in
                        layout.setVisible(kind, false)
                        persistLayout()
                    }
                )
            }
        } else {
            loadingState
        }
    }

    // MARK: - States

    private var loadingState: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            ProgressView()
                .controlSize(.small)
            Text("Loading your month…")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 80)
    }

    private var promptState: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(accent.opacity(0.6))
            Text("Select days to analyze")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text("Tap a day, tap more days to build a multi-selection, or long-press and drag across the grid for a range.")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private var emptyState: some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            Image(systemName: "calendar")
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(accent.opacity(0.6))
            Text("No usage on these days")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text("Run an agent or pick busier days — the cards draw themselves from every request you make.")
                .font(.system(size: 11.5, design: .rounded))
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: MobileTheme.Spacing.md) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(MobileTheme.warning.opacity(0.7))
            Text("Couldn't load this month")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(MobileTheme.Colors.textPrimary)
            Text(message)
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            Button("Try Again") {
                // `loadedMonthStart` is only set on success, so this re-runs
                // the full fetch for the failed month.
                Task {
                    await store.load(
                        gridModel: gridModel,
                        selectedDays: selection.selectedDays,
                        calendar: calendar
                    )
                }
            }
            .font(.system(size: 11, weight: .bold, design: .rounded))
            .foregroundStyle(accent)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 60)
    }

    // MARK: - Layout persistence

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

// MARK: - Layout Editor Sheet
//
// Platform-native card management: reorder via drag handles, visibility via
// toggles, span via a S/M/L segmented picker. Mutations write straight into
// the bound `CalendarPageLayout`; the host persists on every change.

private struct CalendarLayoutEditor: View {
    @Binding var layout: CalendarPageLayout
    let onMutate: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(layout.configs) { config in
                        editorRow(for: config)
                    }
                    .onMove { source, destination in
                        layout.move(fromOffsets: source, toOffset: destination)
                        onMutate()
                    }
                } header: {
                    Text("Cards")
                } footer: {
                    Text("Drag to reorder. Hidden cards keep their spot in line.")
                }

                Section {
                    Button("Reset Layout", role: .destructive) {
                        layout.reset()
                        onMutate()
                    }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Edit Cards")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func editorRow(for config: CalendarCardConfig) -> some View {
        HStack(spacing: 10) {
            Image(systemName: config.kind.systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(MobileTheme.ember)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(config.kind.title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                if config.isVisible {
                    Picker("Size", selection: spanBinding(for: config.kind)) {
                        Text("S").tag(1)
                        Text("M").tag(2)
                        Text("L").tag(3)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 180)
                }
            }
            Spacer(minLength: 8)
            Toggle("Shown", isOn: visibilityBinding(for: config.kind))
                .labelsHidden()
        }
        .padding(.vertical, 2)
    }

    private func visibilityBinding(for kind: CalendarCardKind) -> Binding<Bool> {
        Binding(
            get: { layout.configs.first(where: { $0.kind == kind })?.isVisible ?? true },
            set: { visible in
                layout.setVisible(kind, visible)
                onMutate()
            }
        )
    }

    private func spanBinding(for kind: CalendarCardKind) -> Binding<Int> {
        Binding(
            get: { layout.configs.first(where: { $0.kind == kind })?.span ?? kind.defaultSpan },
            set: { span in
                layout.setSpan(kind, span)
                onMutate()
            }
        )
    }
}

#Preview {
    NavigationStack {
        CalendarView(store: CalendarStore())
    }
}
