import OpenBurnBarCore
import OpenBurnBarInboxModels
import OpenBurnBarUI
import SwiftUI

// MARK: - Home shells
//
// Six bespoke Home surfaces, one per layout thesis that the plain inbox list
// cannot express. (`ledger` and `bento` are not here: they are `InboxView` and
// `InboxPriorityBoard`, which already are those theses.)
//
// House rules for everything in this file:
//
//   * One shell, one dominant element. If two things compete for the eye, the
//     shell has no thesis and may as well be Ledger.
//   * Containers are `DashboardSection`, never ad-hoc glass. That is what keeps
//     eight Home surfaces reading as one product.
//   * Colour comes from `BackdropInk`, passed in rather than read from the
//     environment, so a shell renders identically whether it is mounted under a
//     live kernel or a flat canvas.
//   * Empty is a designed state. A shell with nothing to show says so in its own
//     voice instead of rendering a blank plate.
//   * **Space is declared, not stacked.** A shell states what it wants as
//     `[LivingSlot]` and renders through `HomeLivingLayout`; it never wraps itself
//     in a `ScrollView`, never caps the *composition* at a reading width, and
//     never truncates a list at a constant. A row count comes from the plan;
//     a reading measure comes from `HomeReadingMeasure` and applies to prose.
//   * Motion comes from `MotionTokens`, the shared six-platform vocabulary.

// MARK: - Focus

/// **Focus** — the one item that needs you, at headline size, and nothing else
/// above the fold.
///
/// The enforced rule: exactly one item is rendered large. Everything else is a
/// count and a single line.
struct HomeFocusShell: View {
    let digest: HomeInboxDigest
    let ink: BackdropInk
    /// Live spend for the chart band, cut by harness and by model. Empty is a
    /// designed state.
    var spend: HomeSpendCube = .empty
    let onOpenItem: (String) -> Void
    let onOpenInbox: () -> Void

    private enum Slot {
        static let lead = "focus.lead"
        static let queue = "focus.queue"
    }

    private static let rowUnit: CGFloat = 27
    /// The chart earns real estate rather than being a wash behind the type. Below
    /// this the band is dropped entirely — a 90pt chart is a smear, not a chart.
    /// The extra 24pt over the plot itself is the control strip: breakdown picker and
    /// legend live inside the chart's own frame rather than stealing a row above it.
    private static let chartHeight: CGFloat = 212
    private static let chartFloor: CGFloat = 520

    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                LiquidGlassGroup(spacing: DesignSystem.Spacing.md) {
                    HomeLivingLayout(
                        slots: slots,
                        gutter: DesignSystem.Spacing.md,
                        padding: DesignSystem.Spacing.xl
                    ) { id, placement in
                        switch id {
                        case Slot.lead:
                            if let lead = digest.lead { hero(lead) } else { clearHero }
                        case Slot.queue:
                            queue(rows: placement.rowCount)
                        default:
                            EmptyView()
                        }
                    }
                }

