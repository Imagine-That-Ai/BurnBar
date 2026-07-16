import SwiftUI
import OpenBurnBarUI

struct LivingThemesView: View {
    @AppStorage(MobileBackdropKernel.storageKey) private var selectedKernelID = MobileBackdropKernel.defaultKernel.rawValue
    @AppStorage("burnbar.livingThemes.quality") private var selectedQualityRaw = LivingThemeDeepLink.Quality.eco.rawValue
    @State private var searchText = ""
    @State private var showGenerator = false

    private var selectedKernel: MobileBackdropKernel {
        MobileBackdropKernel.resolved(selectedKernelID)
    }

    private var selectedQuality: LivingThemeDeepLink.Quality {
        get { LivingThemeDeepLink.Quality(rawValue: selectedQualityRaw) ?? .eco }
        nonmutating set { selectedQualityRaw = newValue.rawValue }
    }

    private var visibleKernels: [MobileBackdropKernel] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return MobileBackdropKernel.allCases }
        return MobileBackdropKernel.allCases.filter {
            $0.label.localizedStandardContains(query) ||
                $0.blurb.localizedStandardContains(query)
        }
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 20) {
                selectedPreview
                qualityPicker
                themeGrid
            }
            .padding()
        }
        .background(Color.black.opacity(0.96).ignoresSafeArea())
        .navigationTitle("Living Themes")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, prompt: "Search 42 living themes")
        .preferredColorScheme(.dark)
        .fullScreenCover(isPresented: $showGenerator) {
            WallpaperGeneratorView(
                colorDriver: SwarmColorDriver(),
                livingTheme: selectedKernel,
                livingThemeMaxFrameRate: selectedQuality.maxFrameRate
            )
        }
    }

    private var selectedPreview: some View {
        ZStack(alignment: .bottomLeading) {
            if MobileWebGLKernelBackdropView.supports(kernelID: selectedKernel.rawValue) {
                MobileWebGLKernelBackdropView(
                    kernelID: selectedKernel.rawValue,
                    theme: "dark",
                    maxFrameRate: selectedQuality.maxFrameRate
                )
            } else {
                MobileKernelBackdropView(
                    kernel: selectedKernel,
                    accent: MobileTheme.ember,
                    visibility: .prominent,
                    maxFrameRate: selectedQuality.maxFrameRate
                )
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.88)],
                startPoint: .center,
                endPoint: .bottom
            )

            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(selectedKernel.label)
                        .font(.title2.bold())
                    Text(selectedKernel.blurb)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(2)
                }

                Button {
                    showGenerator = true
                } label: {
                    Label("Make Live Wallpaper", systemImage: "livephoto")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            LinearGradient(
                                colors: [MobileTheme.ember, MobileTheme.blaze],
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens a preview where you can save a wallpaper-ready Live Photo")
            }
            .padding(16)
        }
        .frame(height: 330)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(0.12), lineWidth: 1)
        }
    }

    private var qualityPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Power profile", systemImage: "battery.75percent")
                    .font(.headline)
                Spacer()
                Text(selectedQuality == .eco ? "Recommended" : "\(Int(selectedQuality.maxFrameRate)) fps preview")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            Picker(
                "Power profile",
                selection: Binding(
                    get: { selectedQuality },
                    set: { selectedQuality = $0 }
                )
            ) {
                Text("Eco").tag(LivingThemeDeepLink.Quality.eco)
                Text("Atelier").tag(LivingThemeDeepLink.Quality.atelier)
                Text("Cinema").tag(LivingThemeDeepLink.Quality.cinema)
            }
            .pickerStyle(.segmented)

            Text("Eco keeps previews at 20 fps. Export quality stays full-resolution on every profile.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var themeGrid: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(), spacing: 12),
                GridItem(.flexible(), spacing: 12)
            ],
            spacing: 12
        ) {
            ForEach(visibleKernels) { kernel in
                Button {
                    selectedKernelID = kernel.rawValue
                } label: {
                    LivingThemeCard(
                        kernel: kernel,
                        selected: kernel == selectedKernel
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct LivingThemeCard: View {
    let kernel: MobileBackdropKernel
    let selected: Bool

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            GeometryReader { geometry in
                MobileKernelBackdropFrameView(
                    kernel: kernel,
                    accent: MobileTheme.ember,
                    time: 2.4,
                    size: geometry.size
                )
            }

            LinearGradient(
                colors: [.clear, .black.opacity(0.84)],
                startPoint: .center,
                endPoint: .bottom
            )

            HStack(spacing: 6) {
                Text(kernel.label)
                    .font(.caption.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                Spacer(minLength: 0)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(MobileTheme.ember)
                }
            }
            .padding(10)
        }
        .frame(height: 126)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(selected ? MobileTheme.ember : .white.opacity(0.10), lineWidth: selected ? 2 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(kernel.label)
        .accessibilityValue(selected ? "Selected" : "Not selected")
        .accessibilityHint(kernel.blurb)
    }
}
