import SwiftUI
import OpenBurnBarKernel

/// The reading surface for one inbox item.
///
/// Layout follows the shape of the claim itself: **what happened** (title +
/// brief), **why we believe it** (numbers, then evidence), and **what you can
/// do** — with provenance and disposition anchored to the bottom of the pane.
/// Evidence sits above actions on purpose: the user should be able to disbelieve
/// an item before acting on it.
///
/// The pane is a two-column reading surface at desk widths — claim and evidence
/// on the left, "what now" rail on the right — and collapses to one column when
/// the window narrows. The whole column fills its container rather than hugging
/// a fixed measure, while prose alone keeps a readable line length, and the
/// disposition bar anchors to the bottom so a short item reads as designed
/// rather than truncated.
struct InboxItemDetailView: View {
    @Environment(\.backdropInk) private var ink
    let row: ControlPlaneStore.AIInboxRow
    let onOpenSessionLog: (String) -> Void
    let onArchive: () -> Void
    let onSnooze: (TimeInterval) -> Void
    let onFeedback: (Bool?) -> Void
    var onOpenSettings: (() -> Void)?

    /// Memory approval is optional so the detail view renders in previews and
    /// tests without a memory store wired up.
    var memoryApproval: InboxMemoryApprovalHandler?

    /// Founder Lens dialogue, keyed by condition fingerprint. Optional for the
    /// same preview/test reason; when nil, the item stays a one-shot brief
    /// exactly as before.
    var threadFingerprint: String?

    /// Optional because the detached detail window renders this view without a
    /// dashboard router. Where it is nil, Charts drill-throughs downgrade to an
    /// explained inert row rather than a button that silently does nothing.
    @Environment(NavigationCoordinator.self) private var navigationCoordinator: NavigationCoordinator?

    // MARK: Layout constants

    /// Below this the rail would squeeze both columns; the pane stacks instead.
    private static let railBreakpoint: CGFloat = 880
    private static let railWidth: CGFloat = 320
    /// Prose gets a readable measure even when the pane is enormous. Everything
    /// structural (stats, evidence, composer) fills the column.
    private static let proseMeasure: CGFloat = 860
    /// A ceiling only ultra-wide displays ever reach.
    private static let columnCeiling: CGFloat = 1_560

    var body: some View {
        GeometryReader { proxy in
            let inset = DesignSystem.Spacing.xl
            let available = max(0, proxy.size.width - inset * 2)
            let showsRail = available >= Self.railBreakpoint
            let columnWidth = min(available, Self.columnCeiling)

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    if showsRail {
                        HStack(alignment: .top, spacing: DesignSystem.Spacing.xl) {
                            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                                claimStack
                                conversationStack
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)

                            railColumn
                                .frame(width: Self.railWidth, alignment: .leading)
                        }
                    } else {
                        // Stacked, the rail's actions belong between the case and
                        // the conversation — "what now" never reads as an
                        // afterthought below the composer.
                        claimStack
                        railColumn
                        conversationStack
                    }

                    // Absorbs the slack on a short item so the disposition bar
                    // lands on the bottom edge instead of leaving a raw void.
                    Spacer(minLength: DesignSystem.Spacing.xl)

                    footerSection
                }
                .padding(inset)
                .frame(minHeight: proxy.size.height, alignment: .top)
                .frame(width: columnWidth + inset * 2, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .accessibilityIdentifier(OBBAccessibilityID.inboxDetail)
    }

    // MARK: - Columns

