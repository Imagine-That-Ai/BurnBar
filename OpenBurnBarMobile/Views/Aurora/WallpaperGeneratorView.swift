import SwiftUI
import OpenBurnBarCore
#if canImport(UIKit)
import UIKit
import Photos
#endif

// MARK: - Wallpaper Generator View
//
// Full-screen wallpaper preview + export. Renders the data-driven swarm
// at device resolution with the user's actual provider usage colors, then
// saves to Photos for manual wallpaper setting.
//
// The swarm runs live in the preview so you see exactly what you'll get.
// Tap "Save" to freeze the current frame and export at screen scale.

struct WallpaperGeneratorView: View {
    let colorDriver: SwarmColorDriver

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    @State private var selectedStyle: WallpaperStyle = .swarmDark
    @State private var showClock: Bool = true
    @State private var showProviderLabels: Bool = true
    @State private var isSaving = false
    @State private var saveResult: SaveResult?
    @State private var previewPhase: CGFloat = 0

    enum WallpaperStyle: String, CaseIterable, Identifiable {
        case swarmDark = "Swarm Dark"
        case swarmLight = "Swarm Light"
        case swarmAMOLED = "AMOLED"
        case swarmEmber = "Ember Glow"

        var id: String { rawValue }

        var backgroundColor: Color {
            switch self {
            case .swarmDark: return Color(red: 0.055, green: 0.051, blue: 0.043)
            case .swarmLight: return Color(red: 0.93, green: 0.94, blue: 0.90)
            case .swarmAMOLED: return .black
            case .swarmEmber: return Color(red: 0.08, green: 0.06, blue: 0.04)
            }
        }

        var isDark: Bool {
            switch self {
            case .swarmLight: return false
            default: return true
            }
        }
    }

    enum SaveResult: Identifiable {
        case success
        case permissionDenied
        case error(String)

        var id: String {
            switch self {
            case .success: return "success"
            case .permissionDenied: return "denied"
            case .error(let msg): return "error-\(msg)"
            }
        }
    }