                if geo.size.height >= Self.chartFloor {
                    HomeSpendChart(cube: spend, ink: ink)
                        .frame(height: Self.chartHeight)
                        .padding(.horizontal, DesignSystem.Spacing.xl)
                        .padding(.bottom, DesignSystem.Spacing.lg)
                        .transition(MotionTokens.flow(reduceMotion: reduceMotion))
                }
            }
            .animation(MotionTokens.settle(reduceMotion: reduceMotion), value: geo.size.height >= Self.chartFloor)
        }
        .background {
            HomeBloomBackdrop()
        }
    }

    private var slots: [LivingSlot] {
        var result: [LivingSlot] = [
            LivingSlot(id: Slot.lead, rank: 0, floor: 200, ideal: 340, stretch: 1)
        ]
        let queued = max(0, digest.total - 1)
        if queued > 0 {
            result.append(
                LivingSlot(
                    id: Slot.queue,
                    rank: 1,
                    floor: 45 + Self.rowUnit * 2,
                    ideal: 45 + Self.rowUnit * 4,
                    rows: LivingSlot.RowAppetite(
                        available: queued,
                        baseline: min(2, queued),
                        unit: Self.rowUnit,
                        ceiling: 7
                    )
                )
            )
        }
        return result
    }

    /// The one item, at the size the shell promises. Plateless on purpose — the bloom
    /// is the surface, so there is no slab to leave half-empty.
    private func hero(_ row: ControlPlaneStore.AIInboxRow) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Spacer(minLength: 0)

            Text(InboxPresentation.kindLabel(row.summary.kind).uppercased())
                .font(DesignSystem.Typography.tiny)
                .tracking(1.6)
                .foregroundStyle(InboxPresentation.tint(for: row.summary.kind))

            // The headline is the disclosure control. A separate chevron beside a 46pt
            // line is a hit target nobody finds; the whole title is the affordance and
            // the chevron just says which way it goes.
            Button {
                withAnimation(MotionTokens.settle(reduceMotion: reduceMotion)) { isExpanded.toggle() }
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                    Text(row.summary.title)
                        .font(.system(size: 44, weight: .semibold, design: .rounded))
                        .foregroundStyle(ink.primary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: HomeReadingMeasure.headline, alignment: .leading)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(ink.icon)
                        .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(isExpanded ? "Hide details" : "Show details")
            .accessibilityLabel(row.summary.title)
            .accessibilityHint(isExpanded ? "Hide details" : "Show details")

            Text(HomeShellCopy.sentence(for: row))
                .font(DesignSystem.Typography.body)
                .foregroundStyle(ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: HomeReadingMeasure.body, alignment: .leading)

            if isExpanded {
                detailCards(row)
                    .transition(MotionTokens.flow(reduceMotion: reduceMotion))
            }

            Button { onOpenItem(row.id) } label: {
                HStack(spacing: 7) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 13, weight: .semibold))
                    Text("Open this item")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(ink.primary)
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .burnBarGlassControl(.focus, tint: InboxPresentation.tint(for: row.summary.kind))
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier(OBBAccessibilityID.homeFocusPrimaryAction)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What the chevron reveals: the facts already on the row, as their own glass
    /// cards rather than another sentence.
    private func detailCards(_ row: ControlPlaneStore.AIInboxRow) -> some View {
        FlowLayout(horizontalSpacing: DesignSystem.Spacing.sm, verticalSpacing: DesignSystem.Spacing.sm) {
            ForEach(Array(details(row).enumerated()), id: \.element.label) { index, detail in
                VStack(alignment: .leading, spacing: 3) {
                    Text(detail.label)
                        .font(DesignSystem.Typography.tiny)
                        .tracking(1.1)
                        .foregroundStyle(ink.subtle)
                    Text(detail.value)
                        .font(DesignSystem.Typography.monoSmall)
                        .foregroundStyle(detail.tint)
                        .lineLimit(1)
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .frame(minWidth: 116, alignment: .leading)
                .burnBarGlass(.focus, role: .content, tint: detail.tint, cornerRadius: DesignSystem.Radius.md)
                .animation(MotionTokens.arrive(index: index, reduceMotion: reduceMotion), value: isExpanded)
            }
        }
        .frame(maxWidth: HomeReadingMeasure.body, alignment: .leading)
    }

    private func details(_ row: ControlPlaneStore.AIInboxRow) -> [(label: String, value: String, tint: Color)] {
        var result: [(String, String, Color)] = [
            (
                "PRIORITY",
                InboxPresentation.priorityLabel(row.summary.priority).uppercased(),
                row.summary.priority == .p1 ? DesignSystem.Colors.error : DesignSystem.Colors.amber
            ),
            ("SEEN", "×\(max(1, row.summary.occurrenceCount))", DesignSystem.Colors.whimsy),
            ("LAST", HomeShellCopy.time(row.summary.lastSeenAt), DesignSystem.Colors.ember),
            ("FIRST", HomeShellCopy.dayLabel(row.summary.firstSeenAt).capitalized, ink.secondary)
        ]
        if let project = row.summary.projectName, project.isEmpty == false {
            result.append(("PROJECT", project, DesignSystem.Colors.blaze))
        }
        result.append(("STATE", row.isUnread ? "UNREAD" : "SEEN", ink.secondary))
        return result.map { (label: $0.0, value: $0.1, tint: $0.2) }
    }

    private var clearHero: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Spacer(minLength: 0)
            Text("ALL CLEAR")
                .font(DesignSystem.Typography.tiny)
                .tracking(1.6)
                .foregroundStyle(DesignSystem.Colors.success)
            Text("Nothing needs you")
                .font(.system(size: 44, weight: .semibold, design: .rounded))
                .foregroundStyle(ink.primary)
            Text("Detectors are still running. Anything worth a decision lands here first.")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: HomeReadingMeasure.body, alignment: .leading)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What is behind the lead item — a glass pane floating on the bloom, sized to the
    /// rows the plan granted and nothing more.
    private func queue(rows limit: Int) -> some View {
        let queued = Array(digest.rows.dropFirst().prefix(limit))
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("NEXT")
                .font(DesignSystem.Typography.tiny)
                .tracking(1.4)
                .foregroundStyle(DesignSystem.Colors.amber)

            VStack(spacing: 0) {
                ForEach(Array(queued.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { DashboardSectionRule() }
                    HomeCompactInboxRow(row: row, ink: ink, onOpen: onOpenItem)
                }
            }

            if digest.total - 1 > queued.count {
                Button(action: onOpenInbox) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text("\(digest.total - 1 - queued.count) more waiting")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(ink.subtle)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(ink.icon)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open the full inbox")
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .burnBarGlass(.focus, role: .chrome, tint: DesignSystem.Colors.amber)
    }
}

// MARK: - Reading measure

enum HomeReadingMeasure {
    static let headline: CGFloat = 620
    static let body: CGFloat = 680
    static let editorial: CGFloat = 760
}

// MARK: - Canvas

/// **Canvas** — ambient. An editorial headline, one sentence, three quiet lines.
///
/// The enforced rule: at most one plate on screen, and no number larger than the
/// body text. This is the shell you leave open on a second display.
struct HomeCanvasShell: View {
    let digest: HomeInboxDigest
    let ink: BackdropInk
    let onOpenItem: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                Spacer(minLength: 0)

                Text(headline)
                    .font(.system(size: 36, weight: .light, design: .serif))
                    .foregroundStyle(ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: HomeReadingMeasure.editorial, alignment: .leading)
                    .contentTransition(.opacity)

                Text(subhead)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: HomeReadingMeasure.body, alignment: .leading)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    ForEach(quietLines(in: geo.size.height)) { row in
                        Button { onOpenItem(row.id) } label: {
                            HStack(spacing: DesignSystem.Spacing.sm) {
                                Circle()
                                    .fill(InboxPresentation.tint(for: row.summary.kind))
                                    .frame(width: 5, height: 5)
                                    .shadow(
                                        color: InboxPresentation.tint(for: row.summary.kind).opacity(0.5),
                                        radius: 2
                                    )
                                Text(row.summary.title)
                                    .font(DesignSystem.Typography.caption)
                                    .foregroundStyle(ink.secondary)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 3)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .transition(MotionTokens.flow(reduceMotion: reduceMotion))
                    }
                }
                .frame(maxWidth: HomeReadingMeasure.editorial, alignment: .leading)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, DesignSystem.Spacing.xxl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .animation(MotionTokens.settle(reduceMotion: reduceMotion), value: geo.size.height)
        }
    }

    private func quietLines(in height: CGFloat) -> [ControlPlaneStore.AIInboxRow] {
        guard height > 0 else { return Array(digest.rows.prefix(3)) }
        let beyondHeadline = max(0, height - 260)
        let affordable = 3 + Int(beyondHeadline / 140)
        return Array(digest.rows.prefix(min(6, max(3, affordable))))
    }

    private var headline: String {
        guard let lead = digest.lead else { return "All quiet." }
        return lead.summary.title
    }

    private var subhead: String {
        guard let lead = digest.lead else {
            return "Nothing in the inbox needs a decision right now."
        }
        let others = digest.total - 1
        let tail = others > 0 ? " \(others) other \(others == 1 ? "item" : "items") waiting." : ""
        return HomeShellCopy.sentence(for: lead) + tail
    }
}

