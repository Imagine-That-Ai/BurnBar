import SwiftUI
import OpenBurnBarKernel

/// The dialogue surface for one inbox item: the thread so far, the composer,
/// and — when the assistant proposed a plan step — the accept affordance.
///
/// State discipline mirrors the rest of the inbox: the daemon owns the thread
/// (fingerprint-keyed, so it survives item resolve/reopen churn); this view
/// only renders what the RPC returns and never fabricates local state. A
/// refusal (budget, egress, lens off) renders as an explanation, because the
/// refusal IS the answer.
@MainActor
final class InboxThreadModel: ObservableObject {
    @Published private(set) var thread: BurnBarInboxThread?
    @Published private(set) var isSending = false
    @Published private(set) var refusalReason: String?
    @Published private(set) var acceptedStepIDs: Set<String> = []
    @Published var draft = ""

    let fingerprint: String
    private let loadThread: @Sendable (String) async throws -> BurnBarInboxThread?
    private let sendReply: @Sendable (String, String) async throws -> BurnBarInboxReplyResponse
    private let acceptCandidate: @Sendable (BurnBarInboxPlanCandidate, String) async throws -> BurnBarInboxPlanAcceptResponse

    init(
        fingerprint: String,
        loadThread: @escaping @Sendable (String) async throws -> BurnBarInboxThread?,
        sendReply: @escaping @Sendable (String, String) async throws -> BurnBarInboxReplyResponse,
        acceptCandidate: @escaping @Sendable (BurnBarInboxPlanCandidate, String) async throws -> BurnBarInboxPlanAcceptResponse
    ) {
        self.fingerprint = fingerprint
        self.loadThread = loadThread
        self.sendReply = sendReply
        self.acceptCandidate = acceptCandidate
    }

    /// Production wiring: talks straight to the daemon socket off-main.
    static func live(fingerprint: String) -> InboxThreadModel {
        InboxThreadModel(
            fingerprint: fingerprint,
            loadThread: { fingerprint in
                let socketURL = OpenBurnBarDaemonRuntimePaths.live().socketURL
                return try await Task.detached(priority: .userInitiated) {
                    try OpenBurnBarDaemonSocketClient.inboxThread(fingerprint: fingerprint, at: socketURL)
                }.value
            },
            sendReply: { fingerprint, body in
                let socketURL = OpenBurnBarDaemonRuntimePaths.live().socketURL
                return try await Task.detached(priority: .userInitiated) {
                    try OpenBurnBarDaemonSocketClient.inboxReply(
                        fingerprint: fingerprint,
                        bodyMarkdown: body,
                        at: socketURL
                    )
                }.value
            },
            acceptCandidate: { candidate, pack in
                let socketURL = OpenBurnBarDaemonRuntimePaths.live().socketURL
                return try await Task.detached(priority: .userInitiated) {
                    try OpenBurnBarDaemonSocketClient.inboxPlanAccept(
                        candidate: candidate,
                        pack: pack,
                        at: socketURL
                    )
                }.value
            }
        )
    }

    func refresh() async {
        thread = try? await loadThread(fingerprint)
    }

    /// One-tap "say that differently".
    ///
    /// Goes through the ordinary reply path rather than a new call: a rewrite
    /// is a turn in the same conversation, so it inherits the same egress gate,
    /// the same per-reply budget, the same redaction, and the same thread
    /// persistence. Anything that re-explains an item outside this path would
    /// have to re-implement all four, and that is where they drift apart.
    ///
    /// Any text already typed rides along as the follow-up, so "explain simpler"
    /// does not silently discard a half-written question.
    func send(directive: BurnBarInboxReplyDirective) async {
        guard isSending == false else { return }
        let followUp = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        await deliver(body: directive.encodedBody(followUp: followUp))
    }

