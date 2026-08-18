import SwiftUI
import OpenBurnBarKernel

// MARK: - The Receipt card
//
// One honest screen: the problems solved more than once, joined to what the
// repeats actually cost. Lives on the Charts page as a card section — same
// glass plate, same ink language (silver voice, ember only on the headline
// dollars). The numbers come from `ReceiptBuilder`, which never estimates:
// an empty receipt is a good outcome and is presented as one.

struct ReceiptCardView: View {
    let dataStore: DataStore
    let timeRange: TimeRange
    /// When provided, cluster rows open their most recent session log — the
    /// receipt's claims become inspectable, not just assertable.
    var onOpenConversation: ((String) -> Void)?

    @State private var snapshot: ReceiptSnapshot?
    @State private var isBuilding = false
    /// Set when a rebuild threw. Without this the `try?` swallowed the error and
    /// left `snapshot` nil, so the body — which keys the spinner off `snapshot`
    /// alone — showed "Adding up the repeats…" forever and never retried.
    @State private var buildFailed = false

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            header

            if let snapshot {
                if snapshot.isEmpty {
                    emptyState
                } else {
                    ReceiptSnapshotContent(snapshot: snapshot, onOpenConversation: onOpenConversation)
                }
            } else if buildFailed {
                failureState
            } else {
                loadingState
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .chartGlassCard()
        .task(id: refreshKey) { await rebuild() }
    }

    /// Same invalidation convention as the rest of the page: the store's
    /// content-version counter plus the selected range, never the row arrays.
    private var refreshKey: String {
        "\(timeRange.rawValue)|\(dataStore.usagesVersion)"
    }

    private func rebuild() async {
        isBuilding = true
        buildFailed = false
        defer { isBuilding = false }
        let window = timeRange.dateRange()
        do {
            snapshot = try await ReceiptBuilder.build(dataStore: dataStore, window: window)
        } catch {
            // A transient database error must not read as "still working".
            buildFailed = true
        }
    }

    // MARK: Header

    private var header: some View {
        Text("The Receipt".uppercased())
            .font(DesignSystem.Typography.caption)
            .fontWeight(.semibold)
            .tracking(0.8)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
    }

    // MARK: States

    private var loadingState: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            ProgressView()
                .controlSize(.small)
            Text("Adding up the repeats…")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DesignSystem.Spacing.lg)
    }

    private var failureState: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            Text("Couldn't add up this window.")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            Button("Try again") { Task { await rebuild() } }
                .buttonStyle(.plain)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.blaze)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, DesignSystem.Spacing.lg)
    }

    private var emptyState: some View {
        Text("No re-derived work found in this window. That's the good outcome.")
            .font(DesignSystem.Typography.body)
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .padding(.vertical, DesignSystem.Spacing.sm)
    }
}

// MARK: - Snapshot content

/// Pure rendering of a built snapshot — previewable without a database.
struct ReceiptSnapshotContent: View {
    let snapshot: ReceiptSnapshot

    /// Data-dense but bounded: the expensive waste up top, the tail summed.
    private static let visibleClusterLimit = 8

    private var visibleClusters: [ReceiptCluster] {
        Array(snapshot.clusters.prefix(Self.visibleClusterLimit))
    }

    private var overflowClusters: [ReceiptCluster] {
        Array(snapshot.clusters.dropFirst(Self.visibleClusterLimit))
    }

    var onOpenConversation: ((String) -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            headline

            VStack(spacing: 0) {
                ForEach(Array(visibleClusters.enumerated()), id: \.element.id) { index, cluster in
                    if index > 0 {
                        Divider().overlay(DesignSystem.Colors.borderSubtle)
                    }
                    ReceiptClusterRow(cluster: cluster, onOpenConversation: onOpenConversation)
                }
            }

            if !overflowClusters.isEmpty {
                overflowLine
            }

            if snapshot.costIsPartial {
                partialCostFootnote
            }
        }
    }

    // MARK: Headline — the artifact's one sentence.

    private var headline: some View {
        (
            Text("You solved \(problemPhrase) more than once, across \(agentPhrase). Re-deriving them cost ")
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            + Text(snapshot.totalRederivedCostUSD.formatAsCost())
                .font(DesignSystem.Typography.mono)
                .foregroundStyle(ChartInk.signature)
            + Text(".")
                .foregroundStyle(DesignSystem.Colors.textPrimary)
        )
        .font(DesignSystem.Typography.headline)
    }

    private var problemPhrase: String {
        snapshot.problemCount == 1 ? "1 problem" : "\(snapshot.problemCount) problems"
    }

    private var agentPhrase: String {
        snapshot.distinctAgentCount == 1 ? "1 agent" : "\(snapshot.distinctAgentCount) agents"
    }

    // MARK: Footers

    private var overflowLine: some View {
        let total = overflowClusters.reduce(0) { $0 + $1.rederivedCostUSD }
        return Text("+ \(overflowClusters.count) more re-derived problem\(overflowClusters.count == 1 ? "" : "s"), \(total.formatAsCost())")
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
    }

    /// The undercount disclosure — the receipt says so out loud rather than
    /// quietly presenting a floor as a total.
    private var partialCostFootnote: some View {
        Text("Some sessions have no recorded spend, so the dollar figures are an undercount.")
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
    }
}

