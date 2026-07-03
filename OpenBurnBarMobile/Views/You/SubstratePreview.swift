import SwiftUI
import OpenBurnBarCore

// MARK: - Substrate thumbnail rasterizer
//
// Renders a static, high-fidelity preview of one substrate by driving the EXACT
// `SwarmSubstrate.paint(_:into:)` path the live engine uses, over a synthetic
// provider-glyph cloud, and caching the resulting bitmap per (id, family,
// polarity).
//
// **Why static thumbnails and not 30 live canvases.** The picker only shows one
// kernel family's suite (~5–6 styles) at once, but every live `SwarmCanvasView`
// runs a `TimelineView` redraw loop whose `paint(_:into:)` is `@MainActor`.
// Stacking five or six of those *behind the already-live preview strip* (a real
// WebGL kernel + a transparent swarm) would make each animating mini-canvas
// fight for the same main-actor frame budget, hitching the horizontal scroll on
// a phone. Rasterizing each substrate ONCE with `ImageRenderer` and compositing
// a cheap cached `UIImage` keeps the catalog buttery while still showing each
// substrate's true material (Caustic Pool, Glass Ribbon, Stellar Plasma, …).
// The single live element is the prominent preview strip up top — it carries the
// real motion the moment a card is tapped.
@MainActor
enum SubstrateThumbnail {
    /// Logical render size. Rendered at 2× and displayed scaled-to-fill in the
    /// ~120pt card so the material stays crisp without paying retina memory for
    /// every one of the 30 catalog styles.
    static let renderSize = CGSize(width: 240, height: 280)

    /// One bitmap per resolved look. Substrate renders are deterministic for a
    /// fixed synthetic cloud, so a value is computed at most once and reused.
    private static var cache: [String: UIImage] = [:]

    /// Cached thumbnail for `descriptor` in the given polarity, building it on
    /// first request. The `family` is part of the key because the six "Plain"
    /// descriptors all share id `"plain"` yet carry different family accents.
    static func image(for descriptor: SubstrateDescriptor, dark: Bool) -> UIImage? {
        let key = "\(descriptor.id)|\(descriptor.family.rawValue)|\(dark ? "d" : "l")"
        if let hit = cache[key] { return hit }
        guard let img = render(descriptor, dark: dark) else { return nil }
        cache[key] = img
        return img
    }

    // MARK: Rasterization

