import SwiftUI
import OpenBurnBarKernel

// MARK: - Command Board (Face C)

/// Devices & Sync → Command Board. Every run across every machine in one grid,
/// with the column the plan asks for by name: STARTED BY (§ The three faces of
/// `plans/2026-08-17-war-room-master-plan.md`).
///
/// The rollups come from `CommandBoard` in the Kernel, so "what did the Flame
/// spend on the Mini today" has exactly one answer no matter who asks.
struct CommandBoardDetailView: View {
    let dataStore: DataStore

    @State private var store: CommandBoardStore
    @State private var window: TimeRange = .today

    init(dataStore: DataStore) {
        self.dataStore = dataStore
        _store = State(wrappedValue: CommandBoardStore(dbQueue: dataStore.actor.dbQueue))
    }

    /// The board reads the app-wide windows so "7 days" means here what it
    /// means on the dashboard. Only the two the grid is useful over are
    /// offered; a 30-day scan of every run belongs in reports, not a live board.
    private static let windows: [TimeRange] = [.today, .last7Days]

    var body: some View {
        SettingsDetailContainer(
            title: "Command Board",
            subtitle: "Every run across every machine, with who started it and what it cost."
        ) {
            picker

            if !store.hasLoaded {
                SettingsLoadingCard(message: "Reading the board…")
            } else if store.summary.isEmpty {
                SettingsEmptyCard(
                    title: "Nothing has run yet",
                    message: "Runs appear here as your agents work — on this Mac and on every machine signed into this account."
                )
            } else {
                totalsCard
                rollupCard(title: "By machine", rollups: store.summary.byMachine)
                rollupCard(title: "Started by", rollups: store.summary.byOriginator)
                runsCard
            }
        }
        // Face C answers "what is happening right now", so it keeps asking.
        // Without this the green running dots and the durations freeze at
        // whatever was true when the pane opened.
        .task(id: window) {
            while !Task.isCancelled {
                // The window slides with the clock, so the start is recomputed
                // per pass rather than pinned to when the pane opened.
                await store.load(since: window.dateRange()?.lowerBound ?? .distantPast)
                try? await Task.sleep(for: .seconds(Self.refreshInterval)) // try?-ok(cancellation only; the loop condition handles it)
            }
        }
    }

    private static let refreshInterval: TimeInterval = 10

    private var picker: some View {
        Picker("Window", selection: $window) {
            ForEach(Self.windows) { option in
                Text(option.displayName).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Cards

    private var totalsCard: some View {
        GlassCard {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.xl) {
                metric(
                    "Spend",
                    store.summary.totalCostUSD.formatAsCost()
                )
                metric("Runs", "\(store.summary.runs.count)")
                metric("Running", "\(store.summary.runningCount)")
                Spacer(minLength: 0)
                if store.summary.isFleetActive {
                    HermesPill(text: "Fleet active")
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
            Text(label.uppercased())
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(value)
                .font(DesignSystem.Typography.mono)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        }
    }

    private func rollupCard(title: String, rollups: [CommandBoardRollup]) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text(title.uppercased())
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)

                ForEach(rollups) { rollup in
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        Text(rollup.label)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(1)
                        if rollup.runningCount > 0 {
                            Circle()
                                .fill(DesignSystem.Colors.success)
                                .frame(width: 6, height: 6)
                        }
                        Spacer(minLength: DesignSystem.Spacing.sm)
                        Text("\(rollup.runCount) run\(rollup.runCount == 1 ? "" : "s")")
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Text(rollup.costUSD.formatAsCost())
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .frame(minWidth: 64, alignment: .trailing)
                    }
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private var runsCard: some View {
        GlassCard {
            // Lazy because the window can hold a couple hundred runs and the
            // pane only ever shows a screenful.
            LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack {
                    Text("RUN")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("STARTED BY")
                        .frame(width: 150, alignment: .leading)
                    Text("COST")
                        .frame(width: 72, alignment: .trailing)
                }
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textMuted)

                let now = Date()
                ForEach(store.summary.runs) { run in
                    runRow(run, now: now)
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private func runRow(_ run: CommandBoardRun, now: Date) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    if run.status == .running {
                        Circle()
                            .fill(DesignSystem.Colors.success)
                            .frame(width: 6, height: 6)
                    }
                    Text(run.title)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                }
                Text("\(run.bodyDisplayName) · \(durationLabel(run, now: now))")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(run.originator.label)
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(
                    run.originator.kind == .flame
                        ? DesignSystem.Colors.hermesAureate
                        : DesignSystem.Colors.textSecondary
                )
                .frame(width: 150, alignment: .leading)
                .lineLimit(1)

            Text(run.costUSD.formatAsCost())
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 72, alignment: .trailing)
        }
    }

    private func durationLabel(_ run: CommandBoardRun, now: Date) -> String {
        let seconds = Int(run.duration(now: now))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return String(format: "%.1fh", Double(seconds) / 3_600)
    }
}
