import SwiftUI
import OpenBurnBarCore

/// The reading surface for one inbox item.
///
/// Layout follows the shape of the claim itself: **what happened** (title +
/// brief), **why we believe it** (evidence), **what you can do** (actions), and
/// only then the provenance footer. Evidence sits above actions on purpose — the
/// user should be able to disbelieve an item before acting on it.
struct InboxItemDetailView: View {
    let row: ControlPlaneStore.AIInboxRow
    let onOpenSessionLog: (String) -> Void
    let onArchive: () -> Void
    let onSnooze: (TimeInterval) -> Void
    let onFeedback: (Bool?) -> Void
    var onOpenSettings: (() -> Void)?

    /// Memory approval is optional so the detail view renders in previews and
    /// tests without a memory store wired up.
    var memoryApproval: InboxMemoryApprovalHandler?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                headerSection
                if row.summaryMarkdown.isEmpty == false { bodySection }
                if row.payload.metrics.isEmpty == false { metricsSection }
                if row.payload.evidence.isEmpty == false { evidenceSection }
                if row.payload.memoryCandidates.isEmpty == false { memorySection }
                if row.payload.actions.isEmpty == false { actionsSection }
                footerSection
            }
            .padding(DesignSystem.Spacing.xl)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier(OBBAccessibilityID.inboxDetail)
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
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                OpenBurnBarStatusBadge(
                    title: InboxPresentation.priorityLabel(row.summary.priority),
                    color: InboxPresentation.priorityColor(row.summary.priority)
                )

                if row.summary.state == .resolved {
                    OpenBurnBarStatusBadge(title: "Resolved", color: DesignSystem.Colors.success)
                }

                Spacer(minLength: 0)
            }

            Text(row.summary.title)
                .font(DesignSystem.Typography.display)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: DesignSystem.Spacing.xs) {
                if let project = row.summary.projectName, project.isEmpty == false {
                    Text(project)
                    Text("·")
                }
                Text("first seen \(InboxView.relativeFormatter.localizedString(for: row.summary.firstSeenAt, relativeTo: Date()))")
                if row.summary.occurrenceCount > 1 {
                    Text("· seen \(row.summary.occurrenceCount) times")
                }
            }
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textMuted)

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

    // MARK: - Body

    private var bodySection: some View {
        Text(attributedBody)
            .font(DesignSystem.Typography.body)
            .foregroundStyle(DesignSystem.Colors.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
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

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            sectionLabel("BY THE NUMBERS")
            ElderWandFlowLayout(horizontalSpacing: DesignSystem.Spacing.sm, verticalSpacing: DesignSystem.Spacing.sm) {
                ForEach(displayMetrics, id: \.key) { metric in
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Text(metric.label)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Text(metric.value)
                            .font(DesignSystem.Typography.monoSmall)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                    }
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.6))
                    )
                }
            }
        }
    }

    /// Humanizes raw metric keys (`waste_rate` → "Waste rate", `0.950` → "95%").
    private var displayMetrics: [(key: String, label: String, value: String)] {
        row.payload.metrics
            // `calibration_note` is prose, not a number — it renders in the
            // footer instead of as a stat chip.
            .filter { $0.key != "calibration_note" }
            .sorted { $0.key < $1.key }
            .map { key, value in
                let label = key
                    .replacingOccurrences(of: "_", with: " ")
                    .prefix(1).uppercased() + key.replacingOccurrences(of: "_", with: " ").dropFirst()
                var display = value
                if key.hasSuffix("_rate"), let number = Double(value) {
                    display = "\(Int((number * 100).rounded()))%"
                } else if key.hasSuffix("_usd"), let number = Double(value) {
                    display = String(format: "$%.3f", number)
                } else if key.hasSuffix("_minutes"), let number = Double(value) {
                    display = "\(Int(number.rounded()))m"
                }
                return (key, String(label), display)
            }
    }

    // MARK: - Evidence

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            sectionLabel("EVIDENCE")
            VStack(spacing: DesignSystem.Spacing.xs) {
                ForEach(row.payload.evidence) { evidence in
                    evidenceRow(evidence)
                }
            }
        }
    }

    private func evidenceRow(_ evidence: BurnBarInboxEvidence) -> some View {
        Button {
            open(evidence)
        } label: {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: InboxPresentation.evidenceIcon(for: evidence.kind))
                    .font(.system(size: 11))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(evidence.label)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .lineLimit(1)
                    if let detail = evidence.detail {
                        Text(detail)
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                if evidence.url != nil {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(DesignSystem.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                    .fill(DesignSystem.Colors.surfaceElevated.opacity(0.45))
            )
        }
        .buttonStyle(.plain)
        .disabled(evidence.url == nil)
        .accessibilityLabel("\(evidence.label). \(evidence.detail ?? "")")
    }

    // MARK: - Memory candidates

    /// Proposed memories, always behind explicit approval.
    ///
    /// Approving here routes through the same quarantine → approve authority the
    /// Memory review surface uses, so an inbox-proposed fact gets identical PII
    /// screening, provenance, and audit treatment. Nothing is ever auto-applied.
    private var memorySection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            sectionLabel("WORTH REMEMBERING")

            Text("These are proposals. Nothing is saved to memory — or used in any prompt — until you approve it.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
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

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            sectionLabel("NEXT")
            ElderWandFlowLayout(horizontalSpacing: DesignSystem.Spacing.sm, verticalSpacing: DesignSystem.Spacing.sm) {
                ForEach(row.payload.actions) { action in
                    Button {
                        perform(action)
                    } label: {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Image(systemName: InboxPresentation.actionIcon(for: action.kind))
                                .font(.system(size: 11, weight: .medium))
                            Text(action.title)
                                .font(DesignSystem.Typography.caption)
                        }
                        .foregroundStyle(action.isPrimary ? .white : DesignSystem.Colors.textPrimary)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .background(actionBackground(isPrimary: action.isPrimary))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func actionBackground(isPrimary: Bool) -> some View {
        if isPrimary {
            Capsule().fill(DesignSystem.Colors.primaryGradient)
        } else {
            Capsule()
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.7))
                .overlay(Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1))
        }
    }

    // MARK: - Footer

    /// Provenance and disposition.
    ///
    /// The provenance line is a deliberate honesty feature: the user can always
    /// see whether an item came from arithmetic or from a model, and whether it
    /// survived an adversarial check.
    private var footerSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            Divider().background(DesignSystem.Colors.borderSubtle)

            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: provenanceIcon)
                    .font(.system(size: 10))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(provenanceText)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                Button { onFeedback(row.feedback == "useful" ? nil : true) } label: {
                    Label("Useful", systemImage: row.feedback == "useful" ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(DesignSystem.Typography.tiny)
                }
                .buttonStyle(.plain)
                .foregroundStyle(row.feedback == "useful" ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted)

                Button { onFeedback(row.feedback == "not_useful" ? nil : false) } label: {
                    Label("Not useful", systemImage: row.feedback == "not_useful" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(DesignSystem.Typography.tiny)
                }
                .buttonStyle(.plain)
                .foregroundStyle(row.feedback == "not_useful" ? DesignSystem.Colors.warning : DesignSystem.Colors.textMuted)

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

                Button(action: onArchive) {
                    Label("Archive", systemImage: "archivebox")
                        .font(DesignSystem.Typography.tiny)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
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

    // MARK: - Helpers

    private func sectionLabel(_ text: String) -> some View {
        Text(text)
            .font(DesignSystem.Typography.tiny)
            .tracking(1.2)
            .foregroundStyle(DesignSystem.Colors.textMuted)
    }

    private func open(_ evidence: BurnBarInboxEvidence) {
        guard let urlString = evidence.url else { return }
        if urlString.hasPrefix("openburnbar://sessions/") {
            onOpenSessionLog(String(urlString.dropFirst("openburnbar://sessions/".count)))
            return
        }
        guard let url = URL(string: urlString), url.scheme == "https" || url.scheme == "http" else { return }
        NSWorkspace.shared.open(url)
    }

    private func perform(_ action: BurnBarInboxAction) {
        switch action.kind {
        case .openURL:
            guard let url = URL(string: action.value), url.scheme == "https" || url.scheme == "http" else { return }
            NSWorkspace.shared.open(url)
        case .resumeConversation, .openSessionLog:
            onOpenSessionLog(action.value)
        case .openProject:
            NSWorkspace.shared.open(URL(fileURLWithPath: action.value))
        case .openSettings:
            onOpenSettings?()
        case .runCommand:
            // Never executed automatically — copied for the user to run.
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(action.value, forType: .string)
        }
    }
}

// MARK: - Memory candidate card

/// Approves or dismisses one proposed memory.
struct InboxMemoryCandidateCard: View {
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
                .foregroundStyle(DesignSystem.Colors.textMuted)

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
                .buttonStyle(.plain)
                .disabled(handler == nil)

                Button { state = .dismissed } label: {
                    Text("Dismiss")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)

                Spacer(minLength: 0)

                if handler == nil {
                    Text("Memory is unavailable")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
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
                .foregroundStyle(DesignSystem.Colors.textMuted)
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