    /// The claim and the case for it.
    @ViewBuilder
    private var claimStack: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
            headerSection
            if row.summaryMarkdown.isEmpty == false { bodySection }
            if metrics.isEmpty == false {
                InboxMetricsSection(metrics: metrics, navigator: navigator)
            }
            if row.payload.evidence.isEmpty == false { evidenceSection }
            if row.payload.memoryCandidates.isEmpty == false { memorySection }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The dialogue and the accepted-plan ledger.
    @ViewBuilder
    private var conversationStack: some View {
        if let threadFingerprint {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                InboxThreadHost(fingerprint: threadFingerprint)
                // The accepted ledger with its action controls (promote /
                // follow-up / remember / grade) — renders only when a plan
                // exists. Mission and follow-up creation need a project;
                // items without attribution get the rest of the loop.
                InboxPlansPanel(
                    projectSlug: row.summary.projectID,
                    memoryApproval: memoryApproval
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// What to do about it, and where it came from.
    ///
    /// Always carries the "this item" card, so the rail is never an empty
    /// gutter on an item that happens to suggest no action.
    @ViewBuilder
    private var railColumn: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
            if row.payload.actions.isEmpty == false {
                InboxActionsSection(
                    actions: row.payload.actions,
                    settingsAvailable: onOpenSettings != nil,
                    onOpenSessionLog: onOpenSessionLog,
                    onOpenSettings: onOpenSettings,
                    navigator: navigator
                )
            }
            factsCard
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Navigation

    private var navigator: InboxDrillNavigator {
        InboxDrillNavigator(
            openSessionLog: onOpenSessionLog,
            openWeb: { raw in
                guard let url = URL(string: raw), url.scheme == "https" || url.scheme == "http" else { return }
                NSWorkspace.shared.open(url)
            },
            reveal: { path in
                let expanded = (path as NSString).expandingTildeInPath
                guard expanded.isEmpty == false else { return }
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expanded)])
            },
            openCharts: { navigationCoordinator?.setDashboardRoute(.charts) },
            chartsAvailable: navigationCoordinator != nil
        )
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: InboxPresentation.icon(for: row.summary.kind))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(InboxPresentation.tint(for: row.summary.kind))

                Text(InboxPresentation.kindLabel(row.summary.kind).uppercased())
                    .font(DesignSystem.Typography.tiny)
                    .tracking(1.1)
                    .foregroundStyle(ink.subtle)
                    // Inert by design — a label, not a control — but a label that
                    // answers for itself when you ask.
                    .help(InboxPresentation.kindExplanation(row.summary.kind))
                    .accessibilityLabel("Kind: \(InboxPresentation.kindLabel(row.summary.kind))")
                    .accessibilityHint(InboxPresentation.kindExplanation(row.summary.kind))

                OpenBurnBarStatusBadge(
                    title: InboxPresentation.priorityLabel(row.summary.priority),
                    color: InboxPresentation.priorityColor(row.summary.priority)
                )
                .help(InboxPresentation.priorityExplanation(row.summary.priority))
                .accessibilityLabel("Priority: \(InboxPresentation.priorityLabel(row.summary.priority))")
                .accessibilityHint(InboxPresentation.priorityExplanation(row.summary.priority))

                if row.summary.state == .resolved {
                    OpenBurnBarStatusBadge(title: "Resolved", color: DesignSystem.Colors.success)
                        .help("This condition cleared. The item is kept for the record.")
                }

