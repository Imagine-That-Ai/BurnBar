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
//
// The tray renders the user's ordered `AuroraNavItem` list (see
// `AppCustomization.navItems`), not a hardcoded destination set. Identity is
// per item, so two AI Inbox instances are distinct tabs. Tab width adapts to
// the measured available width (clamped 40…56 pt) so up to
// `AuroraNavItem.maxItems` tabs stay tappable on the smallest iPhones.

struct AuroraNavigationTray: View {
    @Binding var selection: AuroraNavItem
    let items: [AuroraNavItem]
    /// Optional user identity that the `.you` tab renders as the avatar.
    var userPhotoURL: URL?
    var userDisplayName: String?
    /// Cloud entitlement state. Free users see a breathing `ProBadgeDot`
    /// at the corner of the `.you` tab; members see a tiny `MercuryCrest`.
    /// The single dot/crest swap is the universal whisper-vs-status signal
    /// across the app.
    var isCloudMember: Bool = false
    /// Fires continuously during a scrub with the item currently under the
    /// finger. Pass `nil` to clear the preview (gesture cancelled).
    /// The host uses this to drive live content preview without committing.
    var onScrubPreview: ((AuroraNavItem?) -> Void)?
    /// Fires once when the user releases inside the tray, committing the
    /// previewed item. The `selection` binding is also updated.
    var onScrubCommit: ((AuroraNavItem) -> Void)?

    // MARK: - Scrub state

    /// The selection captured at scrub start. Restored if the gesture cancels.
    @State private var restingSelection: AuroraNavItem = .canonical(.pulse)
    /// Item currently under the finger during a scrub.
    @State private var previewItem: AuroraNavItem?
    /// Finger x-position in the pill's local coordinate space.
    @State private var fingerX: CGFloat = 0
    /// Smoothed viewfinder x — springs toward the finger / tab center.
    @State private var viewfinderX: CGFloat = 0
    /// Whether a scrub gesture is in progress.
    @State private var isScrubbing = false
    /// Last preview item we fired a boundary haptic for, so we only haptic
    /// when crossing into a NEW tab.
    @State private var lastHapticItem: AuroraNavItem?
    /// Available width measured from the tray's own full-width slot; drives
    /// the adaptive tab width. Seeded with a common iPhone width so the first
    /// layout pass is sane before geometry lands.
    @State private var measuredWidth: CGFloat = 393

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Floating-pill geometry. Labels stay visible so core routes such as
    // Store are discoverable without relying on icon interpretation.
    private let pillHeight: CGFloat = 62
    private let iconSize: CGFloat = 24
    private let pillSidePadding: CGFloat = 6
    private let pillBottomInset: CGFloat = 14
    /// Minimum breathing room between the pill and the screen edges when the
    /// tab count forces the pill toward full width.
    private let minEdgeMargin: CGFloat = 12

    /// Adaptive per-tab width: the classic 56 pt whenever it fits, compressing
    /// down to 40 pt (still comfortably tappable) as the user adds tabs.
    private var tabWidth: CGFloat {
        let usable = measuredWidth - minEdgeMargin * 2 - pillSidePadding * 2
        guard items.isEmpty == false, usable > 0 else { return 56 }
        return min(56, max(40, usable / CGFloat(items.count)))
    }

    /// Effective pill content width (sum of all tab widths + side padding).
    private var trayContentWidth: CGFloat {
        CGFloat(items.count) * tabWidth + pillSidePadding * 2
    }

    /// The item that should appear selected right now: the preview during a
    /// scrub, otherwise the committed selection.
    private var activeSelection: AuroraNavItem {
        isScrubbing ? (previewItem ?? restingSelection) : selection
    }

