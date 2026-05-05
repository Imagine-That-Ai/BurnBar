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

    @State private var dragOffset: CGFloat = 0
    @State private var pressedDestination: AuroraNavDestination?
    @State private var isDragging = false

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Floating-pill geometry. The tray is a single capsule that hovers
    // above the bottom safe area — like Apple Music / Linear. Tabs are
    // measured to a uniform width and an animated highlight slides
    // beneath the active tab.
    private let pillHeight: CGFloat = 64
    private let iconSize: CGFloat = 22
    private let tabWidth: CGFloat = 56
    private let pillSidePadding: CGFloat = 8
    private let pillBottomInset: CGFloat = 16

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
                    isPressed: pressedDestination == dest
                )
                .frame(width: tabWidth, height: pillHeight - 8)
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
        .overlay(activeHighlight)
        .clipShape(Capsule(style: .continuous))
        .overlay(
            Capsule(style: .continuous)
                .stroke(strokeGradient, lineWidth: 0.6)
        )
        .compositingGroup()
        .shadow(color: Color.black.opacity(0.22), radius: 14, y: 6)
        .padding(.bottom, pillBottomInset)
        .padding(.horizontal, 28)
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

    /// The animated capsule that sits behind the active tab.
    @ViewBuilder
    private var activeHighlight: some View {
        GeometryReader { geo in
            let usableWidth = geo.size.width - pillSidePadding * 2
            let perTab = usableWidth / CGFloat(destinations.count)
            let index = CGFloat(destinations.firstIndex(of: selection) ?? 0)
            let centerX = pillSidePadding + perTab * (index + 0.5) + dragOffset

            Capsule(style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            selection.accent.opacity(0.30),
                            selection.accent.opacity(0.16)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(selection.accent.opacity(0.55), lineWidth: 0.6)
                )
                .frame(width: perTab - 6, height: pillHeight - 14)
                .position(x: centerX, y: geo.size.height / 2)
                .animation(.spring(response: 0.36, dampingFraction: 0.78), value: selection)
                .animation(.spring(response: 0.42, dampingFraction: 0.82), value: dragOffset)
        }
        .allowsHitTesting(false)
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
    let destination: AuroraNavDestination
    let iconSize: CGFloat
    let isSelected: Bool
    let isPressed: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 2) {
            AuroraNavIcon(
                destination: destination,
                size: iconSize,
                isSelected: isSelected,
                isPressed: isPressed
            )
            // Only show the label for the active tab — keeps the floating
            // pill compact, lets the icon breathe, and matches the modern
            // floating-pill pattern on iOS.
            if isSelected {
                Text(destination.label)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(destination.accent)
                    .transition(.opacity.combined(with: .scale(scale: 0.85)))
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(destination.label)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
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
                        destinations: AuroraNavDestination.allCases
                    )
                }
            }
        }
    }

    return PreviewWrapper()
}
