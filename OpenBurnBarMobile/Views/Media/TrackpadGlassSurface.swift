// Glass trackpad surface with adjustable pointer sensitivity.
// Extracted from ScreenShareViewerView.swift (behavior-preserving split).
import SwiftUI
@preconcurrency import AVKit
@preconcurrency import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif
import OpenBurnBarMedia
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

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
        .accessibilityElement()
        .accessibilityIdentifier("mercury.trackpad.surface")
        .accessibilityLabel("Glass Trackpad")
        .accessibilityHint("Drag to move the Mac pointer, tap to click, or swipe vertically to scroll")
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
