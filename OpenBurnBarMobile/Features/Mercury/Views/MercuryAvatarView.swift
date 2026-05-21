import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// Avatar circle for `MercuryHeaderCard`. Renders one of four styles
/// (`.laptop`, `.symbol`, `.emoji`, `.photo`) inside the same animated
/// gradient ring so switching kinds is a smooth crossfade rather than a
/// layout shuffle.
struct MercuryAvatarView: View {
    let style: MercuryAvatarStyle
    let isOnline: Bool
    let accent: Color
    let pulse: Bool
    let reduceMotion: Bool

    @State private var rotateFirst = 0.0
    @State private var rotateSecond = 0.0
    @State private var breatheScale = 0.95

    var body: some View {
        ZStack {
            // Ambient breathing/color-shifting radial auroras in the background
            if isOnline {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                gradient: Gradient(colors: [accent.opacity(0.35), Color.clear]),
                                center: .center,
                                startRadius: 10,
                                endRadius: 70
                            )
                        )
                        .frame(width: 130, height: 130)

                    AngularGradient(
                        colors: [accent, .purple, .blue, accent],
                        center: .center
                    )
                    .clipShape(Circle())
                    .frame(width: 108, height: 108)
                    .blur(radius: 12)
                    .rotationEffect(.degrees(rotateFirst))
                    .opacity(0.4)
                    
                    AngularGradient(
                        colors: [.purple, accent, .cyan, .purple],
                        center: .center
                    )
                    .clipShape(Circle())
                    .frame(width: 98, height: 98)
                    .blur(radius: 16)
                    .rotationEffect(.degrees(rotateSecond))
                    .opacity(0.35)
                }
                .scaleEffect(breatheScale)
            } else {
                Circle()
                    .fill(
                        RadialGradient(
                            gradient: Gradient(colors: [Color.gray.opacity(0.15), Color.clear]),
                            center: .center,
                            startRadius: 10,
                            endRadius: 60
                        )
                    )
                    .frame(width: 120, height: 120)
            }

            Circle()
                .stroke(
                    LinearGradient(
                        colors: [
                            Color.white.opacity(0.65),
                            Color.white.opacity(0.15),
                            accent.opacity(0.5)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.8
                )
                .frame(width: 88, height: 88)
                .scaleEffect(breatheScale)
                .opacity(isOnline ? 1.0 : 0.45)

            Circle()
                .stroke(accent.opacity(0.4), lineWidth: 3.5)
                .blur(radius: 4)
                .frame(width: 88, height: 88)
                .scaleEffect(breatheScale)
                .opacity(isOnline ? 0.75 : 0)

            content
                .frame(width: 64, height: 64)
                .clipShape(Circle())
                .shadow(color: accent.opacity(0.4), radius: 10, x: 0, y: 5)
        }
        .onAppear {
            if !reduceMotion {
                withAnimation(.linear(duration: 10.0).repeatForever(autoreverses: false)) {
                    rotateFirst = 360.0
                }
                withAnimation(.linear(duration: 14.0).repeatForever(autoreverses: false)) {
                    rotateSecond = -360.0
                }
                withAnimation(.easeInOut(duration: 2.2).repeatForever(autoreverses: true)) {
                    breatheScale = 1.06
                }
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var content: some View {
        switch style {
        case .laptop:
            Image(systemName: "macbook")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color.white.opacity(0.8)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        case .symbol(let name):
            Image(systemName: name)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(
                    LinearGradient(
                        colors: [.white, Color.white.opacity(0.8)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
        case .emoji(let glyph):
            Text(glyph)
                .font(.system(size: 36))
        case .photo(let data):
            #if canImport(UIKit)
            if let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage)
                    .resizable()
                    .scaledToFill()
            } else {
                Image(systemName: "person.crop.circle")
                    .font(.system(size: 32))
                    .foregroundStyle(.white)
            }
            #else
            Image(systemName: "person.crop.circle")
                .font(.system(size: 32))
                .foregroundStyle(.white)
            #endif
        }
    }
}
