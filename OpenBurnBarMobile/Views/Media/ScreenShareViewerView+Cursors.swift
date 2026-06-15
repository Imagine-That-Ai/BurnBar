import SwiftUI
@preconcurrency import AVKit
@preconcurrency import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif
import OpenBurnBarMedia
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

// Tap feedback, co-pilot ring, cyber cursor, pointer cursor, trackpad glass surface.
// Extracted from ScreenShareViewerView.swift (god-file decomposition) — same module, verbatim (incl. #if guards).

struct TapFeedbackMarker: View {
    let point: CGPoint
    @State private var bloomAngle: Double = 0
    @State private var animScale: CGFloat = 0.5
    @State private var animOpacity: Double = 1.0

    var body: some View {
        ZStack {
            // Concentric ring 1
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [Color(red: 0.17, green: 0.79, blue: 0.75), .white],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
                .frame(width: 44, height: 44)
                .scaleEffect(animScale)
                .opacity(animOpacity)

            // Concentric ring 2
            Circle()
                .stroke(Color.white.opacity(0.5), lineWidth: 1)
                .frame(width: 24, height: 24)
                .scaleEffect(animScale * 0.7)
                .opacity(animOpacity * 0.8)

            // Center dot
            Circle()
                .fill(Color(red: 0.17, green: 0.79, blue: 0.75))
                .frame(width: 8, height: 8)
                .shadow(color: Color(red: 0.17, green: 0.79, blue: 0.75).opacity(0.6), radius: 4)
        }
        .position(point)
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) {
                animScale = 1.2
                animOpacity = 0.0
            }
        }
        .accessibilityHidden(true)
    }
}

struct CoPilotTargetRing: View {
    let point: CGPoint
    @State private var animScale: CGFloat = 0.6
    @State private var animPulse: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Outermost target ring
            Circle()
                .stroke(
                    LinearGradient(
                        colors: [.red, .orange],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 2
                )
                .frame(width: 48, height: 48)
                .scaleEffect(animScale)

            // Reticle lines (crosshairs)
            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: 16)
                .offset(y: -16)

            Rectangle()
                .fill(Color.red)
                .frame(width: 2, height: 16)
                .offset(y: 16)

            Rectangle()
                .fill(Color.red)
                .frame(width: 16, height: 2)
                .offset(x: -16)

            Rectangle()
                .fill(Color.red)
                .frame(width: 16, height: 2)
                .offset(x: 16)

            // Inner pulsing ring
            Circle()
                .stroke(Color.red.opacity(0.6), lineWidth: 1.5)
                .frame(width: 28, height: 28)
                .scaleEffect(animPulse)

            // Center core dot
            Circle()
                .fill(Color.red)
                .frame(width: 6, height: 6)
                .shadow(color: .red.opacity(0.8), radius: 4)
        }
        .position(point)
        .onAppear {
            withAnimation(.spring(response: 0.38, dampingFraction: 0.62)) {
                animScale = 1.0
            }
            withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true)) {
                animPulse = 1.25
            }
        }
        .accessibilityHidden(true)
    }
}

struct CyberCursorArrow: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let scaleX = rect.width / 24.0
        let scaleY = rect.height / 24.0

        path.move(to: CGPoint(x: 0 * scaleX, y: 0 * scaleY))
        path.addLine(to: CGPoint(x: 18 * scaleX, y: 13 * scaleY))
        path.addLine(to: CGPoint(x: 10 * scaleX, y: 14 * scaleY))
        path.addLine(to: CGPoint(x: 15 * scaleX, y: 23 * scaleY))
        path.addLine(to: CGPoint(x: 12 * scaleX, y: 24 * scaleY))
        path.addLine(to: CGPoint(x: 7 * scaleX, y: 15 * scaleY))
        path.addLine(to: CGPoint(x: 0 * scaleX, y: 19 * scaleY))
        path.closeSubpath()

        return path
    }
}

struct MirrorPointerCursor: View {
    let point: CGPoint
    let size: CGFloat
    let style: MirrorCursorStyle
    let usePremiumSOTAUX: Bool
    @State private var haloScale: CGFloat = 1.0

