import OpenBurnBarCore
import SwiftUI

// MARK: - Memory review inbox

/// F-4: the human approval gate for extracted memories. Mirrors `SessionLogsView`'s
/// command-center idiom — a stats header, a filter-chip bar, then a loading /
/// empty-state / scrolling-list switch. Newly extracted memories arrive quarantined
/// and surface here as "Pending"; the user approves them into the injectable set or
/// rejects them. Approved memories are reviewable (and revocable) under the
/// "Approved" filter.
struct MemoryReviewInboxView: View {
    let model: MemoryReviewInboxModel

    init(model: MemoryReviewInboxModel) {
        self.model = model
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.top, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.md)

            filterBar
                .padding(.horizontal, DesignSystem.Spacing.lg)
                .padding(.bottom, DesignSystem.Spacing.md)

            if model.filter == .pending, model.pendingThreadGroups.isEmpty == false {
                bulkApproveBar
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.bottom, DesignSystem.Spacing.md)
            }

            if let errorMessage = model.errorMessage {
                errorBanner(errorMessage)
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.bottom, DesignSystem.Spacing.md)
            }

            Divider().background(DesignSystem.Colors.border.opacity(0.6))

            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.Colors.background)
        .task { await model.load() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.ember)
                Text("Memory review")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)

                Spacer()

                if model.pendingCount > 0 {
                    pendingPill
                }
            }

            Text("Approve what to remember")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("Memories stay quarantined until you approve them — nothing is used in a chat before you say so.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var pendingPill: some View {
        Text("\(model.pendingCount) pending")
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.amber)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xxs)
            .background(
                Capsule(style: .continuous)
                    .fill(DesignSystem.Colors.amber.opacity(0.16))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(DesignSystem.Colors.amber.opacity(0.40), lineWidth: 0.5)
            )
    }

    // MARK: - Filter bar

    private var bulkApproveBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                ForEach(model.pendingThreadGroups, id: \.threadLogicalID) { group in
                    Button {
                        Task { await model.approveAllPending(threadLogicalID: group.threadLogicalID) }
                    } label: {
                        Text("Approve all from thread (\(group.count))")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .padding(.horizontal, DesignSystem.Spacing.md)
                            .padding(.vertical, DesignSystem.Spacing.xs)
                            .background(
                                Capsule(style: .continuous)
                                    .fill(DesignSystem.Colors.ember.opacity(0.14))
                            )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: DesignSystem.Spacing.xs) {
            ForEach(MemoryReviewInboxModel.Filter.allCases) { filter in
                filterChip(filter)
            }
            Spacer()
        }
    }

    private func filterChip(_ filter: MemoryReviewInboxModel.Filter) -> some View {
        let isActive = model.filter == filter
        let accent = DesignSystem.Colors.ember
        let showCount = filter == .pending && model.pendingCount > 0
        return Button {
            withAnimation(DesignSystem.Animation.snappy) {
                model.filter = filter
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Text(filter.title)
                    .font(DesignSystem.Typography.tiny)
                if showCount {
                    Text("\(model.pendingCount)")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(isActive ? accent : DesignSystem.Colors.textMuted)
                        .padding(.horizontal, DesignSystem.Spacing.xs)
                        .padding(.vertical, DesignSystem.Spacing.xxs)
                        .background(
                            Capsule(style: .continuous)
                                .fill(accent.opacity(isActive ? 0.22 : 0.12))
                        )
                }
            }
            .foregroundStyle(isActive ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.full, style: .continuous)
                    .fill(isActive ? AnyShapeStyle(accent.opacity(0.18)) : AnyShapeStyle(DesignSystem.Colors.surfaceElevated.opacity(0.4)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.full, style: .continuous)
                    .strokeBorder(isActive ? accent.opacity(0.45) : DesignSystem.Colors.border.opacity(0.3), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Error banner

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.warning)
            Text(message)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.warning.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(DesignSystem.Colors.warning.opacity(0.30), lineWidth: 0.5)
        )
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if model.isLoading {
            Spacer()
            VStack(spacing: DesignSystem.Spacing.sm) {
                ProgressView()
                Text("Loading…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
            Spacer()
        } else if model.items.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(model.items) { item in
                        MemoryReviewRow(
                            item: item,
                            isPending: model.filter == .pending,
                            onApprove: { Task { await model.approve(item.id) } },
                            onReject: { Task { await model.reject(item.id) } }
                        )
                    }
                }
                .padding(DesignSystem.Spacing.lg)
            }
            .scrollContentBackground(.hidden)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        MemoryReviewEmptyState(
            icon: model.filter == .pending ? "tray" : "checkmark.seal",
            title: model.filter == .pending ? "No memories to review" : "Nothing approved yet",
            message: model.filter == .pending
                ? "When a chat turns up a durable fact or preference worth remembering, it lands here for your approval."
                : "Memories you approve will appear here. You can revoke any of them at any time."
        )
    }
}

// MARK: - Stable model host

/// Owns the inbox model for a concrete store/scope pair. Keeping the
/// `MemoryReviewInboxModel` in `@State` prevents parent view refreshes (for
/// example the dashboard pending-count badge update after an approve/reject)
/// from replacing a loaded model with a fresh empty one.
@MainActor
struct MemoryReviewInboxHost: View {
    @State private var model: MemoryReviewInboxModel

