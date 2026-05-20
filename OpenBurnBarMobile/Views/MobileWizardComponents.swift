import SwiftUI
import OpenBurnBarCore

// MARK: - Provider Tile (searchable grid)

/// Brand-tinted gradient card used in the mobile wizard's provider grid.
/// Matches the visual language of the macOS `ProviderPlanWizardView` —
/// gradient stroke, capability chips read from `BurnBarProviderAuthRegistry`,
/// per-provider primary tint, and an "Already connected" affordance.
struct MobileProviderWizardTile: View {
    let provider: AgentProvider
    let capabilityChips: [String]
    let oneLineHint: String
    let isSelected: Bool
    let isAlreadyConnected: Bool
    let isRecommended: Bool
    let onTap: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    private var tint: Color { MobileTheme.Colors.primary(for: provider) }
    private var accent: Color { MobileTheme.Colors.accent(for: provider) }

    private var strokeGradient: LinearGradient {
        LinearGradient(
            colors: [tint.opacity(isSelected ? 0.95 : 0.45), accent.opacity(isSelected ? 0.7 : 0.25)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var fillStyle: AnyShapeStyle {
        if isSelected {
            return AnyShapeStyle(LinearGradient(
                colors: [tint.opacity(colorScheme == .dark ? 0.18 : 0.14), tint.opacity(0.04)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ))
        }
        return AnyShapeStyle(MobileTheme.Colors.surface.opacity(0.85))
    }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                HStack(alignment: .top) {
                    ProviderAvatar(provider: provider, mode: .aurora, size: 44)
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(tint)
                            .transition(.scale.combined(with: .opacity))
                    } else if isAlreadyConnected {
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(MobileTheme.Colors.success)
                    } else if isRecommended {
                        Text("Top pick")
                            .font(MobileTheme.Typography.tiny)
                            .fontWeight(.semibold)
                            .foregroundStyle(tint)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(tint.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }

                Text(provider.displayName)
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(1)

                Text(oneLineHint)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if !capabilityChips.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(capabilityChips, id: \.self) { chip in
                            MobileCapabilityChip(label: chip, tint: tint)
                        }
                    }
                }

                if isAlreadyConnected {
                    Label("Connected", systemImage: "checkmark.seal.fill")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.success)
                }
            }
            .padding(MobileTheme.Spacing.md)
            .frame(maxWidth: .infinity, minHeight: 148, alignment: .topLeading)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(fillStyle)
            )
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .stroke(strokeGradient, lineWidth: isSelected ? 1.6 : 0.6)
            )
            .scaleEffect(isSelected ? 1.02 : 1.0)
            .animation(MobileTheme.Animation.snappy, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var accessibilityLabel: String {
        var parts: [String] = [provider.displayName]
        if isAlreadyConnected { parts.append("Already connected") }
        if isRecommended { parts.append("Top pick") }
        if !capabilityChips.isEmpty { parts.append(capabilityChips.joined(separator: ", ")) }
        parts.append(isSelected ? "Selected" : "Not selected")
        return parts.joined(separator: ", ")
    }
}

// MARK: - Capability Chip

/// Small brand-tinted chip used in tiles and the confirm hero.
struct MobileCapabilityChip: View {
    let label: String
    let tint: Color

    var body: some View {
        Text(label)
            .font(MobileTheme.Typography.tiny)
            .fontWeight(.semibold)
            .foregroundStyle(tint)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(tint.opacity(0.14))
            .overlay(
                Capsule().stroke(tint.opacity(0.35), lineWidth: 0.5)
            )
            .clipShape(Capsule())
    }
}

// MARK: - Auth Method Card

/// Card row used to pick a credential method when a registry descriptor
/// advertises more than one. Replaces `Picker(.menu)` with a tappable
/// card that has icon, summary, helper text, and routing/quota pills.
struct MobileAuthMethodCard: View {
    let method: BurnBarProviderAuthMethod
    let provider: AgentProvider
    let isSelected: Bool
    let onTap: () -> Void

