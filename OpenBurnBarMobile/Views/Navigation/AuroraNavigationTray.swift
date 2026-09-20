import SwiftUI

// MARK: - Aurora Navigation Tray (iOS)
//
// A custom swipeable bottom navigation tray that replaces the system TabView.
// Features:
//   • Live finger-scrubbing: press and drag across the pill to preview each
//     destination under the finger, release to commit.
//   • Liquid Glass viewfinder capsule that tracks the touch position and
//     snaps to the tab center as intent resolves (iOS 26+; material fallback
//     on iOS 17–25).
//   • Spring-snap physics with haptic feedback at each tab boundary crossing
//     and a stronger haptic on final commit.
//   • Preview-vs-commit semantics: content follows the finger during scrub
//     (via `onScrubPreview`), analytics fires only on commit (via the
//     `selection` binding + `onScrubCommit`).
//   • Custom Aurora vector icons with animated selection morph.
//   • Reduced-motion respect and full VoiceOver support.

struct AuroraNavigationTray: View {
    @Binding var selection: AuroraNavDestination
    let destinations: [AuroraNavDestination]
    /// Optional user identity that the `.you` tab renders as the avatar.
    var userPhotoURL: URL?
    var userDisplayName: String?
    /// Cloud entitlement state. Free users see a breathing `ProBadgeDot`
    /// at the corner of the `.you` tab; members see a tiny `MercuryCrest`.
    /// The single dot/crest swap is the universal whisper-vs-status signal
    /// across the app.
    var isCloudMember: Bool = false
    /// Fires continuously during a scrub with the destination currently
    /// under the finger. Pass `nil` to clear the preview (gesture cancelled).
    /// The host uses this to drive live content preview without committing.
    var onScrubPreview: ((AuroraNavDestination?) -> Void)?
    /// Fires once when the user releases inside the tray, committing the
    /// previewed destination. The `selection` binding is also updated.
    var onScrubCommit: ((AuroraNavDestination) -> Void)?

    // MARK: - Scrub state

    /// The selection captured at scrub start. Restored if the gesture cancels.
    @State private var restingSelection: AuroraNavDestination = .inbox
    /// Destination currently under the finger during a scrub.
    @State private var previewDestination: AuroraNavDestination?
    /// Finger x-position in the pill's local coordinate space.
    @State private var fingerX: CGFloat = 0
    /// Whether a scrub gesture is in progress.
    @State private var isScrubbing = false
    /// Last preview destination we fired a boundary haptic for, so we
    /// only haptic when crossing into a NEW tab.
    @State private var lastHapticDestination: AuroraNavDestination?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Floating-pill geometry. Labels stay visible so You matches the
    // screen title without relying on icon interpretation.
    private let pillHeight: CGFloat = MobileTrayMetrics.pillHeight
    private let iconSize: CGFloat = 24
    private let tabWidth: CGFloat = 56
    private let pillSidePadding: CGFloat = 6
    private let pillBottomInset: CGFloat = MobileTrayMetrics.pillBottomInset

    /// Effective pill content width (sum of all tab widths + side padding).
    private var trayContentWidth: CGFloat {
        CGFloat(destinations.count) * tabWidth + pillSidePadding * 2
    }

    /// The destination that should appear selected right now: the preview
    /// during a scrub, otherwise the committed selection.
    private var activeSelection: AuroraNavDestination {
        isScrubbing ? (previewDestination ?? restingSelection) : selection
    }

    var body: some View {
        // Pill-only body. The tray is sized to its intrinsic height
        // (`pillHeight + bottomInset`); the parent decides where it sits.
        // Avoids an inner Spacer that would expand the tray to fill the
        // screen and visually swallow the underlying content.
        pill
            .padding(.bottom, pillBottomInset)
            .padding(.horizontal, 32)
            .accessibilityElement(children: .contain)
    }

