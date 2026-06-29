import SwiftUI
import OpenBurnBarCore

struct ThemeSettingsView: View {
    @AppStorage("preferredAppearance") private var preferredAppearance: String = "system"
    @AppStorage("usePremiumSOTAUX") private var usePremiumSOTAUX: Bool = false
    @AppStorage("useWebsiteBackground") private var useWebsiteBackground: Bool = false
    @AppStorage(AppSkin.storageKey) private var appSkin: AppSkin = .aurora
    @AppStorage(MobileBackdropKernel.storageKey) private var mobileBackdropKernel: String = MobileBackdropKernel.defaultKernel.rawValue
    @AppStorage(SwarmSubstratePreferences.enabledKey) private var substrateEnabled: Bool = false
    @AppStorage(SwarmSubstratePreferences.substrateKey) private var substrateID: String = SubstrateCatalog.plainID

    @StateObject private var customization = AppCustomization.shared
    @State private var dashboard = DashboardStore()
    @State private var showWallpaperGenerator = false

    var body: some View {
        Form {
            Section {
                Picker(selection: $appSkin) {
                    Text("Aurora").tag(AppSkin.aurora)
                    Text("Editorial").tag(AppSkin.editorial)
                } label: {
                    SettingsLabel(icon: "doc.richtext", color: MobileTheme.ember, title: "App Skin", imageName: "SettingsIconSettingsB")
                }
                .pickerStyle(.segmented)
                .settingsAnchor(SettingsAnchor.appSkin)
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))

                Picker(selection: $customization.themePalette) {
                    ForEach(AppThemePalette.allCases) { palette in
                        Text(palette.rawValue).tag(palette)
                    }
                } label: {
                    SettingsLabel(icon: "paintpalette.fill", color: MobileTheme.amber, title: "Color Palette", imageName: "SettingsIconSettingsA")
                }
                .pickerStyle(.menu)
                .disabled(appSkin == .editorial)
                .opacity(appSkin == .editorial ? 0.4 : 1)

                Picker(selection: $preferredAppearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                } label: {
                    SettingsLabel(icon: "circle.lefthalf.filled", color: MobileTheme.amber, title: "Appearance Mode", imageName: "SettingsIconSettingsA")
                }
                .pickerStyle(.segmented)
                .disabled(appSkin == .editorial)
                .opacity(appSkin == .editorial ? 0.4 : 1)
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
            } header: {
                Text("Theme Mode")
            } footer: {
                if appSkin == .editorial {
                    Text("Editorial is a light, paper-bright skin with a single coral accent — the app.burnbar.ai console look. It stays light regardless of palette or appearance.")
                } else {
                    Text("Aurora is the signature ember look. Switch to Editorial for a quiet, paper-bright reading skin.")
                }
            }

            Section {
                LiquidGlassTransparencyControl()
                    .settingsAnchor(SettingsAnchor.glassTransparency)
                    .listRowInsets(EdgeInsets(top: 12, leading: 12, bottom: 12, trailing: 12))
            } header: {
                Text("Liquid Glass")
            } footer: {
                Text("Zero matches this device's appearance settings, including Reduce Transparency. Slide toward Clear for more see-through glass, or Frosted for more privacy and contrast. System chrome like the tab bar follows iOS settings only.")
            }

            Section {
                Toggle(isOn: $usePremiumSOTAUX) {
                    SettingsLabel(icon: "sparkles", color: MobileTheme.blaze, title: "Premium SOTA UX")
                }
                .tint(MobileTheme.ember)
                .settingsAnchor(SettingsAnchor.usePremiumSOTAUX)
            } header: {
                Text("Interaction")
            } footer: {
                Text("Cinematic tactile spring physics and high-fidelity haptics.")
            }

