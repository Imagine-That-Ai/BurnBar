import SwiftUI
import OpenBurnBarCore

struct CastleGreatHallContainer: View {
    @State private var result = CastleStatusLoadResult.empty
    @State private var isLoading = true
    @State private var hasLoadedOnce = false

    var body: some View {
        CastleGreatHallView(
            snapshot: result.snapshot,
            failures: result.failures,
            lastRefreshed: result.loadedAt,
            isLoading: isLoading,
            onRetry: { refresh() }
        )
        .task {
            refresh()
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
    }

    private func refresh() {
        isLoading = true
        let configured = CastleStatusReader.configuredStatusURLs()
        let discovered = CastleStatusReader.recentStatusURLs(limit: 12)
        result = CastleStatusReader.loadStatusRecords(at: configured.isEmpty ? discovered : configured)
        isLoading = false
        hasLoadedOnce = true
    }
}

/// The Wand mode the user is casting with.
enum WandCastMode: String, CaseIterable, Identifiable {
    case highestCapability = "headmaster"
    case pareto

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .highestCapability: return "Headmaster's"
        case .pareto: return "Pareto"
        }
    }

    var subtitle: String {
        switch self {
        case .highestCapability: return "Highest capability"
        case .pareto: return "Best quality per quota"
        }
    }

    var systemImage: String {
        switch self {
        case .highestCapability: return "crown.fill"
        case .pareto: return "scalemass.fill"
        }
    }
}

struct CastleGreatHallView: View {
    let snapshot: CastleRunSnapshot
    let failures: [CastleStatusLoadFailure]
    let lastRefreshed: Date?
    var isLoading: Bool = false
    var onRetry: (() -> Void)?

    @State private var selectedMode: WandCastMode = .pareto
    @State private var showUpgradeSheet = false

    private var activeCount: Int {
        snapshot.workers.filter { !$0.phase.isTerminal }.count
    }

    private var totalCast: Int {
        snapshot.totalCount
    }

    private var landedCount: Int {
        snapshot.landedCount
    }

    private var allFailed: Bool {
        !snapshot.isEmpty && snapshot.failedCount == snapshot.totalCount && snapshot.landedCount == 0
    }

    private var partialSuccess: Bool {
        landedCount > 0 && (snapshot.failedCount > 0 || snapshot.noOpCount > 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            wandModeSelector
            if isLoading && snapshot.isEmpty {
                loadingState
            } else if snapshot.isEmpty && failures.isEmpty {
                emptyState
            } else {
                castSummary
                metricsRow
                workerGrid
                failureStrip
                if allFailed, onRetry != nil {
                    retryBar
                }
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background {
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.68))
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .stroke(DesignSystem.Colors.borderSubtle.opacity(0.7), lineWidth: 1)
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("The Wand — worker lanes")
        .sheet(isPresented: $showUpgradeSheet) {
            WandCapUpgradeSheet()
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.amber.opacity(0.12))
                Image(systemName: "wand.and.rays")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.amber)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("The Wand")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(subheadline)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 12)