// MARK: - Stream

/// **Stream** — a timestamped river, newest first.
///
/// The enforced rule: every row is anchored to a time, and rows are grouped by
/// day. Nothing is ranked; recency is the only order.
struct HomeStreamShell: View {
    let digest: HomeInboxDigest
    let ink: BackdropInk
    let onOpenItem: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let rowUnit: CGFloat = 28
    private static let dayChrome: CGFloat = 45

    var body: some View {
        HomeLivingLayout(slots: slots, gutter: DesignSystem.Spacing.md) { _, placement in
            river(rows: placement.rowCount)
        }
    }

    private var slots: [LivingSlot] {
        let days = max(1, digest.days().count)
        return [
            LivingSlot(
                id: "stream.river",
                rank: 0,
                floor: Self.dayChrome + Self.rowUnit * 3,
                ideal: Self.dayChrome * CGFloat(days) + Self.rowUnit * CGFloat(max(3, digest.rows.count)),
                stretch: 1,
                rows: LivingSlot.RowAppetite(
                    available: digest.rows.count,
                    baseline: min(3, digest.rows.count),
                    unit: Self.rowUnit,
                    ceiling: 40
                )
            )
        ]
    }

    @ViewBuilder
    private func river(rows limit: Int) -> some View {
        if digest.rows.isEmpty {
            DashboardSection("STREAM", accent: DesignSystem.Colors.whimsy, fillsHeight: true) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Nothing has happened yet today.")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(ink.secondary)
                    Text("The event stream records decisions, writes, and detector alerts as they occur.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(ink.subtle)
                    Spacer(minLength: 0)
                }
            }
        } else {
            LazyVStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                ForEach(days(limitedTo: limit)) { day in
                    daySection(day)
                        .transition(MotionTokens.flow(reduceMotion: reduceMotion))
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func days(limitedTo limit: Int) -> [HomeInboxDigest.Day] {
        let newest = digest.rows
            .sorted { $0.summary.lastSeenAt > $1.summary.lastSeenAt }
            .prefix(max(1, limit))
        return HomeInboxDigest(rows: Array(newest)).days()
    }

    private func daySection(_ day: HomeInboxDigest.Day) -> some View {
        DashboardSection(
            HomeShellCopy.dayLabel(day.date),
            accent: DesignSystem.Colors.whimsy,
            density: .compact,
            fillsHeight: false
        ) {
            VStack(spacing: 0) {
                ForEach(Array(day.rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 { DashboardSectionRule() }
                    entryRow(row)
                }
            }
        }
    }

    private func entryRow(_ row: ControlPlaneStore.AIInboxRow) -> some View {
        Button { onOpenItem(row.id) } label: {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                Text(HomeShellCopy.time(row.summary.lastSeenAt))
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(ink.subtle)
                    .frame(width: 60, alignment: .leading)

                Image(systemName: InboxPresentation.icon(for: row.summary.kind))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(InboxPresentation.tint(for: row.summary.kind))
                    .frame(width: 16)

                Text(row.summary.title)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(row.isUnread ? ink.primary : ink.secondary)
                    .lineLimit(1)

                Spacer(minLength: DesignSystem.Spacing.sm)

                if row.summary.occurrenceCount > 1 {
                    Text("×\(row.summary.occurrenceCount)")
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(ink.subtle)
                }
                if row.isUnread {
                    Circle()
                        .fill(InboxPresentation.tint(for: row.summary.kind))
                        .frame(width: 5, height: 5)
                        .shadow(
                            color: InboxPresentation.tint(for: row.summary.kind).opacity(0.6),
                            radius: 2
                        )
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(OBBAccessibilityID.inboxRow(row.id))
    }
}

// MARK: - Atlas

/// **Atlas** — needs-you against everything else, with the gap spelled out.
///
/// The enforced rule: every figure carries a comparison. A bare count without a
/// counterpart belongs in Ledger.
struct HomeAtlasShell: View {
    let digest: HomeInboxDigest
    let ink: BackdropInk
    let onOpenItem: (String) -> Void

    private enum Slot {
        static let split = "atlas.split"
        static let attention = "atlas.attention"
        static let kinds = "atlas.kinds"
    }

    private static let rowUnit: CGFloat = 28

    var body: some View {
        HomeLivingLayout(slots: slots, gutter: DesignSystem.Spacing.md) { id, placement in
            switch id {
            case Slot.split: splitHeader
            case Slot.attention: attentionLadder(rows: placement.rowCount)
            case Slot.kinds: kindLadder(rows: placement.rowCount)
            default: EmptyView()
            }
        }
    }

    private var slots: [LivingSlot] {
        let attentionCount = digest.urgent.count + digest.today.count
        let kindCount = digest.kindRanking.count
        return [
            LivingSlot(id: Slot.split, rank: 0, floor: 124, ideal: 136, spans: true),
            LivingSlot(
                id: Slot.attention,
                rank: 1,
                floor: 45 + Self.rowUnit * CGFloat(min(2, max(1, attentionCount))),
                ideal: 45 + Self.rowUnit * CGFloat(min(8, max(2, attentionCount))),
                stretch: 1,
                rows: LivingSlot.RowAppetite(
                    available: attentionCount,
                    baseline: min(2, attentionCount),
                    unit: Self.rowUnit,
                    ceiling: 20
                )
            ),
            LivingSlot(
                id: Slot.kinds,
                rank: 2,
                floor: 45 + Self.rowUnit * CGFloat(min(2, max(1, kindCount))),
                ideal: 45 + Self.rowUnit * CGFloat(min(8, max(2, kindCount))),
                stretch: 1,
                rows: LivingSlot.RowAppetite(
                    available: kindCount,
                    baseline: min(2, kindCount),
                    unit: Self.rowUnit,
                    ceiling: 20
                )
            )
        ]
    }

    private var splitHeader: some View {
        DashboardSection(
            "SPLIT",
            accent: DesignSystem.Colors.blaze,
            emphasis: .featured,
            fillsHeight: true
        ) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                    DashboardSectionValue(
                        label: "Needs you",
                        value: "\(digest.attentionCount)",
                        caption: "\(digest.urgent.count) urgent · \(digest.today.count) today",
                        accent: DesignSystem.Colors.error
                    )
                    DashboardSectionValue(
                        label: "Everything else",
                        value: "\(digest.later.count)",
                        caption: "Worth knowing, not now",
                        accent: DesignSystem.Colors.whimsy
                    )
                    DashboardSectionValue(
                        label: "Unread share",
                        value: HomeShellCopy.percent(digest.unreadShare),
                        caption: "\(digest.unreadCount) of \(digest.total)",
                        accent: DesignSystem.Colors.amber
                    )
                }

                comparativeMeter
            }
        }
    }

    private var comparativeMeter: some View {
        VStack(spacing: 3) {
            GeometryReader { geo in
                let total = max(1, digest.total)
                let urgentWidth = geo.size.width * CGFloat(Double(digest.urgent.count) / Double(total))
                let todayWidth = geo.size.width * CGFloat(Double(digest.today.count) / Double(total))
                let laterWidth = geo.size.width * CGFloat(Double(digest.later.count) / Double(total))

                HStack(spacing: 2) {
                    if digest.urgent.isEmpty == false {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(DesignSystem.Colors.error)
                            .frame(width: max(3, urgentWidth))
                    }
                    if digest.today.isEmpty == false {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(DesignSystem.Colors.amber)
                            .frame(width: max(3, todayWidth))
                    }
                    if digest.later.isEmpty == false {
                        RoundedRectangle(cornerRadius: 2, style: .continuous)
                            .fill(DesignSystem.Colors.whimsy)
                            .frame(width: max(3, laterWidth))
                    }
                }
            }
            .frame(height: 5)
            .background {
                Capsule()
                    .fill(ink.hairline.opacity(0.3))
            }
        }
        .padding(.top, 2)
    }

    private func attentionLadder(rows limit: Int) -> some View {
        DashboardSection(
            "NEEDS YOU",
            accent: DesignSystem.Colors.error,
            density: .compact,
            fillsHeight: false
        ) {
            VStack(spacing: 0) {
                let rows = Array((digest.urgent + digest.today).prefix(limit))
                if rows.isEmpty {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DesignSystem.Colors.success)
                        Text("Clear · 0 items requiring immediate action")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(ink.subtle)
                    }
                    .padding(.vertical, DesignSystem.Spacing.sm)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { DashboardSectionRule() }
                        comparisonRow(row)
                    }
                }
            }
        }
    }

    private func kindLadder(rows limit: Int) -> some View {
        DashboardSection(
            "BY KIND",
            accent: DesignSystem.Colors.whimsy,
            density: .compact,
            fillsHeight: false
        ) {
            VStack(spacing: 0) {
                let ranking = Array(digest.kindRanking.prefix(limit))
                if ranking.isEmpty {
                    Text("No detector signals detected")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(ink.subtle)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                } else {
                    ForEach(Array(ranking.enumerated()), id: \.element.kind) { index, entry in
                        if index > 0 { DashboardSectionRule() }
                        kindComparativeRow(entry)
                    }
                }
            }
        }
    }

    private func kindComparativeRow(
        _ entry: (kind: BurnBarInboxItemKind, count: Int, occurrences: Int)
    ) -> some View {
        let kindTint = InboxPresentation.tint(for: entry.kind)
        let maxCount = max(1, digest.total)
        let share = Double(entry.count) / Double(maxCount)

        return HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: InboxPresentation.icon(for: entry.kind))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(kindTint)
                .frame(width: 14)

            Text(InboxPresentation.kindLabel(entry.kind))
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(ink.primary)
                .lineLimit(1)

            Spacer(minLength: DesignSystem.Spacing.xs)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(ink.hairline.opacity(0.35))
                    Capsule()
                        .fill(kindTint)
                        .frame(width: max(4, geo.size.width * CGFloat(share)))
                }
            }
            .frame(width: 52, height: 4)

            Text("\(entry.count)")
                .font(DesignSystem.Typography.monoSmall)
                .foregroundStyle(kindTint)
                .frame(minWidth: 20, alignment: .trailing)
        }
        .padding(.vertical, 5)
    }

    private func comparisonRow(_ row: ControlPlaneStore.AIInboxRow) -> some View {
        let isP1 = row.summary.priority == .p1
        let priorityColor = isP1 ? DesignSystem.Colors.error : DesignSystem.Colors.amber

        return Button { onOpenItem(row.id) } label: {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
                Text(InboxPresentation.priorityLabel(row.summary.priority).uppercased())
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(priorityColor)
                    .frame(width: 54, alignment: .leading)

                Text(row.summary.title)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(ink.primary)
                    .lineLimit(1)

                Spacer(minLength: DesignSystem.Spacing.sm)

                Text("×\(max(1, row.summary.occurrenceCount))")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(ink.subtle)
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(OBBAccessibilityID.inboxRow(row.id))
    }
}