    init(
        store: ControlPlaneStore,
        scope: MemoryScope,
        afterStatusChange: @escaping @MainActor () async -> Void = {}
    ) {
        self._model = State(initialValue: MemoryReviewInboxModel(
            scope: scope,
            loadPage: { request in try await store.chatMemoryPage(request) },
            openBody: { id in try await store.openChatMemoryBody(id: id) },
            setStatus: { id, status in
                let changed = try await store.setChatMemoryReviewStatus(id: id, status: status, now: Date())
                await afterStatusChange()
                return changed
            }
        ))
    }

    var body: some View {
        MemoryReviewInboxView(model: model)
    }
}

// MARK: - Empty state

/// Mirrors `QuotaEmptyState`'s structure (glow SF Symbol + title + body) sized for the
/// inbox's command-center column. No CTA — the inbox fills itself as chats are
/// reviewed.
private struct MemoryReviewEmptyState: View {
    let icon: String
    let title: String
    let message: String

    @State private var glow = false

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.ember.opacity(0.18),
                                DesignSystem.Colors.amber.opacity(0.10),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 168, height: 168)
                    .blur(radius: 18)
                    .scaleEffect(glow ? 1.06 : 0.94)
                    .opacity(glow ? 1 : 0.7)

                Image(systemName: icon)
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(DesignSystem.Colors.primaryGradient)
            }
            .onAppear {
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                    glow = true
                }
            }

            VStack(spacing: DesignSystem.Spacing.sm) {
                Text(title)
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)

                Text(message)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignSystem.Spacing.xxl)
    }
}

// MARK: - Row

/// One reviewable memory card. Shows the transiently-opened body (truncated), a kind
/// badge, a confidence hint, the source citation chip (read-only — `onJumpToLocal: nil`
/// self-disables it), and the review actions. Pending rows offer Approve / Reject
/// (reject behind a destructive confirmation); approved rows show an "Approved" mark
/// and offer Revoke.
struct MemoryReviewRow: View {
    let item: MemoryReviewInboxModel.Item
    let isPending: Bool
    let onApprove: () -> Void
    let onReject: () -> Void

    @State private var confirmingReject = false

    private var confidencePercent: Int {
        Int((item.memory.confidence * 100).rounded())
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    kindBadge
                    confidenceHint
                    Spacer(minLength: 0)
                }

                Text(bodyText)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: DesignSystem.Spacing.sm) {
                    MemoryCitationChipView(citations: item.memory.citations, onJumpToLocal: nil)
                    Spacer(minLength: 0)
                    actions
                }
            }
            .padding(DesignSystem.Spacing.sm)
        }
        .confirmationDialog(
            "Reject this memory?",
            isPresented: $confirmingReject,
            titleVisibility: .visible
        ) {
            Button("Reject", role: .destructive) { onReject() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It won't be remembered or used in any chat. You can't undo this.")
        }
    }

    // MARK: - Subviews

    private var bodyText: String {
        let trimmed = item.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(Memory contents unavailable)" : trimmed
    }

    private var approveButtonGradient: LinearGradient {
        item.canApprove
            ? DesignSystem.Colors.primaryGradient
            : LinearGradient(
                colors: [DesignSystem.Colors.textMuted.opacity(0.35), DesignSystem.Colors.textMuted.opacity(0.22)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
    }

    private var kindBadge: some View {
        Text(item.memory.kind.rawValue)
            .font(DesignSystem.Typography.tiny)
            .textCase(.uppercase)
            .foregroundStyle(DesignSystem.Colors.amber)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xxs)
            .background(
                Capsule(style: .continuous)
                    .fill(DesignSystem.Colors.amber.opacity(0.14))
            )
            .overlay(
                Capsule(style: .continuous)
                    .strokeBorder(DesignSystem.Colors.ember.opacity(0.25), lineWidth: 0.5)
            )
    }

    private var confidenceHint: some View {
        HStack(spacing: DesignSystem.Spacing.xxs) {
            Image(systemName: "gauge.with.dots.needle.50percent")
                .font(.system(size: 9, weight: .medium))
            Text("\(confidencePercent)%")
                .font(DesignSystem.Typography.tiny)
        }
        .foregroundStyle(DesignSystem.Colors.textMuted)
    }

    @ViewBuilder
    private var actions: some View {
        if isPending {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Button(role: .destructive) {
                    confirmingReject = true
                } label: {
                    Text("Reject")
                        .font(DesignSystem.Typography.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.error)

                Button(action: onApprove) {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                        Text("Approve")
                            .font(DesignSystem.Typography.caption)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(
                        Capsule(style: .continuous)
                            .fill(approveButtonGradient)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!item.canApprove)
            }
        } else {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Label("Approved", systemImage: "checkmark.seal.fill")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.success)

                Button(role: .destructive) {
                    confirmingReject = true
                } label: {
                    Text("Revoke")
                        .font(DesignSystem.Typography.caption)
                }
                .buttonStyle(.plain)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
    }
}
