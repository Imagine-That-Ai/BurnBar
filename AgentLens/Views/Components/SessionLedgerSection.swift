import SwiftUI

// MARK: - Time bucket

enum SessionLedgerBucket: String, CaseIterable, Identifiable {
    case hour
    case day
    case week
    case month

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .hour: return "Hour"
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }

    func startOfBucket(containing date: Date, calendar: Calendar = .current) -> Date {
        switch self {
        case .hour:
            return calendar.dateInterval(of: .hour, for: date)?.start ?? date
        case .day:
            return calendar.startOfDay(for: date)
        case .week:
            return calendar.dateInterval(of: .weekOfYear, for: date)?.start ?? date
        case .month:
            return calendar.dateInterval(of: .month, for: date)?.start ?? date
        }
    }

    func sectionTitle(for bucketStart: Date, calendar: Calendar = .current) -> String {
        switch self {
        case .hour:
            return bucketStart.formatted(
                .dateTime
                    .month(.abbreviated)
                    .day()
                    .hour()
                    .minute()
            )
        case .day:
            return bucketStart.formatted(date: .complete, time: .omitted)
        case .week:
            let end = calendar.date(byAdding: .day, value: 6, to: bucketStart) ?? bucketStart
            let y = bucketStart.formatted(.dateTime.year())
            return "\(bucketStart.formatted(.dateTime.month(.abbreviated).day())) – \(end.formatted(.dateTime.month(.abbreviated).day())), \(y)"
        case .month:
            return bucketStart.formatted(.dateTime.month(.wide).year())
        }
    }
}

// MARK: - Filtering & grouping

enum SessionLedgerSupport {
    static func matchesSearch(_ usage: TokenUsage, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return true }
        if usage.projectName.lowercased().contains(q) { return true }
        if usage.model.lowercased().contains(q) { return true }
        if usage.sessionId.lowercased().contains(q) { return true }
        if usage.provider.displayName.lowercased().contains(q) { return true }
        if usage.id.uuidString.lowercased().contains(q) { return true }
        return false
    }

    static func groupedSessions(
        _ usages: [TokenUsage],
        bucket: SessionLedgerBucket,
        calendar: Calendar = .current
    ) -> [(bucketStart: Date, title: String, sessions: [TokenUsage])] {
        let sorted = usages.sorted { $0.startTime > $1.startTime }
        var buckets: [Date: [TokenUsage]] = [:]
        for u in sorted {
            let k = bucket.startOfBucket(containing: u.startTime, calendar: calendar)
            buckets[k, default: []].append(u)
        }
        return buckets.keys.sorted(by: >).map { k in
            (k, bucket.sectionTitle(for: k, calendar: calendar), buckets[k] ?? [])
        }
    }
}

// MARK: - Section (search + group + list)

struct SessionLedgerSection<EmptyLedger: View>: View {
    let usages: [TokenUsage]
    let theme: ProviderTheme
    @Binding var selectedSession: TokenUsage?
    let onOpenUsage: ((TokenUsage) -> Void)?
    let displayMode: UsageDisplayMode
    /// Model drill-down shows which agent ran the session; provider drill-down hides it.
    let showsAgentBadge: Bool
    let footerCaption: String
    private let emptyLedger: EmptyLedger

    @State private var searchText = ""
    @State private var bucket = SessionLedgerBucket.day

    init(
        usages: [TokenUsage],
        theme: ProviderTheme,
        selectedSession: Binding<TokenUsage?>,
        onOpenUsage: ((TokenUsage) -> Void)? = nil,
        displayMode: UsageDisplayMode,
        showsAgentBadge: Bool,
        footerCaption: String,
        @ViewBuilder emptyLedger: () -> EmptyLedger
    ) {
        self.usages = usages
        self.theme = theme
        self._selectedSession = selectedSession
        self.onOpenUsage = onOpenUsage
        self.displayMode = displayMode
        self.showsAgentBadge = showsAgentBadge
        self.footerCaption = footerCaption
        self.emptyLedger = emptyLedger()
    }

    private var filtered: [TokenUsage] {
        usages.filter { SessionLedgerSupport.matchesSearch($0, query: searchText) }
    }

