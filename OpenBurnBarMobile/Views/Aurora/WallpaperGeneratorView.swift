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
//
// Interactions:
// - Tap to cycle through provider logo formations (individual → grouped)
// - Press and hold to speed up the swarm for faster formation preview
// - Save Still: high-res PNG snapshot of the current swarm state
// - Save Live: looping video for iOS Live/dynamic wallpaper

struct WallpaperGeneratorView: View {
    let colorDriver: SwarmColorDriver

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    // Persistent style choice. Defaults to .appDefault so the wallpaper
    // preview follows the app's current color scheme until the user picks
    // a specific style.
    @AppStorage("burnbar.wallpaper.style") private var selectedStyleRaw: String = WallpaperStyle.appDefault.rawValue
    private var selectedStyle: WallpaperStyle {
        WallpaperStyle(rawValue: selectedStyleRaw) ?? .appDefault
    }
    // Kept as a pass-through so existing call sites stay stable. .appDefault
    // is now a first-class style (fire palette + warm-dark background), so
    // it no longer needs to collapse to swarmDark/Light at render time.
    private var effectiveStyle: WallpaperStyle { selectedStyle }
    @State private var showClock: Bool = true
    @State private var showProviderLabels: Bool = true
    @State private var showProviderGlyphCustomizer: Bool = false
    @State private var isSavingStill = false
    @State private var isSavingLive = false
    @State private var saveResult: SaveResult?
    @State private var previewPhase: CGFloat = 0
    @State private var isHolding = false
    @State private var holdStartDate: Date?
    @State private var showTapHint = true
    @State private var tapHintOpacity: Double = 1.0
    @AppStorage("burnbar.wallpaper.providerGlyphs") private var providerGlyphSelectionRaw = SwarmProviderGlyphSelection.allSentinel
    @State private var currentMode: SwarmFormationMode = .swarm


    // Resizable sidebar (iPad / macOS) state. Width persists across launches.
    // Compact-width devices (iPhone portrait) fall back to a bottom panel.
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @AppStorage("burnbar.wallpaper.sidebarWidth") private var sidebarWidthRaw: Double = 300
    @State private var liveSidebarWidth: Double? = nil

    private var sidebarMinWidth: Double { 240 }
    private var sidebarMaxWidth: Double { 460 }
    private var sidebarWidth: CGFloat {
        let raw = liveSidebarWidth ?? sidebarWidthRaw
        return CGFloat(min(sidebarMaxWidth, max(sidebarMinWidth, raw)))
    }
    private var usesSidebar: Bool { horizontalSizeClass == .regular }
    private var sidebarVisible: Bool { usesSidebar && showProviderGlyphCustomizer }

    enum WallpaperStyle: String, CaseIterable, Identifiable {
        // .appDefault delegates to the app's current color scheme for the
        // background only — the swarm palette is ALWAYS the BurnBar fire
        // palette (red/orange/yellow with sparing blue accents).
        case appDefault = "Default"
        case swarmDark = "Swarm Dark"
        case swarmLight = "Swarm Light"
        case swarmAMOLED = "AMOLED"
        case swarmEmber = "Ember Glow"

        var id: String { rawValue }

        var backgroundColor: Color {
            switch self {
            case .appDefault: return Color(red: 0.05, green: 0.03, blue: 0.02)   // warm near-black
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
            // BurnBar's signature fire palette: red, orange, yellow embers,
            // with sparing blue "whimsy" accents.
            case .appDefault: return .defaultEmber
            case .swarmDark: return .auroraTeal
            case .swarmLight: return .forestMoss
            case .swarmAMOLED: return .cyberpunkViolet
            case .swarmEmber: return .solarFlare
            }
        }
    }

    enum SaveResult: Identifiable {
        case successStill
        case successLive
        case permissionDenied
        case error(String)

        var id: String {
            switch self {
            case .successStill: return "success-still"
            case .successLive: return "success-live"
            case .permissionDenied: return "denied"
            case .error(let msg): return "error-\(msg)"
            }
        }
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            // Full-screen swarm preview
            wallpaperCanvas
                .ignoresSafeArea()

