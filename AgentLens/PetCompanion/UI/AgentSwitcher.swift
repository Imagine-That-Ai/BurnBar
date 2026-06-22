import SwiftUI

// MARK: - PetAgentSwitcher

/// A standalone control to switch the pet's answering agent (PLAN C7), reusing
/// the app's ``ChatBackendID`` exactly as the in-bubble picker does. It persists
/// the choice to `@AppStorage("pet.activeAgent")` so the selection restores
/// across launches, and reports the switch up so the live ``PetChatController``
/// can cancel any in-flight stream and replay history to the new brain.
///
/// This is the reusable surface behind both the bubble header's inline picker and
/// the onboarding agent step. Mid-reply switching semantics (cancel + replay)
/// live in ``PetChatController/switchBackend(to:)``; this view just drives the
/// selection and persistence.
struct PetAgentSwitcher: View {
    /// The persisted active agent (same key PLAN C7 names).
    @AppStorage(PetCompanionFeature.DefaultsKey.activeAgent)
    private var activeAgentRaw = ChatBackendID.codex.rawValue

    /// Optional live auth states keyed by backend (from onboarding's probe), used
    /// to dim unauthenticated brains. Empty = no gating.
    var authStates: [ChatBackendID: PetAuthStatus] = [:]

    /// Backends offered by the host. Empty preserves the legacy all-backends
    /// fallback used before Settings had an enabled-engine list.
    var backends: [ChatBackendID] = ChatBackendID.allCases

    /// Called after the selection changes, so the host can route it into the live
    /// ``PetChatController``.
    var onSwitch: (ChatBackendID) -> Void = { _ in }

    private var offeredBackends: [ChatBackendID] {
        backends.isEmpty ? ChatBackendID.allCases : backends
    }

    private var active: ChatBackendID {
        let persisted = ChatBackendID(rawValue: activeAgentRaw) ?? .codex
        return offeredBackends.contains(persisted) ? persisted : offeredBackends.first ?? persisted
    }

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            ForEach(offeredBackends) { backend in
                row(for: backend)
            }
        }
    }

    private func row(for backend: ChatBackendID) -> some View {
        let isActive = backend == active
        let status = authStates[backend]
        return Button {
            guard backend != active else { return }
            activeAgentRaw = backend.rawValue
            onSwitch(backend)
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: isActive ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isActive ? AnyShapeStyle(DesignSystem.Colors.primaryGradient)
                                              : AnyShapeStyle(DesignSystem.Colors.textMuted))
                Text(backend.displayName)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer(minLength: 0)
                if let status { authChip(status) }
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, DesignSystem.Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(isActive ? DesignSystem.Colors.surface.opacity(0.7) : .clear)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(backend.displayName)
        .accessibilityValue(status?.label ?? (isActive ? "selected" : ""))
        .accessibilityAddTraits(isActive ? [.isSelected] : [])
    }

    @ViewBuilder
    private func authChip(_ status: PetAuthStatus) -> some View {
        let color: Color = {
            switch status {
            case .ready: return DesignSystem.Colors.success
            case .needsLogin: return DesignSystem.Colors.warning
            case .error: return DesignSystem.Colors.error
            case .unknown: return DesignSystem.Colors.textMuted
            }
        }()
        HStack(spacing: DesignSystem.Spacing.xxs) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(status.label)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }
}
