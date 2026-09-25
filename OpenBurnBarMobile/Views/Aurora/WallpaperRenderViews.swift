import AVFoundation
import CoreMedia
import ImageIO
import OpenBurnBarCore
import Photos
import SwiftUI
import UIKit
import UniformTypeIdentifiers

// MARK: - Offline Swarm Render View

@MainActor
struct OfflineSwarmRenderView: View {
    let simulation: SwarmSimulation
    let size: CGSize
    let colorScheme: ColorScheme
    let backgroundColor: Color

    var body: some View {
        ZStack {
            backgroundColor
            Canvas(rendersAsynchronously: false) { context, canvasSize in
                simulation.draw(into: context, size: canvasSize, scheme: colorScheme, isBatteryThrottled: false)
            }
            RadialGradient(
                colors: [.clear, backgroundColor.opacity(0.7)],
                center: .center,
                startRadius: 120,
                endRadius: 500
            )
        }
        .frame(width: size.width, height: size.height)
    }
}

// MARK: - Save Result Sheet

struct SaveResultSheet: View {
    let result: WallpaperGeneratorView.SaveResult
    let colorScheme: ColorScheme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            // Icon
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [iconBgStart, iconBgEnd],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 80, height: 80)

                Image(systemName: iconName)
                    .font(.system(size: 36, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [iconColorStart, iconColorEnd],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
            .padding(.top, 16)

            // Text content
            VStack(spacing: 8) {
                Text(titleText)
                    .font(.title2.bold())
                    .foregroundStyle(colorScheme == .dark ? .white : .black)

                Text(messageText)
                    .font(.subheadline)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(colorScheme == .dark ? .white.opacity(0.7) : .black.opacity(0.6))
                    .padding(.horizontal, 24)
            }

            // Options/Actions
            VStack(spacing: 12) {
                switch result {
                case .successStill, .successLive:
                    Button(action: openSettingsWallpaper) {
                        HStack {
                            Image(systemName: "gearshape.fill")
                            Text("Set in Wallpaper Settings")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            LinearGradient(
                                colors: [MobileTheme.ember, MobileTheme.blaze],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                        .foregroundStyle(.white)
                    }

                    Button(action: openPhotosApp) {
                        HStack {
                            Image(systemName: "photo.fill.on.rectangle.fill")
                            Text("View in Photos App")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(colorScheme == .dark ? .white : .black)
                    }

                case .permissionDenied:
                    Button(action: openAppSettings) {
                        HStack {
                            Image(systemName: "gearshape.fill")
                            Text("Open Settings")
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(
                            LinearGradient(
                                colors: [MobileTheme.ember, MobileTheme.blaze],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 14)
                        )
                        .foregroundStyle(.white)
                    }

                case .error:
                    Button {
                        dismiss()
                    } label: {
                        Text("Dismiss")
                            .fontWeight(.semibold)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(colorScheme == .dark ? Color.white.opacity(0.1) : Color.black.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                            .foregroundStyle(colorScheme == .dark ? .white : .black)
                    }
                }

                if case .permissionDenied = result {
                    Button("Cancel") {
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.gray)
                    .padding(.top, 8)
                } else {
                    Button("Done") {
                        dismiss()
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.gray)
                    .padding(.top, 8)
                }
            }
            .padding(.horizontal, 24)
        }
        .padding(.vertical, 32)
        .background(colorScheme == .dark ? Color(red: 0.08, green: 0.06, blue: 0.05) : Color(red: 0.98, green: 0.98, blue: 0.96))
        .presentationDetents([.fraction(0.55), .medium])
        .presentationDragIndicator(.visible)
    }

    private var iconName: String {
        switch result {
        case .successStill: return "photo.on.rectangle.angled"
        case .successLive: return "livephoto"
        case .permissionDenied: return "exclamationmark.shield.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }

    private var iconColorStart: Color {
        switch result {
        case .successStill, .successLive: return MobileTheme.ember
        case .permissionDenied: return .orange
        case .error: return .red
        }
    }

    private var iconColorEnd: Color {
        switch result {
        case .successStill, .successLive: return MobileTheme.blaze
        case .permissionDenied: return .yellow
        case .error: return .orange
        }
    }

    private var iconBgStart: Color {
        iconColorStart.opacity(0.2)
    }

    private var iconBgEnd: Color {
        iconColorEnd.opacity(0.1)
    }

    private var titleText: String {
        switch result {
        case .successStill: return "Still Wallpaper Saved"
        case .successLive: return "Live Photo Saved!"
        case .permissionDenied: return "Photos Access Required"
        case .error: return "Save Failed"
        }
    }

    private var messageText: String {
        switch result {
        case .successStill:
            return "Your high-resolution still image is now saved to your Photos library."
        case .successLive:
            return "Your dynamic loop is now saved as a wallpaper-ready Live Photo. Set it from Wallpaper or view it in Photos."
        case .permissionDenied:
            return "Enable Photos access in Settings → BurnBar → Photos to save wallpapers."
        case .error(let msg):
            return msg
        }
    }

    private func openSettingsWallpaper() {
        WallpaperSettingsDeepLink.open()
        dismiss()
    }

    private func openPhotosApp() {
        if let url = URL(string: "photos-redirect://") {
            UIApplication.shared.open(url)
        }
        dismiss()
    }

    private func openAppSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) {
            UIApplication.shared.open(url)
        }
        dismiss()
    }
}

// MARK: - Liquid Glass helper (file-scoped)

extension View {
    /// iOS 26 Liquid Glass for surfaces whose legacy styling the shared
    /// adapters in `Theme/LiquidGlass.swift` cannot reproduce exactly
    /// (opacity-tweaked materials, shapeless backgrounds). On iOS 26 the
    /// glass samples the live swarm directly — nothing is drawn underneath
    /// it; on earlier systems the original background runs byte-identical
    /// via the `legacy` closure.
    @ViewBuilder
    func wallpaperLiquidGlass<Legacy: View>(
        in shape: some Shape,
        legacy: (Self) -> Legacy
    ) -> some View {
        if #available(iOS 26, *) {
            self.liquidGlassEffect(.regular, in: shape)
        } else {
            legacy(self)
        }
    }
}

// MARK: - Preview

#Preview {
    WallpaperGeneratorView(
        colorDriver: SwarmColorDriver(
            mode: .idle,
            providers: [
                .init(provider: .claudeCode, weight: 0.5),
                .init(provider: .cursor, weight: 0.25),
                .init(provider: .codex, weight: 0.15),
                .init(provider: .windsurf, weight: 0.10)
            ],
            totalBurnRateUSD: 3.50
        )
    )
}
