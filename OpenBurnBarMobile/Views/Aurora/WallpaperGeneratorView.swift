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
    @State private var showProviderGlyphCustomizer: Bool = false
    @State private var isSaving = false
    @State private var saveResult: SaveResult?
    @State private var previewPhase: CGFloat = 0
    @AppStorage("burnbar.wallpaper.providerGlyphs") private var providerGlyphSelectionRaw = SwarmProviderGlyphSelection.allSentinel

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

        var swarmPalette: SwarmColorPalette {
            switch self {
            case .swarmDark: return .auroraTeal
            case .swarmLight: return .forestMoss
            case .swarmAMOLED: return .cyberpunkViolet
            case .swarmEmber: return .solarFlare
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
                colorDriver: colorDriver,
                colorPalette: selectedStyle.swarmPalette,
                enabledProviderGlyphs: selectedProviderGlyphs
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
                            .font(.system(size: 12, weight: .medium, design: .rounded))
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
        VStack(spacing: 12) {
            if showProviderGlyphCustomizer {
                providerGlyphCustomizer
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

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
                    toggleButton(
                        icon: "slider.horizontal.3",
                        isOn: $showProviderGlyphCustomizer,
                        label: "Provider glyphs"
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
        }
        .padding(.bottom, 30)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showProviderGlyphCustomizer)
    }

    private var providerGlyphCustomizer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(providerGlyphSummaryText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(selectedStyle.isDark ? .white.opacity(0.78) : .black.opacity(0.62))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Spacer()

                Button("All") {
                    providerGlyphSelectionRaw = SwarmProviderGlyphSelection.encode(SwarmProviderGlyphSelection.allProviders)
                }
                .font(.caption.weight(.semibold))

                Button("None") {
                    providerGlyphSelectionRaw = SwarmProviderGlyphSelection.encode([])
                }
                .font(.caption.weight(.semibold))
            }

            LazyVGrid(columns: providerGlyphColumns, alignment: .leading, spacing: 8) {
                ForEach(SwarmProviderGlyphSelection.allProviders) { provider in
                    providerGlyphChip(provider)
                }
            }
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var providerGlyphColumns: [GridItem] {
        [
            GridItem(.adaptive(minimum: 106, maximum: 144), spacing: 8, alignment: .leading)
        ]
    }

    private var selectedProviderGlyphs: [AgentProvider] {
        SwarmProviderGlyphSelection.decode(providerGlyphSelectionRaw)
    }

    private var selectedProviderGlyphSet: Set<AgentProvider> {
        Set(selectedProviderGlyphs)
    }

    private var providerGlyphSummaryText: String {
        let count = selectedProviderGlyphs.count
        let total = SwarmProviderGlyphSelection.allProviders.count
        if count == total { return "All providers" }
        if count == 0 { return "Provider logos hidden" }
        return "\(count)/\(total) provider logos"
    }

    private func providerGlyphChip(_ provider: AgentProvider) -> some View {
        let isSelected = selectedProviderGlyphSet.contains(provider)

        return Button {
            var next = selectedProviderGlyphSet
            if isSelected {
                next.remove(provider)
            } else {
                next.insert(provider)
            }
            providerGlyphSelectionRaw = SwarmProviderGlyphSelection.encode(
                SwarmProviderGlyphSelection.allProviders.filter { next.contains($0) }
            )
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(DesignSystemColors.primary(for: provider))
                    .frame(width: 8, height: 8)

                Text(provider.displayName)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 11, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                isSelected
                    ? Color.white.opacity(selectedStyle.isDark ? 0.18 : 0.32)
                    : Color.white.opacity(selectedStyle.isDark ? 0.07 : 0.18),
                in: Capsule()
            )
            .foregroundStyle(selectedStyle.isDark ? .white : .black)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(provider.displayName)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
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
        #if canImport(UIKit) && canImport(AVFoundation)
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

        let screenBounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale
        let size = CGSize(width: screenBounds.width * scale, height: screenBounds.height * scale)

        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("burnbar_wallpaper_\(Int(Date().timeIntervalSince1970)).mov")

        do {
            let assetWriter = try AVAssetWriter(outputURL: tempURL, fileType: .mov)
            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.hevc,
                AVVideoWidthKey: size.width,
                AVVideoHeightKey: size.height
            ]
            let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            videoInput.expectsMediaDataInRealTime = false
            let pixelBufferAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: videoInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32ARGB),
                    kCVPixelBufferWidthKey as String: size.width,
                    kCVPixelBufferHeightKey as String: size.height
                ]
            )

            guard assetWriter.canAdd(videoInput) else { throw NSError(domain: "AVAssetWriter", code: -1) }
            assetWriter.add(videoInput)
            assetWriter.startWriting()
            assetWriter.startSession(atSourceTime: .zero)

            let frameCount = 60
            let fps: Int32 = 30
            let frameDuration = CMTime(value: 1, timescale: fps)

            for i in 0..<frameCount {
                while !videoInput.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }

                let wallpaperView = ZStack {
                    selectedStyle.backgroundColor
                    SwarmCanvasView(
                        accent: selectedStyle == .swarmEmber ? MobileTheme.ember : .white,
                        pace: .cinematic,
                        colorDriver: colorDriver,
                        colorPalette: selectedStyle.swarmPalette,
                        enabledProviderGlyphs: selectedProviderGlyphs
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
                renderer.proposedSize = ProposedViewSize(width: screenBounds.width, height: screenBounds.height)

                guard let cgImage = renderer.uiImage?.cgImage else { continue }

                var pixelBuffer: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(nil, pixelBufferAdaptor.pixelBufferPool!, &pixelBuffer)
                guard let buffer = pixelBuffer else { continue }

                CVPixelBufferLockBaseAddress(buffer, [])
                let context = CGContext(
                    data: CVPixelBufferGetBaseAddress(buffer),
                    width: Int(size.width),
                    height: Int(size.height),
                    bitsPerComponent: 8,
                    bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue
                )
                context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: size.width, height: size.height))
                CVPixelBufferUnlockBaseAddress(buffer, [])

                let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(i))
                pixelBufferAdaptor.append(buffer, withPresentationTime: presentationTime)

                // Allow UI to update and SwarmCanvasView to tick forward
                try await Task.sleep(nanoseconds: 10_000_000)
            }

            videoInput.markAsFinished()
            await assetWriter.finishWriting()

            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges {
                    let request = PHAssetCreationRequest.forAsset()
                    request.addResource(with: .video, fileURL: tempURL, options: nil)
                } completionHandler: { success, error in
                    try? FileManager.default.removeItem(at: tempURL)
                    if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error ?? NSError(domain: "WallpaperGenerator", code: -1))
                    }
                }
            }
            saveResult = .success
        } catch {
            saveResult = .error(error.localizedDescription)
            try? FileManager.default.removeItem(at: tempURL)
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