                Spacer(minLength: 0)
            }

            Text(row.summary.title)
                .font(DesignSystem.Typography.display)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.xs) {
                if let project = row.summary.projectName, project.isEmpty == false {
                    Text(project)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(ink.subtle)
                    Text("·")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(ink.subtle)
                }
                Text("first seen \(InboxView.relativeFormatter.localizedString(for: row.summary.firstSeenAt, relativeTo: Date()))")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(ink.subtle)
                    .help(InboxOccurrenceInspector.absoluteFormatter.string(from: row.summary.firstSeenAt))

                if row.summary.occurrenceCount > 1 {
                    Text("·")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(ink.subtle)
                    InboxOccurrenceControl(summary: occurrence)
                }
                Spacer(minLength: 0)
            }

            if let note = row.summary.resolutionNote, row.summary.state == .resolved {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(DesignSystem.Colors.success)
                    Text(note)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .padding(DesignSystem.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                        .fill(DesignSystem.Colors.success.opacity(0.10))
                )
            }
        }
    }

    private var occurrence: InboxOccurrenceSummary {
        InboxOccurrenceInspector.summarize(summary: row.summary)
    }

    // MARK: - Body

    private var bodySection: some View {
        Text(attributedBody)
            .font(DesignSystem.Typography.body)
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .lineSpacing(3)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: Self.proseMeasure, alignment: .leading)
    }

    /// Renders the markdown body. Falls back to plain text if the model produced
    /// something `AttributedString` cannot parse, so a formatting quirk never
    /// blanks the item.
    private var attributedBody: AttributedString {
        (try? AttributedString(
            markdown: row.summaryMarkdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(row.summaryMarkdown)
    }

    // MARK: - Metrics

    /// Humanized, formatted, and pre-resolved to their drill-through sources.
    private var metrics: [InboxMetric] {
        InboxMetricInspector.metrics(payload: row.payload, summary: row.summary)
    }

    // MARK: - Evidence

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            InboxSectionLabel(
                text: "EVIDENCE",
                hint: "hover to see where each one goes"
            )
            VStack(spacing: DesignSystem.Spacing.xs) {
                ForEach(row.payload.evidence) { evidence in
                    InboxEvidenceRowView(evidence: evidence, navigator: navigator)
                }
            }
        }
    }

    // MARK: - Memory candidates

    /// Proposed memories, always behind explicit approval.
    ///
    /// Approving here routes through the same quarantine → approve authority the
    /// Memory review surface uses, so an inbox-proposed fact gets identical PII
    /// screening, provenance, and audit treatment. Nothing is ever auto-applied.
    private var memorySection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            InboxSectionLabel(text: "WORTH REMEMBERING")

            Text("These are proposals. Nothing is saved to memory — or used in any prompt — until you approve it.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(ink.subtle)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(row.payload.memoryCandidates) { candidate in
                InboxMemoryCandidateCard(
                    candidate: candidate,
                    itemFingerprint: row.summary.fingerprint,
                    handler: memoryApproval
                )
            }
        }
    }

    // MARK: - Facts card

    /// The rail's constant: what this item is, when it started, and who wrote
    /// it. Everything here is metadata the header cannot carry without becoming
    /// a wall of dim text.
    private var factsCard: some View {
        InboxGlassPanel(accent: InboxPresentation.tint(for: row.summary.kind)) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                InboxSectionLabel(text: "THIS ITEM")

                factLine("Kind", InboxPresentation.kindLabel(row.summary.kind))
                factLine("Priority", InboxPresentation.priorityLabel(row.summary.priority))
                factLine("State", stateLabel)
                if let project = row.summary.projectName, project.isEmpty == false {
                    factLine("Project", project)
                }
                factLine("First seen", InboxOccurrenceInspector.absoluteFormatter.string(from: occurrence.firstSeen))
                factLine("Last seen", InboxOccurrenceInspector.absoluteFormatter.string(from: occurrence.lastSeen))
                factLine("Occurrences", InboxMetricInspector.groupedCount(Double(row.summary.occurrenceCount)))
                if let cadence = occurrence.cadence {
                    factLine("Cadence", cadence)
                }
            }
        }
    }

    private var stateLabel: String {
        switch row.summary.state {
        case .new: return "New"
        case .updated: return "Updated"
        case .resolved: return "Resolved"
        case .expired: return "Expired"
        }
    }

    private func factLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.sm) {
            Text(label.uppercased())
                .font(DesignSystem.Typography.tiny)
                .tracking(0.8)
                .foregroundStyle(ink.subtle)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label): \(value)")
    }

    // MARK: - Footer

    /// Provenance and disposition, anchored to the bottom of the pane.
    ///
    /// The provenance line is a deliberate honesty feature: the user can always
    /// see whether an item came from arithmetic or from a model, and whether it
    /// survived an adversarial check.
    private var footerSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Divider().background(DesignSystem.Colors.borderSubtle)

            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: provenanceIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(ink.subtle)
                    .padding(.top, 2)
                Text(provenanceText)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(ink.subtle)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Provenance. \(provenanceText)")

            HStack(spacing: DesignSystem.Spacing.md) {
                dispositionButton(
                    title: "Useful",
                    symbol: row.feedback == "useful" ? "hand.thumbsup.fill" : "hand.thumbsup",
                    tint: row.feedback == "useful" ? DesignSystem.Colors.success : ink.subtle,
                    help: "Teach the inbox that items like this are worth surfacing",
                    action: { onFeedback(row.feedback == "useful" ? nil : true) }
                )

                dispositionButton(
                    title: "Not useful",
                    symbol: row.feedback == "not_useful" ? "hand.thumbsdown.fill" : "hand.thumbsdown",
                    tint: row.feedback == "not_useful" ? DesignSystem.Colors.warning : ink.subtle,
                    help: "Teach the inbox to rank items like this lower",
                    action: { onFeedback(row.feedback == "not_useful" ? nil : false) }
                )

                Spacer(minLength: 0)

                Menu {
                    Button("Snooze for an hour") { onSnooze(3_600) }
                    Button("Snooze until tomorrow") { onSnooze(24 * 3_600) }
                    Button("Snooze for a week") { onSnooze(7 * 24 * 3_600) }
                } label: {
                    Label("Snooze", systemImage: "clock")
                        .font(DesignSystem.Typography.tiny)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Hide this item until later. It comes back — nothing is deleted.")

                dispositionButton(
                    title: "Archive",
                    symbol: "archivebox",
                    tint: ink.subtle,
                    help: "Move this item out of the active list. Archived items stay readable under the Archived filter — nothing is deleted.",
                    action: onArchive
                )
            }
        }
    }

    private func dispositionButton(
        title: String,
        symbol: String,
        tint: Color,
        help: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(tint)
                .padding(.horizontal, DesignSystem.Spacing.sm)
                .padding(.vertical, DesignSystem.Spacing.xxs)
                .contentShape(Rectangle())
        }
        .buttonStyle(InboxPressStyle())
        .help(help)
        .accessibilityLabel(title)
        .accessibilityHint(help)
    }

    private var provenanceIcon: String {
        switch row.payload.verification?.verdict {
        case .deterministic: return "function"
        case .confirmed: return "checkmark.shield"
        case .unclear: return "questionmark.diamond"
        case .unverified: return "exclamationmark.shield"
        case .refuted, .none: return "sparkles"
        }
    }

    /// Plain-language provenance. No jargon: "measured directly" beats
    /// "deterministic detector".
    private var provenanceText: String {
        let source = row.summary.modelProvenance == "local-rules"
            ? "Measured directly on this Mac — no model was involved."
            : "Written by \(Self.friendlyModelNames(row.summary.modelProvenance))."

        let calibrationNote = row.payload.metrics["calibration_note"].map { " " + $0 } ?? ""
        guard let verification = row.payload.verification else { return source + calibrationNote }
        switch verification.verdict {
        case .deterministic:
            return source + " " + (verification.reason ?? "") + calibrationNote
        case .confirmed:
            return source + " A second model checked this and agreed." + calibrationNote
        case .unclear:
            return source + " A second model could not confirm it, so it is ranked lower." + calibrationNote
        case .unverified:
            return source + " It was not independently checked." + calibrationNote
        case .refuted:
            return source + calibrationNote
        }
    }

    static func friendlyModelNames(_ provenance: String) -> String {
        provenance
            .split(separator: "+")
            .map { component -> String in
                let parts = component.split(separator: ":", maxSplits: 1)
                return parts.count == 2 ? String(parts[1]) : String(component)
            }
            .joined(separator: " and ")
    }
}