    private static func render(_ descriptor: SubstrateDescriptor, dark: Bool) -> UIImage? {
        let size = renderSize
        let substrate = descriptor.make()
        let dots = previewCloud(in: size)
        let frame = previewFrame(descriptor: descriptor, dots: dots, size: size, dark: dark)

        let content = ZStack {
            panel(dark: dark)
            Canvas(rendersAsynchronously: false) { ctx, _ in
                var c = ctx
                // Substrates paint OVER the engine's dot cloud and return `true`
                // when they fully own the frame. PlainDots / unfilled stubs
                // return `false`; we then draw the dots ourselves so the
                // "Plain · dots" tile still reads as a coloured swarm field.
                let handled = substrate.paint(frame, into: c)
                if !handled { drawDots(dots, into: &c) }
            }
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(size)
        return renderer.uiImage
    }

    /// The subtle plate behind the swarm — a dark slate (or pale haze in light
    /// polarity) so additive/`.plusLighter` materials bloom the way they do over
    /// the real backdrop instead of washing out on white.
    private static func panel(dark: Bool) -> some View {
        LinearGradient(
            colors: dark
                ? [Color(red: 0.06, green: 0.06, blue: 0.10), Color(red: 0.02, green: 0.02, blue: 0.05)]
                : [Color(red: 0.94, green: 0.93, blue: 0.97), Color(red: 0.87, green: 0.87, blue: 0.92)],
            startPoint: .top, endPoint: .bottom)
    }

    /// Default dot render for substrates that decline the frame — small filled
    /// brand-coloured discs, slightly enlarged so the field reads after the card
    /// downscale.
    private static func drawDots(_ dots: [SwarmSubstrateDot], into ctx: inout GraphicsContext) {
        for d in dots {
            let r = max(2.0, d.radius * 1.5)
            let rect = CGRect(x: d.x - r, y: d.y - r, width: r * 2, height: r * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(d.color))
        }
    }

    // MARK: Synthetic field

    /// A dense, formed blob filling ~90% of the canvas with quasi-uniform points
    /// in BurnBar provider hues. Spatially-coherent colour (by angular sector)
    /// lets flow/streamline idioms read; the formed regime (`isShapeMode`) lets
    /// shape-keyed materials express their full character.
    private static func previewCloud(in size: CGSize) -> [SwarmSubstrateDot] {
        var dots: [SwarmSubstrateDot] = []
        let cx = Double(size.width) * 0.5, cy = Double(size.height) * 0.5
        let rx = Double(size.width) * 0.46, ry = Double(size.height) * 0.46
        let brand = [RGBA(r: 0.80, g: 0.47, b: 0.36), RGBA(r: 0.66, g: 0.40, b: 1.0),
                     RGBA(r: 0.0, g: 0.65, b: 0.49), RGBA(r: 0.26, g: 0.92, b: 0.23),
                     RGBA(r: 0.0, g: 0.65, b: 0.89)]
        var rng = XorShift32(seed: 0x5A6B_2C3D)
        var i = 0, tries = 0
        while dots.count < 190 && tries < 60_000 {
            tries += 1
            let nx = rng.next() * 2 - 1, ny = rng.next() * 2 - 1
            guard nx * nx + ny * ny <= 1 else { continue }      // inside the ellipse
            let ang = atan2(ny, nx)
            let sector = Int((ang + .pi) / (2 * .pi) * 5) % 5
            let sz = 1.4 + rng.next() * 1.2
            dots.append(SwarmSubstrateDot(
                x: cx + nx * rx, y: cy + ny * ry,
                vx: -sin(ang), vy: cos(ang),
                radius: max(1.0, sz * 1.05), baseSize: sz, rgba: brand[sector],
                opacity: 0.92, inShape: true, role: nil, slotIndex: sector,
                colorIndex: shash(Double(i) * 1.7), flowProgress: 0))
            i += 1
        }
        return dots
    }

    /// Build the formed, settled `SwarmSubstrateFrame` the same way the engine
    /// does, tinting the `stage` with the descriptor's own family accents so each
    /// thumbnail carries its world's colour.
    private static func previewFrame(descriptor: SubstrateDescriptor,
                                     dots: [SwarmSubstrateDot],
                                     size: CGSize, dark: Bool) -> SwarmSubstrateFrame {
        var sumX = 0.0, sumY = 0.0
        for d in dots { sumX += d.x; sumY += d.y }
        let n = Double(max(1, dots.count))
        let cx = sumX / n, cy = sumY / n
        var dsum = 0.0
        for d in dots { dsum += hypot(d.x - cx, d.y - cy) }
        let stage = SubstrateStage(
            accent: descriptor.accent,
            accent2: descriptor.accent2,
            ink: dark ? RGBA(r: 0.9, g: 0.93, b: 1.0) : RGBA(r: 0.1, g: 0.1, b: 0.14),
            dark: dark)
        return SwarmSubstrateFrame(
            size: size, dark: dark, reduced: false, batteryThrottled: false,
            uiMode: .standard, isShapeMode: true, formed: true, settleProgress: 1.0,
            t: 9.0, dt: 1.0, stage: stage, backdrop: nil, dots: dots,
            cx: cx, cy: cy, cloudRadius: dsum / n, sizePx: 2.4,
            structure: SubstrateStructureProvider())
    }
}

// MARK: - Tall substrate card

/// One tall, vertical substrate card for the iOS picker: a real mini-render of
/// the substrate filling most of the card, with the style name + family/texture
/// caption on a glassy footer and a clear accent-ringed selected state.
struct MobileSubstrateCard: View {
    let descriptor: SubstrateDescriptor
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var thumbnail: UIImage?

    private let cardWidth: CGFloat = 126
    private let cardHeight: CGFloat = 172
    private let corner: CGFloat = 18

