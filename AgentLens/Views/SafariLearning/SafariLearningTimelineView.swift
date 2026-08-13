import OpenBurnBarKernel
import SwiftUI

// MARK: - Timeline

struct SafariLearningTimelineView: View {
    @Bindable var model: SafariLearningTimelineViewModel

    @State private var showingDeleteProfileConfirmation = false

    private var editDraftBinding: Binding<SafariLearningEditDraft?> {
        Binding(
            get: { model.editDraft },
            set: { value in
                if value == nil {
                    model.cancelEditing()
                }
            }
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            SafariLearningHero(
                enabled: model.enabled,
                eligible: model.isEligibleTier,
                tierName: model.tierDisplayName,
                totalCount: model.proposals.count,
                proposedCount: model.proposedCount,
                activeCount: model.activeCount,
                profileMutation: model.profileMutation,
                actionsDisabled: model.profileActionsDisabled,
                onEnable: { Task { await model.optIn() } },
                onPause: { Task { await model.pauseLearning() } },
                onDelete: { showingDeleteProfileConfirmation = true }
            )
            .padding(.horizontal, DesignSystem.Spacing.xl)
            .padding(.top, DesignSystem.Spacing.xl)
            .padding(.bottom, DesignSystem.Spacing.lg)

            if let banner = model.banner {
                SafariLearningBannerView(
                    banner: banner,
                    onDismiss: model.dismissBanner
                )
                .padding(.horizontal, DesignSystem.Spacing.xl)
                .padding(.bottom, DesignSystem.Spacing.md)
            }

            SafariLearningFilterBar(model: model)
                .padding(.horizontal, DesignSystem.Spacing.xl)
                .padding(.bottom, DesignSystem.Spacing.lg)

            Divider()
                .overlay(DesignSystem.Colors.border.opacity(0.58))

            content
        }
        .frame(minWidth: 720, minHeight: 520)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DesignSystem.Colors.background)
        .accessibilityIdentifier(OBBAccessibilityID.safariLearningRoot)
        .task {
            guard !model.hasLoaded else { return }
            await model.load()
        }
        .sheet(item: editDraftBinding) { draft in
            SafariLearningEditorSheet(model: model, draft: draft)
        }
        .alert(
            "Delete everything BurnBar learned from Safari?",
            isPresented: $showingDeleteProfileConfirmation
        ) {
            Button("Delete Learned Profile", role: .destructive) {
                Task { await model.deleteLearnedProfile() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This turns learning off and permanently removes every learned memory, site rule, proposed skill, active skill file, and retained Safari-learning history. Your normal Safari sessions remain available."
            )
        }
    }

