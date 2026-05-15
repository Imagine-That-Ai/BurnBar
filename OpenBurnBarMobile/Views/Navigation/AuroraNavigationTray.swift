import SwiftUI

// MARK: - Aurora Navigation Tray (iOS)
//
// A custom swipeable bottom navigation tray that replaces the system TabView.
// Features:
//   • Horizontal drag-to-switch between destinations
//   • Spring-snap physics with haptic feedback at each tab boundary
//   • Custom Aurora vector icons with animated selection morph
//   • Glass material backdrop with subtle top border
//   • Reduced-motion respect and full VoiceOver support

struct AuroraNavigationTray: View {
    @Binding var selection: AuroraNavDestination
    let destinations: [AuroraNavDestination]
    /// Optional user identity that the `.you` tab renders as the avatar.
    var userPhotoURL: URL? = nil
    var userDisplayName: String? = nil
    /// Cloud entitlement state. Free users see a breathing `ProBadgeDot`
    /// at the corner of the `.you` tab; members see a tiny `MercuryCrest`.
    /// The single dot/crest swap is the universal whisper-vs-status signal
    /// across the app.
    var isCloudMember: Bool = false

    @State private var dragOffset: CGFloat = 0
    @State private var pressedDestination: AuroraNavDestination?
    @State private var isDragging = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Floating-pill geometry. Compact pill — emphasis is on the icon
    // animation, not the chrome around it. Selection is signaled by an
    // accent dot under the icon plus the icon's own animated wake-up,
    // not a heavy capsule highlight.
    private let pillHeight: CGFloat = 50
    private let iconSize: CGFloat = 26
    private let tabWidth: CGFloat = 52
    private let pillSidePadding: CGFloat = 6
    private let pillBottomInset: CGFloat = 14

    var body: some View {
        // Pill-only body. The tray is sized to its intrinsic height
        // (`pillHeight + bottomInset`); the parent decides where it sits.
        // Avoids an inner Spacer that would expand the tray to fill the
        // screen and visually swallow the underlying content.
        HStack(spacing: 0) {
            ForEach(destinations) { dest in
                AuroraTabItem(
                    destination: dest,
                    iconSize: iconSize,
                    isSelected: selection == dest,
                    isPressed: pressedDestination == dest,
                    userPhotoURL: dest == .you ? userPhotoURL : nil,
                    userDisplayName: dest == .you ? userDisplayName : nil,
                    cloudIndicator: dest == .you ? (isCloudMember ? .member : .free) : .none
                )
                .frame(width: tabWidth, height: pillHeight - 6)
                .contentShape(Capsule())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            if pressedDestination != dest {
                                pressedDestination = dest
                            }
                        }
                        .onEnded { _ in
                            withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                                selection = dest
                                pressedDestination = nil
                            }
                            HapticBus.tabChange()
                        }
                )
                .simultaneousGesture(
                    TapGesture().onEnded {
                        withAnimation(.spring(response: 0.34, dampingFraction: 0.78)) {
                            selection = dest
                        }
                        HapticBus.tabChange()
                    }
                )
            }
        }
        .padding(.horizontal, pillSidePadding)
        .frame(height: pillHeight)
        .background(pillBackground)
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(strokeGradient, lineWidth: 0.6)
        )
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.18), radius: 10, y: 4)
        .padding(.bottom, pillBottomInset)
        .padding(.horizontal, 32)
        .gesture(swipeGesture)
        .accessibilityElement(children: .contain)
    }

    // MARK: - Background

    @ViewBuilder
    private var pillBackground: some View {
        ZStack {
            // Translucent material so the underlying scroll content shows
            // through faintly — sells the "floating" effect.
            Capsule(style: .continuous).fill(.ultraThinMaterial)

            // Subtle warm tint
            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            MobileTheme.ember.opacity(colorScheme == .dark ? 0.07 : 0.04),
                            Color.clear,
                            MobileTheme.amber.opacity(colorScheme == .dark ? 0.05 : 0.03)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
    }

    private var strokeGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color.white.opacity(colorScheme == .dark ? 0.18 : 0.45),
                MobileTheme.Colors.border.opacity(colorScheme == .dark ? 0.30 : 0.40),
                Color.white.opacity(colorScheme == .dark ? 0.10 : 0.30)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Swipe gesture (works across the whole pill)

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 14, coordinateSpace: .local)
            .onChanged { value in
                isDragging = true
                let raw = value.translation.width
                let currentIndex = destinations.firstIndex(of: selection) ?? 0
                let resistance: CGFloat =
                    (currentIndex == 0 && raw > 0) ||
                    (currentIndex == destinations.count - 1 && raw < 0)
                        ? 0.30 : 0.55
                dragOffset = raw * resistance
            }
            .onEnded { value in
                isDragging = false
                let velocity = value.predictedEndLocation.x - value.location.x
                let total = value.translation.width + velocity * 0.25
                let threshold: CGFloat = 36
                let currentIndex = destinations.firstIndex(of: selection) ?? 0

                var newIndex = currentIndex
                if total < -threshold, currentIndex < destinations.count - 1 {
                    newIndex = currentIndex + 1
                } else if total > threshold, currentIndex > 0 {
                    newIndex = currentIndex - 1
                }

                if newIndex != currentIndex {
                    withAnimation(.spring(response: 0.36, dampingFraction: 0.80)) {
                        selection = destinations[newIndex]
                    }
                    HapticBus.tabChange()
                }
                withAnimation(.spring(response: 0.42, dampingFraction: 0.82)) {
                    dragOffset = 0
                }
            }
    }
}