// MARK: - Cluster row

private struct ReceiptClusterRow: View {
    let cluster: ReceiptCluster
    var onOpenConversation: ((String) -> Void)?

    /// The member a click should open: the LATEST re-derivation — the one the
    /// user would actually re-read to stop paying for it again.
    private var latestConversationID: String? {
        cluster.conversations.last?.id
    }

    var body: some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                Text(cluster.representativeTitle)
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)

                Text(detailLine)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(cluster.rederivedCostUSD.formatAsCost())
                .font(DesignSystem.Typography.mono)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            if onOpenConversation != nil, latestConversationID != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .padding(.vertical, DesignSystem.Spacing.sm)

        if let onOpenConversation, let latestConversationID {
            Button {
                onOpenConversation(latestConversationID)
            } label: {
                row.contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open the latest session for this problem")
        } else {
            row
        }
    }

    /// "solved 3× · Claude Code, Codex · OpenBurnBar · Jun 3 – Jun 9"
    private var detailLine: String {
        var parts: [String] = ["solved \(cluster.solveCount)×"]
        parts.append(cluster.providers.map(\.displayName).joined(separator: ", "))
        parts.append(cluster.projectName)
        if let span = dateSpan { parts.append(span) }
        return parts.joined(separator: " · ")
    }

    private var dateSpan: String? {
        guard let first = cluster.conversations.first?.startTime,
              let last = cluster.conversations.last?.startTime else { return nil }
        let formatter = Date.FormatStyle(date: .abbreviated, time: .omitted)
        if Calendar.current.isDate(first, inSameDayAs: last) {
            return first.formatted(formatter)
        }
        return "\(first.formatted(formatter)) – \(last.formatted(formatter))"
    }
}

// MARK: - Previews

#Preview("Receipt — clusters") {
    ReceiptSnapshotContent(snapshot: ReceiptSnapshot(
        clusters: [
            ReceiptCluster(
                id: "receipt:preview-1",
                representativeTitle: "Fix flaky auth token refresh test",
                projectName: "OpenBurnBar",
                conversations: [
                    ReceiptConversationRef(
                        id: "preview-1a",
                        provider: .claudeCode,
                        startTime: Date(timeIntervalSinceNow: -6 * 86_400),
                        costUSD: 2.10,
                        hasUsage: true
                    ),
                    ReceiptConversationRef(
                        id: "preview-1b",
                        provider: .codex,
                        startTime: Date(timeIntervalSinceNow: -2 * 86_400),
                        costUSD: 5.40,
                        hasUsage: true
                    )
                ],
                rederivedCostUSD: 5.40
            ),
            ReceiptCluster(
                id: "receipt:preview-2",
                representativeTitle: "Debug xcodegen membership drift",
                projectName: "OpenBurnBar",
                conversations: [
                    ReceiptConversationRef(
                        id: "preview-2a",
                        provider: .claudeCode,
                        startTime: Date(timeIntervalSinceNow: -4 * 86_400),
                        costUSD: 1.20,
                        hasUsage: true
                    ),
                    ReceiptConversationRef(
                        id: "preview-2b",
                        provider: .claudeCode,
                        startTime: Date(timeIntervalSinceNow: -1 * 86_400),
                        costUSD: 0,
                        hasUsage: false
                    )
                ],
                rederivedCostUSD: 0
            )
        ],
        distinctAgentCount: 2,
        totalRederivedCostUSD: 5.40,
        windowDays: 7,
        costIsPartial: true
    ))
    .padding(DesignSystem.Spacing.lg)
    .frame(width: 560)
}