            if let lastRefreshed {
                Text(lastRefreshed.formatted(date: .omitted, time: .shortened))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.7)))
            }
        }
    }

    private var subheadline: String {
        if isLoading && snapshot.isEmpty {
            return "Casting — waiting for worker status records."
        }
        if snapshot.isEmpty {
            return failures.isEmpty ? "No worker verdicts found yet." : "\(failures.count) status record\(failures.count == 1 ? "" : "s") need attention."
        }
        if activeCount > 0 {
            return "\(activeCount) worker\(activeCount == 1 ? "" : "s") still running. \(landedCount) of \(totalCast) landed."
        }
        if landedCount == 0 && totalCast > 0 {
            return "No work landed. \(totalCast) worker\(totalCast == 1 ? "" : "s") were cast."
        }
        if partialSuccess {
            return "\(landedCount) of \(totalCast) landed. \(snapshot.failedCount) failed, \(snapshot.noOpCount) no work."
        }
        return "\(landedCount) of \(totalCast) workers landed work."
    }

    private var wandModeSelector: some View {
        HStack(spacing: 8) {
            ForEach(WandCastMode.allCases) { mode in
                Button {
                    selectedMode = mode
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: mode.systemImage)
                            .font(.system(size: 11, weight: .semibold))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mode.displayName)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                            Text(mode.subtitle)
                                .font(.system(size: 10, weight: .medium, design: .rounded))
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                    }
                    .foregroundStyle(selectedMode == mode ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textSecondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(selectedMode == mode ? DesignSystem.Colors.amber.opacity(0.14) : DesignSystem.Colors.surfaceElevated.opacity(0.5))
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .stroke(selectedMode == mode ? DesignSystem.Colors.amber.opacity(0.4) : DesignSystem.Colors.borderSubtle.opacity(0.5), lineWidth: 1)
                            )
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(mode.displayName) Wand, \(mode.subtitle)")
                .accessibilityAddTraits(selectedMode == mode ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wand mode selector")
    }

    @ViewBuilder
    private var castSummary: some View {
        if !snapshot.isEmpty {
            HStack(spacing: 8) {
                if landedCount > 0 && partialSuccess {
                    Label("\(landedCount) of \(totalCast) landed", systemImage: "flag.fill")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.success)
                    if snapshot.failedCount > 0 {
                        Text("\(snapshot.failedCount) failed")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.error)
                    }
                    if snapshot.noOpCount > 0 {
                        Text("\(snapshot.noOpCount) no work")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                } else if landedCount > 0 {
                    Label("\(landedCount) worker\(landedCount == 1 ? "" : "s") landed work", systemImage: "flag.fill")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.success)
                } else if totalCast > 0 {
                    Label("No work landed", systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.error)
                }
                Spacer(minLength: 0)
                Button {
                    showUpgradeSheet = true
                } label: {
                    Label("Go wider", systemImage: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.amber)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Go wider with higher tiers")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DesignSystem.Colors.surfaceElevated.opacity(0.5)))
        }
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 32, height: 32)
                .background(Circle().fill(DesignSystem.Colors.surfaceElevated.opacity(0.7)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("No Wand cast yet")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Worker lanes will light up when you cast The Wand and status records arrive.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DesignSystem.Colors.surfaceElevated.opacity(0.52)))
        .accessibilityLabel("Loading Wand worker status")
    }

    private var loadingState: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Casting The Wand")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Worker lanes will appear as status records arrive.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DesignSystem.Colors.surfaceElevated.opacity(0.52)))
        .accessibilityLabel("Loading Wand worker status")
    }

    @ViewBuilder
    private var retryBar: some View {
        if let onRetry {
            HStack(spacing: 10) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.amber)
                    .accessibilityHidden(true)
                Text("All workers failed. Retry the cast to try again.")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer(minLength: 0)
                Button("Retry") {
                    onRetry()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(DesignSystem.Colors.amber)
                .accessibilityLabel("Retry Wand cast")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(DesignSystem.Colors.amber.opacity(0.08)))
        }
    }

    private var metricsRow: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 10, alignment: .leading)],
            alignment: .leading,
            spacing: 10
        ) {
            CastleMetricPill(label: "Landed", value: landedCount, tint: DesignSystem.Colors.success, systemImage: "flag.fill")
            CastleMetricPill(label: "Running", value: activeCount, tint: DesignSystem.Colors.amber, systemImage: "sparkles")
            CastleMetricPill(label: "No work", value: snapshot.noOpCount, tint: DesignSystem.Colors.textMuted, systemImage: "flag.slash")
            CastleMetricPill(label: "Failed", value: snapshot.failedCount + failures.count, tint: DesignSystem.Colors.error, systemImage: "exclamationmark.triangle.fill")
        }
    }

    private var workerGrid: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 176, maximum: 240), spacing: 12, alignment: .top)],
            alignment: .leading,
            spacing: 12
        ) {
            ForEach(snapshot.workers) { worker in
                CastleWorkerTile(worker: worker)
            }
        }
    }

    @ViewBuilder
    private var failureStrip: some View {
        if !failures.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                Label("Unreadable status records", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.error)
                ForEach(failures.prefix(3)) { failure in
                    Text("\(failure.path): \(failure.reason)")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(2)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DesignSystem.Colors.error.opacity(0.08)))
        }
    }
}

private struct CastleMetricPill: View {
    let label: String
    let value: Int
    let tint: Color
    let systemImage: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .accessibilityHidden(true)
            Text("\(value)")
                .font(DesignSystem.Typography.monoSmall)
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .background(Capsule().fill(tint.opacity(0.10)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label), \(value)")
    }
}

private struct CastleWorkerTile: View {
    let worker: CastleWorkerStatus

