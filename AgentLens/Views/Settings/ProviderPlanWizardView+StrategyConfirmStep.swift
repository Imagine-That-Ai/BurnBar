import AppKit
import SwiftUI
import OpenBurnBarCore

// MARK: - Plan Strategy

// Strategy and confirm steps.
// Extracted from ProviderPlanWizardView.swift (god-type decomposition) — same module, same isolation, verbatim.

extension ProviderPlanWizardView {

    @ViewBuilder
    func liveValidationView(_ method: BurnBarProviderAuthMethod) -> some View {
        let validation = method.validate(apiKeyInput)
        if let message = validation.message {
            HStack(spacing: 4) {
                Image(systemName: validation.isWarning ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                    .font(.system(size: 10, weight: .semibold))
                Text(message)
                    .font(DesignSystem.Typography.tiny)
            }
            .foregroundStyle(validation.isWarning ? DesignSystem.Colors.warning : DesignSystem.Colors.success)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background((validation.isWarning ? DesignSystem.Colors.warning : DesignSystem.Colors.success).opacity(0.10))
            .clipShape(Capsule())
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    @ViewBuilder
    func liveQuotaProbeView() -> some View {
        if isProbingQuota {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("Probing live quota…")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(DesignSystem.Colors.surfaceElevated.opacity(0.6))
            .clipShape(Capsule())
        } else if let result = quotaProbeResult {
            HStack(spacing: 6) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.success)
                Text(result)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(DesignSystem.Colors.success.opacity(0.12))
            .clipShape(Capsule())
        } else if let error = quotaProbeError {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.warning)
                Text(error)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(DesignSystem.Colors.warning.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
    }

    @ViewBuilder
    var strategySelectionStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            if let provider = selectedProvider {
                providerStripHeader(provider)
            }

            Text("How should this account be used?")
                .font(DesignSystem.Typography.body)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textPrimary)

            Text("OpenBurnBar fails over deterministically when a plan hits its quota or returns an auth error.")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)

            VStack(spacing: DesignSystem.Spacing.sm) {
                ForEach(ProviderPlanStrategy.allCases) { strategy in
                    strategyCard(strategy)
                }
            }
        }
    }

    @ViewBuilder
    func strategyCard(_ strategy: ProviderPlanStrategy) -> some View {
        let isSelected = selectedStrategy == strategy
        let primary: Color = selectedProviderID
            .map { ProviderBrand.colorForProviderID($0) } ?? DesignSystem.Colors.blaze

        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedStrategy = strategy
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                        .fill(LinearGradient(
                            colors: isSelected
                                ? [primary, primary.opacity(0.6)]
                                : [DesignSystem.Colors.surfaceElevated, DesignSystem.Colors.surfaceElevated],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 48, height: 48)
                    Image(systemName: strategy.iconName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isSelected ? .white : DesignSystem.Colors.textSecondary)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(strategy.displayName)
                        .font(DesignSystem.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(strategy.summary)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                }

                Spacer()

                strategyDiagram(for: strategy, primary: primary, selected: isSelected)
            }
            .padding(DesignSystem.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(isSelected ? primary.opacity(0.08) : DesignSystem.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(
                        isSelected ? primary : DesignSystem.Colors.border,
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
    }

    @ViewBuilder
    func strategyDiagram(for strategy: ProviderPlanStrategy, primary: Color, selected: Bool) -> some View {
        switch strategy {
        case .auto:
            HStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { index in
                    Capsule()
                        .fill(selected ? primary.opacity(0.85 - Double(index) * 0.2) : DesignSystem.Colors.textMuted.opacity(0.4))
                        .frame(width: 8, height: 16)
                }
            }
        case .preferred:
            HStack(spacing: 3) {
                Capsule().fill(selected ? primary : DesignSystem.Colors.textMuted.opacity(0.4)).frame(width: 12, height: 18)
                Capsule().fill(DesignSystem.Colors.textMuted.opacity(0.3)).frame(width: 8, height: 12)
                Capsule().fill(DesignSystem.Colors.textMuted.opacity(0.3)).frame(width: 8, height: 12)
            }
        case .backup:
            HStack(spacing: 3) {
                Capsule().fill(DesignSystem.Colors.textMuted.opacity(0.3)).frame(width: 8, height: 14)
                Capsule().fill(DesignSystem.Colors.textMuted.opacity(0.3)).frame(width: 8, height: 14)
                Capsule().fill(selected ? primary.opacity(0.7) : DesignSystem.Colors.textMuted.opacity(0.4)).frame(width: 8, height: 14)
            }
        }
    }

    @ViewBuilder
    var confirmStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            if let provider = selectedProvider {
                confirmHeroCard(provider)
            }

            confirmDetailRows

            if let error = saveError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(DesignSystem.Colors.error)
                    Text(error)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.error)
                }
                .padding(.horizontal, DesignSystem.Spacing.md)
                .padding(.vertical, DesignSystem.Spacing.sm)
                .background(DesignSystem.Colors.error.opacity(0.10))
                .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
            }

            Text("OpenBurnBar stores your credentials in the macOS Keychain and the daemon socket. Connect once, used everywhere.")
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(DesignSystem.Colors.textMuted)
        }
    }

    @ViewBuilder
    func confirmHeroCard(_ provider: OpenBurnBarDaemonProviderConfiguration) -> some View {
        let primary = ProviderBrand.colorForProviderID(provider.providerID)
        let descriptor = self.descriptor(for: provider.providerID)

        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(LinearGradient(
                            colors: [primary, primary.opacity(0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ))
                        .frame(width: 64, height: 64)
                        .shadow(color: primary.opacity(0.4), radius: 12, x: 0, y: 4)
                    CatalogProviderLogoView(brand: provider.brand, size: 40)
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(provider.displayName)
                        .font(DesignSystem.Typography.title)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text(planLabel.isEmpty ? "Untitled plan" : planLabel)
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    if let method = selectedAuthMethod {
                        HStack(spacing: 4) {
                            Image(systemName: method.kind.symbolName).font(.system(size: 9, weight: .semibold))
                            Text(method.displayName).font(DesignSystem.Typography.tiny).fontWeight(.semibold)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(primary.opacity(0.18))
                        .foregroundStyle(primary)
                        .clipShape(Capsule())
                    }
                }
                Spacer()
            }

            Text(descriptor.summary)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .padding(DesignSystem.Spacing.lg)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .fill(DesignSystem.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [primary.opacity(0.6), primary.opacity(0.0)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        )
    }

    @ViewBuilder
    var confirmDetailRows: some View {
        VStack(spacing: 0) {
            confirmRow(symbol: "key.fill", label: "Credential", value: maskedKey)
            divider
            confirmRow(symbol: "tag.fill", label: "Label", value: planLabel.trimmingCharacters(in: .whitespacesAndNewlines))
            divider
            confirmRow(symbol: selectedStrategy.iconName, label: "Strategy", value: selectedStrategy.displayName)
            divider
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "gauge.with.needle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .frame(width: 18)
                Text("Live quota")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Spacer()
                if let result = quotaProbeResult {
                    Text(result)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.success)
                } else if isProbingQuota {
                    ProgressView().controlSize(.mini)
                } else if let method = selectedAuthMethod, !method.unlocksQuotaRefresh {
                    Text("Tracking only")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } else {
                    Text("Will probe after save")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            .padding(DesignSystem.Spacing.md)
        }
        .background(DesignSystem.Colors.surface)
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
        )
    }
}
