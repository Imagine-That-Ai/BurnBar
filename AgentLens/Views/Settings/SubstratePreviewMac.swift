import AppKit
import SwiftUI
import OpenBurnBarCore

// MARK: - Substrate thumbnail rasterizer (macOS)
//
// The macOS twin of iOS `SubstrateThumbnail` (OpenBurnBarMobile/Views/You/
// SubstratePreview.swift). Renders a static, high-fidelity preview of one
// substrate by driving the EXACT `SwarmSubstrate.paint(_:into:)` path the live
// engine uses, over a synthetic provider-glyph cloud, and caching the resulting
// `NSImage` per (id, family, polarity).
//
// **Why static thumbnails.** The Appearance pane already carries ONE live
// preview — `AppearancePreviewCard`'s mini `SwarmCanvasView` repaints the
// selected substrate in real time. Stacking a second animated canvas per catalog
// card would multiply the main-actor frame cost for no extra signal. Rasterizing
// each substrate ONCE with `ImageRenderer` and compositing a cheap cached
// `NSImage` shows every substrate's true material (Caustic Pool, Glass Ribbon,
// Stellar Plasma, …) while the single live element up top carries the motion.
@MainActor
enum SubstrateThumbnailMac {
    /// Logical render size; rendered at 2× and shown scaled-to-fill in the card.
    static let renderSize = CGSize(width: 220, height: 250)

    private static var cache: [String: NSImage] = [:]

    /// Cached thumbnail for `descriptor` in the given polarity, building it on
    /// first request. `family` is part of the key because the six "Plain"
    /// descriptors share id `"plain"` yet carry different family accents.
    static func image(for descriptor: SubstrateDescriptor, dark: Bool) -> NSImage? {
        let key = "\(descriptor.id)|\(descriptor.family.rawValue)|\(dark ? "d" : "l")"
        if let hit = cache[key] { return hit }
        guard let img = render(descriptor, dark: dark) else { return nil }
        cache[key] = img
        return img
    }

    // MARK: Rasterization

    private static func render(_ descriptor: SubstrateDescriptor, dark: Bool) -> NSImage? {
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
                // return `false`; draw the dots ourselves so the "Plain · dots"
                // card still reads as a coloured swarm field.
                let handled = substrate.paint(frame, into: c)
                if !handled { drawDots(dots, into: &c) }
            }
        }
        .frame(width: size.width, height: size.height)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        renderer.isOpaque = true
        renderer.proposedSize = ProposedViewSize(size)
        return renderer.nsImage
    }

    /// The subtle plate behind the swarm — a dark slate (or pale haze in light
    /// polarity) so additive / `.plusLighter` materials bloom the way they do
    /// over the real backdrop instead of washing out on white.
    private static func panel(dark: Bool) -> some View {
        LinearGradient(
            colors: dark
                ? [Color(red: 0.06, green: 0.06, blue: 0.10), Color(red: 0.02, green: 0.02, blue: 0.05)]
                : [Color(red: 0.94, green: 0.93, blue: 0.97), Color(red: 0.87, green: 0.87, blue: 0.92)],
            startPoint: .top, endPoint: .bottom)
    }

    /// Default dot render for substrates that decline the frame.
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
    /// lets flow/streamline idioms read; the formed regime lets shape-keyed
    /// materials express their full character.
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
    /// does, tinting `stage` with the descriptor's own family accents so each
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

// MARK: - Tall substrate card (macOS)

/// One tall, vertical substrate card for the macOS Appearance picker: a real
/// mini-render of the substrate filling most of the card, with the style name +
/// family/texture caption on a footer and a clear accent-ringed selected state.
/// The macOS twin of iOS `MobileSubstrateCard`.
struct MacSubstrateCard: View {
    let descriptor: SubstrateDescriptor
    let isSelected: Bool
    let action: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var thumbnail: NSImage?
    @State private var isHovering = false

    private let cardWidth: CGFloat = 116
    private let cardHeight: CGFloat = 158
    private let corner: CGFloat = 14
    private let captionHeight: CGFloat = 46

    /// Re-rasterize when the look being shown changes (kernel-family swap
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
                    .strokeBorder(isSelected ? DesignSystem.Colors.ember : DesignSystem.Colors.border,
                                  lineWidth: isSelected ? 2 : 0.75)
            )
            .overlay(alignment: .topTrailing) {
                if isSelected { selectedBadge }
            }
            .shadow(color: isSelected ? DesignSystem.Colors.ember.opacity(0.35) : .black.opacity(0.18),
                    radius: isSelected ? 9 : 4, x: 0, y: isSelected ? 4 : 2)
            .scaleEffect(isHovering && !isSelected ? 1.02 : 1.0)
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
            .animation(.easeOut(duration: 0.14), value: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .task(id: thumbKey) {
            await Task.yield()
            let img = SubstrateThumbnailMac.image(for: descriptor, dark: colorScheme == .dark)
            withAnimation(.easeOut(duration: 0.25)) { thumbnail = img }
        }
        .help("\(descriptor.label) — \(descriptor.family.displayName) substrate")
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
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            } else {
                LinearGradient(colors: [descriptor.accent.color, descriptor.accent2.color],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                ProgressView()
                    .controlSize(.small)
            }
            LinearGradient(colors: [.clear, .clear, .black.opacity(0.30)],
                           startPoint: .top, endPoint: .bottom)
        }
        .frame(width: cardWidth, height: cardHeight - captionHeight)
        .clipped()
    }

    private var caption: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(descriptor.label)
                .font(DesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            HStack(spacing: 4) {
                Image(systemName: descriptor.family.symbolName)
                    .font(.system(size: 7, weight: .bold))
                Text(descriptor.hint.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.6)
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? DesignSystem.Colors.ember : DesignSystem.Colors.textMuted)
        }
        .frame(maxWidth: .infinity, minHeight: captionHeight, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(DesignSystem.Colors.surfaceElevated)
    }

    private var selectedBadge: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 9, weight: .heavy))
            .foregroundStyle(.white)
            .padding(4)
            .background(Circle().fill(DesignSystem.Colors.ember))
            .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
            .padding(6)
            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
            .transition(.scale.combined(with: .opacity))
    }
}