    @ViewBuilder
    private var content: some View {
        if model.isLoading && !model.hasLoaded {
            SafariLearningLoadingState()
        } else if model.proposals.isEmpty {
            SafariLearningEmptyState(
                icon: model.isEligibleTier ? "brain.head.profile" : "lock.shield",
                title: model.isEligibleTier
                    ? (model.enabled ? "Nothing learned yet" : "Learning is ready when you are")
                    : "Safari learning is a Pro+ feature",
                message: emptyProfileMessage
            )
        } else if model.visibleProposals.isEmpty {
            SafariLearningEmptyState(
                icon: model.hasActiveSearch
                    ? "magnifyingglass"
                    : "line.3.horizontal.decrease.circle",
                title: model.hasActiveSearch
                    ? "No matching learning"
                    : "Nothing in this filter",
                message: model.hasActiveSearch
                    ? "Try a different title, site, status, or phrase."
                    : "Choose another status to review the rest of your learned timeline."
            )
        } else {
            ScrollView {
                LazyVStack(spacing: DesignSystem.Spacing.md) {
                    ForEach(model.visibleProposals) { proposal in
                        SafariLearningTimelineCard(
                            proposal: proposal,
                            profileEnabled: model.enabled,
                            isMutating: model.isMutating(proposal.proposalId),
                            onEdit: { model.beginEditing(proposal) },
                            onApprove: {
                                Task { await model.approve(proposal) }
                            },
                            onReject: {
                                Task { await model.reject(proposal) }
                            },
                            onRollback: {
                                Task {
                                    await model.rollbackToPreviousVersion(
                                        proposal
                                    )
                                }
                            },
                            onForget: {
                                Task { await model.forget(proposal) }
                            }
                        )
                    }
                }
                .padding(DesignSystem.Spacing.xl)
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var emptyProfileMessage: String {
        if !model.isEligibleTier {
            return "Free-tier Safari use stays session-only and writes no durable memories or skills. Pro, Pro Max, and Ultra can opt in."
        }
        if model.enabled {
            return "Only explicit corrections, reviewed recovery patterns, repeated workflows, and deliberate long action sequences can create proposals."
        }
        return "Turn learning on to let Safari create reviewable proposals. Nothing becomes active without the daemon review gate and your approval."
    }
}

// MARK: - Hero

private struct SafariLearningHero: View {
    let enabled: Bool
    let eligible: Bool
    let tierName: String
    let totalCount: Int
    let proposedCount: Int
    let activeCount: Int
    let profileMutation: SafariLearningTimelineViewModel.ProfileMutation?
    let actionsDisabled: Bool
    let onEnable: () -> Void
    let onPause: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.xl) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                ZStack {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    DesignSystem.Colors.ember.opacity(0.24),
                                    DesignSystem.Colors.amber.opacity(0.12)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    Image(systemName: "brain.head.profile")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.primaryGradient)
                        .accessibilityHidden(true)
                }
                .frame(width: 58, height: 58)
                .overlay {
                    Circle()
                        .strokeBorder(
                            DesignSystem.Colors.ember.opacity(0.28),
                            lineWidth: 0.75
                        )
                }

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    Text("What BurnBar learned about you")
                        .font(DesignSystem.Typography.display)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)

                    Text(
                        "A reviewable, versioned gallery of Safari preferences, site rules, and portable skills — never a hidden rewrite of BurnBar’s policy."
                    )
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: DesignSystem.Spacing.sm) {
                        SafariLearningMetricPill(
                            label: "\(totalCount) total",
                            tint: DesignSystem.Colors.textSecondary
                        )
                        SafariLearningMetricPill(
                            label: "\(proposedCount) proposed",
                            tint: DesignSystem.Colors.amber
                        )
                        SafariLearningMetricPill(
                            label: "\(activeCount) active",
                            tint: DesignSystem.Colors.success
                        )
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SafariLearningProfileControl(
                enabled: enabled,
                eligible: eligible,
                tierName: tierName,
                hasItems: totalCount > 0,
                mutation: profileMutation,
                actionsDisabled: actionsDisabled,
                onEnable: onEnable,
                onPause: onPause,
                onDelete: onDelete
            )
            .frame(width: 290)
        }
        .padding(DesignSystem.Spacing.xl)
        .background {
            RoundedRectangle(
                cornerRadius: DesignSystem.Radius.xl,
                style: .continuous
            )
            .fill(
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.surfaceElevated,
                        DesignSystem.Colors.surface,
                        DesignSystem.Colors.ember.opacity(0.055)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: DesignSystem.Radius.xl,
                style: .continuous
            )
            .strokeBorder(
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.ember.opacity(0.26),
                        DesignSystem.Colors.border.opacity(0.6),
                        DesignSystem.Colors.amber.opacity(0.18)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.75
            )
        }
        .shadow(
            color: DesignSystem.Shadows.medium.color,
            radius: DesignSystem.Shadows.medium.radius,
            x: DesignSystem.Shadows.medium.x,
            y: DesignSystem.Shadows.medium.y
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Safari learning profile")
    }
}