// MARK: - Individual Tab Item

struct AuroraTabItem: View {
    enum CloudIndicator { case none, free, member }

    let destination: AuroraNavDestination
    let iconSize: CGFloat
    let isSelected: Bool
    let isPressed: Bool
    var userPhotoURL: URL? = nil
    var userDisplayName: String? = nil
    var cloudIndicator: CloudIndicator = .none

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                AuroraNavIcon(
                    destination: destination,
                    size: iconSize,
                    isSelected: isSelected,
                    isPressed: isPressed,
                    userPhotoURL: userPhotoURL,
                    userDisplayName: userDisplayName
                )

                // Pro vocabulary — the whisper. Free users see a small
                // breathing dot; members see their selected CloudBadge. Same
                // slot, different state. Sits in the top-right corner of the
                // icon, nudged slightly northeast so the badge clears the
                // glyph stroke.
                cloudIndicatorOverlay
                    .offset(x: 9, y: -6)
            }

            // Tiny accent dot under the active icon — replaces the heavy
            // capsule highlight so the icon, not the chrome, is the
            // emphasis when a tab is active.
            Circle()
                .fill(destination.accent)
                .frame(width: 4, height: 4)
                .opacity(isSelected ? 1 : 0)
                .scaleEffect(isSelected ? 1 : 0.4)
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: isSelected)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
    }

    @ViewBuilder
    private var cloudIndicatorOverlay: some View {
        switch cloudIndicator {
        case .none:
            EmptyView()
        case .free:
            ProBadgeDot(pulse: .breathing)
        case .member:
            CloudBadge(size: .custom(16))
        }
    }

    private var accessibilityLabel: String {
        switch cloudIndicator {
        case .none:
            return destination.label
        case .free:
            return "\(destination.label). OpenBurnBar Cloud available."
        case .member:
            return "\(destination.label). Cloud Member."
        }
    }
}

// MARK: - Preview

#Preview("Aurora Navigation Tray") {
    struct PreviewWrapper: View {
        @State private var selection: AuroraNavDestination = .pulse

        var body: some View {
            ZStack {
                AuroraBackdrop()
                VStack {
                    Spacer()
                    AuroraNavigationTray(
                        selection: $selection,
                        destinations: AuroraNavDestination.allCases,
                        userPhotoURL: nil,
                        userDisplayName: "Alberto Nunez"
                    )
                }
            }
        }
    }

    return PreviewWrapper()
}