    func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false, isSending == false else { return }
        await deliver(body: body)
    }

    private func deliver(body: String) async {
        isSending = true
        refusalReason = nil
        defer { isSending = false }
        do {
            let response = try await sendReply(fingerprint, body)
            if let reason = response.refusalReason {
                refusalReason = reason
            } else {
                draft = ""
            }
        } catch {
            refusalReason = error.localizedDescription
        }
        // The daemon persisted the user turn either way; re-read the truth.
        await refresh()
    }

    /// Accept into plan — the human confirmation that turns a proposal into a
    /// durable ledger row. The store deduplicates on content identity (same
    /// title+body on the same plan returns the existing row), and this model
    /// additionally refuses re-entry while a call is in flight, so neither a
    /// double-click nor a recreated view can mint duplicates.
    @Published private(set) var acceptInFlight: Set<String> = []

    func accept(candidate: BurnBarInboxPlanCandidate, messageID: String) async {
        let key = messageID + candidate.title
        guard acceptInFlight.contains(key) == false else { return }
        acceptInFlight.insert(key)
        defer { acceptInFlight.remove(key) }
        do {
            _ = try await acceptCandidate(candidate, "engOps")
            acceptedStepIDs.insert(key)
        } catch {
            refusalReason = error.localizedDescription
        }
    }

    func isAccepted(candidate: BurnBarInboxPlanCandidate, messageID: String) -> Bool {
        acceptedStepIDs.contains(messageID + candidate.title)
    }
}

/// Owns the thread model per fingerprint so `InboxItemDetailView` can stay a
/// value-type view: `.id(row.id)` on the detail pane recreates this host (and
/// its `@StateObject`) when selection changes, which is exactly the lifetime
/// the model wants.
struct InboxThreadHost: View {
    let fingerprint: String
    @StateObject private var model: InboxThreadModel

    init(fingerprint: String) {
        self.fingerprint = fingerprint
        _model = StateObject(wrappedValue: InboxThreadModel.live(fingerprint: fingerprint))
    }

    var body: some View {
        InboxThreadSection(model: model)
    }
}

struct InboxThreadSection: View {
    @Environment(\.backdropInk) private var ink
    @ObservedObject var model: InboxThreadModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Text("DISCUSS")
                    .font(DesignSystem.Typography.tiny)
                    .tracking(1.1)
                    .foregroundStyle(ink.subtle)
                if let thread = model.thread, thread.totalCostUSD > 0 {
                    Text(String(format: "· $%.3f", thread.totalCostUSD))
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(ink.subtle)
                }
            }

            if let thread = model.thread, thread.messages.isEmpty == false {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    ForEach(thread.messages) { message in
                        InboxThreadBubble(
                            message: message,
                            isAccepted: { candidate in
                                model.isAccepted(candidate: candidate, messageID: message.id)
                            },
                            onAccept: { candidate in
                                Task { await model.accept(candidate: candidate, messageID: message.id) }
                            }
                        )
                    }
                }
            }

            if let reason = model.refusalReason {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "exclamationmark.circle")
                        .foregroundStyle(DesignSystem.Colors.warning)
                    Text(reason)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(DesignSystem.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                        .fill(DesignSystem.Colors.warning.opacity(0.10))
                )
            }

            rewriteChips

            HStack(spacing: DesignSystem.Spacing.sm) {
                TextField("Ask about this item…", text: $model.draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(DesignSystem.Typography.body)
                    .lineLimit(1...5)
                    .padding(DesignSystem.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                            .fill(DesignSystem.Colors.surfaceElevated.opacity(0.7))
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                                    .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1)
                            )
                    )
                    .onSubmit { Task { await model.send() } }
                    .disabled(model.isSending)

                Button {
                    Task { await model.send() }
                } label: {
                    if model.isSending {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(
                                model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    ? AnyShapeStyle(ink.subtle)
                                    : AnyShapeStyle(DesignSystem.Colors.primaryGradient)
                            )
                    }
                }
                .buttonStyle(.plain)
                .disabled(
                    model.isSending
                        || model.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
                .accessibilityLabel("Send reply")
            }
        }
        .task(id: model.fingerprint) { await model.refresh() }
    }

    /// The one-tap register controls.
    ///
    /// These exist because the honest failure mode of an analyst brief is not
    /// "wrong" — it is "pitched at the wrong person". A brief written for
    /// someone who already knows the internals is noise to someone skimming at
    /// 1am, and the reverse is condescending. Rather than pick one register and
    /// be wrong half the time, the item can be re-pitched in one click.
    ///
    /// Order matters: the two the user reaches for most (simpler, shorter) come
    /// first. `expert` is deliberately last — it is the least-used and the most
    /// expensive, since it produces the longest completion.
    private var rewriteChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                ForEach(Self.chipOrder, id: \.self) { directive in
                    Button {
                        Task { await model.send(directive: directive) }
                    } label: {
                        Text(Self.chipLabel(directive))
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                Capsule().fill(DesignSystem.Colors.surfaceElevated.opacity(0.7))
                            )
                            .overlay(
                                Capsule().stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(model.isSending)
                    // The full sentence it will send, so a click is never a
                    // surprise and the thread turn reads as something the user
                    // could have typed.
                    .help(directive.userTurnMarkdown)
                    .accessibilityLabel(directive.userTurnMarkdown)
                    .accessibilityIdentifier(OBBAccessibilityID.inboxRewriteChip(directive.rawValue))
                }
            }
            .padding(.horizontal, 1)
        }
        .frame(height: 26)
    }

    private static let chipOrder: [BurnBarInboxReplyDirective] = [
        .plainEnglish, .shorter, .deeper, .professional, .expert
    ]

    /// Short enough to fit a chip; the full sentence lives in the tooltip and
    /// the VoiceOver label.
    private static func chipLabel(_ directive: BurnBarInboxReplyDirective) -> String {
        switch directive {
        case .plainEnglish: return "Plain English"
        case .shorter: return "Shorter"
        case .deeper: return "Go deeper"
        case .professional: return "Colleague"
        case .expert: return "Expert"
        }
    }
}

