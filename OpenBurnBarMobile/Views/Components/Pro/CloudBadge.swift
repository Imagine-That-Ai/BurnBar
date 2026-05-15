import SwiftUI
import OpenBurnBarCore

// MARK: - Cloud Badge
//
// User-selectable Cloud Member brand mark. Each style is a vector PDF in the
// asset catalog; the same `CloudBadge` view renders whichever style the user
// chose. Members can swap between styles from the badge picker on the
// Cloud destination — more styles will be added later. Free users see the
// default helmet via the catalog entries until the entitlement flips.
//
// The selected style is persisted in `UserDefaults` under the key
// `cloud.badge.style` so it survives launches and syncs into the You-tab,
// nav tray, and store hero on every render.

enum CloudBadgeStyle: String, CaseIterable, Identifiable, Hashable {
    case shield     = "shield"
    case waxSeal    = "wax_seal"
    case brassCoin  = "brass_coin"
    case sunDisc    = "sun_disc"

    var id: String { rawValue }

    /// Display name surfaced in the picker.
    var title: String {
        switch self {
        case .shield:    return "Silver Shield"
        case .waxSeal:   return "Wax Seal"
        case .brassCoin: return "Brass Signet"
        case .sunDisc:   return "Sun Disc"
        }
    }

    /// Short one-line characterization for the picker.
    var blurb: String {
        switch self {
        case .shield:    return "Pewter heraldry — clean, classic."
        case .waxSeal:   return "Coral wax + silver flame — handcrafted."
        case .brassCoin: return "Engraved brass coin — coveted signet."
        case .sunDisc:   return "Obsidian sunburst — ornate and cinematic."
        }
    }

    /// Asset name in the iOS asset catalog (vector PDF imageset).
    var assetName: String {
        switch self {
        case .shield:    return "CloudBadgeShield"
        case .waxSeal:   return "CloudBadgeWaxSeal"
        case .brassCoin: return "CloudBadgeBrassCoin"
        case .sunDisc:   return "CloudBadgeSunDisc"
        }
    }

    static var defaultStyle: CloudBadgeStyle { .brassCoin }
}

// MARK: - Selection store
//
// `@AppStorage` keeps the choice in `UserDefaults`. Phase B can promote this
// into the user's Firestore profile so the badge follows across devices —
// the API of `selectedStyle` stays the same.

private enum CloudBadgeDefaults {
    static let key = "cloud.badge.style"
}

extension View {
    /// Convenience for surfaces that need to react to badge changes.
    func cloudBadgePicker(isPresented: Binding<Bool>) -> some View {
        sheet(isPresented: isPresented) {
            NavigationStack {
                CloudBadgePicker()
            }
            .presentationDetents([.medium, .large])
        }
    }
}

// MARK: - Badge view

/// Renders the user's currently selected badge at any size. Designed to be a
/// drop-in replacement for the previous `FirefighterHelmet` and `MercuryCrest`
/// callsites — pass the size you want, the rest is automatic.
struct CloudBadge: View {
    enum Size {
        case small   // 24pt — nav tray, list rows
        case medium  // 48pt — member row, store hero badge
        case large   // 96pt — destination hero
        case custom(CGFloat)

        var diameter: CGFloat {
            switch self {
            case .small:           return 28
            case .medium:          return 56
            case .large:           return 104
            case .custom(let d):   return d
            }
        }
    }

    var size: Size = .medium
    /// Override the persisted style — used by the picker preview so each
    /// option can render the badge it represents.
    var styleOverride: CloudBadgeStyle? = nil

    @AppStorage(CloudBadgeDefaults.key) private var storedRaw: String = CloudBadgeStyle.defaultStyle.rawValue

    private var resolvedStyle: CloudBadgeStyle {
        styleOverride ?? CloudBadgeStyle(rawValue: storedRaw) ?? .defaultStyle
    }

    var body: some View {
        Image(resolvedStyle.assetName)
            .resizable()
            .renderingMode(.original)
            .scaledToFit()
            .frame(width: size.diameter, height: size.diameter)
            .shadow(color: MobileTheme.ember.opacity(0.40), radius: size.diameter * 0.12, y: size.diameter * 0.04)
            .accessibilityLabel("OpenBurnBar Cloud member badge")
    }
}

// MARK: - Badge picker

/// Sheet that lets members preview and pick a badge. Persists to UserDefaults
/// via `@AppStorage`. Layout: a 2-column grid of tappable tiles, each with
/// the badge centered in a warm aurora glass cell + the title underneath.

struct CloudBadgePicker: View {
    @AppStorage(CloudBadgeDefaults.key) private var storedRaw: String = CloudBadgeStyle.defaultStyle.rawValue
    @Environment(\.dismiss) private var dismiss

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    var body: some View {
        ZStack {
            EmberSurfaceBackground()
                .ignoresSafeArea()

            ScrollView {
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                    header
                    LazyVGrid(columns: columns, spacing: 16) {
                        ForEach(CloudBadgeStyle.allCases) { style in
                            CloudBadgePickerTile(
                                style: style,
                                isSelected: storedRaw == style.rawValue
                            ) {
                                Haptics.selection()
                                storedRaw = style.rawValue
                            }
                        }
                    }
                    .padding(.horizontal, MobileTheme.Spacing.lg)

                    Text("Your badge appears on the You tab, the bottom nav, and the Cloud destination — across every device you sign in on.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .padding(.horizontal, MobileTheme.Spacing.lg)
                        .padding(.bottom, MobileTheme.Spacing.xl)
                }
                .padding(.top, MobileTheme.Spacing.lg)
            }
        }
        .navigationTitle("Cloud Badge")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
                    .foregroundStyle(MobileTheme.ember)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PICK YOUR BADGE")
                .font(MobileTheme.Typography.caption)
                .fontWeight(.heavy)
                .tracking(2.0)
                .foregroundStyle(MobileTheme.amber)
            Text("Wear your fire.")
                .font(MobileTheme.Typography.display)
                .foregroundStyle(MobileTheme.primaryGradient)
            Text("Four to start — more arrive with each major Cloud release.")
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, MobileTheme.Spacing.lg)
    }
}

// MARK: - Picker tile

private struct CloudBadgePickerTile: View {
    let style: CloudBadgeStyle
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: MobileTheme.Spacing.md) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    MobileTheme.ember.opacity(isSelected ? 0.32 : 0.14),
                                    MobileTheme.amber.opacity(isSelected ? 0.26 : 0.10),
                                    MobileTheme.blaze.opacity(isSelected ? 0.20 : 0.08)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    CloudBadge(size: .custom(108), styleOverride: style)
                }
                .frame(height: 156)
                .overlay(
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: isSelected
                                    ? [MobileTheme.amber, MobileTheme.ember, MobileTheme.amber]
                                    : [MobileTheme.Colors.border.opacity(0.45), MobileTheme.Colors.border.opacity(0.25)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isSelected ? 1.6 : 0.7
                        )
                )
                .shadow(color: MobileTheme.ember.opacity(isSelected ? 0.35 : 0.10), radius: isSelected ? 18 : 6, y: 4)

                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(MobileTheme.ember)
                        }
                        Text(style.title)
                            .font(MobileTheme.Typography.headline)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                    }
                    Text(style.blurb)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(style.title). \(style.blurb)\(isSelected ? ", selected" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }
}

// MARK: - Preview

#Preview("Cloud badge picker") {
    NavigationStack {
        CloudBadgePicker()
    }
}
