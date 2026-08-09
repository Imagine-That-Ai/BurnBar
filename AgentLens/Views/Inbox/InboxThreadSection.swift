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

    func send() async {
        let body = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard body.isEmpty == false, isSending == false else { return }
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
    /// durable ledger row. Tracks accepted candidates so the button collapses
    /// into a receipt instead of inviting a duplicate.
    func accept(candidate: BurnBarInboxPlanCandidate, messageID: String) async {
        do {
            _ = try await acceptCandidate(candidate, "engOps")
            acceptedStepIDs.insert(messageID + candidate.title)
        } catch {
            refusalReason = error.localizedDescription
        }
    }

    func isAccepted(candidate: BurnBarInboxPlanCandidate, messageID: String) -> Bool {
        acceptedStepIDs.contains(messageID + candidate.title)
    }
}

struct InboxThreadSection: View {
    @ObservedObject var model: InboxThreadModel

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Text("DISCUSS")
                    .font(DesignSystem.Typography.tiny)
                    .tracking(1.1)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                if let thread = model.thread, thread.totalCostUSD > 0 {
                    Text(String(format: "· $%.3f", thread.totalCostUSD))
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
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
                                    ? AnyShapeStyle(DesignSystem.Colors.textMuted)
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
}

/// One turn. Assistant turns may carry plan candidates, rendered as an accept
/// card under the message — the proposal is visible, the accept is explicit.
private struct InboxThreadBubble: View {
    let message: BurnBarInboxThreadMessage
    let isAccepted: (BurnBarInboxPlanCandidate) -> Bool
    let onAccept: (BurnBarInboxPlanCandidate) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: message.role == .user ? "person.fill" : "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Text(message.role == .user ? "You" : "Inbox")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                if let provenance = message.modelProvenance {
                    Text("· \(provenance)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
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
            .foregroundStyle(DesignSystem.Colors.textMuted)

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