    var body: some View {
        ZStack {
            // Full-screen swarm preview
            wallpaperCanvas
                .ignoresSafeArea()

            // Overlay controls
            VStack {
                topBar
                Spacer()
                providerLegend
                bottomControls
            }
            .padding()
        }
        .statusBarHidden(true)
        .alert(item: $saveResult) { result in
            switch result {
            case .success:
                Alert(
                    title: Text("Saved to Photos"),
                    message: Text("Open Settings → Wallpaper to set your new BurnBar wallpaper."),
                    dismissButton: .default(Text("Done")) { dismiss() }
                )
            case .permissionDenied:
                Alert(
                    title: Text("Photos Access Required"),
                    message: Text("Enable Photos access in Settings → BurnBar → Photos to save wallpapers."),
                    dismissButton: .default(Text("OK"))
                )
            case .error(let msg):
                Alert(
                    title: Text("Save Failed"),
                    message: Text(msg),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
        .preferredColorScheme(selectedStyle.isDark ? .dark : .light)
    }

    // MARK: - Wallpaper Canvas

    @ViewBuilder
    private var wallpaperCanvas: some View {
        ZStack {
            selectedStyle.backgroundColor
                .ignoresSafeArea()

            SwarmCanvasView(
                accent: selectedStyle == .swarmEmber ? MobileTheme.ember : .white,
                pace: .cinematic,
                colorDriver: colorDriver
            )

            // Subtle radial vignette
            RadialGradient(
                colors: [
                    .clear,
                    selectedStyle.backgroundColor.opacity(0.7)
                ],
                center: .center,
                startRadius: 120,
                endRadius: 500
            )
            .allowsHitTesting(false)

            // Optional clock overlay (shows wallpaper context)
            if showClock {
                VStack(spacing: 2) {
                    Text(clockTime)
                        .font(.system(size: 72, weight: .thin, design: .rounded))
                        .foregroundStyle(selectedStyle.isDark ? .white : .black)
                        .opacity(0.3)
                    Text(clockDate)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(selectedStyle.isDark ? .white : .black)
                        .opacity(0.2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 100)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack {
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title2)
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(selectedStyle.isDark ? .white.opacity(0.7) : .black.opacity(0.5))
            }

            Spacer()

            // Style picker
            Menu {
                ForEach(WallpaperStyle.allCases) { style in
                    Button {
                        withAnimation(.spring(response: 0.4)) {
                            selectedStyle = style
                        }
                    } label: {
                        HStack {
                            Text(style.rawValue)
                            if style == selectedStyle {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "paintbrush.fill")
                    Text(selectedStyle.rawValue)
                        .font(.subheadline.weight(.semibold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .foregroundStyle(selectedStyle.isDark ? .white : .black)
            }
        }
        .padding(.top, 50)
    }

    // MARK: - Provider Legend

    @ViewBuilder
    private var providerLegend: some View {
        if showProviderLabels, !colorDriver.providers.isEmpty {
            HStack(spacing: 12) {
                ForEach(Array(colorDriver.providers.prefix(4).enumerated()), id: \.offset) { _, pw in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(DesignSystemColors.primary(for: pw.provider))
                            .frame(width: 8, height: 8)
                        Text(pw.provider.rawValue)
                            .font(.system(size: 11, weight: .medium, design: .rounded))
                            .foregroundStyle(selectedStyle.isDark ? .white.opacity(0.6) : .black.opacity(0.5))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial.opacity(0.6), in: Capsule())
            .padding(.bottom, 12)
        }
    }

    // MARK: - Bottom Controls

    private var bottomControls: some View {
        HStack(spacing: 16) {
            // Toggle options
            HStack(spacing: 12) {
                toggleButton(
                    icon: "clock.fill",
                    isOn: $showClock,
                    label: "Clock"
                )
                toggleButton(
                    icon: "tag.fill",
                    isOn: $showProviderLabels,
                    label: "Labels"
                )
            }

            Spacer()

            // Save button
            Button {
                Task { await saveWallpaper() }
            } label: {
                HStack(spacing: 8) {
                    if isSaving {
                        ProgressView()
                            .tint(.white)
                            .scaleEffect(0.8)
                    } else {
                        Image(systemName: "square.and.arrow.down.fill")
                    }
                    Text(isSaving ? "Saving…" : "Save Wallpaper")
                        .font(.subheadline.weight(.bold))
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [MobileTheme.ember, MobileTheme.blaze],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    in: Capsule()
                )
                .foregroundStyle(.white)
            }
            .disabled(isSaving)
        }
        .padding(.bottom, 30)
    }

    @ViewBuilder
    private func toggleButton(icon: String, isOn: Binding<Bool>, label: String) -> some View {
        Button {
            withAnimation(.spring(response: 0.3)) {
                isOn.wrappedValue.toggle()
            }
        } label: {
            Image(systemName: icon)
                .font(.system(size: 14))
                .frame(width: 36, height: 36)
                .background(
                    isOn.wrappedValue
                        ? AnyShapeStyle(.ultraThinMaterial)
                        : AnyShapeStyle(Color.white.opacity(0.1))
                    , in: Circle()
                )
                .foregroundStyle(
                    isOn.wrappedValue
                        ? (selectedStyle.isDark ? Color.white : Color.black)
                        : Color.gray
                )
        }
        .accessibilityLabel(label)
        .accessibilityAddTraits(isOn.wrappedValue ? .isSelected : [])
    }

    // MARK: - Clock

    private var clockTime: String {
        let f = DateFormatter()
        f.dateFormat = "h:mm"
        return f.string(from: Date())
    }

    private var clockDate: String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d"
        return f.string(from: Date())
    }

    // MARK: - Save

    @MainActor
    private func saveWallpaper() async {
        #if canImport(UIKit)
        isSaving = true
        defer { isSaving = false }

        // Request Photos permission
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let granted: Bool
        switch status {
        case .authorized, .limited:
            granted = true
        case .denied, .restricted:
            granted = false
        case .notDetermined:
            granted = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                    continuation.resume(returning: newStatus == .authorized || newStatus == .limited)
                }
            }
        @unknown default:
            granted = false
        }

        guard granted else {
            saveResult = .permissionDenied
            return
        }

        // Render the wallpaper at screen scale
        let screenBounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale

        let wallpaperView = ZStack {
            selectedStyle.backgroundColor
            SwarmCanvasView(
                accent: selectedStyle == .swarmEmber ? MobileTheme.ember : .white,
                pace: .cinematic,
                colorDriver: colorDriver
            )
            RadialGradient(
                colors: [.clear, selectedStyle.backgroundColor.opacity(0.7)],
                center: .center,
                startRadius: 120,
                endRadius: 500
            )
        }
        .frame(width: screenBounds.width, height: screenBounds.height)
        .preferredColorScheme(selectedStyle.isDark ? .dark : .light)

        let renderer = ImageRenderer(content: wallpaperView)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(
            width: screenBounds.width,
            height: screenBounds.height
        )

        guard let uiImage = renderer.uiImage else {
            saveResult = .error("Failed to render wallpaper image.")
            return
        }

        guard let data = uiImage.pngData() else {
            saveResult = .error("Failed to encode wallpaper as PNG.")
            return
        }

        // Write to temp file and save to Photos
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar_wallpaper_\(Int(Date().timeIntervalSince1970)).png")
        do {
            try data.write(to: tempURL)
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .photo, fileURL: tempURL, options: nil)
                } completionHandler: { success, error in
                    try? FileManager.default.removeItem(at: tempURL)
                    if success {
                        continuation.resume()
                    } else {
                        continuation.resume(
                            throwing: error ?? NSError(domain: "WallpaperGenerator", code: -1)
                        )
                    }
                }
            }
            saveResult = .success
        } catch {
            saveResult = .error(error.localizedDescription)
        }
        #endif
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
