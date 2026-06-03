import SwiftUI
import OpenBurnBarCore

struct ThemeSettingsView: View {
    @AppStorage("preferredAppearance") private var preferredAppearance: String = "system"
    @AppStorage("usePremiumSOTAUX") private var usePremiumSOTAUX: Bool = false
    @AppStorage("useWebsiteBackground") private var useWebsiteBackground: Bool = false
    @AppStorage(AppSkin.storageKey) private var appSkin: AppSkin = .aurora

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
                    SettingsLabel(icon: "doc.richtext", color: MobileTheme.ember, title: "App Skin")
                }
                .pickerStyle(.segmented)
                .settingsAnchor(SettingsAnchor.appSkin)
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))

                Picker(selection: $customization.themePalette) {
                    ForEach(AppThemePalette.allCases) { palette in
                        Text(palette.rawValue).tag(palette)
                    }
                } label: {
                    SettingsLabel(icon: "paintpalette.fill", color: MobileTheme.amber, title: "Color Palette")
                }
                .pickerStyle(.menu)
                .disabled(appSkin == .editorial)
                .opacity(appSkin == .editorial ? 0.4 : 1)

                Picker(selection: $preferredAppearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                } label: {
                    SettingsLabel(icon: "circle.lefthalf.filled", color: MobileTheme.amber, title: "Appearance Mode")
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

                NavigationLink {
                    SwarmBackgroundSettingsView()
                } label: {
                    SettingsLabel(icon: "slider.horizontal.3", color: customization.themePalette.tintColor ?? MobileTheme.ember, title: "Customize Swarm Background")
                }
            } header: {
                Text("Backdrop style")
            } footer: {
                Text("Live swarm backdrop that follows the selected app palette and provider glyph filters.")
            }

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
}