    var body: some View {
        // Pill-only body, centered in a full-width slot. The slot spans the
        // screen so the pill can measure how much room it actually has; the
        // pill itself stays intrinsic-width. The parent decides where it sits.
        pill
            .padding(.bottom, pillBottomInset)
            .frame(maxWidth: .infinity)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { measuredWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, width in
                            measuredWidth = width
                        }
                }
            )
            .accessibilityElement(children: .contain)
    }

    /// The floating pill. On iOS 26 the body is true Liquid Glass: the warm
    /// tint capsule rides directly on `.glassEffect` (no ultraThinMaterial
    /// underneath — glass cannot sample through material) and the shadow
    /// attaches to the glass capsule itself, because a `compositingGroup`
    /// would flatten the glass specular. Older systems keep the original
    /// material + tint stack.
    @ViewBuilder
    private var pill: some View {
        if #available(iOS 26.0, *) {
            tabRow
                .clipShape(Capsule(style: .continuous))
                .background(
                    warmTintCapsule
                        .liquidGlassEffect(.regular.interactive(), in: Capsule(style: .continuous))
                        .shadow(color: Color.black.opacity(0.18), radius: 10, y: 4)
                )
                .overlay(alignment: .leading) {
                    // Liquid Glass viewfinder capsule — tracks the finger,
                    // tints with the previewed destination's accent.
                    viewfinderOverlay
                        .allowsHitTesting(false)
                }
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(strokeGradient, lineWidth: 0.6)
                )
                .contentShape(Capsule(style: .continuous))
                .gesture(scrubGesture)
        } else {
            tabRow
                .overlay(alignment: .leading) {
                    viewfinderOverlay
                        .allowsHitTesting(false)
                }
                .background(pillBackground)
                .clipShape(Capsule(style: .continuous))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(strokeGradient, lineWidth: 0.6)
                )
                .compositingGroup()
                .shadow(color: Color.black.opacity(0.18), radius: 10, y: 4)
                .contentShape(Capsule(style: .continuous))
                .gesture(scrubGesture)
        }
    }

    private var tabRow: some View {
        HStack(spacing: 0) {
            ForEach(items) { item in
                AuroraTabItem(
                    item: item,
                    iconSize: iconSize,
                    tabWidth: tabWidth,
                    isSelected: activeSelection == item,
                    isPreviewed: isScrubbing && previewItem == item,
                    isPressed: false,
                    userPhotoURL: item.kind == .you ? userPhotoURL : nil,
                    userDisplayName: item.kind == .you ? userDisplayName : nil,
                    cloudIndicator: item.kind == .you ? (isCloudMember ? .member : .free) : .none
                )
                .frame(width: tabWidth, height: pillHeight - 6)
                .contentShape(Capsule())
            }
        }
        .padding(.horizontal, pillSidePadding)
        .frame(height: pillHeight)
    }

    // MARK: - Liquid Glass viewfinder overlay

    /// A tracking capsule that follows the finger during scrub, tinted with
    /// the previewed destination's accent. On iOS 26+ it rides on
    /// `liquidGlassEffect`; on older systems it's a material + tint capsule.
    @ViewBuilder
    private var viewfinderOverlay: some View {
        if isScrubbing, let preview = previewItem {
            let capsuleWidth = tabWidth + 4
            let x = viewfinderX - capsuleWidth / 2
            Capsule(style: .continuous)
                .fill(preview.kind.accent.opacity(colorScheme == .dark ? 0.12 : 0.08))
                .frame(width: capsuleWidth, height: pillHeight - 4)
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(preview.kind.accent.opacity(0.45), lineWidth: 1)
                )
                .offset(x: x)
                .transition(.opacity)
                .animation(AuroraNavGestureModel.viewfinderAnimation(reduceMotion: reduceMotion),
                           value: viewfinderX)
                .animation(.easeInOut(duration: 0.15), value: previewItem)
        }
    }

    // MARK: - Scrub gesture

    private var scrubGesture: some Gesture {
        DragGesture(minimumDistance: 0, coordinateSpace: .local)
            .onChanged { value in
                if !isScrubbing {
                    // Capture resting state at scrub start.
                    restingSelection = selection
                    isScrubbing = true
                    lastHapticItem = nil
                    // Seed the viewfinder at the current tab center.
                    let currentIdx = items.firstIndex(of: selection) ?? 0
                    viewfinderX = AuroraNavGestureModel.viewfinderCenterX(
                        index: currentIdx,
                        count: items.count,
                        trayWidth: trayContentWidth
                    ) + pillSidePadding
                }
                fingerX = value.location.x
                // Resolve preview item from finger position.
                let localX = fingerX - pillSidePadding
                guard let preview = AuroraNavGestureModel.destination(
                    x: localX,
                    trayWidth: CGFloat(items.count) * tabWidth,
                    destinations: items
                ) else { return }
                if previewItem != preview {
                    previewItem = preview
                    // Move viewfinder toward the previewed tab center.
                    let idx = items.firstIndex(of: preview) ?? 0
                    viewfinderX = AuroraNavGestureModel.viewfinderCenterX(
                        index: idx,
                        count: items.count,
                        trayWidth: CGFloat(items.count) * tabWidth
                    ) + pillSidePadding
                    onScrubPreview?(preview)
                    // Boundary haptic — only when crossing into a new tab.
                    if lastHapticItem != preview {
                        lastHapticItem = preview
                        HapticBus.tabChange()
                    }
                }
            }
            .onEnded { value in
                // Determine if the finger ended inside the pill bounds.
                let insideX = value.location.x >= 0 && value.location.x <= trayContentWidth
                if insideX, let committed = previewItem {
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
                previewItem = nil
                lastHapticItem = nil
            }
    }

    // MARK: - Background

    /// Pre-iOS 26 fallback: translucent material so the underlying scroll
    /// content shows through faintly — sells the "floating" effect.
    @ViewBuilder
    private var pillBackground: some View {
        ZStack {
            Capsule(style: .continuous).fill(.ultraThinMaterial)
            warmTintCapsule
        }
    }

    /// Subtle warm tint — the capsule body shared by both the Liquid Glass
    /// branch and the material fallback.
    private var warmTintCapsule: some View {
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
}

// MARK: - Individual Tab Item

struct AuroraTabItem: View {
    enum CloudIndicator { case none, free, member }

    let item: AuroraNavItem
    let iconSize: CGFloat
    var tabWidth: CGFloat = 56
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
                AuroraNavIcon(
                    destination: item.kind,
                    size: iconSize,
                    isSelected: showsActive,
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

            Text(item.trayLabel)
                .font(.system(size: 9, weight: showsActive ? .bold : .semibold, design: .rounded))
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .foregroundStyle(showsActive ? item.kind.accent : MobileTheme.Colors.textSecondary)
                .frame(width: min(48, tabWidth - 8))

            Capsule(style: .continuous)
                .fill(item.kind.accent)
                .frame(width: showsActive ? 16 : 4, height: 3)
                .opacity(showsActive ? 1 : 0.35)
                .animation(.spring(response: 0.28, dampingFraction: 0.72), value: showsActive)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(showsActive ? [.isSelected, .isButton] : .isButton)
        // Stable UI-test hook for the floating nav tray. Inert in production:
        // an accessibility identifier changes no behavior, only exposes each
        // tab to XCUITest so the scrub-gesture destination can be tapped.
        // Canonical items keep the historical `auroraTab.<kind>` id; extra
        // instances (second inbox, …) append their instance id so duplicated
        // kinds stay individually addressable.
        .accessibilityIdentifier(accessibilityIdentifierValue)
    }

    private var accessibilityIdentifierValue: String {
        if item.id == AuroraNavItem.canonical(item.kind).id {
            return "auroraTab.\(item.kind.id)"
        }
        return "auroraTab.\(item.kind.id).\(item.id)"
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
            return item.displayLabel
        case .free:
            return "\(item.displayLabel). OpenBurnBar Cloud available."
        case .member:
            return "\(item.displayLabel). Cloud Member."
        }
    }
}

// MARK: - Preview

#Preview("Aurora Navigation Tray") {
    struct PreviewWrapper: View {
        @State private var items: [AuroraNavItem] = AuroraNavItem.defaultItems
        @State private var selection: AuroraNavItem = .canonical(.pulse)

        var body: some View {
            ZStack {
                AuroraBackdrop()
                VStack {
                    Spacer()
                    AuroraNavigationTray(
                        selection: $selection,
                        items: items,
                        userPhotoURL: nil,
                        userDisplayName: "Alberto Nunez"
                    )
                }
            }
        }
    }

    return PreviewWrapper()
}
