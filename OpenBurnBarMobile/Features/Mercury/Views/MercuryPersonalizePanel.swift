import SwiftUI
import OpenBurnBarMedia

/// The glassmorphic, evocative, always-visible personalization centerpiece.
/// All controls live here — nothing is hidden behind a gear. Sections
/// have a subtle accent-tinted halo when expanded so the surface feels
/// alive as the user tweaks things.
struct MercuryPersonalizePanel: View {
    let peer: MercuryPeer
    @Binding var personalization: MercuryDevicePersonalization
    let sampledAuto: Color
    let nicknameSuggestions: [String]

    @State private var expandedSection: Section? = .nickname
    @State private var nicknameDraft: String = ""

    private var accent: Color {
        switch personalization.accent {
        case .autoFromWallpaper: return sampledAuto
        default: return personalization.accent.staticColor
        }
    }

    enum Section: String, Hashable, CaseIterable, Identifiable {
        case nickname
        case accent
        case avatar
        case background
        case actions
        case badges
        case haptics
        case system

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .nickname:   return "textformat.abc"
            case .accent:     return "paintpalette.fill"
            case .avatar:     return "person.crop.circle.fill"
            case .background: return "rectangle.fill.on.rectangle.fill"
            case .actions:    return "square.stack.3d.up.fill"
            case .badges:     return "tag.fill"
            case .haptics:    return "iphone.gen3.radiowaves.left.and.right"
            case .system:     return "switch.2"
            }
        }

        var title: String {
            switch self {
            case .nickname:   return "Nickname"
            case .accent:     return "Accent"
            case .avatar:     return "Avatar"
            case .background: return "Background"
            case .actions:    return "Actions"
            case .badges:     return "Status pills"
            case .haptics:    return "Haptics"
            case .system:     return "System"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            cardHeader

            ForEach(Section.allCases) { section in
                sectionRow(for: section)
                if section != Section.allCases.last {
                    Divider().background(accent.opacity(0.08))
                }
            }
        }
        .padding(20)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    accent.opacity(0.45),
                                    Color.white.opacity(0.06)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .shadow(color: accent.opacity(0.18), radius: 22, x: 0, y: 14)
        )
        .onAppear {
            nicknameDraft = personalization.nickname ?? ""
        }
    }

    @ViewBuilder
    private var cardHeader: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.5), accent.opacity(0.15)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 36, height: 36)
                Image(systemName: "sparkles")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text("Personalize")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Make this Mac yours.")
                    .font(.system(size: 12, design: .rounded))
                    .foregroundStyle(Color.white.opacity(0.55))
            }
            Spacer(minLength: 8)
        }
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private func sectionRow(for section: Section) -> some View {
        let isExpanded = expandedSection == section
        VStack(spacing: isExpanded ? 12 : 0) {
            Button {
                withAnimation(.spring(response: 0.4, dampingFraction: 0.78)) {
                    expandedSection = isExpanded ? nil : section
                }
                personalization.haptics.play()
            } label: {
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(accent.opacity(isExpanded ? 0.25 : 0.12))
                            .frame(width: 28, height: 28)
                        Image(systemName: section.icon)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(accent)
                    }
                    Text(section.title)
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Spacer(minLength: 8)
                    summary(for: section)
                        .font(.system(size: 12, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.white.opacity(0.55))
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .padding(.vertical, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                expanded(for: section)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(accent.opacity(isExpanded ? 0.08 : 0))
        )
    }

    @ViewBuilder
    private func expanded(for section: Section) -> some View {
        switch section {
        case .nickname:
            nicknameEditor
        case .accent:
            MercuryAccentPicker(
                selection: $personalization.accent,
                sampledAuto: sampledAuto,
                haptics: personalization.haptics
            )
        case .avatar:
            MercuryAvatarStylePicker(
                selection: $personalization.avatar,
                accent: accent,
                haptics: personalization.haptics
            )
        case .background:
            MercuryBackgroundStylePicker(
                selection: $personalization.background,
                accent: accent,
                haptics: personalization.haptics
            )
        case .actions:
            MercuryActionVisibilityList(
                order: $personalization.actionOrder,
                accent: accent,
                haptics: personalization.haptics
            )
        case .badges:
            MercuryBadgePicker(
                selection: $personalization.badges,
                accent: accent,
                haptics: personalization.haptics
            )
        case .haptics:
            MercuryHapticsPicker(
                selection: $personalization.haptics,
                accent: accent
            )
        case .system:
            systemToggles
        }
    }

    @ViewBuilder
    private var nicknameEditor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(peer.displayName, text: $nicknameDraft)
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
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
                .accessibilityLabel("Nickname")

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
        VStack(spacing: 12) {
            Toggle(isOn: $personalization.showHermesSquareTile) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Hermes Square tile")
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
                    Text("Premium SOTA UX")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                    Text("Enable dynamic fluid lights, glass press, & touch trails")
                        .font(.system(size: 11, design: .rounded))
                        .foregroundStyle(Color.white.opacity(0.55))
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: accent))
        }
    }

    @ViewBuilder
    private func summary(for section: Section) -> some View {
        Text(summaryText(for: section))
    }

    private func summaryText(for section: Section) -> String {
        switch section {
        case .nickname:
            if let nickname = personalization.nickname, !nickname.isEmpty {
                return nickname
            }
            return "Default"
        case .accent:
            return personalization.accent.displayName
        case .avatar:
            return personalization.avatar.kind.displayName
        case .background:
            return personalization.background.displayName
        case .actions:
            return "\(personalization.actionOrder.count) visible"
        case .badges:
            return "\(personalization.badges.count) of 2"
        case .haptics:
            return personalization.haptics.displayName
        case .system:
            let count = (personalization.showHermesSquareTile ? 1 : 0) + (personalization.mimicLoginBackground ? 1 : 0)
            return "\(count) on"
        }
    }
}