    /// The floating pill. One `LiquidGlassGroup` capsule so the four tabs
    /// share a sampling volume — glass cannot sample other glass. No ember
    /// glow, specular stroke, or drop shadow. `.interactive()` lets specular
    /// respond to the scrub. Older systems use material.
    @ViewBuilder
    private var pill: some View {
        LiquidGlassGroup {
            if #available(iOS 26.0, *) {
                tabRow
                    .liquidGlassEffect(.regular.interactive(), in: Capsule(style: .continuous))
                    .contentShape(Capsule(style: .continuous))
                    .gesture(scrubGesture)
            } else {
                tabRow
                    .background(pillBackground)
                    .clipShape(Capsule(style: .continuous))
                    .contentShape(Capsule(style: .continuous))
                    .gesture(scrubGesture)
            }
        }
    }

    private var tabRow: some View {
        HStack(spacing: 0) {
            ForEach(destinations) { dest in
                AuroraTabItem(
                    destination: dest,
                    iconSize: iconSize,
                    isSelected: activeSelection == dest,
                    isPreviewed: isScrubbing && previewDestination == dest,
                    isPressed: false,
                    userPhotoURL: dest == .you ? userPhotoURL : nil,
                    userDisplayName: dest == .you ? userDisplayName : nil,
                    cloudIndicator: dest == .you ? (isCloudMember ? .member : .free) : .none
                )
                .frame(width: tabWidth, height: pillHeight - 6)
                .contentShape(Capsule())
            }
        }
        .padding(.horizontal, pillSidePadding)
        .frame(height: pillHeight)
    }

    // MARK: - Scrub gesture

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if !isScrubbing {
                    // Capture resting state at scrub start.
                    restingSelection = selection
                    isScrubbing = true
                    lastHapticDestination = nil
                }
                fingerX = value.location.x
                // Resolve preview destination from finger position.
                let localX = fingerX - pillSidePadding
                guard let preview = AuroraNavGestureModel.destination(
                    x: localX,
                    trayWidth: CGFloat(destinations.count) * tabWidth,
                    destinations: destinations
                ) else { return }
                if previewDestination != preview {
                    previewDestination = preview
                    onScrubPreview?(preview)
                    // Boundary haptic — only when crossing into a new tab.
                    if lastHapticDestination != preview {
                        lastHapticDestination = preview
                        HapticBus.tabChange()
                    }
                }
            }
            .onEnded { value in
                // Determine if the finger ended inside the pill bounds.
                let insideX = value.location.x >= 0 && value.location.x <= trayContentWidth + pillSidePadding * 2
                if insideX, let committed = previewDestination {
                    // Commit: write the binding (fires analytics via .onChange
                    // in the host) and notify the host.
                    withAnimation(AuroraNavGestureModel.transitionAnimation(reduceMotion: reduceMotion)) {
                        selection = committed
                    }
                    onScrubCommit?(committed)
                    onScrubPreview?(nil)
                    // Stronger haptic on final commit.
                    HapticBus.primaryAction()
                } else {
                    // Cancel: revert to resting selection.
                    onScrubPreview?(nil)
                }
                // Reset scrub state.
                isScrubbing = false
                previewDestination = nil
                lastHapticDestination = nil
            }
    }

    // MARK: - Background

    /// Pre-iOS 26 fallback: translucent material so the underlying scroll
    /// content shows through faintly — sells the "floating" effect.
    @ViewBuilder
    private var pillBackground: some View {
        Capsule(style: .continuous).fill(.ultraThinMaterial)
    }
}

// MARK: - Individual Tab Item

struct AuroraTabItem: View {
    enum CloudIndicator { case none, free, member }

    let destination: AuroraNavDestination
    let iconSize: CGFloat
    let isSelected: Bool
    var isPreviewed: Bool = false
    var isPressed: Bool = false
    var userPhotoURL: URL?
    var userDisplayName: String?
    var cloudIndicator: CloudIndicator = .none

    @Environment(\.colorScheme) private var colorScheme

    /// Whether the icon should show its active visual treatment: committed
    /// selection OR live preview during a scrub.
    private var showsActive: Bool { isSelected || isPreviewed }

    var body: some View {
        VStack(spacing: 3) {
            ZStack(alignment: .topTrailing) {
                trayGlyph

                // Pro vocabulary — the whisper. Free users see a small
                // breathing dot; members see their selected CloudBadge. Same
                // slot, different state. Sits in the top-right corner of the
                // icon, nudged slightly northeast so the badge clears the
                // glyph stroke.
                cloudIndicatorOverlay
                    .offset(x: 9, y: -6)
            }

            Text(destination.trayLabel)
                .font(.system(size: 11, weight: showsActive ? .semibold : .regular))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .foregroundStyle(showsActive ? Color.primary : MobileTheme.Colors.textSecondary)
                .frame(width: 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(showsActive ? [.isSelected, .isButton] : .isButton)
        // Stable UI-test hook for the floating nav tray. Inert in production:
        // an accessibility identifier changes no behavior, only exposes each
        // tab to XCUITest so the scrub-gesture destination can be tapped.
        .accessibilityIdentifier("auroraTab.\(destination.id)")
    }

    /// ChatGPT-quiet tray glyphs: monochrome SF Symbols. You keeps a photo
    /// when signed in; otherwise it is the same person glyph as the rest.
    @ViewBuilder
    private var trayGlyph: some View {
        if destination == .you, userPhotoURL != nil || !(userDisplayName ?? "").isEmpty {
            AuroraNavIcon(
                destination: destination,
                size: iconSize,
                isSelected: showsActive,
                isPressed: isPressed,
                userPhotoURL: userPhotoURL,
                userDisplayName: userDisplayName
            )
        } else {
            Image(systemName: destination.traySystemImage)
                .font(.system(size: iconSize * 0.72, weight: showsActive ? .semibold : .regular))
                .foregroundStyle(showsActive ? Color.primary : Color.secondary)
                .symbolRenderingMode(.monochrome)
                .frame(width: iconSize, height: iconSize)
                .scaleEffect(isPressed ? 0.88 : 1)
        }
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
        @State private var selection: AuroraNavDestination = .inbox

        var body: some View {
            ZStack {
                Color(uiColor: .systemGroupedBackground).ignoresSafeArea()
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
