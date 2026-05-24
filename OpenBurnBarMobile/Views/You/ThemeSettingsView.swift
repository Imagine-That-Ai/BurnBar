import SwiftUI
import OpenBurnBarCore

struct ThemeSettingsView: View {
    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("preferredAppearance") private var preferredAppearance: String = "system"
    @AppStorage("usePremiumSOTAUX") private var usePremiumSOTAUX: Bool = false
    @AppStorage("useWebsiteBackground") private var useWebsiteBackground: Bool = false

    @StateObject private var customization = AppCustomization.shared
    @State private var dashboard = DashboardStore()
    @State private var showWallpaperGenerator = false

    var body: some View {
        ZStack {
            AuroraBackdrop(density: .subtle)

            Form {
                Section {
                    Picker(selection: $customization.themePalette) {
                        ForEach(AppThemePalette.allCases) { palette in
                            Text(palette.rawValue).tag(palette)
                        }
                    } label: {
                        SettingsLabel(icon: "paintpalette.fill", color: MobileTheme.amber, title: "Color Palette")
                    }
                    .pickerStyle(.menu)

                    Picker(selection: $preferredAppearance) {
                        Text("System").tag("system")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    } label: {
                        SettingsLabel(icon: "circle.lefthalf.filled", color: MobileTheme.amber, title: "Appearance Mode")
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                } header: {
                    Text("Theme Mode")
                }
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))

                Section {
                    Toggle(isOn: $usePremiumSOTAUX) {
                        VStack(alignment: .leading, spacing: 4) {
                            SettingsLabel(icon: "sparkles", color: MobileTheme.blaze, title: "Premium SOTA UX")
                            Text("Cinematic tactile spring physics and high-fidelity haptics")
                                .font(MobileTheme.Typography.tiny)
                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                        }
                    }
                    .tint(MobileTheme.ember)
                    .settingsAnchor(SettingsAnchor.usePremiumSOTAUX)
                } header: {
                    Text("Interaction")
                }
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))

                Section {
                    Toggle(isOn: $useWebsiteBackground) {
                        VStack(alignment: .leading, spacing: 4) {
                            SettingsLabel(icon: "grid.rectangles.three.row", color: MobileTheme.whimsy, title: "Website Background")
                            Text("Live swarm backdrop that follows the selected app palette and provider glyph filters")
                                .font(MobileTheme.Typography.tiny)
                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                        }
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
                }
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))

                Section {
                    Button {
                        showWallpaperGenerator = true
                    } label: {
                        HStack {
                            SettingsLabel(icon: "photo.artframe", color: MobileTheme.ember, title: "Generate Wallpaper")
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                        }
                    }
                    .tint(colorScheme == .dark ? .white : .primary)

                    Text("Create a swarm wallpaper colored by your AI provider usage. Save to Photos, then set as your wallpaper.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                } header: {
                    Text("Wallpaper")
                }
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))

                Section {
                    ForEach(customization.primaryDestinations, id: \.self) { dest in
                        HStack {
                            Image(systemName: dest.fallbackIcon)
                                .foregroundColor(dest.accent)
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
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))

                Section {
                    ForEach(customization.secondaryDestinations, id: \.self) { dest in
                        HStack {
                            Image(systemName: dest.fallbackIcon)
                                .foregroundColor(dest.accent)
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
                .listRowBackground(Color.white.opacity(colorScheme == .dark ? 0.08 : 0.60))
            }
            .scrollContentBackground(.hidden)
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