// MARK: - Cockpit

/// **Cockpit** — instruments over a compact list.
///
/// The enforced rule: gauges belong to the Cockpit idiom — this shell and
/// `cockpitLayout` — and nowhere else, and an alarm reads loud only when
/// something is actually wrong.
struct HomeCockpitShell: View {
    let digest: HomeInboxDigest
    let ink: BackdropInk
    let activeAgentCount: Int
    let onOpenItem: (String) -> Void

    private enum Slot {
        static let instruments = "cockpit.instruments"
        static let alarms = "cockpit.alarms"
        static let queue = "cockpit.queue"
    }

    private static let rowUnit: CGFloat = 28

    var body: some View {
        HomeLivingLayout(slots: slots, gutter: DesignSystem.Spacing.md) { id, placement in
            switch id {
            case Slot.instruments: instruments
            case Slot.alarms: alarms
            case Slot.queue: queue(rows: placement.rowCount)
            default: EmptyView()
            }
        }
    }

    private var slots: [LivingSlot] {
        [
            LivingSlot(id: Slot.instruments, rank: 0, floor: 154, ideal: 164, spans: true),
            LivingSlot(id: Slot.alarms, rank: 1, floor: 148, ideal: 160),
            LivingSlot(
                id: Slot.queue,
                rank: 2,
                floor: 45 + Self.rowUnit * CGFloat(min(3, max(1, digest.rows.count))),
                ideal: 45 + Self.rowUnit * CGFloat(min(10, max(3, digest.rows.count))),
                stretch: 1,
                rows: LivingSlot.RowAppetite(
                    available: digest.rows.count,
                    baseline: min(3, digest.rows.count),
                    unit: Self.rowUnit,
                    ceiling: 30
                )
            )
        ]
    }