    var body: some View {
        Group {
            if usePremiumSOTAUX {
                ZStack(alignment: .topLeading) {
                    Circle()
                        .stroke(glowColor, lineWidth: 1.5)
                        .frame(width: 8, height: 8)
                        .scaleEffect(haloScale)
                        .opacity(Double(2.0 - haloScale))
                        .offset(x: -4, y: -4)

                    Circle()
                        .fill(glowColor)
                        .frame(width: 3, height: 3)
                        .offset(x: -1.5, y: -1.5)

                    CyberCursorArrow()
                        .fill(
                            LinearGradient(
                                colors: [.white, glowColor.opacity(0.8)],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .frame(width: size, height: size)
                        .overlay(
                            CyberCursorArrow()
                                .stroke(Color.white, lineWidth: 1.0)
                        )
                        .shadow(color: glowColor.opacity(0.5), radius: 6, x: 2, y: 2)
                }
                .frame(width: size, height: size)
                .offset(x: size / 2, y: size / 2)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.0).repeatForever(autoreverses: false)) {
                        haloScale = 2.0
                    }
                }
            } else {
                cursorGlyph
                    .font(.system(size: size, weight: .bold))
                    .shadow(color: glowColor.opacity(0.65), radius: 8, x: 0, y: 0)
                    .shadow(color: .black.opacity(0.35), radius: 4, x: 0, y: 2)
            }
        }
        .position(point)
        .animation(.interactiveSpring(response: 0.22, dampingFraction: 0.78, blendDuration: 0), value: point)
        .transition(.scale(scale: 0.85).combined(with: .opacity))
        .accessibilityHidden(true)
    }

    private var glowColor: Color {
        switch style {
        case .mercury: return Color(red: 0.17, green: 0.79, blue: 0.75) // neon teal glow
        case .ember: return Color(red: 0.91, green: 0.44, blue: 0.38)   // neon coral/ember glow
        case .aurora: return Color(red: 0.56, green: 0.50, blue: 0.85)  // neon purple glow
        case .white: return .white
        case .hidden: return .clear
        }
    }

    @ViewBuilder
    private var cursorGlyph: some View {
        switch style {
        case .mercury:
            Image(systemName: "cursorarrow")
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color(red: 0.17, green: 0.79, blue: 0.75)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        case .ember:
            Image(systemName: "cursorarrow")
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color(red: 0.91, green: 0.44, blue: 0.38)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        case .aurora:
            Image(systemName: "cursorarrow")
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color(red: 0.56, green: 0.50, blue: 0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        case .white:
            Image(systemName: "cursorarrow")
                .foregroundStyle(.white)
        case .hidden:
            EmptyView()
        }
    }
}

struct TrackpadGlassSurface: View {
    let isVisible: Bool
    let usePremiumSOTAUX: Bool
    @Binding var sensitivity: Double
    let onActiveChange: (Bool) -> Void
    let onMove: (CGSize) -> Void
    let onClick: (Int) -> Void
    let onScroll: (Double) -> Void
    @State private var lastTranslation: CGSize = .zero
    @State private var pressStartedAt: Date?
    @State private var touchLocation: CGPoint?
    @State private var touchHistory: [CGPoint] = []
    @State private var showSensitivitySlider = false

