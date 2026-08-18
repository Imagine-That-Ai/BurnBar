import SwiftUI
import UIKit
import OpenBurnBarHermes
import OpenBurnBarKernel

// MARK: - AI Inbox detail
//
// The reading surface for one mirrored item. Section order follows the shape of
// the claim itself: what happened, why we believe it, what you can do, and only
// then provenance — so the user can disbelieve an item before acting on it.
//
// ## What this surface deliberately cannot do
//
// The inbox is produced by the Mac daemon against the Mac's local index. Three
// of the six action kinds (`resumeConversation`, `openSessionLog`,
// `openProject`) and the `openburnbar://sessions/…` evidence links all address
// things that only exist on that Mac: a local conversation row keyed by an id
// the phone has no lookup for, a filesystem path, a Mac settings anchor.
//
// Rather than render buttons that quietly do nothing, those become reference
// chips that copy their value and say plainly where they open. `https` links —
// pull requests, issues, workflow runs — are real and open here.

/// The pushed detail screen.
///
/// Wraps `AIInboxDetailView` so the compact stack owns the two behaviors a
/// detail column does not need: resolving the item from the live store on every
/// redraw (so an action taken here redraws the screen the user is on), and
/// popping when the item is dismissed.
struct AIInboxDetailScreen: View {
    @Bindable var store: AIInboxStore
    let itemID: String

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if let item = store.items.first(where: { $0.id == itemID }) {
                AIInboxDetailView(
                    item: item,
                    // Archive and snooze are "I am done with this" gestures, so
                    // they pop back to the list. Leaving the user on the detail
                    // of an item they just dismissed reads as an inert tap.
                    onArchive: {
                        Task {
                            await store.archive(itemID)
                            dismiss()
                        }
                    },
                    onSnooze: { interval in
                        Task {
                            await store.snooze(itemID, for: interval)
                            dismiss()
                        }
                    },
                    onFeedback: { useful in Task { await store.setFeedback(itemID, useful: useful) } }
                )
            } else {
                // The Mac resolved or expired the item while it was open. Say so
                // rather than leaving a blank screen behind a back button.
                AuroraStatePane(
                    kind: .empty,
                    icon: "checkmark.seal",
                    title: "This item is gone",
                    message: "Your Mac closed it while you were reading. Go back for the current list."
                )
                .padding(.horizontal, AuroraDesign.Layout.cardInset)
            }
        }
        .background(AuroraBackdrop(density: .subtle).ignoresSafeArea())
        .navigationTitle("Inbox item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }
}

struct AIInboxDetailView: View {
    let item: AIInboxStore.Item
    let onArchive: () -> Void
    let onSnooze: (TimeInterval) -> Void
    let onFeedback: (Bool?) -> Void

