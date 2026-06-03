import SwiftUI
import OpenBurnBarCore

// MARK: - Basin Hero
//
// Compact summary of the whole vault: tier badge, a tier-split bar showing how
// many domains are end-to-end / zero-access / server-readable, and the headline
// promise. Reads the generated registry so the split is always accurate.

struct DataVaultBasinHero: View {
    let tier: String
    let domains: [DataDomain]
    let usageByDomain: [String: DataDomainUsageRow]

    private var counts: (e2e: Int, zero: Int, server: Int) {
        domains.reduce(into: (0, 0, 0)) { acc, domain in
            switch domain.encryptionTier {
            case .endToEnd: acc.0 += 1
            case .zeroAccess: acc.1 += 1
            case .serverReadable: acc.2 += 1
            }
        }
    }

    private var sealedCount: Int { counts.e2e + counts.zero }

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 22, padding: MobileTheme.Spacing.lg) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("YOUR DATA, SEALED")
                            .font(MobileTheme.Typography.tiny)
                            .fontWeight(.heavy)
                            .tracking(1.8)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                        Text("The Basin")
                            .font(MobileTheme.Typography.display)
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        EncryptionTier.endToEnd.tierColor,
                                        EncryptionTier.serverReadable.tierColor,
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                    }
                    Spacer()
                    DataTierBadge(tier: tier)
                }

                Text("\(sealedCount) of \(domains.count) data kinds are sealed — the server stores ciphertext it can't open. \(counts.server) are metadata-only for your cockpit.")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                tierSplitBar
            }
        }
    }

    private var tierSplitBar: some View {
        GeometryReader { geo in
            HStack(spacing: 3) {
                segment(width: geo.size.width, count: counts.e2e, tier: .endToEnd)
                segment(width: geo.size.width, count: counts.zero, tier: .zeroAccess)
                segment(width: geo.size.width, count: counts.server, tier: .serverReadable)
            }
        }
        .frame(height: 10)
        .clipShape(Capsule(style: .continuous))
    }

    private func segment(width: CGFloat, count: Int, tier: EncryptionTier) -> some View {
        let fraction = domains.isEmpty ? 0 : CGFloat(count) / CGFloat(domains.count)
        return Capsule(style: .continuous)
            .fill(tier.tierColor)
            .frame(width: max(0, width * fraction - 3))
    }
}

// MARK: - Tier badge

struct DataTierBadge: View {
    let tier: String

    private var label: String {
        switch tier {
        case "ultra": return "ULTRA"
        case "pro": return "CLOUD PRO"
        default: return "FREE"
        }
    }

    private var accent: Color {
        switch tier {
        case "ultra": return EncryptionTier.endToEnd.tierColor
        case "pro": return EncryptionTier.serverReadable.tierColor
        default: return MobileTheme.Colors.textMuted
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .heavy, design: .rounded))
            .tracking(1.2)
            .foregroundStyle(tier == "free" ? MobileTheme.Colors.textMuted : .black)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(tier == "free" ? accent.opacity(0.18) : accent.opacity(0.95))
            )
    }
}

// MARK: - Inventory row

struct DataDomainInventoryRow: View {
    let domain: DataDomain
    let usage: DataDomainUsageRow?
    let isLoading: Bool

    var body: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            HStack(spacing: 12) {
                Image(systemName: domain.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(domain.encryptionTier.tierColor)
                    .frame(width: 42, height: 42)
                    .background(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(domain.encryptionTier.tierColor.opacity(0.16))
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text(domain.title)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    HStack(spacing: 5) {
                        Image(systemName: domain.encryptionTier.lockSymbol)
                            .font(.system(size: 9, weight: .bold))
                        Text(domain.encryptionTier.shortLabel)
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .tracking(0.4)
                    }
                    .foregroundStyle(domain.encryptionTier.tierColor)

                    Text(usageLabel)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }

                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            .contentShape(Rectangle())
        }
    }

    private var usageLabel: String {
        guard let usage else { return isLoading ? "Counting…" : "—" }
        var label = DataVaultFormat.count(usage.count, noun: "item")
        if usage.bytes > 0 { label += " · \(DataVaultFormat.bytes(usage.bytes))" }
        return label
    }
}

// MARK: - Pensieve cap meters

struct PensieveCapMeters: View {
    let limits: PensieveLimitsDTO
    let usage: DataDomainUsageRow
    let tier: String

    var body: some View {
        VStack(spacing: 8) {
            meter(label: "Chunks", value: usage.count, limit: limits.chunks, formatted: "\(usage.count) / \(limits.chunks)")
            meter(label: "Storage", value: usage.bytes, limit: limits.bytes, formatted: "\(DataVaultFormat.bytes(usage.bytes)) / \(DataVaultFormat.bytes(limits.bytes))")
        }
    }

    private func meter(label: String, value: Int, limit: Int, formatted: String) -> some View {
        let fraction = limit > 0 ? min(1, Double(value) / Double(limit)) : 0
        let nearCap = fraction >= 0.9
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                Spacer()
                Text(formatted)
                    .font(MobileTheme.Typography.monoTiny)
                    .foregroundStyle(nearCap ? EncryptionTier.serverReadable.tierColor : MobileTheme.Colors.textMuted)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(MobileTheme.Colors.textMuted.opacity(0.15))
                    Capsule()
                        .fill(nearCap ? EncryptionTier.serverReadable.tierColor : EncryptionTier.endToEnd.tierColor)
                        .frame(width: max(0, geo.size.width * fraction))
                }
            }
            .frame(height: 6)
        }
    }
}

// MARK: - Action rows

struct DataVaultActionRow: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    let action: () -> Void

    var body: some View {
        Button {
            HapticBus.chipChange()
            action()
        } label: {
            DataVaultActionRowChrome(title: title, subtitle: subtitle, icon: icon, tint: tint)
        }
        .buttonStyle(.plain)
    }
}

struct DataVaultActionRowChrome: View {
    let title: String
    let subtitle: String
    let icon: String
    let tint: Color
    var isDestructive = false
    var showsBusy = false

    var body: some View {
        AuroraGlassCard(variant: isDestructive ? .urgent : .standard, cornerRadius: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(tint.opacity(0.16))
                        .frame(width: 42, height: 42)
                    if showsBusy {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: icon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(tint)
                    }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(isDestructive ? tint : MobileTheme.Colors.textPrimary)
                    Text(subtitle)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            .contentShape(Rectangle())
        }
    }
}