    private var instruments: some View {
        DashboardSection(
            "INSTRUMENTS",
            accent: DesignSystem.Colors.ember,
            density: .compact,
            fillsHeight: true
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: DesignSystem.Spacing.md) { gauges }
                VStack(spacing: DesignSystem.Spacing.md) { gauges }
            }
        }
    }

    @ViewBuilder
    private var gauges: some View {
        CockpitGauge(
            label: "Attention load",
            readout: HomeShellCopy.percent(digest.attentionLoad),
            value: digest.attentionLoad,
            redline: 0.5,
            accent: DesignSystem.Colors.error,
            caption: "\(digest.attentionCount)/\(digest.total)"
        )
        CockpitGauge(
            label: "Unread",
            readout: HomeShellCopy.percent(digest.unreadShare),
            value: digest.unreadShare,
            redline: 0.75,
            accent: DesignSystem.Colors.amber
        )
        CockpitGauge(
            label: "Fleet",
            readout: "\(activeAgentCount)",
            value: min(1, Double(activeAgentCount) / 6),
            redline: nil,
            accent: DesignSystem.Colors.success,
            caption: activeAgentCount == 1 ? "agent live" : "agents live"
        )
    }

    private var alarms: some View {
        DashboardSection(
            "ALARM PANEL",
            accent: DesignSystem.Colors.warning,
            density: .compact,
            fillsHeight: false
        ) {
            VStack(spacing: DesignSystem.Spacing.xs) {
                CockpitAlarmPanel(alarms: alarmRows)

                HStack(spacing: DesignSystem.Spacing.md) {
                    telemetryItem(label: "UNREAD", value: "\(digest.unreadCount)", color: DesignSystem.Colors.amber)
                    telemetryItem(label: "TOTAL", value: "\(digest.total)", color: ink.primary)
                    telemetryItem(
                        label: "FLEET",
                        value: "\(activeAgentCount)",
                        color: activeAgentCount > 0 ? DesignSystem.Colors.success : ink.subtle
                    )
                }
                .padding(.horizontal, DesignSystem.Spacing.xs)
                .padding(.top, DesignSystem.Spacing.xs)
            }
        }
    }

    private func telemetryItem(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(ink.subtle)
            Text(value)
                .font(DesignSystem.Typography.monoTiny)
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var alarmRows: [(title: String, detail: String, state: CockpitAlarmRow.State)] {
        var rows: [(title: String, detail: String, state: CockpitAlarmRow.State)] = []

        rows.append((
            title: "Urgent queue",
            detail: digest.urgent.isEmpty
                ? "No P1 items open"
                : "\(digest.urgent.count) P1 \(digest.urgent.count == 1 ? "item" : "items") open",
            state: digest.urgent.isEmpty ? .nominal : .alarm
        ))

        rows.append((
            title: "Today queue",
            detail: digest.today.isEmpty
                ? "Nothing due today"
                : "\(digest.today.count) waiting on a decision",
            state: digest.today.isEmpty ? .nominal : .caution
        ))

        rows.append((
            title: "Fleet observation",
            detail: activeAgentCount > 0
                ? "\(activeAgentCount) agent\(activeAgentCount == 1 ? "" : "s") writing now"
                : "No agent activity observed",
            state: .nominal
        ))

        return rows
    }

    private func queue(rows limit: Int) -> some View {
        DashboardSection(
            "QUEUE",
            accent: DesignSystem.Colors.blaze,
            density: .compact,
            fillsHeight: true
        ) {
            VStack(spacing: 0) {
                let rows = Array(digest.rows.prefix(limit))
                if rows.isEmpty {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "checkmark.circle")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DesignSystem.Colors.success)
                        Text("Queue clear · No pending items")
                            .font(DesignSystem.Typography.caption)
                            .foregroundStyle(ink.subtle)
                    }
                    .padding(.vertical, DesignSystem.Spacing.sm)
                } else {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { DashboardSectionRule() }
                        HomeCompactInboxRow(row: row, ink: ink, onOpen: onOpenItem)
                    }
                    if digest.total > rows.count {
                        DashboardSectionRule()
                        Text("\(digest.total - rows.count) more in the inbox")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(ink.subtle)
                            .padding(.top, DesignSystem.Spacing.xs)
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }
}