private struct SafariLearningProfileControl: View {
    let enabled: Bool
    let eligible: Bool
    let tierName: String
    let hasItems: Bool
    let mutation: SafariLearningTimelineViewModel.ProfileMutation?
    let actionsDisabled: Bool
    let onEnable: () -> Void
    let onPause: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                Circle()
                    .fill(statusTint)
                    .frame(width: 9, height: 9)
                    .overlay {
                        Circle()
                            .strokeBorder(
                                statusTint.opacity(0.35),
                                lineWidth: 3
                            )
                            .scaleEffect(1.65)
                    }
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                    Text(statusTitle)
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("\(tierName) membership")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }

            Text(statusMessage)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if let mutation {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    ProgressView()
                        .controlSize(.small)
                    Text(mutation.progressLabel)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else if eligible {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Button(action: enabled ? onPause : onEnable) {
                        Label(
                            enabled ? "Pause" : "Turn On",
                            systemImage: enabled ? "pause.fill" : "sparkles"
                        )
                        .font(DesignSystem.Typography.caption)
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(
                        enabled
                            ? DesignSystem.Colors.textSecondary
                            : DesignSystem.Colors.ember
                    )
                    .disabled(actionsDisabled)
                    .accessibilityIdentifier(
                        OBBAccessibilityID.safariLearningProfileToggle
                    )

                    if enabled || hasItems {
                        Button(role: .destructive, action: onDelete) {
                            Image(systemName: "trash")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(.bordered)
                        .help("Turn learning off and delete the learned profile")
                        .disabled(actionsDisabled)
                        .accessibilityLabel("Delete learned profile")
                        .accessibilityIdentifier(
                            OBBAccessibilityID.safariLearningDeleteProfile
                        )
                    }
                }
            } else {
                Label("Session-only on Free", systemImage: "lock")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .padding(DesignSystem.Spacing.lg)
        .background {
            RoundedRectangle(
                cornerRadius: DesignSystem.Radius.lg,
                style: .continuous
            )
            .fill(DesignSystem.Colors.background.opacity(0.72))
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: DesignSystem.Radius.lg,
                style: .continuous
            )
            .strokeBorder(DesignSystem.Colors.border.opacity(0.52), lineWidth: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(statusTitle)
        .accessibilityValue("\(tierName) membership")
    }

    private var statusTitle: String {
        if !eligible { return "Learning unavailable" }
        return enabled ? "Learning is on" : "Learning is paused"
    }

    private var statusMessage: String {
        if !eligible {
            return "No durable Safari learning is written on this tier."
        }
        if enabled {
            return "Explicit proposals only. Every activation stays reviewable and reversible."
        }
        return "Existing items remain visible, but new writes and recall are disabled."
    }

    private var statusTint: Color {
        if !eligible { return DesignSystem.Colors.textMuted }
        return enabled ? DesignSystem.Colors.success : DesignSystem.Colors.warning
    }
}

private struct SafariLearningMetricPill: View {
    let label: String
    let tint: Color

    var body: some View {
        Text(label)
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(tint)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xxs)
            .background {
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.11))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.24), lineWidth: 0.5)
            }
    }
}

// MARK: - Filters and search

private struct SafariLearningFilterBar: View {
    @Bindable var model: SafariLearningTimelineViewModel

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.md) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .accessibilityHidden(true)

                TextField(
                    "Search titles, content, reasons, or sites",
                    text: $model.searchText
                )
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .accessibilityLabel("Search learned items")
                .accessibilityIdentifier(
                    OBBAccessibilityID.safariLearningSearch
                )

                if model.hasActiveSearch {
                    Button {
                        model.searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear learning search")
                }
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .frame(minWidth: 230, maxWidth: 380)
            .frame(height: 34)
            .background {
                RoundedRectangle(
                    cornerRadius: DesignSystem.Radius.md,
                    style: .continuous
                )
                .fill(DesignSystem.Colors.surfaceElevated)
            }
            .overlay {
                RoundedRectangle(
                    cornerRadius: DesignSystem.Radius.md,
                    style: .continuous
                )
                .strokeBorder(
                    DesignSystem.Colors.border.opacity(0.62),
                    lineWidth: 0.5
                )
            }

            HStack(spacing: DesignSystem.Spacing.xs) {
                ForEach(SafariLearningTimelineViewModel.Filter.allCases) { filter in
                    SafariLearningFilterChip(
                        filter: filter,
                        filteredCount: model.count(for: filter),
                        selected: model.filter == filter,
                        onSelect: { model.filter = filter }
                    )
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Learning status filters")

            Spacer(minLength: 0)

            Button {
                Task { await model.refresh() }
            } label: {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    if model.isRefreshing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(model.isRefreshing ? "Refreshing" : "Refresh")
                }
                .font(DesignSystem.Typography.caption)
            }
            .buttonStyle(.bordered)
            .disabled(
                model.isLoading
                    || model.isRefreshing
                    || model.profileMutation != nil
            )
            .keyboardShortcut("r", modifiers: .command)
            .accessibilityIdentifier(OBBAccessibilityID.safariLearningRefresh)
        }
    }
}

