import SwiftUI
import OpenBurnBarCore

// MARK: - Settings Copilot View

/// The detail-pane view for the Copilot. Renders:
/// - Tier 1 instant search results (when the query matches the manifest)
/// - Tier 2 agentic response (when the user asks a question)
/// - Proposed action confirm chips
/// - Empty state with "Ask Copilot" CTA
struct SettingsCopilotResultsView: View {
    @Bindable var router: SettingsRouter
    @Bindable var copilot: SettingsCopilotController

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                // Tier 2: Streaming / completed response
                if copilot.phase == .streaming || !copilot.streamedText.isEmpty {
                    copilotResponseSection
                }

                // Proposed action confirm chips
                if !copilot.proposedActions.isEmpty {
                    proposedActionsSection
                }

                // Error state
                if case .error(let message) = copilot.phase {
                    copilotErrorView(message)
                }

                // Tier 1: Instant search results
                if !copilot.searchResults.isEmpty {
                    instantResultsSection
                }

                // Empty state
                if copilot.searchResults.isEmpty && copilot.streamedText.isEmpty &&
                   copilot.proposedActions.isEmpty && copilot.phase != .streaming {
                    if case .error = copilot.phase {
                        EmptyView()
                    } else {
                        emptyState
                    }
                }
            }
            .padding(DesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(DesignSystem.Colors.background)
        .scrollContentBackground(.hidden)
        .navigationTitle("Copilot")
    }

    // MARK: - Copilot response

    @ViewBuilder
    private var copilotResponseSection: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.xs) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.hermesAureate)
                    Text("Copilot")
                        .font(DesignSystem.Typography.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    if copilot.phase == .streaming {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Spacer()
                }

                if copilot.phase == .streaming && copilot.streamedText.isEmpty {
                    // Mercury-style thinking dots
                    MercuryPoolDots()
                } else {
                    Text(copilot.streamedText)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    // MARK: - Proposed actions

    @ViewBuilder
    private var proposedActionsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("Proposed changes")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            ForEach(copilot.proposedActions) { action in
                CopilotActionChip(
                    action: action,
                    isApplied: copilot.appliedActionIDs.contains(action.id),
                    onConfirm: { copilot.confirmAction(id: action.id) },
                    onDismiss: { copilot.dismissAction(id: action.id) }
                )
            }
        }
    }

    // MARK: - Error

    private func copilotErrorView(_ message: String) -> some View {
        GlassCard {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(DesignSystem.Colors.warning)
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xxs) {
                    Text("Copilot unavailable")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(message)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
            }
            .padding(DesignSystem.Spacing.lg)
        }
    }

    // MARK: - Instant results

    @ViewBuilder
    private var instantResultsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            Text("\(copilot.searchResults.count) setting\(copilot.searchResults.count == 1 ? "" : "s") match")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)

            ForEach(copilot.searchResults) { item in
                Button {
                    router.navigate(to: item)
                } label: {
                    SettingsDrillRow(
                        icon: item.tab.icon,
                        iconTint: item.tab.accentColor,
                        title: item.title,
                        subtitle: item.subtitle,
                        logoProviders: item.logoProviders
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: DesignSystem.Spacing.md) {
            Spacer(minLength: 40)

            Image(systemName: "sparkles")
                .font(.system(size: 36, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.hermesAureate)

            Text("Ask the Settings Copilot")
                .font(DesignSystem.Typography.headline)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("Type a question above — try \"make it dark\", \"expose my models to Cursor\", or \"enable auto summaries\".")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
                .fixedSize(horizontal: false, vertical: true)

            exampleChips

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var exampleChips: some View {
        VStack(spacing: DesignSystem.Spacing.xs) {
            ForEach([
                "Switch to dark mode",
                "Turn on the model proxy",
                "Enable conversation indexing",
                "How do I add an API key?"
            ], id: \.self) { suggestion in
                Button {
                    router.query = suggestion
                    Task { await copilot.ask(suggestion) }
                } label: {
                    Text(suggestion)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .padding(.horizontal, DesignSystem.Spacing.md)
                        .padding(.vertical, DesignSystem.Spacing.xs)
                        .background(
                            Capsule()
                                .fill(DesignSystem.Colors.surface.opacity(0.5))
                                .overlay(
                                    Capsule()
                                        .stroke(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.5)
                                )
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Copilot Action Chip

/// A single proposed action with Confirm and Dismiss buttons.
struct CopilotActionChip: View {
    let action: SettingsActionRegistry.Action
    let isApplied: Bool
    let onConfirm: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.hermesAureate.opacity(0.16))
                    .frame(width: 28, height: 28)
                Image(systemName: isApplied ? "checkmark.circle.fill" : "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(isApplied ? DesignSystem.Colors.success : DesignSystem.Colors.hermesAureate)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(action.title)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(action.detail)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .layoutPriority(1)

            Spacer()

            if isApplied {
                Text("Applied")
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.success)
            } else {
                Button("Confirm") { onConfirm() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(DesignSystem.Colors.blaze)

                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(DesignSystem.Colors.surfaceElevated.opacity(0.36))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
    }
}