            Section {
                Toggle(isOn: $useWebsiteBackground) {
                    SettingsLabel(icon: "grid.rectangles.three.row", color: MobileTheme.whimsy, title: "Website Background")
                }
                .tint(MobileTheme.ember)
                .settingsAnchor(SettingsAnchor.useWebsiteBackground)

                Picker(selection: $mobileBackdropKernel) {
                    ForEach(MobileBackdropKernel.allCases) { kernel in
                        Text(kernel.label).tag(kernel.rawValue)
                    }
                } label: {
                    SettingsLabel(icon: "rectangle.3.group.bubble.left.fill", color: MobileTheme.amber, title: "Backdrop Kernel")
                }
                .pickerStyle(.menu)
                .disabled(!useWebsiteBackground || appSkin == .editorial)
                .opacity(useWebsiteBackground && appSkin != .editorial ? 1 : 0.45)
                .settingsAnchor(SettingsAnchor.backdropKernel)

                if useWebsiteBackground, appSkin != .editorial, let kernel = MobileBackdropKernel(rawValue: mobileBackdropKernel) {
                    Text(kernel.blurb)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                NavigationLink {
                    SwarmBackgroundSettingsView()
                } label: {
                    SettingsLabel(icon: "slider.horizontal.3", color: customization.themePalette.tintColor ?? MobileTheme.ember, title: "Customize Swarm Background")
                }
            } header: {
                Text("Backdrop style")
            } footer: {
                Text("Choose from the same app.burnbar.ai backdrop kernels on iPhone and iPad. Constellation still follows provider glyph filters.")
            }

            substrateSection

            Section {
                Button {
                    showWallpaperGenerator = true
                } label: {
                    HStack {
                        SettingsLabel(icon: "photo.artframe", color: MobileTheme.ember, title: "Generate Wallpaper")
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .tint(.primary)
            } header: {
                Text("Wallpaper")
            } footer: {
                Text("Create a swarm wallpaper colored by your AI provider usage. Save to Photos, then set as your wallpaper.")
            }

            Section {
                ForEach(customization.primaryDestinations, id: \.self) { dest in
                    HStack {
                        Image(systemName: dest.fallbackIcon)
                            .foregroundStyle(dest.accent)
                            .frame(width: 24)
                        Text(dest.label)
                    }
                }
                .onMove { indices, newOffset in
                    customization.primaryDestinations.move(fromOffsets: indices, toOffset: newOffset)
                }
            } header: {
                Text("Primary Sidebar Layout")
            } footer: {
                Text("Reorder primary items. Use Edit to drag.")
            }

            Section {
                ForEach(customization.secondaryDestinations, id: \.self) { dest in
                    HStack {
                        Image(systemName: dest.fallbackIcon)
                            .foregroundStyle(dest.accent)
                            .frame(width: 24)
                        Text(dest.label)
                    }
                }
                .onMove { indices, newOffset in
                    customization.secondaryDestinations.move(fromOffsets: indices, toOffset: newOffset)
                }
            } header: {
                Text("Secondary Sidebar Layout")
            } footer: {
                Text("Reorder secondary items. Use Edit to drag.")
            }
        }
        .navigationTitle("Theme Settings")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                EditButton()
            }
        }
        .fullScreenCover(isPresented: $showWallpaperGenerator) {
            WallpaperGeneratorView(colorDriver: dashboard.swarmColorDriver)
        }
        .task { await dashboard.load() }
    }

    /// The substrate family coupled to the active iOS backdrop kernel.
    private var substrateFamily: SubstrateFamily { SubstrateFamily.forKernel(mobileBackdropKernel) }

    /// Per-theme substrate picker — mirrors the macOS Appearance picker, coupled
    /// to the iOS `mobileBackdropKernel`. The host views already honor the shared
    /// `swarmSubstrate` selection, so toggling here lights up the swarm immediately.
    @ViewBuilder
    private var substrateSection: some View {
        Section {
            Toggle(isOn: $substrateEnabled) {
                SettingsLabel(icon: "circle.hexagongrid.fill", color: MobileTheme.whimsy, title: "Swarm Substrate")
            }
            .tint(MobileTheme.ember)
            .disabled(appSkin == .editorial)
            .opacity(appSkin == .editorial ? 0.45 : 1)

            if substrateEnabled, appSkin != .editorial {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: substrateFamily.symbolName)
                            .font(.caption)
                            .foregroundStyle(MobileTheme.ember)
                        Text(substrateFamily.displayName)
                            .font(.subheadline.weight(.semibold))
                        Text("· substrate")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 10) {
                            ForEach(SubstrateCatalog.styles(forKernel: mobileBackdropKernel)) { style in
                                MobileSubstrateTile(descriptor: style, isSelected: substrateID == style.id) {
                                    substrateID = style.id
                                }
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
                .listRowInsets(EdgeInsets(top: 10, leading: 12, bottom: 12, trailing: 12))
            }
        } header: {
            Text("Swarm Substrate")
        } footer: {
            Text("Compose the provider-glyph swarm from a material drawn from the active backdrop theme — twinkling stars, glass ribbons, caustic light, crepuscular shafts. The styles re-couple to whichever backdrop kernel is selected above.")
        }
    }
}