    var body: some View {
        GeometryReader { proxy in
            let width = min(proxy.size.width * 0.46, 360)
            let height = min(proxy.size.height * 0.40, 260)

            ZStack {
                // Fine grid crosshairs in background
                trackpadGridPattern(width: width, height: height)

                // Trail ring representing current touch location
                if usePremiumSOTAUX {
                    ForEach(Array(touchHistory.enumerated()), id: \.offset) { index, point in
                        let age = CGFloat(touchHistory.count - 1 - index)
                        let opacity = 0.8 * (1.0 - age * 0.22)
                        let scale = 1.0 - age * 0.15
                        let frameSize = 24.0 * scale
                        if frameSize > 2 {
                            Circle()
                                .stroke(Color(red: 0.17, green: 0.79, blue: 0.75).opacity(Double(opacity)), lineWidth: max(0.5, 1.5 - age * 0.2))
                                .frame(width: frameSize, height: frameSize)
                                .position(point)
                        }
                    }
                } else {
                    if let touchLocation {
                        Circle()
                            .stroke(Color(red: 0.17, green: 0.79, blue: 0.75).opacity(0.8), lineWidth: 1.5)
                            .frame(width: 24, height: 24)
                            .position(touchLocation)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .frame(width: width, height: height)
            .mirrorGlassBackground(cornerRadius: 26)
            .overlay(
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: touchLocation != nil ? [Color(red: 0.17, green: 0.79, blue: 0.75), Color(red: 0.56, green: 0.50, blue: 0.85)] : [.white.opacity(0.15), .clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
                    .animation(.easeInOut(duration: 0.25), value: touchLocation != nil)
            )
            .overlay(alignment: .topLeading) {
                HStack(spacing: 6) {
                    Image(systemName: "hand.point.up.left")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Glass Trackpad")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white.opacity(0.75))
                .padding(16)
            }
            .overlay(alignment: .topTrailing) {
                trackpadSensitivityControl
                    .padding(.top, 10)
                    .padding(.trailing, 12)
            }
            .opacity(isVisible ? 1 : 0.001)
            .position(x: proxy.size.width - width / 2 - 18, y: proxy.size.height - height / 2 - 34)
            .contentShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if pressStartedAt == nil {
                            pressStartedAt = Date()
                        }
                        touchLocation = value.location
                        if usePremiumSOTAUX {
                            touchHistory.append(value.location)
                            if touchHistory.count > 4 {
                                touchHistory.removeFirst()
                            }
                        }
                        onActiveChange(true)
                        let delta = value.translation - lastTranslation
                        lastTranslation = value.translation
                        if abs(delta.width) > 0.5 || abs(delta.height) > 0.5 {
                            let scaled = CGSize(
                                width: delta.width * sensitivity,
                                height: delta.height * sensitivity
                            )
                            onMove(scaled)
                        }
                    }
                    .onEnded { value in
                        touchLocation = nil
                        touchHistory.removeAll()
                        let heldDuration = pressStartedAt.map { Date().timeIntervalSince($0) } ?? 0
                        pressStartedAt = nil
                        let distance = hypot(value.translation.width, value.translation.height)
                        if let mouseButton = ScreenShareControlInputPolicy.trackpadClickMouseButton(
                            heldDuration: heldDuration,
                            travelDistance: distance
                        ) {
                            if mouseButton == 1 {
                                triggerLightHaptic()
                            } else {
                                triggerMediumHaptic()
                            }
                            onClick(mouseButton)
                        } else if abs(value.translation.height) > abs(value.translation.width) * 1.5 {
                            onScroll(Double(value.translation.height / max(proxy.size.height, 1)))
                        }
                        lastTranslation = .zero
                        onActiveChange(false)
                    }
            )
        }
        .ignoresSafeArea()
    }

    private func triggerLightHaptic() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .light)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    private func triggerMediumHaptic() {
        #if canImport(UIKit)
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        #endif
    }

    private var sensitivityLabel: String {
        if sensitivity < 0.6 { return "Slow" }
        if sensitivity < 1.15 { return "Normal" }
        if sensitivity < 2.0 { return "Fast" }
        return "Turbo"
    }

    private var sensitivityIcon: String {
        if sensitivity < 0.6 { return "tortoise" }
        if sensitivity < 1.15 { return "figure.walk" }
        if sensitivity < 2.0 { return "hare" }
        return "bolt"
    }

    @ViewBuilder
    private var trackpadSensitivityControl: some View {
        LiquidGlassGroup(spacing: 6) {
            HStack(spacing: 6) {
                if showSensitivitySlider {
                    HStack(spacing: 8) {
                        Image(systemName: "tortoise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                        Slider(
                            value: $sensitivity,
                            in: 0.3...3.0,
                            step: 0.1
                        )
                        .tint(Color(red: 0.17, green: 0.79, blue: 0.75))
                        .frame(width: 100)
                        Image(systemName: "hare")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.5))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .liquidGlassInteractive(in: Capsule())
                    .transition(.asymmetric(
                        insertion: .scale(scale: 0.5, anchor: .trailing).combined(with: .opacity),
                        removal: .scale(scale: 0.8, anchor: .trailing).combined(with: .opacity)
                    ))
                }

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.78)) {
                        showSensitivitySlider.toggle()
                    }
                } label: {
                    Image(systemName: sensitivityIcon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 32, height: 32)
                        .liquidGlassInteractive(in: .circle)
                }
                .accessibilityLabel("Trackpad sensitivity: \(sensitivityLabel)")
                .accessibilityHint("Tap to adjust pointer speed")
            }
        }
    }

    @ViewBuilder
    private func trackpadGridPattern(width: CGFloat, height: CGFloat) -> some View {
        ZStack {
            // Thin horizontal lines
            VStack(spacing: height / 6) {
                ForEach(0..<5) { _ in
                    Divider()
                        .background(Color.white.opacity(0.04))
                }
            }
            .frame(width: width, height: height)

            // Thin vertical lines
            HStack(spacing: width / 6) {
                ForEach(0..<5) { _ in
                    Divider()
                        .background(Color.white.opacity(0.04))
                }
            }
            .frame(width: width, height: height)
        }
    }
}