// MARK: - Ask

/// **Ask** — the question box first; items are the context underneath it.
///
/// The enforced rule: the field is the first and largest element, and the
/// suggestions are generated from what is actually in the inbox rather than a
/// hardcoded list that goes stale.
struct HomeAskShell: View {
    let digest: HomeInboxDigest
    let ink: BackdropInk
    let onAsk: (String) -> Void
    let onOpenItem: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var query = ""
    @FocusState private var isFieldFocused: Bool

    private enum Slot {
        static let command = "ask.command"
        static let context = "ask.context"
    }

    private static let rowUnit: CGFloat = 28

    var body: some View {
        LiquidGlassGroup(spacing: DesignSystem.Spacing.md) {
            HomeLivingLayout(slots: slots, gutter: DesignSystem.Spacing.md, padding: DesignSystem.Spacing.lg) { id, placement in
                switch id {
                case Slot.command: commandBar
                case Slot.context: context(rows: placement.rowCount)
                default: EmptyView()
                }
            }
        }
    }

    /// Two slots, not three. The prompts live *inside* the command bar because they
    /// are part of asking, and because a third slot is what let them become a column
    /// of five chips stranded above 600pt of bare plate. A cloud cannot stretch.
    private var slots: [LivingSlot] {
        [
            LivingSlot(id: Slot.command, rank: 0, floor: 132, ideal: 148, spans: true),
            LivingSlot(
                id: Slot.context,
                rank: 1,
                floor: 45 + Self.rowUnit * 3,
                ideal: 45 + Self.rowUnit * 7,
                stretch: 1,
                rows: LivingSlot.RowAppetite(
                    available: digest.rows.count,
                    baseline: min(3, digest.rows.count),
                    unit: Self.rowUnit,
                    ceiling: 16
                )
            )
        ]
    }