/// One turn. Assistant turns may carry plan candidates, rendered as an accept
/// card under the message — the proposal is visible, the accept is explicit.
private struct InboxThreadBubble: View {
    @Environment(\.backdropInk) private var ink
    let message: BurnBarInboxThreadMessage
    let isAccepted: (BurnBarInboxPlanCandidate) -> Bool
    let onAccept: (BurnBarInboxPlanCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: message.role == .user ? "person.fill" : "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(ink.subtle)
                Text(message.role == .user ? "You" : "Inbox")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(ink.subtle)
                if let provenance = message.modelProvenance {
                    Text("· \(provenance)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(ink.subtle)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }

            Text(attributedBody)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(message.planCandidates, id: \.title) { candidate in
                planCandidateCard(candidate)
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                .fill(
                    message.role == .user
                        ? DesignSystem.Colors.surfaceElevated.opacity(0.5)
                        : DesignSystem.Colors.surfaceElevated.opacity(0.85)
                )
        )
    }

    private var attributedBody: AttributedString {
        (try? AttributedString(
            markdown: message.bodyMarkdown,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )) ?? AttributedString(message.bodyMarkdown)
    }

    @ViewBuilder
    private func planCandidateCard(_ candidate: BurnBarInboxPlanCandidate) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "flag.checkered")
                    .font(.system(size: 10, weight: .medium))
                Text("PROPOSED PLAN STEP · \(candidate.horizon.rawValue.uppercased())")
                    .font(DesignSystem.Typography.tiny)
                    .tracking(0.8)
            }
            .foregroundStyle(ink.subtle)

            Text(candidate.title)
                .font(DesignSystem.Typography.body.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            Text(candidate.bodyMarkdown)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if isAccepted(candidate) {
                Label("Accepted into plan", systemImage: "checkmark.seal.fill")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.success)
            } else {
                Button {
                    onAccept(candidate)
                } label: {
                    Label("Accept into plan", systemImage: "plus.circle.fill")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(.white)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.xs)
                        .background(Capsule().fill(DesignSystem.Colors.primaryGradient))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)
                .stroke(DesignSystem.Colors.borderSubtle, lineWidth: 1)
        )
    }
}