/// One Image #3-style substrate card for the iOS picker.
private struct MobileSubstrateTile: View {
    let descriptor: SubstrateDescriptor
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(LinearGradient(colors: [descriptor.accent.color, descriptor.accent2.color],
                                         startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 96, height: 46)
                    .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
                Text(descriptor.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(descriptor.hint.uppercased())
                    .font(.system(size: 8, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 96, alignment: .leading)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color(.secondarySystemBackground)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(isSelected ? MobileTheme.ember : Color.primary.opacity(0.08),
                              lineWidth: isSelected ? 1.6 : 0.5))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Liquid Glass transparency control

/// Slider + live preview for `LiquidGlassTransparency`. The preview capsule
/// renders through the same `liquidGlassSurface` adapter as the rest of the
/// app, so dragging the slider shows exactly what every glass surface will do.
private struct LiquidGlassTransparencyControl: View {
    @AppStorage(LiquidGlassTransparency.storageKey) private var rawTransparency: Double = 0
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// Magnetic detent: snap to the system center when the thumb lands close.
    private var sliderValue: Binding<Double> {
        Binding(
            get: { LiquidGlassTransparency.effective(rawTransparency, reduceTransparency: false) },
            set: { rawTransparency = abs($0) < 0.06 ? 0 : $0 }
        )
    }

    var body: some View {
        VStack(spacing: 14) {
            preview

            HStack(spacing: 12) {
                Text("Frosted")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Slider(value: sliderValue, in: LiquidGlassTransparency.range)
                    .tint(MobileTheme.ember)
                    .accessibilityLabel("Glass transparency")
                    .accessibilityValue(accessibilityDescription)
                Text("Clear")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Text(statusText)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
                if rawTransparency != 0 {
                    Button("Reset to System") { rawTransparency = 0 }
                        .font(.footnote.weight(.semibold))
                        .buttonStyle(.borderless)
                        .tint(MobileTheme.ember)
                }
            }
        }
        .sensoryFeedback(.selection, trigger: rawTransparency == 0)
    }

    /// A colorful backdrop behind a real glass capsule, so the see-through
    /// level is obvious as the slider moves. The detail is rendered as soft,
    /// blurred orbs rather than hard-edged shapes: at the clearest setting the
    /// iOS 26 clear-glass lens warps crisp edges into dark chevron artifacts and
    /// its adaptive dimming grays bright fills, whereas smooth color fields
    /// refract cleanly — exactly the rich kind of backdrop clear glass is for.
    private var preview: some View {
        ZStack {
            previewBackdrop
            HStack(spacing: 8) {
                Image(systemName: "flame.fill")
                    .font(.subheadline)
                Text("Liquid Glass")
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .liquidGlassSurface(in: Capsule())
        }
        .frame(height: 88)
        .accessibilityHidden(true)
    }

    private var previewBackdrop: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [
                        MobileTheme.ember.opacity(0.92),
                        MobileTheme.whimsy.opacity(0.85),
                        MobileTheme.amber.opacity(0.9)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                ZStack {
                    softOrb(.white.opacity(0.40), size: 88, x: -96, y: -14)
                    softOrb(MobileTheme.amber.opacity(0.55), size: 74, x: 104, y: 16)
                    softOrb(MobileTheme.whimsy.opacity(0.45), size: 60, x: -34, y: 22)
                    softOrb(.white.opacity(0.28), size: 52, x: 28, y: 24)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    /// A single soft color orb. Blur scales with size so edges stay smooth and
    /// the clear-glass lens has nothing crisp to distort into artifacts.
    private func softOrb(_ color: Color, size: CGFloat, x: CGFloat, y: CGFloat) -> some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .blur(radius: size * 0.22)
            .offset(x: x, y: y)
    }

    private var statusText: String {
        if reduceTransparency && rawTransparency > 0 {
            return "Reduce Transparency is on — glass stays frosted until it's turned off."
        }
        let t = LiquidGlassTransparency.effective(rawTransparency, reduceTransparency: false)
        if t == 0 { return "Matching this device's appearance settings." }
        let percent = Int((abs(t) * 100).rounded())
        return t > 0 ? "\(percent)% clearer than system." : "\(percent)% frostier than system."
    }

    private var accessibilityDescription: String {
        let t = LiquidGlassTransparency.effective(rawTransparency, reduceTransparency: false)
        if t == 0 { return "System default" }
        let percent = Int((abs(t) * 100).rounded())
        return t > 0 ? "\(percent) percent clearer" : "\(percent) percent frostier"
    }
}