private struct SafariLearningFilterChip: View {
    let filter: SafariLearningTimelineViewModel.Filter
    let filteredCount: Int
    let selected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Text(filter.title)
                if filteredCount != 0 {
                    Text("\(filteredCount)")
                        .font(DesignSystem.Typography.tiny)
                        .padding(.horizontal, DesignSystem.Spacing.xs)
                        .padding(.vertical, 1)
                        .background {
                            Capsule(style: .continuous)
                                .fill(
                                    selected
                                        ? DesignSystem.Colors.ember.opacity(0.2)
                                        : DesignSystem.Colors.surfaceMuted
                                )
                        }
                }
            }
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(
                selected
                    ? DesignSystem.Colors.textPrimary
                    : DesignSystem.Colors.textSecondary
            )
            .padding(.horizontal, DesignSystem.Spacing.md)
            .frame(height: 32)
            .background {
                Capsule(style: .continuous)
                    .fill(
                        selected
                            ? DesignSystem.Colors.ember.opacity(0.14)
                            : DesignSystem.Colors.surface.opacity(0.58)
                    )
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(
                        selected
                            ? DesignSystem.Colors.ember.opacity(0.42)
                            : DesignSystem.Colors.border.opacity(0.42),
                        lineWidth: 0.5
                    )
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(filter.title), \(count) items")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier(
            OBBAccessibilityID.safariLearningFilter(filter.rawValue)
        )
    }
}

// MARK: - Banner

private struct SafariLearningBannerView: View {
    let banner: SafariLearningTimelineViewModel.Banner
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(tint)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(banner.title)
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(verbatim: banner.message)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .accessibilityLabel("Dismiss message")
        }
        .padding(DesignSystem.Spacing.md)
        .background {
            RoundedRectangle(
                cornerRadius: DesignSystem.Radius.md,
                style: .continuous
            )
            .fill(tint.opacity(0.1))
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: DesignSystem.Radius.md,
                style: .continuous
            )
            .strokeBorder(tint.opacity(0.3), lineWidth: 0.5)
        }
        .accessibilityElement(children: .combine)
    }

    private var tint: Color {
        switch banner.kind {
        case .success: DesignSystem.Colors.success
        case .warning: DesignSystem.Colors.warning
        case .error: DesignSystem.Colors.error
        }
    }

    private var icon: String {
        switch banner.kind {
        case .success: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .error: "xmark.octagon.fill"
        }
    }
}

// MARK: - Timeline card

private struct SafariLearningTimelineCard: View {
    private enum Confirmation {
        case reject
        case rollback
        case forget
    }

    let proposal: BurnBarSafariLearningProposal
    let profileEnabled: Bool
    let isMutating: Bool
    let onEdit: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void
    let onRollback: () -> Void
    let onForget: () -> Void

    @State private var expanded = false
    @State private var confirmation: Confirmation?

