// Cursor style + pointer/tap/co-pilot overlay subviews for the mirror.
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

enum MirrorCursorStyle: String, CaseIterable, Identifiable {
    case mercury
    case ember
    case aurora
    case white
    case hidden

    var id: String { rawValue }

    var label: String {
        switch self {
        case .mercury: return "Mercury cursor"
        case .ember: return "Ember cursor"
        case .aurora: return "Aurora cursor"
        case .white: return "White cursor"
        case .hidden: return "Hide cursor"
        }
    }
}

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