// MARK: - Memory candidate card

/// Approves or dismisses one proposed memory.
struct InboxMemoryCandidateCard: View {
    @Environment(\.backdropInk) private var ink
    let candidate: BurnBarInboxMemoryCandidate
    let itemFingerprint: String
    let handler: InboxMemoryApprovalHandler?

    @State private var state: ApprovalState = .pending
    @State private var errorMessage: String?

    enum ApprovalState: Equatable {
        case pending
        case working
        case approved
        case dismissed
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Text(candidate.kind.uppercased())
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.amber)
                        .padding(.horizontal, DesignSystem.Spacing.sm)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(DesignSystem.Colors.amber.opacity(0.14)))

                    Spacer(minLength: 0)

                    Image(systemName: "gauge.with.dots.needle.67percent")
                        .font(.system(size: 9))
                    Text("\(Int((candidate.confidence * 100).rounded()))%")
                        .font(DesignSystem.Typography.monoTiny)
                }
                .foregroundStyle(ink.subtle)
                .help("How confident the analyst is that this fact is durable")

                Text(candidate.text)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                if let errorMessage {
                    Text(errorMessage)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.warning)
                }

                controls
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var controls: some View {
        switch state {
        case .pending:
            HStack(spacing: DesignSystem.Spacing.sm) {
                Button { approve() } label: {
                    Text("Remember this")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(.white)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.xs)
                        .background(Capsule().fill(DesignSystem.Colors.primaryGradient))
                }
                .buttonStyle(InboxPressStyle())
                .disabled(handler == nil)
                .help("Save this fact to memory, after the same PII screening the Memory review surface applies")

                Button { state = .dismissed } label: {
                    Text("Dismiss")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(ink.subtle)
                }
                .buttonStyle(InboxPressStyle())
                .help("Drop this proposal. Nothing is written.")

                Spacer(minLength: 0)

                if handler == nil {
                    Text("Memory is unavailable")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(ink.subtle)
                }
            }
        case .working:
            ProgressView().controlSize(.small)
        case .approved:
            Label("Saved to memory", systemImage: "checkmark.seal.fill")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.success)
        case .dismissed:
            Label("Dismissed", systemImage: "xmark.circle")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(ink.subtle)
        }
    }

    private func approve() {
        guard let handler else { return }
        state = .working
        errorMessage = nil
        Task {
            do {
                try await handler.approve(candidate: candidate, itemFingerprint: itemFingerprint)
                state = .approved
            } catch {
                state = .pending
                errorMessage = error.localizedDescription
            }
        }
    }
}