    private var confirmationPresented: Binding<Bool> {
        Binding(
            get: { confirmation != nil },
            set: { isPresented in
                if !isPresented {
                    confirmation = nil
                }
            }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        SafariLearningBadge(
                            label: proposal.reviewStatus.displayName,
                            tint: proposal.reviewStatus.tint
                        )
                        SafariLearningBadge(
                            label: proposal.kind.displayName,
                            tint: proposal.kind.tint
                        )
                        Text("v\(proposal.version)")
                            .font(DesignSystem.Typography.monoTiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }

                    Text(verbatim: proposal.title)
                        .font(DesignSystem.Typography.title)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                if isMutating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Updating \(proposal.title)")
                }
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(verbatim: proposal.content)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineSpacing(3)
                    .lineLimit(expanded ? nil : 5)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if proposal.content.count > 280 {
                    Button(expanded ? "Show less" : "Show full content") {
                        expanded.toggle()
                    }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.ember)
                }
            }

            HStack(alignment: .top, spacing: DesignSystem.Spacing.lg) {
                SafariLearningDetail(
                    icon: "quote.bubble",
                    label: "Why it was proposed",
                    value: proposal.reason
                )
                SafariLearningDetail(
                    icon: "scope",
                    label: "Expected effect",
                    value: proposal.expectedOutcome
                )
            }

            HStack(alignment: .center, spacing: DesignSystem.Spacing.sm) {
                Label(sourceLabel, systemImage: "safari")
                    .lineLimit(1)
                Text("•")
                    .accessibilityHidden(true)
                Text(
                    proposal.updatedAt,
                    format: .dateTime
                        .year()
                        .month(.abbreviated)
                        .day()
                        .hour()
                        .minute()
                )
                Spacer(minLength: 0)
                actions
            }
            .font(DesignSystem.Typography.caption)
            .foregroundStyle(DesignSystem.Colors.textMuted)
        }
        .padding(DesignSystem.Spacing.xl)
        .background {
            RoundedRectangle(
                cornerRadius: DesignSystem.Radius.lg,
                style: .continuous
            )
            .fill(DesignSystem.Colors.surfaceElevated)
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: DesignSystem.Radius.lg,
                style: .continuous
            )
            .strokeBorder(
                LinearGradient(
                    colors: [
                        proposal.reviewStatus.tint.opacity(0.42),
                        DesignSystem.Colors.border.opacity(0.48)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.65
            )
        }
        .shadow(
            color: DesignSystem.Shadows.small.color,
            radius: DesignSystem.Shadows.small.radius,
            x: DesignSystem.Shadows.small.x,
            y: DesignSystem.Shadows.small.y
        )
        .disabled(isMutating)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(
            OBBAccessibilityID.safariLearningRow(proposal.proposalId)
        )
        .confirmationDialog(
            confirmationTitle,
            isPresented: confirmationPresented,
            titleVisibility: .visible
        ) {
            switch confirmation {
            case .reject:
                Button("Reject Proposal", role: .destructive, action: onReject)
                Button("Cancel", role: .cancel) {}
            case .rollback:
                Button(
                    "Restore Version \(proposal.version - 1)",
                    action: onRollback
                )
                Button("Cancel", role: .cancel) {}
            case .forget:
                Button("Forget Item", role: .destructive, action: onForget)
                Button("Cancel", role: .cancel) {}
            case nil:
                EmptyView()
            }
        } message: {
            Text(confirmationMessage)
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            if proposal.reviewStatus == .proposed
                || proposal.reviewStatus == .approved {
                Button("Edit", action: onEdit)
                    .buttonStyle(.plain)
                    .disabled(!profileEnabled)
                    .help(
                        profileEnabled
                            ? "Edit this version"
                            : "Turn learning on before editing"
                    )
            }

            if proposal.version > 1 {
                Button("Rollback") {
                    confirmation = .rollback
                }
                .buttonStyle(.plain)
                .disabled(!profileEnabled)
                .help(
                    profileEnabled
                        ? "Restore the immediately previous version"
                        : "Turn learning on before rolling back"
                )
            }

            if proposal.reviewStatus == .proposed {
                Button(role: .destructive) {
                    confirmation = .reject
                } label: {
                    Text("Reject")
                }
                .buttonStyle(.plain)

                Button(role: .destructive) {
                    confirmation = .forget
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.plain)
                .help("Permanently forget this proposal")
                .accessibilityLabel("Forget proposal")

                Button(action: onApprove) {
                    Label("Approve", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.ember)
                .disabled(!profileEnabled)
                .help(
                    profileEnabled
                        ? "Approve and activate this proposal"
                        : "Turn learning on before approving"
                )
            } else {
                Button(role: .destructive) {
                    confirmation = .forget
                } label: {
                    Text("Forget")
                }
                .buttonStyle(.plain)
            }
        }
        .font(DesignSystem.Typography.caption)
    }

    private var sourceLabel: String {
        guard let url = URL(string: proposal.sourceURL),
              let host = url.host,
              !host.isEmpty else {
            return proposal.sourceURL
        }
        return host
    }

    private var confirmationTitle: String {
        switch confirmation {
        case .reject:
            "Reject “\(proposal.title)”?"
        case .rollback:
            "Restore the previous version?"
        case .forget:
            "Forget “\(proposal.title)”?"
        case nil:
            "Confirm learning action"
        }
    }

    private var confirmationMessage: String {
        switch confirmation {
        case .reject:
            "The item will not become active. Its versioned history remains available for an intentional rollback."
        case .rollback:
            "Version \(proposal.version - 1) will be restored as a new version. The current version remains in the audit history."
        case .forget:
            "This removes the timeline item and any active memory or portable skill materialization. This action cannot be undone from the app."
        case nil:
            ""
        }
    }
}

