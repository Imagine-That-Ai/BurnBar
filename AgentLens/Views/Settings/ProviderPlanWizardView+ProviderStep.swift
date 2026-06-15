import AppKit
import SwiftUI
import OpenBurnBarCore

// MARK: - Plan Strategy

// Provider selection step.
// Extracted from ProviderPlanWizardView.swift (god-type decomposition) — same module, same isolation, verbatim.

extension ProviderPlanWizardView {

    @ViewBuilder
    func slotButton(
        _ symbol: String,
        help: String,
        tint: Color = DesignSystem.Colors.textSecondary,
        disabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(disabled ? DesignSystem.Colors.textMuted : tint)
                .frame(width: 26, height: 26)
                .background(DesignSystem.Colors.surfaceElevated)
                .clipShape(Circle())
                .overlay(Circle().strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.65 : 1)
        .help(help)
    }

    @ViewBuilder
    func addPlanCTA(providerID: String) -> some View {
        let provider = daemonManager.providerConfigurations.first { $0.providerID == providerID }
        let title = provider?.credentialSlots.isEmpty == true && provider?.hasRoutingCapability == true
            ? "Add route credential"
            : "Add another account"

        Button {
            startAddFlow(providerID: providerID)
        } label: {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: "plus.circle.fill")
                    .font(.system(size: 16, weight: .semibold))
                Text(title)
                    .font(DesignSystem.Typography.body)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSystem.Spacing.sm + 2)
            .background(stepAccentGradient)
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    func slotStatusColor(for status: BurnBarProviderCredentialSlotStatus) -> Color {
        switch status {
        case .ready: return DesignSystem.Colors.success
        case .coolingDown: return DesignSystem.Colors.warning
        case .exhausted, .missingSecret: return DesignSystem.Colors.error
        case .disabled: return DesignSystem.Colors.textMuted
        }
    }

    @ViewBuilder
    var providerSelectionStep: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            providerSearchField

            if filteredProviders.isEmpty {
                emptySearchNotice
            } else {
                if !routingProviders.isEmpty {
                    sectionHeader("Routed proxy", subtitle: "Connect once and proxy traffic round-robins across plans.")
                    providerGrid(routingProviders)
                }

                if !trackingProviders.isEmpty {
                    sectionHeader("Quota & tracking", subtitle: "Connect for live quota and usage tracking.", topPadding: routingProviders.isEmpty ? 0 : DesignSystem.Spacing.lg)
                    providerGrid(trackingProviders)
                }
            }
        }
    }

    @ViewBuilder
    var providerSearchField: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            TextField("Search providers", text: $providerSearchQuery)
                .textFieldStyle(.plain)
                .font(DesignSystem.Typography.body)
                .foregroundStyle(DesignSystem.Colors.textPrimary)
            if !providerSearchQuery.isEmpty {
                Button { providerSearchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, DesignSystem.Spacing.md)
        .padding(.vertical, DesignSystem.Spacing.sm + 2)
        .background(DesignSystem.Colors.surface)
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .strokeBorder(DesignSystem.Colors.border, lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous))
    }

    @ViewBuilder
    var emptySearchNotice: some View {
        VStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text("No providers match \"\(providerSearchQuery)\"")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(DesignSystem.Spacing.xl)
    }

    @ViewBuilder
    func sectionHeader(_ title: String, subtitle: String? = nil, topPadding: CGFloat = 0) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
            if let subtitle {
                Text(subtitle)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
            }
        }
        .padding(.top, topPadding)
    }

    @ViewBuilder
    func providerGrid(_ providers: [OpenBurnBarDaemonProviderConfiguration]) -> some View {
        let columns = [
            GridItem(.flexible(), spacing: DesignSystem.Spacing.sm),
            GridItem(.flexible(), spacing: DesignSystem.Spacing.sm)
        ]
        LazyVGrid(columns: columns, spacing: DesignSystem.Spacing.sm) {
            ForEach(providers) { provider in
                providerTile(provider)
            }
        }
    }

    @ViewBuilder
    func providerTile(_ config: OpenBurnBarDaemonProviderConfiguration) -> some View {
        let isSelected = selectedProviderID == config.providerID
        let descriptor = self.descriptor(for: config.providerID)
        let primary = ProviderBrand.colorForProviderID(config.providerID)
        let accountCount = providerAccountCount(config)

        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                selectedProviderID = config.providerID
                selectedAuthMethodID = descriptor.primaryMethod.id
            }
        } label: {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .fill(LinearGradient(
                                colors: [primary.opacity(0.32), primary.opacity(0.08)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ))
                            .frame(width: 40, height: 40)
                        CatalogProviderLogoView(brand: config.brand, size: 26)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text(config.displayName)
                            .font(DesignSystem.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                        if accountCount == 0 {
                            Text("Not connected")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        } else {
                            Text("\(accountCount) account\(accountCount == 1 ? "" : "s")")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                        }
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(primary)
                            .transition(.scale.combined(with: .opacity))
                    }
                }

                Text(descriptor.summary)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 4) {
                    if descriptor.supportsProxyRouting {
                        miniChip("Routing", system: "arrow.triangle.swap", tint: DesignSystem.Colors.blaze)
                    }
                    if descriptor.supportsQuotaRefresh {
                        miniChip("Quota", system: "gauge.with.needle", tint: DesignSystem.Colors.success)
                    }
                    Spacer()
                }
            }
            .padding(DesignSystem.Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(isSelected ? primary.opacity(0.10) : DesignSystem.Colors.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: isSelected
                                ? [primary, primary.opacity(0.6)]
                                : [DesignSystem.Colors.border, DesignSystem.Colors.border.opacity(0.5)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: isSelected ? 1.5 : 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
    }
}