    private var house: CastleHouse { worker.houseModel }
    private var primary: Color { DesignSystem.Colors.primary(for: house.provider) }
    private var accent: Color { DesignSystem.Colors.accent(for: house.provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .center, spacing: 10) {
                ZStack {
                    HouseCrest(
                        house: house,
                        size: 46,
                        primary: tilePrimary,
                        accent: tileAccent,
                        phase: worker.phase
                    )
                    honestyRing
                }
                .frame(width: 52, height: 52)

                VStack(alignment: .leading, spacing: 3) {
                    Text(house.name)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                    Text(worker.modelArg ?? "model pending")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 7) {
                Label(worker.phase.wandLabel, systemImage: phaseIcon)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(phaseTint)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let head = worker.headSHA?.prefix(7), worker.landsCommit {
                    Text(String(head))
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            providerQuotaRow

            honestyFlags
        }
        .padding(12)
        .frame(minHeight: 128, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(tileFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(tileStroke, lineWidth: worker.landsCommit ? 1.3 : 1)
                )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(house.name), \(worker.modelArg ?? "model pending"), \(worker.phase.wandLabel), provider \(house.provider.rawValue)")
    }

    private var tilePrimary: Color {
        switch worker.phase {
        case .failed, .noOp, .demoted:
            return DesignSystem.Colors.textMuted
        default:
            return primary
        }
    }

    private var tileAccent: Color {
        switch worker.phase {
        case .failed, .noOp, .demoted:
            return DesignSystem.Colors.border
        default:
            return accent
        }
    }

    private var tileFill: Color {
        if worker.landsCommit {
            return DesignSystem.Colors.success.opacity(0.08)
        }
        switch worker.phase {
        case .failed:
            return DesignSystem.Colors.error.opacity(0.08)
        case .noOp, .demoted:
            return DesignSystem.Colors.surfaceElevated.opacity(0.45)
        default:
            return primary.opacity(0.08)
        }
    }

    private var tileStroke: Color {
        if worker.landsCommit {
            return DesignSystem.Colors.success.opacity(0.45)
        }
        switch worker.phase {
        case .failed:
            return DesignSystem.Colors.error.opacity(0.32)
        case .noOp:
            return DesignSystem.Colors.textMuted.opacity(0.28)
        default:
            return primary.opacity(0.28)
        }
    }

    private var phaseTint: Color {
        if worker.landsCommit { return DesignSystem.Colors.success }
        switch worker.phase {
        case .failed: return DesignSystem.Colors.error
        case .noOp, .demoted: return DesignSystem.Colors.textMuted
        case .completed, .completing: return DesignSystem.Colors.amber
        default: return primary
        }
    }

    private var phaseIcon: String {
        if worker.landsCommit { return "flag.fill" }
        switch worker.phase {
        case .failed: return "exclamationmark.triangle.fill"
        case .noOp: return "flag.slash"
        case .demoted: return "chevron.down.circle"
        case .completed, .completing: return "hourglass"
        case .fanoutWakes, .houseLit, .running: return "sparkles"
        case .landed: return "flag.fill"
        }
    }

    @ViewBuilder
    private var providerQuotaRow: some View {
        HStack(spacing: 5) {
            Image(systemName: providerIcon)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .accessibilityHidden(true)
            Text(house.provider.rawValue)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .lineLimit(1)
            if worker.honesty.contains(.quotaUnknown) {
                Text("Quota unknown")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DesignSystem.Colors.warning.opacity(0.12)))
            } else if worker.honesty.contains(.quotaPressure) {
                Text("Quota pressure")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.amber)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DesignSystem.Colors.amber.opacity(0.12)))
            } else if worker.honesty.contains(.routeDemoted) {
                Text("Provider unavailable")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.error)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(DesignSystem.Colors.error.opacity(0.12)))
            }
        }
    }

    private var providerIcon: String {
        house.provider.iconName
    }

    @ViewBuilder
    private var honestyRing: some View {
        if worker.honesty.contains(.quotaUnknown) {
            Circle()
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
                .foregroundStyle(DesignSystem.Colors.warning)
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder
    private var honestyFlags: some View {
        if !worker.honesty.isEmpty {
            HStack(spacing: 5) {
                ForEach(worker.honesty, id: \.rawValue) { flag in
                    Text(flag.displayLabel)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(flag == .failed ? DesignSystem.Colors.error : DesignSystem.Colors.textMuted)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(DesignSystem.Colors.surface.opacity(0.72)))
                }
            }
        }
    }
}

#Preview("Castle Great Hall") {
    CastleGreatHallView(
        snapshot: CastleRunSnapshot(workers: [
            CastleWorkerStatus(runtime: "codex", modelArg: "gpt-5.5", phase: .landed, landsCommit: true, headSHA: "abcdef123456"),
            CastleWorkerStatus(runtime: "claude", modelArg: "claude-opus-4-8", phase: .completed, landsCommit: false, honesty: [.quotaUnknown]),
            CastleWorkerStatus(runtime: "gemini", modelArg: "gemini-3.1-pro-preview", phase: .noOp, landsCommit: false, honesty: [.noOp])
        ]),
        failures: [],
        lastRefreshed: Date(),
        isLoading: false
    )
    .padding()
    .frame(width: 760)
}