private struct SafariLearningBadge: View {
    let label: String
    let tint: Color

    var body: some View {
        Text(label)
            .font(DesignSystem.Typography.tiny)
            .textCase(.uppercase)
            .foregroundStyle(tint)
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xxs)
            .background {
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.12))
            }
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(0.3), lineWidth: 0.5)
            }
    }
}

private struct SafariLearningDetail: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DesignSystem.Colors.ember)
                .frame(width: 16)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text(label)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .textCase(.uppercase)
                Text(verbatim: value)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(3)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Editor

private struct SafariLearningEditorSheet: View {
    let model: SafariLearningTimelineViewModel
    @Bindable var draft: SafariLearningEditDraft

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
                ZStack {
                    Circle()
                        .fill(DesignSystem.Colors.ember.opacity(0.14))
                    Image(systemName: draft.kind.systemImage)
                        .foregroundStyle(DesignSystem.Colors.primaryGradient)
                        .accessibilityHidden(true)
                }
                .frame(width: 42, height: 42)

                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    Text("Refine learned item")
                        .font(DesignSystem.Typography.title)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(
                        "\(draft.kind.displayName) · \(draft.reviewStatus.displayName) · version \(draft.expectedVersion)"
                    )
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                }

                Spacer(minLength: 0)
            }
            .padding(DesignSystem.Spacing.xl)

            Divider()
                .overlay(DesignSystem.Colors.border.opacity(0.58))

            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xl) {
                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        HStack {
                            Text("Title")
                                .font(DesignSystem.Typography.headline)
                            Spacer()
                            SafariLearningByteCount(
                                count: draft.titleByteCount,
                                limit: SafariLearningEditDraft.maximumTitleBytes
                            )
                        }

                        TextField("Concise learned-item title", text: $draft.title)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier(
                                OBBAccessibilityID.safariLearningEditorTitle
                            )
                    }

                    VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                        HStack {
                            Text("Learned content")
                                .font(DesignSystem.Typography.headline)
                            Spacer()
                            SafariLearningByteCount(
                                count: draft.contentByteCount,
                                limit: SafariLearningEditDraft.maximumContentBytes
                            )
                        }

                        TextEditor(text: $draft.content)
                            .font(DesignSystem.Typography.body)
                            .scrollContentBackground(.hidden)
                            .padding(DesignSystem.Spacing.sm)
                            .frame(minHeight: 220)
                            .background {
                                RoundedRectangle(
                                    cornerRadius: DesignSystem.Radius.md,
                                    style: .continuous
                                )
                                .fill(DesignSystem.Colors.surfaceElevated)
                            }
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: DesignSystem.Radius.md,
                                    style: .continuous
                                )
                                .strokeBorder(
                                    DesignSystem.Colors.border.opacity(0.68),
                                    lineWidth: 0.5
                                )
                            }
                            .accessibilityLabel("Learned content")
                            .accessibilityIdentifier(
                                OBBAccessibilityID.safariLearningEditorContent
                            )

                        Text(
                            "BurnBar stores this as plain, supplemental content. It can never replace system policy, grant tools, or authorize an action. Secret and noise checks run again when you save."
                        )
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                    }

                    if let errorMessage = draft.errorMessage {
                        SafariLearningEditorError(
                            message: errorMessage,
                            showReload: draft.hasConflict,
                            onReload: model.reloadCurrentVersionForEditor
                        )
                    } else if let validationMessage = draft.validationMessage {
                        Label(
                            validationMessage,
                            systemImage: "info.circle"
                        )
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
                .padding(DesignSystem.Spacing.xl)
            }

            Divider()
                .overlay(DesignSystem.Colors.border.opacity(0.58))

            HStack(spacing: DesignSystem.Spacing.md) {
                Spacer()
                Button("Cancel", action: model.cancelEditing)
                    .keyboardShortcut(.cancelAction)
                    .disabled(draft.isSaving)

                Button {
                    Task { await model.saveEdit() }
                } label: {
                    HStack(spacing: DesignSystem.Spacing.sm) {
                        if draft.isSaving {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(draft.isSaving ? "Saving…" : "Save New Version")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.ember)
                .keyboardShortcut(.defaultAction)
                .disabled(!draft.canSave)
                .accessibilityIdentifier(
                    OBBAccessibilityID.safariLearningEditorSave
                )
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .frame(width: 640, height: 590)
        .background(DesignSystem.Colors.background)
        .interactiveDismissDisabled(draft.isSaving)
        .accessibilityIdentifier(OBBAccessibilityID.safariLearningEditor)
    }
}

private struct SafariLearningByteCount: View {
    let count: Int
    let limit: Int

    var body: some View {
        Text("\(count.formatted()) / \(limit.formatted()) bytes")
            .font(DesignSystem.Typography.monoTiny)
            .foregroundStyle(
                count > limit
                    ? DesignSystem.Colors.error
                    : DesignSystem.Colors.textMuted
            )
            .accessibilityLabel("\(count) of \(limit) UTF-8 bytes")
    }
}

private struct SafariLearningEditorError: View {
    let message: String
    let showReload: Bool
    let onReload: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignSystem.Colors.warning)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                Text(verbatim: message)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if showReload {
                    Button("Load Current Version", action: onReload)
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(
                cornerRadius: DesignSystem.Radius.md,
                style: .continuous
            )
            .fill(DesignSystem.Colors.warning.opacity(0.1))
        }
        .overlay {
            RoundedRectangle(
                cornerRadius: DesignSystem.Radius.md,
                style: .continuous
            )
            .strokeBorder(
                DesignSystem.Colors.warning.opacity(0.3),
                lineWidth: 0.5
            )
        }
    }
}