    /// Re-rasterize when the look that's being shown changes (kernel family swap
    /// re-tints the shared "Plain" card; appearance flips polarity).
    private var thumbKey: String {
        "\(descriptor.id)|\(descriptor.family.rawValue)|\(colorScheme == .dark ? "d" : "l")"
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 0) {
                preview
                caption
            }
            .frame(width: cardWidth, height: cardHeight)
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .strokeBorder(isSelected ? MobileTheme.ember : Color.primary.opacity(0.10),
                                  lineWidth: isSelected ? 2 : 0.75)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected { selectedBadge }
            }
            .shadow(color: isSelected ? MobileTheme.ember.opacity(0.40) : .black.opacity(0.18),
                    radius: isSelected ? 11 : 5, x: 0, y: isSelected ? 5 : 3)
            .scaleEffect(isSelected ? 1.0 : 0.97)
            .animation(.spring(response: 0.32, dampingFraction: 0.8), value: isSelected)
        }
        .buttonStyle(.plain)
        .task(id: thumbKey) {
            // Defer one runloop so the row lays out before we rasterize, then
            // fetch (or build once, then cache) the thumbnail off the first hitch.
            await Task.yield()
            let img = SubstrateThumbnail.image(for: descriptor, dark: colorScheme == .dark)
            withAnimation(.easeOut(duration: 0.28)) { thumbnail = img }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(descriptor.label), \(descriptor.family.displayName) substrate")
        .accessibilityAddTraits(accessibilityTraits)
    }

    private var accessibilityTraits: AccessibilityTraits {
        var traits: AccessibilityTraits = .isButton
        if isSelected { traits.insert(.isSelected) }
        return traits
    }

    /// The mini-render filling the top of the card, with a soft scrim toward the
    /// caption for legibility. Falls back to the family accent wash until the
    /// bitmap lands (and if rendering ever fails).
    private var preview: some View {
        ZStack {
            if let thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [descriptor.accent.color, descriptor.accent2.color],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                ProgressView()
                    .controlSize(.small)
                    .tint(.white.opacity(0.7))
            }
            LinearGradient(colors: [.clear, .clear, .black.opacity(0.30)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: cardWidth, height: cardHeight - captionHeight)
        .clipped()
    }

    private let captionHeight: CGFloat = 52

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(descriptor.label)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 4) {
                Image(systemName: descriptor.family.symbolName)
                    .font(.system(size: 8, weight: .bold))
                Text(descriptor.hint.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(0.7)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? MobileTheme.ember : Color.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: captionHeight, alignment: .leading)
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial)
    }

    private var selectedBadge: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 10, weight: .heavy))
            .foregroundStyle(.white)
            .padding(5)
            .background(Circle().fill(MobileTheme.ember))
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
            .padding(8)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .transition(.scale.combined(with: .opacity))
    }
}

// MARK: - Live backdrop preview strip

/// A prominent, live preview of the swarm substrate sitting OVER the active
/// backdrop kernel. It renders the real ``WebsiteBackgroundView`` — the same
/// WebGL kernel + transparent swarm composite the app paints behind every
/// screen — so tapping a card (which writes the shared `substrateKey`) swaps the
/// material here instantly, no navigation required.
struct SubstrateLivePreviewStrip: View {
    @AppStorage(SwarmSubstratePreferences.substrateKey) private var substrateID: String = SubstrateCatalog.plainID
    @AppStorage(MobileBackdropKernel.storageKey) private var mobileBackdropKernel: String = MobileBackdropKernel.defaultKernel.rawValue
    @Environment(\.colorScheme) private var colorScheme
    @State private var pulse = false

    private let stripHeight: CGFloat = 154
    private let corner: CGFloat = 20

    /// The descriptor that will actually render for the live selection (a pick
    /// that doesn't belong to the active kernel's family resolves to that
    /// family's Plain), so the caption always names what is on screen.
    private var resolved: SubstrateDescriptor {
        SubstrateCatalog.resolved(forKernel: mobileBackdropKernel, selectedID: substrateID)
    }

    var body: some View {
        ZStack {
            // The real composite. Pinned to the strip frame and clipped; hit
            // testing off so taps fall through to the cards / form.
            WebsiteBackgroundView(accent: MobileTheme.ember, visibility: .prominent)
                .environment(\.webglBackdropAncestorActive, true)
                .environment(\.mobileBackgroundVisibility, .prominent)
                .allowsHitTesting(false)
                .frame(height: stripHeight)
                .frame(maxWidth: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))

            caption
        }
        .frame(height: stripHeight)
        .overlay(alignment: .topLeading) { liveBadge }
        .overlay(
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(.white.opacity(0.12), lineWidth: 0.75)
        )
        .shadow(color: .black.opacity(0.25), radius: 8, x: 0, y: 4)
        .onAppear { pulse = true }
    }

    /// Bottom material bar naming the live selection; cross-fades as it changes.
    private var caption: some View {
        VStack {
            Spacer(minLength: 0)
            HStack(spacing: 9) {
                Image(systemName: resolved.family.symbolName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(MobileTheme.ember)
                VStack(alignment: .leading, spacing: 1) {
                    Text(resolved.label)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text("\(resolved.family.displayName) · \(resolved.hint)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
            .id(resolved.id)
            .transition(.opacity)
        }
        .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
        .animation(.easeInOut(duration: 0.3), value: resolved.id)
    }

    private var liveBadge: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(MobileTheme.ember)
                .frame(width: 6, height: 6)
                .opacity(pulse ? 1 : 0.35)
                .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulse)
            Text("LIVE")
                .font(.system(size: 9, weight: .heavy))
                .tracking(1.0)
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(.black.opacity(0.35)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .padding(10)
    }
}