    @Environment(\.openURL) private var openURL
    @State private var copiedReferenceID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.xl) {
                headerSection
                if item.record.summaryMarkdown.isEmpty == false { bodySection }
                if item.record.payload.metrics.isEmpty == false { metricsSection }
                if item.record.payload.evidence.isEmpty == false { evidenceSection }
                if item.record.payload.memoryCandidates.isEmpty == false { memorySection }
                if item.record.payload.actions.isEmpty == false { actionsSection }
                footerSection
            }
            .padding(AuroraDesign.Layout.cardInset)
            .padding(.bottom, MobileTheme.Spacing.xxxl)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        // No backdrop here: the host owns it. Both hosts already paint one, and
        // two stacked animated backdrops would drift against each other.
        .accessibilityIdentifier("inbox.detail")
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            HStack(spacing: MobileTheme.Spacing.xs) {
                Image(systemName: AIInboxPresentation.icon(for: item.record.kind))
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(AIInboxPresentation.tint(for: item.record.kind))

                Text(AIInboxPresentation.kindLabel(item.record.kind).uppercased())
                    .font(MobileTheme.Typography.tiny)
                    .tracking(1.1)
                    .foregroundStyle(MobileTheme.Colors.textMuted)

                AIInboxPriorityBadge(priority: item.record.priority)

                if item.record.state == .resolved {
                    Text("RESOLVED")
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                        .tracking(0.6)
                        .foregroundStyle(MobileTheme.success)
                        .padding(.horizontal, MobileTheme.Spacing.sm)
                        .padding(.vertical, 2)
                        .background(Capsule(style: .continuous).fill(MobileTheme.success.opacity(0.16)))
                }

                Spacer(minLength: 0)
            }

            Text(item.record.title)
                .font(MobileTheme.Typography.title)
                .foregroundStyle(MobileTheme.Colors.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: MobileTheme.Spacing.xxs) {
                if let project = item.record.projectName, project.isEmpty == false {
                    Text(project)
                    Text("·")
                }
                Text("first seen \(MissionConsoleFormatting.relativeTime(item.record.firstSeenAt))")
                if item.record.occurrenceCount > 1 {
                    Text("· seen \(item.record.occurrenceCount) times")
                }
            }
            .font(MobileTheme.Typography.caption)
            .foregroundStyle(MobileTheme.Colors.textMuted)

            if let note = item.record.resolutionNote, item.record.state == .resolved {
                HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
                    Image(systemName: "checkmark.seal.fill")
                        .foregroundStyle(MobileTheme.success)
                    Text(note)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(MobileTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: AuroraDesign.Shape.chipCorner, style: .continuous)
                        .fill(MobileTheme.success.opacity(0.10))
                )
            }
        }
    }

    // MARK: - Body

    /// `HermesInlineMarkdown` is the app's own markdown renderer and produces
    /// presentation intents only, so the body inherits the ambient typography
    /// instead of carrying its own. The item body is short prose with no atom
    /// chips in it, so the heavier `HermesRichBubble` layout engine would buy
    /// nothing but a re-measure.
    private var bodySection: some View {
        Text(HermesInlineMarkdown.attributedString(item.record.summaryMarkdown))
            .font(MobileTheme.Typography.body)
            .foregroundStyle(MobileTheme.Colors.textPrimary)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Metrics

    private var metricsSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            AuroraSection("By the numbers", accent: MobileTheme.amber)
            ElderWandFlowLayout(spacing: MobileTheme.Spacing.xs) {
                ForEach(displayMetrics, id: \.key) { metric in
                    HStack(spacing: MobileTheme.Spacing.xs) {
                        Text(metric.label)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                        Text(metric.value)
                            .font(MobileTheme.Typography.monoSmall)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                    }
                    .padding(.horizontal, MobileTheme.Spacing.sm)
                    .padding(.vertical, MobileTheme.Spacing.xs)
                    .background(
                        RoundedRectangle(cornerRadius: AuroraDesign.Shape.chipCorner, style: .continuous)
                            .fill(MobileTheme.Colors.surfaceElevated.opacity(0.6))
                    )
                }
            }
        }
    }

    private var displayMetrics: [(key: String, label: String, value: String)] {
        item.record.payload.metrics
            .sorted { $0.key < $1.key }
            .map { key, value in
                let display = AIInboxPresentation.metricDisplay(key: key, value: value)
                return (key, display.label, display.value)
            }
    }

    // MARK: - Evidence

    private var evidenceSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            AuroraSection("Evidence", accent: MobileTheme.whimsy)
            VStack(spacing: MobileTheme.Spacing.xs) {
                ForEach(item.record.payload.evidence) { evidence in
                    evidenceRow(evidence)
                }
            }
        }
    }

    private func evidenceRow(_ evidence: BurnBarInboxEvidence) -> some View {
        let target = Self.evidenceTarget(evidence.url)
        return Button {
            open(target, referenceID: evidence.id)
        } label: {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
                Image(systemName: AIInboxPresentation.evidenceIcon(for: evidence.kind))
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .frame(width: 18)

                VStack(alignment: .leading, spacing: 2) {
                    Text(evidence.label)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .multilineTextAlignment(.leading)
                        .lineLimit(2)
                    if let detail = evidence.detail {
                        Text(detail)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .lineLimit(1)
                    }
                }

                Spacer(minLength: 0)

                trailingGlyph(for: target, referenceID: evidence.id)
            }
            .padding(MobileTheme.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: AuroraDesign.Shape.chipCorner, style: .continuous)
                    .fill(MobileTheme.Colors.surfaceElevated.opacity(0.45))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(target == .unavailable)
        .accessibilityLabel(accessibilityLabel(for: evidence, target: target))
    }

    @ViewBuilder
    private func trailingGlyph(for target: ReferenceTarget, referenceID: String) -> some View {
        switch target {
        case .web:
            Image(systemName: "arrow.up.forward.square")
                .font(MobileScaledFont.system(size: 11, weight: .semibold))
                .foregroundStyle(MobileTheme.Colors.textMuted)
        case .macReference:
            Image(systemName: copiedReferenceID == referenceID ? "checkmark" : "doc.on.doc")
                .font(MobileScaledFont.system(size: 11, weight: .semibold))
                .foregroundStyle(copiedReferenceID == referenceID ? MobileTheme.success : MobileTheme.Colors.textMuted)
        case .unavailable:
            EmptyView()
        }
    }

    private func accessibilityLabel(for evidence: BurnBarInboxEvidence, target: ReferenceTarget) -> String {
        var parts = [evidence.label]
        if let detail = evidence.detail { parts.append(detail) }
        switch target {
        case .web: parts.append("Opens in your browser")
        case .macReference: parts.append("Lives on your Mac. Double tap to copy the reference.")
        case .unavailable: break
        }
        return parts.joined(separator: ". ")
    }

    // MARK: - Memory candidates

    /// Read-only on purpose.
    ///
    /// Approving a memory routes through the Mac's quarantine → approve
    /// authority, which owns the PII screening, the provenance rows, and the
    /// audit trail. Reproducing an approve button here would either duplicate
    /// that authority or fake it, so the phone shows the proposal and says where
    /// the decision is made.
    private var memorySection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            AuroraSection("Worth remembering", accent: MobileTheme.whimsy)

            Text("Proposals only. Nothing is saved to memory — or used in any prompt — until you approve it on your Mac.")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(item.record.payload.memoryCandidates) { candidate in
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
                    HStack(spacing: MobileTheme.Spacing.xs) {
                        Text(candidate.kind.uppercased())
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.amber)
                            .padding(.horizontal, MobileTheme.Spacing.sm)
                            .padding(.vertical, 2)
                            .background(Capsule(style: .continuous).fill(MobileTheme.amber.opacity(0.14)))

                        Spacer(minLength: 0)

                        Image(systemName: "gauge.with.dots.needle.67percent")
                            .font(MobileScaledFont.system(size: 10))
                        Text("\(Int((candidate.confidence * 100).rounded()))%")
                            .font(MobileTheme.Typography.monoTiny)
                    }
                    .foregroundStyle(MobileTheme.Colors.textMuted)

                    Text(candidate.text)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .padding(MobileTheme.Spacing.md)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: AuroraDesign.Shape.chipCorner, style: .continuous)
                        .fill(MobileTheme.Colors.surfaceElevated.opacity(0.45))
                )
            }
        }
    }

    // MARK: - Actions

    private var actionsSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            AuroraSection("Next", accent: MobileTheme.ember)

            ElderWandFlowLayout(spacing: MobileTheme.Spacing.xs) {
                ForEach(item.record.payload.actions) { action in
                    actionButton(action)
                }
            }

            if item.record.payload.actions.contains(where: { Self.actionTarget($0).isMacReference }) {
                Text("Steps marked with a copy glyph run on the Mac that found this. Tap to copy the reference.")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func actionButton(_ action: BurnBarInboxAction) -> some View {
        let target = Self.actionTarget(action)
        return Button {
            open(target, referenceID: action.id)
        } label: {
            HStack(spacing: MobileTheme.Spacing.xs) {
                Image(systemName: target.isMacReference && copiedReferenceID == action.id
                      ? "checkmark"
                      : AIInboxPresentation.actionIcon(for: action.kind))
                    .font(MobileScaledFont.system(size: 11, weight: .medium))
                Text(action.title)
                    .font(MobileTheme.Typography.caption)
            }
            .foregroundStyle(action.isPrimary ? .white : MobileTheme.Colors.textPrimary)
            .padding(.horizontal, MobileTheme.Spacing.md)
            .padding(.vertical, MobileTheme.Spacing.sm)
            .background(actionBackground(isPrimary: action.isPrimary))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func actionBackground(isPrimary: Bool) -> some View {
        if isPrimary {
            Capsule(style: .continuous).fill(MobileTheme.primaryGradient)
        } else {
            Capsule(style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated.opacity(0.7))
                .overlay(Capsule(style: .continuous).stroke(MobileTheme.Colors.borderSubtle, lineWidth: 1))
        }
    }

    // MARK: - Footer

    /// Provenance is an honesty feature: the user can always see whether an item
    /// came from arithmetic or from a model, and whether it survived a second
    /// opinion. Same sentences as the Mac footer, so a claim never reads
    /// stronger on one device than the other.
    private var footerSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            Divider().background(MobileTheme.Colors.borderSubtle)

            HStack(alignment: .top, spacing: MobileTheme.Spacing.sm) {
                Image(systemName: provenanceIcon)
                    .font(MobileScaledFont.system(size: 11))
                Text(provenanceText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .font(MobileTheme.Typography.tiny)
            .foregroundStyle(MobileTheme.Colors.textMuted)

            HStack(spacing: MobileTheme.Spacing.md) {
                Button {
                    HapticBus.toggle()
                    onFeedback(item.feedback == "useful" ? nil : true)
                } label: {
                    Label("Useful", systemImage: item.feedback == "useful" ? "hand.thumbsup.fill" : "hand.thumbsup")
                        .font(MobileTheme.Typography.tiny)
                }
                .buttonStyle(.plain)
                .foregroundStyle(item.feedback == "useful" ? MobileTheme.success : MobileTheme.Colors.textMuted)
                .accessibilityIdentifier("inbox.detail.feedback.useful")

                Button {
                    HapticBus.toggle()
                    onFeedback(item.feedback == "not_useful" ? nil : false)
                } label: {
                    Label("Not useful", systemImage: item.feedback == "not_useful" ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                        .font(MobileTheme.Typography.tiny)
                }
                .buttonStyle(.plain)
                .foregroundStyle(item.feedback == "not_useful" ? MobileTheme.warning : MobileTheme.Colors.textMuted)
                .accessibilityIdentifier("inbox.detail.feedback.notUseful")

                Spacer(minLength: 0)

                Menu {
                    Button("Snooze for an hour") { onSnooze(3_600) }
                    Button("Snooze until tomorrow") { onSnooze(24 * 3_600) }
                    Button("Snooze for a week") { onSnooze(7 * 24 * 3_600) }
                } label: {
                    Label("Snooze", systemImage: "clock")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                .accessibilityIdentifier("inbox.detail.snooze")

                Button {
                    HapticBus.destructive()
                    onArchive()
                } label: {
                    Label("Archive", systemImage: "archivebox")
                        .font(MobileTheme.Typography.tiny)
                }
                .buttonStyle(.plain)
                .foregroundStyle(MobileTheme.Colors.textMuted)
                .accessibilityIdentifier("inbox.detail.archive")
            }
        }
    }

    private var provenanceIcon: String {
        switch item.record.payload.verification?.verdict {
        case .deterministic: return "function"
        case .confirmed: return "checkmark.shield"
        case .unclear: return "questionmark.diamond"
        case .unverified: return "exclamationmark.shield"
        case .refuted, .none: return "sparkles"
        }
    }

    private var provenanceText: String {
        let source = item.record.modelProvenance == "local-rules"
            ? "Measured directly on your Mac — no model was involved."
            : "Written by \(AIInboxPresentation.friendlyModelNames(item.record.modelProvenance))."

        guard let verification = item.record.payload.verification else { return source }
        switch verification.verdict {
        case .deterministic:
            return source + " " + (verification.reason ?? "")
        case .confirmed:
            return source + " A second model checked this and agreed."
        case .unclear:
            return source + " A second model could not confirm it, so it is ranked lower."
        case .unverified:
            return source + " It was not independently checked."
        case .refuted:
            return source
        }
    }

    // MARK: - Reference resolution

    /// What tapping a link or an action can actually do from a phone.
    ///
    /// Named `unavailable` rather than `none` so it can never be confused with
    /// `Optional.none` at a call site that compares against a non-optional.
    enum ReferenceTarget: Hashable {
        /// An `https` destination the phone can open itself.
        case web(URL)
        /// A Mac-local address (session id, project path, shell command, settings
        /// anchor). Copyable, never pretend-navigable.
        case macReference(String)
        case unavailable

        /// `case macReference` carries a payload, so `== .macReference` does not
        /// compile; this is the "is it copyable" question the UI actually asks.
        var isMacReference: Bool {
            if case .macReference = self { return true }
            return false
        }
    }

    static func evidenceTarget(_ urlString: String?) -> ReferenceTarget {
        guard let urlString, urlString.isEmpty == false else { return .unavailable }
        if let url = URL(string: urlString), url.scheme == "https" || url.scheme == "http" {
            return .web(url)
        }
        // `openburnbar://sessions/<id>` addresses a row in the Mac's local
        // conversation index. The cloud mirror is keyed by a different document
        // id, so the phone genuinely cannot resolve it — copy the id instead of
        // opening the wrong session.
        let sessionPrefix = "openburnbar://sessions/"
        if urlString.hasPrefix(sessionPrefix) {
            let id = String(urlString.dropFirst(sessionPrefix.count))
            return id.isEmpty ? .unavailable : .macReference(id)
        }
        return .macReference(urlString)
    }

    static func actionTarget(_ action: BurnBarInboxAction) -> ReferenceTarget {
        switch action.kind {
        case .openURL:
            guard let url = URL(string: action.value), url.scheme == "https" || url.scheme == "http" else {
                return .unavailable
            }
            return .web(url)
        case .resumeConversation, .openSessionLog, .openProject, .openSettings, .runCommand:
            return action.value.isEmpty ? .unavailable : .macReference(action.value)
        }
    }

    private func open(_ target: ReferenceTarget, referenceID: String) {
        switch target {
        case .web(let url):
            HapticBus.primaryAction()
            openURL(url)
        case .macReference(let value):
            // Never auto-executed, exactly as on the Mac: a shell command lands
            // on the pasteboard for the user to run deliberately.
            UIPasteboard.general.string = value
            HapticBus.toggle()
            copiedReferenceID = referenceID
        case .unavailable:
            break
        }
    }
}