    /// The field, first and largest, with the prompt cloud tucked under it.
    private var commandBar: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "sparkle.magnifyingglass")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.whimsy)

                TextField("Ask about your agents, spend, or inbox", text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 19, weight: .regular, design: .rounded))
                    .foregroundStyle(ink.primary)
                    .focused($isFieldFocused)
                    .onSubmit(submit)
                    .accessibilityIdentifier(OBBAccessibilityID.homeAskField)

                Button(action: submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 21))
                        .foregroundStyle(query.isEmpty ? ink.subtle : DesignSystem.Colors.whimsy)
                }
                .buttonStyle(.plain)
                .disabled(query.isEmpty)
                .help("Ask")
            }

            HomeChipCloud(prompts: prompts, ink: ink) { prompt in
                query = prompt
                submit()
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .burnBarGlass(.ask, role: .chrome, tint: DesignSystem.Colors.whimsy)
        .overlay {
            // Focus is drawn as light gathering on the rim rather than a system ring,
            // so the bar stays a piece of glass instead of becoming a form control.
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .strokeBorder(DesignSystem.Colors.whimsy.opacity(isFieldFocused ? 0.55 : 0), lineWidth: 1.5)
        }
        .animation(MotionTokens.tick(reduceMotion: reduceMotion), value: isFieldFocused)
        .contentShape(Rectangle())
        .onTapGesture { isFieldFocused = true }
    }

    private var prompts: [String] {
        var result = ["What did I spend today, and on what?"]
        if let lead = digest.lead {
            result.append("Explain \"\(HomeShellCopy.clipped(lead.summary.title))\"")
        }
        for entry in digest.kindRanking.prefix(2) {
            result.append("Why do I keep getting \(InboxPresentation.kindLabel(entry.kind).lowercased()) items?")
        }
        if digest.attentionCount > 0 {
            result.append("What should I fix first?")
        }
        return result
    }

    /// What the question can be asked *about*. The only slot that stretches, because
    /// it is the only one with rows to spend the height on.
    private func context(rows limit: Int) -> some View {
        let rows = Array(digest.rows.prefix(limit))
        return VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("CONTEXT")
                .font(DesignSystem.Typography.tiny)
                .tracking(1.4)
                .foregroundStyle(DesignSystem.Colors.blaze)

            if rows.isEmpty {
                Text("Nothing in the inbox to reason about yet.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(ink.subtle)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                        if index > 0 { DashboardSectionRule() }
                        HomeCompactInboxRow(row: row, ink: ink, onOpen: onOpenItem)
                    }
                }
                if digest.total > rows.count {
                    Text("\(digest.total - rows.count) more in the inbox")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(ink.subtle)
                        .padding(.top, DesignSystem.Spacing.xxs)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .burnBarGlass(.ask, role: .content, tint: DesignSystem.Colors.blaze)
    }

    private func submit() {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else { return }
        onAsk(trimmed)
        query = ""
    }
}