// MARK: - Loading and empty states

private struct SafariLearningLoadingState: View {
    var body: some View {
        VStack(spacing: DesignSystem.Spacing.lg) {
            ProgressView()
                .controlSize(.large)
            Text("Loading your learned timeline…")
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct SafariLearningEmptyState: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.ember.opacity(0.14),
                                DesignSystem.Colors.amber.opacity(0.07),
                                Color.clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 154, height: 154)
                    .blur(radius: 16)
                    .accessibilityHidden(true)

                Image(systemName: icon)
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(DesignSystem.Colors.primaryGradient)
                    .accessibilityHidden(true)
            }

            VStack(spacing: DesignSystem.Spacing.sm) {
                Text(title)
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(message)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(DesignSystem.Spacing.xxl)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Presentation helpers

private extension BurnBarSafariLearningProposalKind {
    var displayName: String {
        switch self {
        case .memory: "Memory"
        case .skill: "Page skill"
        case .siteRule: "Site rule"
        }
    }

    var systemImage: String {
        switch self {
        case .memory: "brain"
        case .skill: "wand.and.stars"
        case .siteRule: "safari"
        }
    }

    var tint: Color {
        switch self {
        case .memory: DesignSystem.Colors.whimsy
        case .skill: DesignSystem.Colors.ember
        case .siteRule: DesignSystem.Colors.amber
        }
    }
}

private extension BurnBarSafariLearningReviewStatus {
    var displayName: String {
        switch self {
        case .proposed: "Proposed"
        case .approved: "Active"
        case .rejected: "Rejected"
        case .archived: "Archived"
        }
    }

    var tint: Color {
        switch self {
        case .proposed: DesignSystem.Colors.amber
        case .approved: DesignSystem.Colors.success
        case .rejected: DesignSystem.Colors.error
        case .archived: DesignSystem.Colors.textMuted
        }
    }
}
