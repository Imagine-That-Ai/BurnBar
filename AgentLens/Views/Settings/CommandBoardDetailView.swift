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
    @State private var window: Window = .today

    init(dataStore: DataStore) {
        self.dataStore = dataStore
        _store = State(wrappedValue: CommandBoardStore(dbQueue: dataStore.actor.dbQueue))
    }

    enum Window: String, CaseIterable, Identifiable {
        case today = "Today"
        case week = "7 days"

        var id: String { rawValue }

        var start: Date {
            switch self {
            case .today: return Calendar.current.startOfDay(for: Date())
            case .week: return Date().addingTimeInterval(-7 * 86_400)
            }
        }
    }

    var body: some View {
        SettingsDetailContainer(
            title: "Command Board",
            subtitle: "Every run across every machine, with who started it and what it cost."
        ) {
            picker

            if !store.hasLoaded {
                loadingCard
            } else if store.summary.isEmpty {
                emptyCard
            } else {
                totalsCard
                rollupCard(title: "By machine", rollups: store.summary.byMachine)
                rollupCard(title: "Started by", rollups: store.summary.byOriginator)
                runsCard
            }
        }
        .task(id: window) { await store.load(since: window.start) }
    }

    private var picker: some View {
        Picker("Window", selection: $window) {
            ForEach(Window.allCases) { option in
                Text(option.rawValue).tag(option)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    // MARK: - Cards

    private var loadingCard: some View {
        GlassCard {
            HStack(spacing: DesignSystem.Spacing.sm) {
                ProgressView()
                    .controlSize(.small)
                Text("Reading the board…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private var emptyCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Nothing has run yet")
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Runs appear here as your agents work — on this Mac and on every machine signed into this account.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DesignSystem.Spacing.md)
        }
    }

    private var totalsCard: some View {
        GlassCard {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.xl) {
                metric(
                    "Spend",
                    store.summary.totalCostUSD.formatted(.currency(code: "USD"))
                )
                metric("Runs", "\(store.summary.runs.count)")
                metric("Running", "\(store.summary.runningCount)")
                Spacer(minLength: 0)
                if store.summary.isFleetActive {
                    Text("Fleet active")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                        .padding(.horizontal, DesignSystem.Spacing.xs)
                        .padding(.vertical, 2)
                        .background(
                            Capsule().stroke(DesignSystem.Colors.hermesAureate.opacity(0.6), lineWidth: 1)
                        )
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
                        Text(rollup.costUSD.formatted(.currency(code: "USD")))
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
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
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

                ForEach(store.summary.runs) { run in
                    runRow(run)
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
    }

    private func runRow(_ run: CommandBoardRun) -> some View {
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
                Text("\(run.bodyDisplayName) · \(durationLabel(run))")
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

            Text(run.costUSD.formatted(.currency(code: "USD")))
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .frame(width: 72, alignment: .trailing)
        }
    }

    private func durationLabel(_ run: CommandBoardRun) -> String {
        let seconds = Int(run.duration(now: Date()))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3_600 { return "\(seconds / 60)m" }
        return String(format: "%.1fh", Double(seconds) / 3_600)
    }
}