// MARK: - Shared parts

/// The one compact inbox line the Cockpit, Focus, and Ask shells share.
struct HomeCompactInboxRow: View {
    let row: ControlPlaneStore.AIInboxRow
    let ink: BackdropInk
    let onOpen: (String) -> Void

    var body: some View {
        Button { onOpen(row.id) } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: InboxPresentation.icon(for: row.summary.kind))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(InboxPresentation.tint(for: row.summary.kind))
                    .frame(width: 14)
                Text(row.summary.title)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(row.isUnread ? ink.primary : ink.secondary)
                    .lineLimit(1)
                Spacer(minLength: DesignSystem.Spacing.sm)
                if let project = row.summary.projectName, project.isEmpty == false {
                    Text(project)
                        .font(DesignSystem.Typography.monoTiny)
                        .foregroundStyle(ink.subtle)
                        .lineLimit(1)
                }
                if row.isUnread {
                    Circle()
                        .fill(InboxPresentation.tint(for: row.summary.kind))
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(OBBAccessibilityID.inboxRow(row.id))
    }
}

/// Sentences and formats the shells share, so "seen 6× since Tuesday" is worded
/// the same whether Focus or Canvas says it.
@MainActor
enum HomeShellCopy {
    static func percent(_ fraction: Double) -> String {
        "\(Int((max(0, min(1, fraction)) * 100).rounded()))%"
    }

    static func clipped(_ text: String, limit: Int = 48) -> String {
        text.count <= limit ? text : String(text.prefix(limit - 1)) + "…"
    }

    static func time(_ date: Date) -> String {
        timeFormatter.string(from: date)
    }

    static func dayLabel(_ date: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(date) { return "TODAY" }
        if calendar.isDateInYesterday(date) { return "YESTERDAY" }
        return dayFormatter.string(from: date).uppercased()
    }

    static func sentence(for row: ControlPlaneStore.AIInboxRow) -> String {
        var parts: [String] = [InboxPresentation.priorityLabel(row.summary.priority)]
        if let project = row.summary.projectName, project.isEmpty == false {
            parts.append("in \(project)")
        }
        if row.summary.occurrenceCount > 1 {
            parts.append("seen \(row.summary.occurrenceCount)×")
        }
        parts.append("last \(Self.relative.localizedString(for: row.summary.lastSeenAt, relativeTo: Date()))")
        return parts.joined(separator: " · ")
    }

    private static let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE, MMM d"
        return formatter
    }()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
    }()
}
