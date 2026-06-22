import SwiftUI
import AppKit
import OpenBurnBarCore

// MARK: - Desktop Pet View

struct DesktopPetView: View {
    let settingsManager: SettingsManager
    @Bindable var chatController: ChatSessionController
    var onDismiss: () -> Void
    var onOpenSettings: () -> Void
    var onOpenFullChat: (PetChatDestination) -> Void

    @State private var showContextMenu = false
    @State private var showResizeSlider = false
    @State private var showDestinationPicker = false
    @State private var isHovering = false
    @State private var dragStartOrigin: NSPoint?
    @State private var showFullChatChoice = false

    private var petKind: DesktopPetKind { settingsManager.pets.selectedPet }
    private var petSize: CGFloat { settingsManager.pets.petSize }
    private var bubbleEnabled: Bool { settingsManager.pets.chatBubbleEnabled }

    private var petColor: Color {
        switch petKind.accentColor {
        case "ember":         return DesignSystem.Colors.ember
        case "hermesMercury": return DesignSystem.Colors.hermesMercury
        case "whimsy":        return DesignSystem.Colors.whimsy
        case "teal":          return DesignSystem.Colors.teal
        case "blaze":         return DesignSystem.Colors.blaze
        case "frost":         return DesignSystem.Colors.frost
        case "amber":         return DesignSystem.Colors.amber
        default:              return DesignSystem.Colors.ember
        }
    }

