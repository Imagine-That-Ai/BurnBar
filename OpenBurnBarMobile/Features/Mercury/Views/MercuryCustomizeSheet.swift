import SwiftUI
import OpenBurnBarMedia

/// Bottom sheet that holds the deep personalization controls. Users
/// reach it from the "Customize…" card in the Mood carousel. The main
/// screen stays uncluttered; power users get all the knobs in one
/// glassmorphic surface here.
struct MercuryCustomizeSheet: View {
    let peer: MercuryPeer
    @Binding var personalization: MercuryDevicePersonalization
    let sampledAuto: Color
    let nicknameSuggestions: [String]

    @Environment(\.dismiss) private var dismiss
    @State private var nicknameDraft: String = ""

    private var accent: Color {
        switch personalization.accent {
        case .autoFromWallpaper: return sampledAuto
        default: return personalization.accent.staticColor
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    section(title: "Nickname", icon: "textformat.abc") {
                        nicknameEditor
                    }

                    section(title: "Accent", icon: "paintpalette.fill") {
                        MercuryAccentPicker(
                            selection: $personalization.accent,
                            sampledAuto: sampledAuto,
                            haptics: personalization.haptics
                        )
                    }

                    section(title: "Avatar", icon: "person.crop.circle.fill") {
                        MercuryAvatarStylePicker(
                            selection: $personalization.avatar,
                            accent: accent,
                            haptics: personalization.haptics
                        )
                    }

                    section(title: "Background", icon: "rectangle.fill.on.rectangle.fill") {
                        MercuryBackgroundStylePicker(
                            selection: $personalization.background,
                            accent: accent,
                            haptics: personalization.haptics
                        )
                    }

                    section(title: "Actions", icon: "square.stack.3d.up.fill") {
                        MercuryActionVisibilityList(
                            order: $personalization.actionOrder,
                            accent: accent,
                            haptics: personalization.haptics
                        )
                    }

                    section(title: "Status pills", icon: "tag.fill") {
                        MercuryBadgePicker(
                            selection: $personalization.badges,
                            accent: accent,
                            haptics: personalization.haptics
                        )
                    }

                    section(title: "Haptics", icon: "iphone.gen3.radiowaves.left.and.right") {
                        MercuryHapticsPicker(
                            selection: $personalization.haptics,
                            accent: accent
                        )
                    }

                    section(title: "System", icon: "switch.2") {
                        systemToggles
                    }
                }
                .padding(20)
                .padding(.bottom, 40)
            }
            .scrollIndicators(.hidden)
            .background(sheetBackground)
            .navigationTitle("Customize")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle(accent)
                }
            }
        }
        .onAppear { nicknameDraft = personalization.nickname ?? "" }
    }

    @ViewBuilder
    private func section<Content: View>(
        title: String,
        icon: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.7))
                Text(title)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.78))
                    .textCase(.uppercase)
                    .kerning(0.5)
                Spacer()
            }
            content()
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                )
        )
    }

    @ViewBuilder
    private var nicknameEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(peer.displayName, text: $nicknameDraft)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .stroke(accent.opacity(0.35), lineWidth: 1)
                        )
                )
                .onChange(of: nicknameDraft) { _, newValue in
                    let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                    personalization.nickname = trimmed.isEmpty ? nil : trimmed
                }
                .submitLabel(.done)

            if !nicknameSuggestions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(nicknameSuggestions, id: \.self) { suggestion in
                            Button {
                                nicknameDraft = suggestion
                                personalization.nickname = suggestion
                                personalization.haptics.play()
                            } label: {
                                Text(suggestion)
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Capsule().fill(accent.opacity(0.22)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var systemToggles: some View {
        VStack(spacing: 14) {
            Toggle(isOn: $personalization.showHermesSquareTile) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Agents tile")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Show My Mac on the main grid")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: accent))

            Toggle(isOn: $personalization.mimicLoginBackground) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Mimic Mac wallpaper")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Background mirrors your Mac's desktop")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: accent))

            Toggle(isOn: Binding(
                get: { personalization.usePremiumSOTAUX ?? false },
                set: { personalization.usePremiumSOTAUX = $0 }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Premium UX")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Shimmer, bevel, deeper haptics on buttons")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: accent))
        }
    }

    @ViewBuilder
    private var sheetBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.10, blue: 0.12),
                    Color(red: 0.04, green: 0.04, blue: 0.05)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            RadialGradient(
                colors: [accent.opacity(0.12), Color.clear],
                center: .top,
                startRadius: 0,
                endRadius: 320
            )
        }
        .ignoresSafeArea()
    }
}
