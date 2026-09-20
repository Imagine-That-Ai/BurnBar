import AppKit
import OpenBurnBarUI
import SwiftUI

// MARK: - Avatar Sizing

/// Predefined sizes for the BurnBar profile avatar across different UI surfaces.
enum BurnBarProfileAvatarSize {
    /// 22pt — tight status bars and compact tray actions
    case compact
    /// 26pt — top rail and window toolbar items
    case toolbar
    /// 32pt — cards, popover headers, and mid-sized rails
    case medium
    /// 40pt — floating profile popover header
    case header
    /// 52pt — large identity cards and modal account sheets
    case large

    var diameter: CGFloat {
        switch self {
        case .compact: return 22
        case .toolbar: return 26
        case .medium:  return 32
        case .header:  return 40
        case .large:   return 52
        }
    }

    var font: Font {
        switch self {
        case .compact: return .system(size: 9.5, weight: .bold, design: .rounded)
        case .toolbar: return .system(size: 11, weight: .bold, design: .rounded)
        case .medium:  return .system(size: 13, weight: .bold, design: .rounded)
        case .header:  return .system(size: 16, weight: .bold, design: .rounded)
        case .large:   return .system(size: 21, weight: .bold, design: .rounded)
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .compact: return 10
        case .toolbar: return 12
        case .medium:  return 15
        case .header:  return 18
        case .large:   return 24
        }
    }

    var badgeDiameter: CGFloat {
        switch self {
        case .compact: return 7
        case .toolbar: return 8.5
        case .medium:  return 10
        case .header:  return 12.5
        case .large:   return 15
        }
    }
}

// MARK: - BurnBar Profile Avatar

/// An avatar view for OpenBurnBar. Displays the user's remote photo URL,
/// elegant initials on an ember/mesh gradient, or a brand emblem fallback,
/// framed by an ambient membership tier ring and activity badge.
struct BurnBarProfileAvatar: View {
    var size: BurnBarProfileAvatarSize = .toolbar
    var avatarURL: URL?
    var displayName: String?
    var email: String?
    var tier: MacCloudTier = .free
    var showTierRing: Bool = true
    var showStatusBadge: Bool = false
    var isLiveOrSyncing: Bool = false

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            avatarBaseView
                .frame(width: size.diameter, height: size.diameter)
                .clipShape(Circle())
                .overlay(tierRingOverlay)

            if showStatusBadge {
                statusBadgeView
                    .offset(x: 1, y: 1)
            }
        }
        .frame(width: size.diameter, height: size.diameter)
    }

    // MARK: - Avatar Base

    @ViewBuilder
    private var avatarBaseView: some View {
        if let avatarURL {
            AsyncImage(url: avatarURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure, .empty:
                    initialsOrEmblemView
                @unknown default:
                    initialsOrEmblemView
                }
            }
        } else {
            initialsOrEmblemView
        }
    }

    // MARK: - Initials / Emblem View

    private var initialsOrEmblemView: some View {
        let initials = Self.extractInitials(displayName: displayName, email: email)

        return ZStack {
            avatarBackgroundGradient

            if let initials, !initials.isEmpty {
                Text(initials)
                    .font(size.font)
                    .foregroundStyle(Color.white)
                    .shadow(color: Color.black.opacity(0.3), radius: 2, y: 1)
            } else {
                Image(systemName: "flame.fill")
                    .font(.system(size: size.iconSize, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color.white, Color.white.opacity(0.85)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .shadow(color: DesignSystem.Colors.ember.opacity(0.5), radius: 3, y: 1)
            }
        }
    }

    // MARK: - Background Gradient

    private var avatarBackgroundGradient: some View {
        ZStack {
            switch tier {
            case .ultra:
                LinearGradient(
                    colors: [
                        Color(hex: "F39C12"),
                        Color(hex: "E74C3C"),
                        Color(hex: "8E44AD")
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .pro:
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.ember,
                        DesignSystem.Colors.amber
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .cloud:
                LinearGradient(
                    colors: [
                        DesignSystem.Colors.whimsy,
                        DesignSystem.Colors.frost
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            case .free:
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [DesignSystem.Colors.surfaceElevated, Color(hex: "2D3748")]
                        : [Color(hex: "DFE6E9"), Color(hex: "B2BEC3")],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }

            // Radial highlight sheen on top
            RadialGradient(
                colors: [Color.white.opacity(0.25), Color.clear],
                center: .topLeading,
                startRadius: 0,
                endRadius: size.diameter * 0.8
            )
        }
    }

    // MARK: - Tier Ring Overlay

    @ViewBuilder
    private var tierRingOverlay: some View {
        if showTierRing {
            switch tier {
            case .ultra:
                Circle()
                    .strokeBorder(
                        AngularGradient(
                            colors: [
                                Color(hex: "FFD700"),
                                DesignSystem.Colors.amber,
                                DesignSystem.Colors.ember,
                                DesignSystem.Colors.whimsy,
                                Color(hex: "FFD700")
                            ],
                            center: .center
                        ),
                        lineWidth: size == .large || size == .header ? 2.0 : 1.25
                    )
            case .pro:
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.amber,
                                DesignSystem.Colors.ember
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: size == .large || size == .header ? 1.75 : 1.0
                    )
            case .cloud:
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.frost,
                                DesignSystem.Colors.glacier
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: size == .large || size == .header ? 1.5 : 0.9
                    )
            case .free:
                Circle()
                    .strokeBorder(
                        colorScheme == .dark
                            ? Color.white.opacity(0.18)
                            : Color.black.opacity(0.12),
                        lineWidth: 0.75
                    )
            }
        }
    }

    // MARK: - Status Badge View

    private var statusBadgeView: some View {
        ZStack {
            Circle()
                .fill(DesignSystem.Colors.surface)
                .frame(width: size.badgeDiameter + 2, height: size.badgeDiameter + 2)

            Circle()
                .fill(isLiveOrSyncing ? DesignSystem.Colors.success : statusColorForTier)
                .frame(width: size.badgeDiameter, height: size.badgeDiameter)
        }
    }

    private var statusColorForTier: Color {
        switch tier {
        case .ultra, .pro: return DesignSystem.Colors.amber
        case .cloud:       return DesignSystem.Colors.frost
        case .free:        return DesignSystem.Colors.textMuted
        }
    }

    // MARK: - Helpers

    /// Extracts 1 or 2 uppercase initials from the display name or email address.
    static func extractInitials(displayName: String?, email: String?) -> String? {
        if let name = displayName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            let components = name.split(separator: " ").filter { !$0.isEmpty }
            if components.count >= 2 {
                let first = components[0].prefix(1)
                let second = components[1].prefix(1)
                return "\(first)\(second)".uppercased()
            } else if let single = components.first, !single.isEmpty {
                return String(single.prefix(2)).uppercased()
            }
        }

        if let email = email?.trimmingCharacters(in: .whitespacesAndNewlines), !email.isEmpty {
            let localPart = email.split(separator: "@").first ?? ""
            if !localPart.isEmpty {
                return String(localPart.prefix(2)).uppercased()
            }
        }

        return nil
    }
}