            // Gesture overlay — tap to cycle shapes, hold to speed up
            gestureOverlay
                .ignoresSafeArea()

            // Overlay controls (pushed clear of the sidebar on regular width)
            VStack {
                topBar
                Spacer()

                // Tap hint
                if showTapHint {
                    tapHintView
                        .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                providerLegend
                bottomControls
            }
            .padding()
            .padding(.trailing, sidebarVisible ? sidebarWidth : 0)
            .animation(.spring(response: 0.32, dampingFraction: 0.86), value: sidebarVisible)
            .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.92), value: sidebarWidth)

            // Right sidebar (iPad / macOS) — resizable provider list.
            if sidebarVisible {
                providerSidebar
                    .frame(width: sidebarWidth)
                    .frame(maxHeight: .infinity)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                    .ignoresSafeArea(edges: [.top, .bottom])
            }
        }
        .statusBarHidden(true)
        .alert(item: $saveResult) { result in
            switch result {
            case .successStill:
                Alert(
                    title: Text("Still Wallpaper Saved"),
                    message: Text("Your wallpaper has been saved to Photos. Open Settings → Wallpaper to set it."),
                    dismissButton: .default(Text("Done"))
                )
            case .successLive:
                Alert(
                    title: Text("Live Wallpaper Saved"),
                    message: Text("Your dynamic wallpaper has been saved to Photos. Open Settings → Wallpaper to set it as a Live wallpaper."),
                    dismissButton: .default(Text("Done"))
                )
            case .permissionDenied:
                Alert(
                    title: Text("Photos Access Required"),
                    message: Text("Enable Photos access in Settings → BurnBar → Photos to save wallpapers.")
                ,
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
        .preferredColorScheme(selectedStyle == .appDefault ? nil : (selectedStyle.isDark ? .dark : .light))
    }

    // MARK: - Wallpaper Canvas

    @ViewBuilder
    private var wallpaperCanvas: some View {
        ZStack {
            effectiveStyle.backgroundColor
                .ignoresSafeArea()

            SwarmCanvasView(
                accent: selectedStyle == .swarmEmber ? MobileTheme.ember : .white,
                pace: .cinematic,
                colorDriver: colorDriver,
                colorPalette: effectiveStyle.swarmPalette,
                motionSpeedMultiplier: isHolding ? 2.5 : 1.0,
                enabledProviderGlyphs: selectedProviderGlyphs,
                currentMode: $currentMode
            )

            // Subtle radial vignette
            RadialGradient(
                colors: [
                    .clear,
                    effectiveStyle.backgroundColor.opacity(0.7)
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
                        .foregroundStyle(effectiveStyle.isDark ? .white : .black)
                        .opacity(0.3)
                    Text(clockDate)
                        .font(.system(size: 16, weight: .medium, design: .rounded))
                        .foregroundStyle(effectiveStyle.isDark ? .white : .black)
                        .opacity(0.2)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, 100)
                .allowsHitTesting(false)
            }
        }
    }

    // MARK: - Gesture Overlay (Tap + Hold)

    private var gestureOverlay: some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isHolding {
                            isHolding = true
                            holdStartDate = Date()
                            dismissTapHint()
                        }
                    }
                    .onEnded { _ in
                        let wasTap = holdStartDate.map { Date().timeIntervalSince($0) < 0.35 } ?? false
                        isHolding = false
                        holdStartDate = nil
                        if wasTap {
                            // Tap → cycle to next swarm shape
                            NotificationCenter.default.post(name: .cycleSwarmShapeRequested, object: nil)
                            #if canImport(UIKit)
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                            #endif
                        }
                    }
            )
    }

    // MARK: - Tap Hint

    private var tapHintView: some View {
        HStack(spacing: 8) {
            Image(systemName: "hand.tap.fill")
                .font(.system(size: 13, weight: .semibold))
            Text("Tap to explore · Hold to speed up")
                .font(.system(size: 13, weight: .medium, design: .rounded))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial.opacity(0.7), in: Capsule())
        .foregroundStyle(effectiveStyle.isDark ? .white.opacity(0.7) : .black.opacity(0.5))
        .opacity(tapHintOpacity)
        .padding(.bottom, 8)
    }

    private func dismissTapHint() {
        guard showTapHint else { return }
        withAnimation(.easeOut(duration: 0.4)) {
            tapHintOpacity = 0
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            showTapHint = false
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
                    .foregroundStyle(effectiveStyle.isDark ? .white.opacity(0.7) : .black.opacity(0.5))
            }

            Spacer()

            // Style picker
            Menu {
                ForEach(WallpaperStyle.allCases, id: \.self) { style in
                    Button {
                        withAnimation(.spring(response: 0.4)) {
                            selectedStyleRaw = style.rawValue
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
                .foregroundStyle(effectiveStyle.isDark ? .white : .black)
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
                        UnifiedProviderLogoView(provider: pw.provider, size: 14, useFallbackColor: true)
                        Text(pw.provider.rawValue)
                            .font(.system(size: 12, weight: .medium, design: .rounded))
                            .foregroundStyle(effectiveStyle.isDark ? .white.opacity(0.6) : .black.opacity(0.5))
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
            // Inline customizer is the compact-width (iPhone) fallback only.
            // On regular width (iPad / macOS) the sidebar hosts it instead.
            if showProviderGlyphCustomizer && !usesSidebar {
                providerGlyphCustomizer
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 12) {
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

                // Dual save buttons
                saveStillButton
                saveLiveButton
            }
        }
        .padding(.bottom, 30)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: showProviderGlyphCustomizer)
    }

    // MARK: - Save Buttons

    private var saveStillButton: some View {
        Button {
            Task { await saveStillWallpaper() }
        } label: {
            HStack(spacing: 6) {
                if isSavingStill {
                    ProgressView()
                        .tint(effectiveStyle.isDark ? .white : .black)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "photo.fill")
                        .font(.system(size: 12))
                }
                Text(isSavingStill ? "Saving…" : "Still")
                    .font(.caption.weight(.bold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .foregroundStyle(effectiveStyle.isDark ? .white : .black)
        }
        .disabled(isSavingStill || isSavingLive)
        .accessibilityLabel("Save still wallpaper")
    }

    private var saveLiveButton: some View {
        Button {
            Task { await saveLiveWallpaper() }
        } label: {
            HStack(spacing: 6) {
                if isSavingLive {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(0.7)
                } else {
                    Image(systemName: "livephoto")
                        .font(.system(size: 12))
                }
                Text(isSavingLive ? "Saving…" : "Live")
                    .font(.caption.weight(.bold))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
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
        .disabled(isSavingStill || isSavingLive)
        .accessibilityLabel("Save live wallpaper")
    }

    // MARK: - Provider Glyph Customizer

    private var providerGlyphCustomizer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(providerGlyphSummaryText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(effectiveStyle.isDark ? .white.opacity(0.78) : .black.opacity(0.62))
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


    // MARK: - Provider Sidebar (iPad / macOS)

    private var providerSidebar: some View {
        HStack(spacing: 0) {
            sidebarResizeHandle

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(providerGlyphSummaryText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(effectiveStyle.isDark ? .white.opacity(0.82) : .black.opacity(0.7))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)

                    Spacer()

                    Button("All") {
                        providerGlyphSelectionRaw = SwarmProviderGlyphSelection.encode(SwarmProviderGlyphSelection.allProviders)
                    }
                    .font(.footnote.weight(.semibold))

                    Button("None") {
                        providerGlyphSelectionRaw = SwarmProviderGlyphSelection.encode([])
                    }
                    .font(.footnote.weight(.semibold))

                    Button {
                        withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                            showProviderGlyphCustomizer = false
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(effectiveStyle.isDark ? .white.opacity(0.55) : .black.opacity(0.45))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Close provider sidebar")
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(SwarmProviderGlyphSelection.allProviders) { provider in
                            providerSidebarRow(provider)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
            .padding(.horizontal, 18)
            .padding(.top, 22)
            .padding(.bottom, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.ultraThinMaterial)
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(effectiveStyle.isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.08))
                .frame(width: 0.5)
        }
    }

    private var sidebarResizeHandle: some View {
        ZStack {
            // Wider transparent hit target for easy grabbing on iPad pointer / touch.
            Color.clear
                .frame(width: 14)
                .contentShape(Rectangle())

            // Visible grip — subtle vertical pill tint.
            Capsule()
                .fill(effectiveStyle.isDark ? Color.white.opacity(0.22) : Color.black.opacity(0.22))
                .frame(width: 4, height: 44)
        }
        .frame(maxHeight: .infinity)
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    // translation.width is cumulative from gesture start; use the
                    // persistent baseline so the math stays stable across ticks.
                    // Dragging leftward (negative width) grows the sidebar.
                    let proposed = sidebarWidthRaw - Double(value.translation.width)
                    liveSidebarWidth = min(sidebarMaxWidth, max(sidebarMinWidth, proposed))
                }
                .onEnded { _ in
                    if let w = liveSidebarWidth {
                        sidebarWidthRaw = w
                    }
                    liveSidebarWidth = nil
                }
        )
        .accessibilityLabel("Resize provider sidebar")
        .accessibilityAddTraits(.isButton)
    }

    private func providerSidebarRow(_ provider: AgentProvider) -> some View {
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
            HStack(spacing: 12) {
                UnifiedProviderLogoView(provider: provider, size: 22, useFallbackColor: true)
                    .frame(width: 26, height: 26)

                Text(provider.displayName)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(
                        isSelected
                            ? Color.accentColor
                            : (effectiveStyle.isDark ? Color.white.opacity(0.45) : Color.black.opacity(0.35))
                    )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isSelected
                    ? Color.white.opacity(effectiveStyle.isDark ? 0.14 : 0.32)
                    : Color.white.opacity(effectiveStyle.isDark ? 0.05 : 0.14),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .foregroundStyle(effectiveStyle.isDark ? .white : .black)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(provider.displayName)
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
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
                UnifiedProviderLogoView(provider: provider, size: 16, useFallbackColor: true)

                Text(provider.displayName)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)

                Spacer(minLength: 0)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(
                isSelected
                    ? Color.white.opacity(effectiveStyle.isDark ? 0.18 : 0.32)
                    : Color.white.opacity(effectiveStyle.isDark ? 0.07 : 0.18),
                in: Capsule()
            )
            .foregroundStyle(effectiveStyle.isDark ? .white : .black)
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
                        ? (effectiveStyle.isDark ? Color.white : Color.black)
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

    // MARK: - Photos Permission

    @MainActor
    private func requestPhotosPermission() async -> Bool {
        #if canImport(UIKit)
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .authorized, .limited:
            return true
        case .denied, .restricted:
            return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .addOnly) { newStatus in
                    continuation.resume(returning: newStatus == .authorized || newStatus == .limited)
                }
            }
        @unknown default:
            return false
        }
        #else
        return false
        #endif
    }

    // MARK: - Save Still Wallpaper

    @MainActor
    private func saveStillWallpaper() async {
        #if canImport(UIKit)
        isSavingStill = true
        defer { isSavingStill = false }

        guard await requestPhotosPermission() else {
            saveResult = .permissionDenied
            return
        }

        let screenBounds = UIScreen.main.bounds
        let scale = UIScreen.main.scale

        // Render the current swarm state at full device resolution
        let wallpaperView = ZStack {
            effectiveStyle.backgroundColor
            SwarmCanvasView(
                accent: selectedStyle == .swarmEmber ? MobileTheme.ember : .white,
                pace: .cinematic,
                colorDriver: colorDriver,
                colorPalette: effectiveStyle.swarmPalette,
                enabledProviderGlyphs: selectedProviderGlyphs
            )
            RadialGradient(
                colors: [.clear, effectiveStyle.backgroundColor.opacity(0.7)],
                center: .center,
                startRadius: 120,
                endRadius: 500
            )
        }
        .frame(width: screenBounds.width, height: screenBounds.height)
        .preferredColorScheme(selectedStyle == .appDefault ? nil : (selectedStyle.isDark ? .dark : .light))

        let renderer = ImageRenderer(content: wallpaperView)
        renderer.scale = scale
        renderer.proposedSize = ProposedViewSize(width: screenBounds.width, height: screenBounds.height)

        guard let uiImage = renderer.uiImage else {
            saveResult = .error("Failed to render wallpaper image.")
            return
        }

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest.creationRequestForAsset(from: uiImage)
                } completionHandler: { success, error in
                    if success {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: error ?? NSError(domain: "WallpaperGenerator", code: -1))
                    }
                }
            }
            saveResult = .successStill
            // Gentle success haptic
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            saveResult = .error(error.localizedDescription)
        }
        #endif
    }

    // MARK: - Save Live Wallpaper

    @MainActor
    private func saveLiveWallpaper() async {
        #if canImport(UIKit) && canImport(AVFoundation)
        isSavingLive = true
        defer { isSavingLive = false }

        guard await requestPhotosPermission() else {
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

            // 6-second loop (was 3s). Lets the swarm settle on screen for
            // long enough that the final formation reads, with a long-enough
            // tail of subtle ember motion to feel alive when looped.
            let frameCount = 180
            let fps: Int32 = 30
            let frameDuration = CMTime(value: 1, timescale: fps)

            // 1. Create a single simulation instance to avoid re-seeding / flickering
            let simulation = SwarmSimulation(
                particleCount: SwarmCanvasView.adaptiveParticleCount,
                pace: .cinematic,
                enabledProviderGlyphs: selectedProviderGlyphs
            )
            simulation.colorPalette = effectiveStyle.swarmPalette
            simulation.setColorDriver(colorDriver)
            simulation.setAutoCyclingEnabled(false)
            simulation.assignMode(currentMode)

            // 2. Pre-advance simulation by 600 steps (10s at 60Hz physics)
            //    BEFORE recording starts. The previous 4s wasn't enough — the
            //    cinematic pace plus complex shapes (anime girl, multi-glyph
            //    layouts) need more time to converge to a recognizable form.
            //    With 10s of pre-roll, the recorded video opens on a settled
            //    formation and only the gentle ember motion remains.
            var currentTime = Date()
            for _ in 0..<600 {
                simulation.advance(to: currentTime, bounds: screenBounds.size, reduceMotion: false, isBatteryThrottled: false)
                currentTime = currentTime.addingTimeInterval(1.0 / 60.0)
            }

            // 3. Render 90 frames using the single advanced simulation
            for i in 0..<frameCount {
                while !videoInput.isReadyForMoreMediaData {
                    try await Task.sleep(nanoseconds: 10_000_000)
                }

                // Step simulation twice to advance virtual time by 1/30s (at 60Hz physics accuracy)
                for _ in 0..<2 {
                    simulation.advance(to: currentTime, bounds: screenBounds.size, reduceMotion: false, isBatteryThrottled: false)
                    currentTime = currentTime.addingTimeInterval(1.0 / 60.0)
                }

                let renderView = OfflineSwarmRenderView(
                    simulation: simulation,
                    size: screenBounds.size,
                    colorScheme: effectiveStyle.isDark ? .dark : .light,
                    backgroundColor: effectiveStyle.backgroundColor
                )

                let renderer = ImageRenderer(content: renderView)
                renderer.scale = scale
                renderer.proposedSize = ProposedViewSize(screenBounds.size)

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

                // Yield to run loop slightly to prevent blocking UI main thread
                try await Task.sleep(nanoseconds: 5_000_000)
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
            saveResult = .successLive
            // Gentle success haptic
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            saveResult = .error(error.localizedDescription)
            try? FileManager.default.removeItem(at: tempURL)
        }
        #endif
    }
}

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