#Preview("Loading state") {
    CastleGreatHallView(
        snapshot: CastleRunSnapshot(workers: []),
        failures: [],
        lastRefreshed: nil,
        isLoading: true
    )
    .padding()
    .frame(width: 760)
}

#Preview("All failed") {
    CastleGreatHallView(
        snapshot: CastleRunSnapshot(workers: [
            CastleWorkerStatus(runtime: "codex", modelArg: "gpt-5.5", phase: .failed, landsCommit: false, honesty: [.failed]),
            CastleWorkerStatus(runtime: "claude", modelArg: "claude-4", phase: .failed, landsCommit: false, honesty: [.failed])
        ]),
        failures: [],
        lastRefreshed: Date(),
        isLoading: false,
        onRetry: {} // Preview stub — the live retry hook is wired by the hosting dashboard.
    )
    .padding()
    .frame(width: 760)
}

#Preview("Partial success") {
    CastleGreatHallView(
        snapshot: CastleRunSnapshot(workers: [
            CastleWorkerStatus(runtime: "codex", modelArg: "gpt-5.5", phase: .landed, landsCommit: true, headSHA: "abc123"),
            CastleWorkerStatus(runtime: "claude", modelArg: "claude-4", phase: .failed, landsCommit: false, honesty: [.failed]),
            CastleWorkerStatus(runtime: "gemini", modelArg: "gemini-3.1", phase: .noOp, landsCommit: false, honesty: [.noOp])
        ]),
        failures: [],
        lastRefreshed: Date(),
        isLoading: false
    )
    .padding()
    .frame(width: 760)
}

// MARK: - Upgrade Sheet

/// Premium cap-limit upgrade sheet. Answers what happened, what unlocks, why
/// it matters, the provider-token truth, and the action — without a generic
/// paywall feel. Cap values are sourced from `WandFanOut` so they can never
/// drift from the source of truth.
struct WandCapUpgradeSheet: View {
    @Environment(\.dismiss) private var dismiss

    private let ladder: [(tier: CloudTier, cap: Int)] = [
        (.none, WandFanOut.maxParallel(for: .none)),
        (.cloud, WandFanOut.maxParallel(for: .cloud)),
        (.pro, WandFanOut.maxParallel(for: .pro)),
        (.ultra, WandFanOut.maxParallel(for: .ultra))
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            header

            capLadder

            truthNote

            actions
        }
        .padding(24)
        .frame(maxWidth: 480)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(DesignSystem.Colors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1)
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Upgrade to cast more agents in parallel")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.amber.opacity(0.14))
                    Image(systemName: "wand.and.rays")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.amber)
                }
                .frame(width: 40, height: 40)
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Go wider")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("More parallel agents, more model diversity, faster convergence.")
                        .font(.system(size: 12, weight: .medium, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
            }
        }
    }

    private var capLadder: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(ladder, id: \.tier) { entry in
                HStack {
                    Text(entry.tier == .none ? "Local" : entry.tier.displayName)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Spacer()
                    HStack(spacing: 4) {
                        ForEach(0..<entry.cap, id: \.self) { _ in
                            Circle()
                                .fill(capColor(entry.tier))
                                .frame(width: 8, height: 8)
                        }
                        Text("\(entry.cap) agent\(entry.cap == 1 ? "" : "s")")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 6).fill(DesignSystem.Colors.surfaceElevated.opacity(0.5)))
            }
        }
    }

    private var truthNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.shield.fill")
                .foregroundStyle(DesignSystem.Colors.success)
                .accessibilityHidden(true)
            Text("Your model tokens still come from your connected providers. BurnBar orchestrates the routing.")
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).fill(DesignSystem.Colors.success.opacity(0.06)))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button("Compare plans") {
                dismiss()
            }
            .buttonStyle(.bordered)
            .accessibilityLabel("Compare plans")

            Spacer()

            Button {
                dismiss()
            } label: {
                Text("Upgrade to Cloud Pro")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
            }
            .buttonStyle(.borderedProminent)
            .tint(DesignSystem.Colors.amber)
            .accessibilityLabel("Upgrade to Cloud Pro")
        }
    }

    private func capColor(_ tier: CloudTier) -> Color {
        switch tier {
        case .none: return DesignSystem.Colors.textMuted
        case .cloud: return DesignSystem.Colors.blaze
        case .pro: return DesignSystem.Colors.success
        case .ultra: return DesignSystem.Colors.amber
        }
    }
}