    private var groups: [(bucketStart: Date, title: String, sessions: [TokenUsage])] {
        SessionLedgerSupport.groupedSessions(filtered, bucket: bucket)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Session Ledger")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text(footerCaption)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            if usages.isEmpty {
                emptyLedger
            } else {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                    ledgerSearchField

                    HStack(alignment: .center) {
                        Text("Group by")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)

                        Spacer(minLength: DesignSystem.Spacing.md)

                        SessionLedgerBucketPicker(selection: $bucket, accent: theme.primaryColor)
                    }
                }

                if filtered.isEmpty {
                    ledgerEmptyFilter
                } else {
                    ledgerGroupedList
                }
            }
        }
    }

    private var ledgerSearchField: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.textMuted)

            TextField("Search path, model, session…", text: $searchText)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm + 2)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.88))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.55), lineWidth: 0.5)
        )
    }

    private var ledgerEmptyFilter: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Text("No matches")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("Try another path fragment, model name, or session id.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)

            Button("Clear search") {
                searchText = ""
            }
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(theme.primaryColor)
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, DesignSystem.Spacing.xl)
    }

    private var ledgerGroupedList: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            ForEach(Array(groups.enumerated()), id: \.element.bucketStart) { _, group in
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack {
                        Text(group.title)
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)

                        Spacer()

                        Text("\(group.sessions.count) session\(group.sessions.count == 1 ? "" : "s")")
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }

                    VStack(spacing: DesignSystem.Spacing.xs) {
                        ForEach(group.sessions) { usage in
                            SessionLedgerEntryRow(
                                usage: usage,
                                theme: theme,
                                displayMode: displayMode,
                                showsAgentBadge: showsAgentBadge
                            ) {
                                if let onOpenUsage {
                                    onOpenUsage(usage)
                                } else {
                                    selectedSession = usage
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Capsule bucket control

private struct SessionLedgerBucketPicker: View {
    @Binding var selection: SessionLedgerBucket
    let accent: Color

    var body: some View {
        HStack(spacing: 0) {
            ForEach(Array(SessionLedgerBucket.allCases.enumerated()), id: \.element.id) { index, bucket in
                if index > 0 {
                    Rectangle()
                        .fill(DesignSystem.Colors.border.opacity(0.35))
                        .frame(width: 0.5, height: 14)
                }

                Button {
                    withAnimation(DesignSystem.Animation.snappy) {
                        selection = bucket
                    }
                } label: {
                    Text(bucket.shortLabel)
                        .font(DesignSystem.Typography.tiny)
                        .fontWeight(selection == bucket ? .semibold : .medium)
                        .foregroundStyle(selection == bucket ? accent : DesignSystem.Colors.textMuted)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 7)
                        .frame(minWidth: 52)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                                .fill(selection == bucket ? accent.opacity(0.14) : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Group sessions by \(bucket.shortLabel)")
            }
        }
        .padding(3)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.5)
        )
    }
}

// MARK: - Row

private struct SessionLedgerEntryRow: View {
    let usage: TokenUsage
    let theme: ProviderTheme
    var displayMode: UsageDisplayMode
    var showsAgentBadge: Bool
    let onTap: () -> Void

    private var cacheEfficient: Bool {
        usage.totalTokens > 0 && Double(usage.cacheReadTokens) / Double(usage.totalTokens) > 0.5
    }

    var body: some View {
        GlassCard(interactive: true) {
            HStack(spacing: DesignSystem.Spacing.md) {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                    .fill(theme.gradient)
                    .frame(width: 3)

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: DesignSystem.Spacing.sm) {
                            Text(usage.startTime.formatted(date: .omitted, time: .shortened))
                                .font(DesignSystem.Typography.monoSmall)
                                .foregroundStyle(theme.primaryColor)

                            if showsAgentBadge {
                                Text(usage.provider.displayName)
                                    .font(DesignSystem.Typography.tiny)
                                    .foregroundStyle(DesignSystem.Colors.primary(for: usage.provider))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(DesignSystem.Colors.primary(for: usage.provider).opacity(0.12))
                                    .clipShape(.capsule)
                            }
                        }

                        Text(usage.projectName)
                            .font(DesignSystem.Typography.body)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .lineLimit(2)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(
                            displayMode == .currency
                                ? usage.cost.formatAsCost()
                                : usage.totalTokens.formatAsTokenVolume()
                        )
                            .font(DesignSystem.Typography.mono)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)

                        Text(usage.model)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(1)

                        if cacheEfficient {
                            Text("Cache efficient")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.success)
                        }
                    }
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .stroke(cacheEfficient ? DesignSystem.Colors.success : Color.clear, lineWidth: 1.5)
                )
            }
        .onTapGesture(perform: onTap)
    }
}