    /// The latest assistant response, summarized into a plain-English TLDR.
    private var tldrText: String {
        guard let lastAssistant = chatController.messages.last(where: { $0.role == .assistant }) else {
            return "No response yet. Click the menu bar icon to start a chat."
        }

        let raw = ChatMessageRecord.joinedText(from: lastAssistant.displayTranscript)
        let plain = HermesAtomParser.plainText(raw)

        guard !plain.isEmpty else {
            return "Waiting for a response..."
        }

        return summarizeToTLDR(plain)
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xs) {
            if bubbleEnabled {
                chatBubble
            }

            HStack(spacing: 0) {
                petSprite
            }
        }
        .padding(DesignSystem.Spacing.sm)
        .background(Color.clear)
        .onHover { hovering in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
                isHovering = hovering
            }
        }
    }

    // MARK: - Pet Sprite

    private var petSprite: some View {
        ZStack {
            // Soft glow behind the pet
            Circle()
                .fill(
                    RadialGradient(
                        colors: [petColor.opacity(0.25), Color.clear],
                        center: .center,
                        startRadius: petSize * 0.3,
                        endRadius: petSize * 0.8
                    )
                )
                .frame(width: petSize * 1.4, height: petSize * 1.4)
                .opacity(isHovering ? 1 : 0.6)

            // Pet face
            ZStack {
                Circle()
                    .fill(petColor.gradient.opacity(0.85))
                    .frame(width: petSize, height: petSize)
                    .overlay(
                        Circle()
                            .strokeBorder(
                                LinearGradient(
                                    colors: [Color.white.opacity(0.3), petColor.opacity(0.5)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                    )

                Image(systemName: petKind.sfSymbol)
                    .font(.system(size: petSize * 0.4, weight: .medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .symbolEffect(.pulse, options: .repeating, isActive: chatController.isStreaming)
            }
            .shadow(color: petColor.opacity(0.3), radius: 8, y: 4)
        }
        .contentShape(Circle())
        .help("Long-press or right-click for options")
        .gesture(
            DragGesture(minimumDistance: 4)
                .onChanged { value in
                    if dragStartOrigin == nil {
                        dragStartOrigin = panelOrigin()
                    }
                    movePanel(translation: value.translation, startOrigin: dragStartOrigin ?? .zero)
                }
                .onEnded { _ in
                    persistPanelPosition()
                    dragStartOrigin = nil
                }
        )
        .onLongPressGesture(minimumDuration: 0.4) {
            showContextMenu = true
        }
        .simultaneousGesture(
            TapGesture()
                .onEnded {
                    showContextMenu = true
                }
        )
        .contextMenu {
            Button("Dismiss Pet", role: .destructive) {
                onDismiss()
            }
            Button("Change Pet") {
                onOpenSettings()
            }
            Divider()
            Slider(value: Binding(
                get: { settingsManager.pets.petSize },
                set: { settingsManager.pets.petSize = $0 }
            ), in: 48...128, step: 4) {
                Text("Size") }
            Toggle("Show Chat Bubble", isOn: Binding(
                get: { settingsManager.pets.chatBubbleEnabled },
                set: { settingsManager.pets.chatBubbleEnabled = $0 }
            ))
        }
        .popover(isPresented: $showContextMenu, arrowEdge: .bottom) {
            petContextMenu
        }
        .accessibilityLabel(petKind.displayName)
        .accessibilityHint("Desktop pet. Drag to reposition. Long-press or click for options.")
        .accessibilityAddTraits(.isButton)
    }

    // MARK: - Chat Bubble

    private var chatBubble: some View {
        VStack(alignment: .trailing, spacing: DesignSystem.Spacing.xxs) {
            HStack(alignment: .top, spacing: DesignSystem.Spacing.xs) {
                // TLDR text
                Text(tldrText)
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(4)
                    .frame(maxWidth: 220, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                // Ellipses button to open full chat
                Button {
                    handleEllipsesTap()
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                        .padding(4)
                        .background(
                            Circle()
                                .fill(DesignSystem.Colors.surface.opacity(0.6))
                        )
                }
                .buttonStyle(.plain)
                .help("Open full chat")
                .accessibilityLabel("Open full chat")
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.85))
                    .liquidGlassSurface(
                        in: RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous),
                        fallback: .ultraThinMaterial
                    )
            )
            .clipShape(RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                petColor.opacity(0.35),
                                DesignSystem.Colors.border.opacity(0.3)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: Color.black.opacity(0.1), radius: 8, y: 4)

            // Bubble tail pointing down to the pet
            BubbleTail(color: petColor)
                .frame(width: 12, height: 8)
                .padding(.trailing, petSize * 0.35)
        }
        .transition(.scale(scale: 0.8).combined(with: .opacity))
    }

    // MARK: - Context Menu

    @ViewBuilder
    private var petContextMenu: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: petKind.sfSymbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(petColor)
                Text(petKind.displayName)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
            }
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)

            Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)

            // Dismiss
            contextMenuButton(icon: "xmark.circle", label: "Dismiss Pet", color: DesignSystem.Colors.error.opacity(0.8)) {
                showContextMenu = false
                onDismiss()
            }

            // Change pet -> opens settings
            contextMenuButton(icon: "arrow.triangle.2.circlepath", label: "Change Pet", color: petColor) {
                showContextMenu = false
                onOpenSettings()
            }

            // Resize slider
            contextMenuButton(icon: "arrow.up.left.and.arrow.down.right", label: "Resize", color: DesignSystem.Colors.textSecondary) {
                showResizeSlider.toggle()
            }

            if showResizeSlider {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    HStack {
                        Image(systemName: "circle.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                        Slider(value: Binding(
                            get: { settingsManager.pets.petSize },
                            set: { settingsManager.pets.petSize = $0 }
                        ), in: 48...128, step: 4) {
                        } minimumValueLabel: {
                            Text("S")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        } maximumValueLabel: {
                            Text("L")
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textMuted)
                        }
                        Image(systemName: "circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                    .padding(.horizontal, DesignSystem.Spacing.md)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                }
            }

            Divider().foregroundStyle(DesignSystem.Colors.borderSubtle)

            // Toggle chat bubble
            Toggle(isOn: Binding(
                get: { settingsManager.pets.chatBubbleEnabled },
                set: { settingsManager.pets.chatBubbleEnabled = $0 }
            )) {
                HStack(spacing: DesignSystem.Spacing.sm) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 16)
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                    Text("Show Chat Bubble")
                        .font(DesignSystem.Typography.caption)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: petColor))
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.sm)

            // Choose chat destination
            contextMenuButton(icon: settingsManager.pets.preferredChatDestination.sfSymbol, label: "Full Chat Opens: \(settingsManager.pets.preferredChatDestination.displayName)", color: DesignSystem.Colors.textSecondary) {
                showDestinationPicker.toggle()
            }

            if showDestinationPicker {
                VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                    ForEach(PetChatDestination.allCases) { dest in
                        Button {
                            settingsManager.pets.preferredChatDestination = dest
                            showDestinationPicker = false
                        } label: {
                            HStack(spacing: DesignSystem.Spacing.sm) {
                                Image(systemName: dest.sfSymbol)
                                    .font(.system(size: 11))
                                    .foregroundStyle(petColor)
                                    .frame(width: 16)
                                Text(dest.displayName)
                                    .font(DesignSystem.Typography.caption)
                                Spacer()
                                if settingsManager.pets.preferredChatDestination == dest {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(petColor)
                                }
                            }
                            .foregroundStyle(DesignSystem.Colors.textSecondary)
                            .padding(.horizontal, DesignSystem.Spacing.md)
                            .padding(.vertical, DesignSystem.Spacing.xs + 2)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(width: 240)
        .background(DesignSystem.Colors.surfaceElevated.opacity(0.95))
    }

    private func contextMenuButton(icon: String, label: String, color: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 16)
                    .foregroundStyle(color)
                Text(label)
                    .font(DesignSystem.Typography.caption)
                Spacer()
            }
            .foregroundStyle(color)
            .padding(.horizontal, DesignSystem.Spacing.md)
            .padding(.vertical, DesignSystem.Spacing.xs + 2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Actions

    private func handleEllipsesTap() {
        let dest = settingsManager.pets.preferredChatDestination
        onOpenFullChat(dest)
    }

    // MARK: - Panel Movement Helpers

    private func panelOrigin() -> NSPoint {
        NSApp.windows.first { $0 is DesktopPetPanel }?.frame.origin ?? .zero
    }

    private func movePanel(translation: CGSize, startOrigin: NSPoint) {
        guard let panel = NSApp.windows.first(where: { $0 is DesktopPetPanel }) as? DesktopPetPanel else { return }
        panel.handleDrag(translation: translation, startOrigin: startOrigin)
    }

    private func persistPanelPosition() {
        guard let panel = NSApp.windows.first(where: { $0 is DesktopPetPanel }) as? DesktopPetPanel else { return }
        panel.persistDraggedPosition()
    }

    // MARK: - TLDR Summarizer

    /// Condenses a raw assistant response into a short, plain-English TLDR.
    /// Takes the first few meaningful sentences and trims to a readable length,
    /// producing a conversational summary suitable for a chat bubble.
    private func summarizeToTLDR(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "```[\\s\\S]*?```", with: "[code]", options: .regularExpression)
            .replacingOccurrences(of: "\\*\\*(.+?)\\*\\*", with: "$1", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Split into sentences
        let sentences = cleaned.components(separatedBy: CharacterSet(charactersIn: ".!?\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count > 8 }

        guard !sentences.isEmpty else {
            let truncated = String(cleaned.prefix(180))
            return truncated + (cleaned.count > 180 ? "..." : "")
        }

        // Take the first 1-2 sentences, capped at 180 chars
        var summary = sentences.prefix(2).joined(separator: ". ")
        if !summary.hasSuffix(".") && !summary.hasSuffix("!") && !summary.hasSuffix("?") {
            summary += "."
        }

        if summary.count > 180 {
            let truncated = String(summary.prefix(177))
            // Find the last space to avoid cutting mid-word
            if let lastSpace = truncated.lastIndex(of: " ") {
                summary = String(truncated[..<lastSpace]) + "..."
            } else {
                summary = truncated + "..."
            }
        }

        return summary
    }
}

// MARK: - Bubble Tail

private struct BubbleTail: View {
    let color: Color

    var body: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 12, y: 0))
            path.addLine(to: CGPoint(x: 6, y: 8))
            path.closeSubpath()
        }
        .fill(DesignSystem.Colors.surface.opacity(0.85))
        .overlay(
            Path { path in
                path.move(to: CGPoint(x: 0, y: 0))
                path.addLine(to: CGPoint(x: 6, y: 8))
                path.addLine(to: CGPoint(x: 12, y: 0))
            }
            .stroke(color.opacity(0.3), lineWidth: 0.75)
        )
    }
}
