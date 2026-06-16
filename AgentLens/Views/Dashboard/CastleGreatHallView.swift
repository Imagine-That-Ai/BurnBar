import SwiftUI
import OpenBurnBarCore

struct CastleGreatHallContainer: View {
    @State private var result = CastleStatusLoadResult.empty

    var body: some View {
        CastleGreatHallView(
            snapshot: result.snapshot,
            failures: result.failures,
            lastRefreshed: result.loadedAt
        )
        .task {
            refresh()
        }
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in
            refresh()
        }
    }

    private func refresh() {
        let configured = CastleStatusReader.configuredStatusURLs()
        let discovered = CastleStatusReader.recentStatusURLs(limit: 12)
        result = CastleStatusReader.loadStatusRecords(at: configured.isEmpty ? discovered : configured)
    }
}

struct CastleGreatHallView: View {
    let snapshot: CastleRunSnapshot
    let failures: [CastleStatusLoadFailure]
    let lastRefreshed: Date?

    private var activeCount: Int {
        snapshot.workers.filter { !$0.phase.isTerminal }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if snapshot.isEmpty && failures.isEmpty {
                emptyState
            } else {
                metricsRow
                workerGrid
                failureStrip
            }
        }
        .padding(18)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.68))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(DesignSystem.Colors.borderSubtle.opacity(0.7), lineWidth: 1)
                )
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Castle Great Hall")
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.ember.opacity(0.12))
                Image(systemName: "crown.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.amber)
            }
            .frame(width: 36, height: 36)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text("Castle Great Hall")
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(subheadline)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
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
        if snapshot.isEmpty {
            return failures.isEmpty ? "No worker verdicts found." : "\(failures.count) status record\(failures.count == 1 ? "" : "s") need attention."
        }
        if activeCount > 0 {
            return "\(activeCount) House\(activeCount == 1 ? "" : "s") still moving. \(snapshot.headline)."
        }
        return "\(snapshot.headline). No-op and failed Houses stay out of the tally."
    }

    private var emptyState: some View {
        HStack(spacing: 12) {
            Image(systemName: "moon.stars")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .frame(width: 32, height: 32)
                .background(Circle().fill(DesignSystem.Colors.surfaceElevated.opacity(0.7)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Castle idle")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("The Great Hall will light when worker status records arrive.")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DesignSystem.Colors.surfaceElevated.opacity(0.52)))
    }

    private var metricsRow: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 104, maximum: 180), spacing: 10, alignment: .leading)],
            alignment: .leading,
            spacing: 10
        ) {
            CastleMetricPill(label: "Raised", value: snapshot.landedCount, tint: DesignSystem.Colors.success, systemImage: "flag.fill")
            CastleMetricPill(label: "Moving", value: activeCount, tint: DesignSystem.Colors.amber, systemImage: "sparkles")
            CastleMetricPill(label: "No-op", value: snapshot.noOpCount, tint: DesignSystem.Colors.textMuted, systemImage: "flag.slash")
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
                .font(.system(size: 13, weight: .bold, design: .monospaced))
            Text(label)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
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
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: 7) {
                Label(worker.phase.displayLabel, systemImage: phaseIcon)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(phaseTint)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let head = worker.headSHA?.prefix(7), worker.landsCommit {
                    Text(String(head))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

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
        .accessibilityLabel("\(house.name), \(worker.modelArg ?? "model pending"), \(worker.phase.displayLabel)")
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
        lastRefreshed: Date()
    )
    .padding()
    .frame(width: 760)
}