    private var tint: Color { MobileTheme.Colors.primary(for: provider) }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [tint.opacity(0.28), tint.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 38, height: 38)
                    Image(systemName: method.kind.symbolName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(method.displayName)
                            .font(MobileTheme.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(tint)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                    Text(method.summary)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 4) {
                        if method.unlocksProxyRouting {
                            MobileCapabilityChip(label: "Routes on Mac", tint: tint)
                        }
                        if method.unlocksQuotaRefresh {
                            MobileCapabilityChip(label: "Live quota", tint: tint)
                        }
                    }
                    .padding(.top, 2)
                }
                Spacer(minLength: 0)
            }
            .padding(MobileTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.10) : MobileTheme.Colors.surface.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .stroke(isSelected ? tint : MobileTheme.Colors.border, lineWidth: isSelected ? 1.5 : 0.6)
            )
            .animation(MobileTheme.Animation.snappy, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(method.displayName). \(method.summary)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Sync Mode Card

/// Card replacement for the cloud / hosted / self-hosted segmented picker.
struct MobileSyncModeCard: View {
    let mode: QuotaConnectionMode
    let provider: AgentProvider
    let isSelected: Bool
    let onTap: () -> Void

    private var tint: Color { MobileTheme.Colors.primary(for: provider) }

    private var titleText: String {
        switch mode {
        case .cloud: return "Cloud sync"
        case .hosted: return "Hosted Quota Sync"
        case .selfHosted: return "Self-hosted runner"
        }
    }

    private var symbolName: String {
        switch mode {
        case .cloud: return "icloud.fill"
        case .hosted: return "lock.shield.fill"
        case .selfHosted: return "server.rack"
        }
    }

    private var summary: String {
        switch mode {
        case .cloud:      return "Standard cloud credentials. Refreshes from any signed-in device."
        case .hosted:     return "OpenBurnBar stores \(provider.displayName) auth server-side. Quota refreshes only when requested."
        case .selfHosted: return "Your runner handles \(provider.displayName) auth. We only receive sanitized snapshots."
        }
    }

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: MobileTheme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(LinearGradient(
                            colors: [tint.opacity(0.28), tint.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 38, height: 38)
                    Image(systemName: symbolName)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(tint)
                }
                .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(titleText)
                            .font(MobileTheme.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 14, weight: .semibold))
                                .foregroundStyle(tint)
                        }
                    }
                    Text(summary)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(MobileTheme.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(isSelected ? tint.opacity(0.10) : MobileTheme.Colors.surface.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .stroke(isSelected ? tint : MobileTheme.Colors.border, lineWidth: isSelected ? 1.5 : 0.6)
            )
            .animation(MobileTheme.Animation.snappy, value: isSelected)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(titleText). \(summary)")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Validation Chip

/// Animated chip tied to `BurnBarProviderAuthMethod.validate(_:)` results.
/// Shows nothing for `.empty`, success-green for `.ok`, amber for `.warning`.
struct MobileValidationChip: View {
    let validation: BurnBarProviderAuthValidation

    var body: some View {
        if let message = validation.message {
            HStack(spacing: 6) {
                Image(systemName: validation.isOK ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                Text(message)
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.medium)
            }
            .foregroundStyle(validation.isOK ? MobileTheme.Colors.success : MobileTheme.Colors.warning)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill((validation.isOK ? MobileTheme.Colors.success : MobileTheme.Colors.warning).opacity(0.12))
            )
            .transition(.opacity.combined(with: .scale(scale: 0.96)))
        } else {
            EmptyView()
        }
    }
}

// MARK: - Confirm Hero

/// Provider-themed hero card used at the top of the credential entry and
/// review steps. Brand gradient stroke + ProviderAvatar(.aurora) + capability
/// chips read from the registry.
struct MobileProviderConfirmHero: View {
    let provider: AgentProvider
    let title: String
    let subtitle: String
    let capabilityChips: [String]
    let maskedCredential: String?

    private var tint: Color { MobileTheme.Colors.primary(for: provider) }
    private var accent: Color { MobileTheme.Colors.accent(for: provider) }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            HStack(alignment: .center, spacing: MobileTheme.Spacing.md) {
                ProviderAvatar(provider: provider, mode: .aurora, size: 52)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(MobileTheme.Typography.title)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }

            if !capabilityChips.isEmpty {
                HStack(spacing: 4) {
                    ForEach(capabilityChips, id: \.self) { chip in
                        MobileCapabilityChip(label: chip, tint: tint)
                    }
                }
            }

            if let maskedCredential, !maskedCredential.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                    Text(maskedCredential)
                        .font(MobileTheme.Typography.monoSmall)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    Capsule().fill(MobileTheme.Colors.surfaceElevated)
                )
            }
        }
        .padding(MobileTheme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(LinearGradient(
                    colors: [tint.opacity(0.18), accent.opacity(0.08), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(LinearGradient(
                    colors: [tint.opacity(0.7), accent.opacity(0.4)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ), lineWidth: 1)
        )
    }
}

// MARK: - Wizard Progress Dots

struct MobileWizardProgressDots: View {
    let total: Int
    let active: Int
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<total, id: \.self) { index in
                Capsule()
                    .fill(index <= active ? tint : MobileTheme.Colors.border)
                    .frame(width: index == active ? 18 : 6, height: 6)
                    .animation(MobileTheme.Animation.snappy, value: active)
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Helpers

func mobileMaskCredential(_ credential: String) -> String {
    let trimmed = credential.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty { return "" }
    if trimmed.count <= 8 { return String(repeating: "•", count: trimmed.count) }
    let prefix = trimmed.prefix(4)
    let suffix = trimmed.suffix(4)
    let dotCount = max(4, min(trimmed.count - 8, 24))
    return "\(prefix)\(String(repeating: "•", count: dotCount))\(suffix)"
}
