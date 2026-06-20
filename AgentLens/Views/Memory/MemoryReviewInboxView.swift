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
                            onApprove: { await model.approve(item.id) },
                            onReject: { await model.reject(item.id) }
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

// MARK: - Empty state

/// Mirrors `QuotaEmptyState`'s structure (glow SF Symbol + title + body) sized for the
/// inbox's command-center column. No CTA — the inbox fills itself as chats are
/// reviewed.
private struct MemoryReviewEmptyState: View {
    let icon: String
    let title: String
    let message: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                    .scaleEffect(reduceMotion ? 1.0 : (glow ? 1.06 : 0.94))
                    .opacity(reduceMotion ? 0.9 : (glow ? 1 : 0.7))

                Image(systemName: icon)
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(DesignSystem.Colors.primaryGradient)
            }
            .onAppear {
                // Reduce-motion users get a calm static halo instead of an
                // infinite pulse — matches `ConstellationBackgroundView`.
                guard !reduceMotion else { return }
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
    let onApprove: () async -> Void
    let onReject: () async -> Void

    @State private var confirmingReject = false
    /// Guards a transition in flight (approve / reject / revoke). While true the
    /// row's action buttons disable and the tapped action shows a spinner, so the
    /// user sees the write land instead of a dead-feeling tap-then-vanish.
    @State private var isTransitioning = false

    private var confidencePercent: Int {
        Int((item.memory.confidence * 100).rounded())
    }

    /// Honest gauge: the needle tracks the actual confidence (the static
    /// `50percent` symbol would show the same needle for a 5% and a 95% fact).
    /// Mirrors `BurnRailBudgetChip`'s threshold→symbol idiom.
    private var confidenceSymbol: String {
        switch confidencePercent {
        case 90...: return "gauge.with.dots.needle.100percent"
        case 67...: return "gauge.with.dots.needle.67percent"
        case 34...: return "gauge.with.dots.needle.50percent"
        default:    return "gauge.with.dots.needle.33percent"
        }
    }

    /// Higher confidence reads as more trustworthy (success tint); low confidence
    /// stays muted so a weak fact doesn't borrow the authority of a strong one.
    private var confidenceTint: Color {
        switch confidencePercent {
        case 67...: return DesignSystem.Colors.success
        case 34...: return DesignSystem.Colors.textSecondary
        default:    return DesignSystem.Colors.textMuted
        }
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
            Button("Reject", role: .destructive) { runTransition(onReject) }
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
            Image(systemName: confidenceSymbol)
                .font(.system(size: 9, weight: .medium))
            Text("\(confidencePercent)%")
                .font(DesignSystem.Typography.tiny)
        }
        .foregroundStyle(confidenceTint)
        .help("How confident the model is this is a durable fact worth keeping")
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
                .disabled(isTransitioning)

                Button {
                    runTransition(onApprove)
                } label: {
                    HStack(spacing: DesignSystem.Spacing.xs) {
                        if isTransitioning {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                        }
                        Text(isTransitioning ? "Approving" : "Approve")
                            .font(DesignSystem.Typography.caption)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                    .background(
                        Capsule(style: .continuous)
                            .fill(DesignSystem.Colors.primaryGradient)
                    )
                }
                .buttonStyle(.plain)
                .disabled(isTransitioning)
            }
        } else {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Label("Approved", systemImage: "checkmark.seal.fill")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.success)

                if isTransitioning {
                    ProgressView().controlSize(.mini)
                } else {
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

    /// Runs a review transition with in-flight feedback: disable the row's actions
    /// and show a spinner until the store write + reload settles. The subsequent
    /// reload removes the row from its current bucket, so `isTransitioning` only
    /// needs to bridge the write window.
    private func runTransition(_ action: @escaping () async -> Void) {
        guard !isTransitioning else { return }
        isTransitioning = true
        Task {
            defer { isTransitioning = false }
            await action()
        }
    }
}
