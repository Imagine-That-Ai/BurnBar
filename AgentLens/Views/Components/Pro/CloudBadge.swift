import SwiftUI
import OpenBurnBarCore

// MARK: - Cloud Badge (macOS)
//
// Parity with `OpenBurnBarMobile/Views/Components/Pro/CloudBadge.swift`.
// Four vector PDFs live in `AgentLens/Resources/Assets.xcassets` under
// `CloudBadge*.imageset`; the same `CloudBadge` view renders whichever
// style the user picked. Selection persists via `@AppStorage` under
// the same key as iOS so a member who picks a badge on iPhone sees
// the same one on the Mac as soon as the preference flushes.

enum CloudBadgeStyle: String, CaseIterable, Identifiable, Hashable {
    case shield    = "shield"
    case waxSeal   = "wax_seal"
    case brassCoin = "brass_coin"
    case sunDisc   = "sun_disc"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .shield:    return "Silver Shield"
        case .waxSeal:   return "Wax Seal"
        case .brassCoin: return "Brass Signet"
        case .sunDisc:   return "Sun Disc"
        }
    }

    var blurb: String {
        switch self {
        case .shield:    return "Pewter heraldry — clean, classic."
        case .waxSeal:   return "Coral wax + silver flame — handcrafted."
        case .brassCoin: return "Engraved brass coin — coveted signet."
        case .sunDisc:   return "Obsidian sunburst — ornate and cinematic."
        }
    }

    /// Asset name in the macOS asset catalog (vector PDF imageset).
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

private enum CloudBadgeDefaults {
    static let key = "cloud.badge.style"
}

// MARK: - Badge view

/// Renders the user's currently selected Cloud Member badge. Pass
/// `styleOverride` from the picker preview to show a specific style.
struct CloudBadge: View {
    enum Size {
        case small
        case medium
        case large
        case custom(CGFloat)

        var diameter: CGFloat {
            switch self {
            case .small:         return 28
            case .medium:        return 56
            case .large:         return 104
            case .custom(let d): return d
            }
        }
    }

    var size: Size = .medium
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
            .shadow(color: DesignSystem.Colors.ember.opacity(0.35), radius: size.diameter * 0.10, y: size.diameter * 0.03)
            .accessibilityLabel("OpenBurnBar Cloud member badge")
    }
}

/// Wraps `CloudBadge` in a soft ember halo so it lifts off the gradient.
struct CloudBadgeWithHalo: View {
    var size: CloudBadge.Size = .medium
    var styleOverride: CloudBadgeStyle? = nil

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    RadialGradient(
                        colors: [
                            DesignSystem.Colors.amber.opacity(0.55),
                            DesignSystem.Colors.ember.opacity(0.25),
                            .clear
                        ],
                        center: .center,
                        startRadius: 0,
                        endRadius: size.diameter * 0.85
                    )
                )
                .frame(width: size.diameter + 24, height: size.diameter + 24)
            CloudBadge(size: size, styleOverride: styleOverride)
        }
    }
}

// MARK: - Badge picker

/// Sheet that lets members preview and pick a badge. Persists to UserDefaults
/// via the shared `cloud.badge.style` key so the choice is picked up on
/// iPhone / iPad via the same `@AppStorage` binding (UserDefaults itself is
/// per-app, but the key contract is identical so a future Firestore-sync
/// pass can promote both sides).
struct CloudBadgePicker: View {
    @AppStorage(CloudBadgeDefaults.key) private var storedRaw: String = CloudBadgeStyle.defaultStyle.rawValue
    @Environment(\.dismiss) private var dismiss

    private let columns: [GridItem] = [
        GridItem(.flexible(), spacing: 18),
        GridItem(.flexible(), spacing: 18)
    ]

    var body: some View {
        ZStack {
            DesignSystem.Colors.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(CloudBadgeStyle.allCases) { style in
                            CloudBadgePickerTile(
                                style: style,
                                isSelected: storedRaw == style.rawValue
                            ) {
                                storedRaw = style.rawValue
                            }
                        }
                    }
                    Text("Your badge appears on the Mac dashboard sidebar, the menu-bar popover footer, the Cloud pane, and on every other signed-in device.")
                        .font(.system(size: 12))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .padding(.top, 4)
                    HStack {
                        Spacer()
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                            .controlSize(.large)
                    }
                    .padding(.top, 12)
                }
                .padding(28)
            }
        }
        .frame(minWidth: 560, minHeight: 540)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PICK YOUR BADGE")
                .font(.system(size: 11, weight: .bold))
                .tracking(2.4)
                .foregroundStyle(DesignSystem.Colors.ember)
            Text("Wear your fire.")
                .font(.system(size: 32, weight: .bold, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.primaryGradient)
            Text("Four to start — more arrive with each major Cloud release.")
                .font(.system(size: 13))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }
}

private struct CloudBadgePickerTile: View {
    let style: CloudBadgeStyle
    let isSelected: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(.ultraThinMaterial)
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    DesignSystem.Colors.ember.opacity(isSelected ? 0.32 : 0.14),
                                    DesignSystem.Colors.amber.opacity(isSelected ? 0.26 : 0.10),
                                    DesignSystem.Colors.blaze.opacity(isSelected ? 0.20 : 0.08)
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
                                    ? [DesignSystem.Colors.amber, DesignSystem.Colors.ember, DesignSystem.Colors.amber]
                                    : [DesignSystem.Colors.border.opacity(0.45), DesignSystem.Colors.border.opacity(0.25)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: isSelected ? 1.6 : 0.7
                        )
                )
                .shadow(color: DesignSystem.Colors.ember.opacity(isSelected ? 0.35 : 0.10), radius: isSelected ? 18 : 6, y: 4)

                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        if isSelected {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(DesignSystem.Colors.ember)
                        }
                        Text(style.title)
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                    }
                    Text(style.blurb)
                        .font(.system(size: 11))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .multilineTextAlignment(.center)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(style.title). \(style.blurb)\(isSelected ? ", selected" : "")")
    }
}
