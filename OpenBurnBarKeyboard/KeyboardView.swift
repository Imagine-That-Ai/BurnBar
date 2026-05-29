import SwiftUI
import OpenBurnBarCore

// MARK: - Keyboard View
/// A state-of-the-art custom SwiftUI keyboard view.
///
/// Features a horizontal scrolling snippet bar at the top with the BurnBar logo
/// and a '+' button to add new snippets inline, a standard QWERTY layout with
/// Shift support, and a fully functional inline composer.
struct KeyboardView: View {
    let snippets: [TextExpansionSnippet]
    let onInsertText: (String) -> Void
    let onDeleteBackward: () -> Void
    let onAdvanceToNextInputMode: () -> Void
    let onSnippetUsed: (TextExpansionSnippet) -> Void
    let onReload: () -> Void

    @State private var isShifted = false
    @State private var isComposing = false
    @State private var composeTrigger = "&&"
    @State private var composeBody = ""
    @State private var composeFocus: ComposeField = .trigger
    @State private var composeError: String? = nil

    @Environment(\.colorScheme) private var colorScheme

    enum ComposeField {
        case trigger
        case body
    }

    var body: some View {
        VStack(spacing: 0) {
            // 1. Horizontally scrollable snippet bar
            HorizontalSnippetBar(
                snippets: snippets,
                onInsert: { snippet in
                    onInsertText(snippet.body)
                    onSnippetUsed(snippet)
                },
                onAddSnippet: {
                    withAnimation(UnifiedDesignSystem.Animation.standard) {
                        composeTrigger = "&&"
                        composeBody = ""
                        composeFocus = .trigger
                        composeError = nil
                        isComposing = true
                    }
                }
            )
            .frame(height: 46)
            .background(blurBackground)

            Divider()
                .background(UnifiedDesignSystem.Colors.border.opacity(0.3))

            // 2. Main content area: standard keyboard or composer overlay
            ZStack {
                if isComposing {
                    composeOverlay
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    keyboardGrid
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 6)
            .padding(.horizontal, 4)
        }
        .frame(maxWidth: .infinity)
        .background(keyboardBackground)
    }

    // MARK: - Keyboards Grid

    private var keyboardGrid: some View {
        VStack(spacing: 6) {
            // Row 1: qwertyuiop
            keyRow(["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"])

            // Row 2: asdfghjkl
            keyRow(["a", "s", "d", "f", "g", "h", "j", "k", "l"])

            // Row 3: shift, zxcvbnm, delete
            HStack(spacing: 5) {
                specialKey(
                    systemImage: isShifted ? "shift.fill" : "shift",
                    action: { isShifted.toggle() },
                    isAccent: isShifted
                )
                .frame(width: 42)

                ForEach(["z", "x", "c", "v", "b", "n", "m"], id: \.self) { char in
                    letterKey(char)
                }

                specialKey(
                    systemImage: "delete.left",
                    action: {
                        if isComposing {
                            handleComposeDelete()
                        } else {
                            onDeleteBackward()
                        }
                    }
                )
                .frame(width: 42)
            }

            // Row 4: globe/next, &&, space, return
            HStack(spacing: 5) {
                specialKey(
                    systemImage: "globe",
                    action: onAdvanceToNextInputMode
                )
                .frame(width: 42)

                letterKey("&&")
                    .frame(width: 48)

                keyButton(
                    title: "space",
                    action: {
                        if isComposing {
                            handleComposeInput(" ")
                        } else {
                            onInsertText(" ")
                        }
                    },
                    backgroundColor: keyColor(isSpecial: false)
                )

                specialKey(
                    systemImage: "arrow.turn.down.left",
                    action: {
                        if isComposing {
                            // Saving snippet or changing field
                            if composeFocus == .trigger {
                                composeFocus = .body
                            } else {
                                handleSaveSnippet()
                            }
                        } else {
                            onInsertText("\n")
                        }
                    },
                    isAccent: true
                )
                .frame(width: 58)
            }
        }
    }

    // MARK: - Subviews & Layouts

    private func keyRow(_ keys: [String]) -> some View {
        HStack(spacing: 5) {
            ForEach(keys, id: \.self) { key in
                letterKey(key)
            }
        }
    }

    private func letterKey(_ char: String) -> some View {
        let title = isShifted ? char.uppercased() : char
        return keyButton(
            title: title,
            action: {
                if isComposing {
                    handleComposeInput(title)
                } else {
                    onInsertText(title)
                }
            },
            backgroundColor: keyColor(isSpecial: false)
        )
    }

    private func keyButton(
        title: String,
        action: @escaping () -> Void,
        backgroundColor: Color
    ) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 19, weight: .regular, design: .rounded))
                .foregroundColor(textColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(backgroundColor)
                        .shadow(color: Color.black.opacity(0.12), radius: 0.5, x: 0, y: 1)
                )
        }
        .buttonStyle(KeyboardKeyButtonStyle())
    }

    private func specialKey(
        systemImage: String,
        action: @escaping () -> Void,
        isAccent: Bool = false
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(isAccent ? .white : textColor)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(isAccent ? UnifiedDesignSystem.Colors.ember : keyColor(isSpecial: true))
                        .shadow(color: Color.black.opacity(0.12), radius: 0.5, x: 0, y: 1)
                )
        }
        .buttonStyle(KeyboardKeyButtonStyle())
    }

    // MARK: - Inline Composer Overlay

    private var composeOverlay: some View {
        VStack(spacing: 8) {
            HStack {
                Text("New Snippet")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(textColor)

                Spacer()

                if let composeError {
                    Text(composeError)
                        .font(.system(size: 11, weight: .medium, design: .rounded))
                        .foregroundColor(UnifiedDesignSystem.Colors.error)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)

            // Dynamic Form fields
            HStack(spacing: 8) {
                // Trigger Field
                Button { composeFocus = .trigger } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("TRIGGER")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(UnifiedDesignSystem.Colors.textMuted)
                        Text(composeTrigger.isEmpty ? "&&" : composeTrigger)
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundColor(composeTrigger.isEmpty ? .gray : textColor)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(width: 90, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                composeFocus == .trigger ? UnifiedDesignSystem.Colors.ember : Color.clear,
                                lineWidth: 1.5
                            )
                            .background(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.4))
                    )
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)

                // Body Field
                Button { composeFocus = .body } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("EXPANDS TO")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundColor(UnifiedDesignSystem.Colors.textMuted)
                        Text(composeBody.isEmpty ? "Enter expansion text..." : composeBody)
                            .font(.system(size: 13, weight: .regular))
                            .foregroundColor(composeBody.isEmpty ? .gray : textColor)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(
                                composeFocus == .body ? UnifiedDesignSystem.Colors.ember : Color.clear,
                                lineWidth: 1.5
                            )
                            .background(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.4))
                    )
                    .cornerRadius(8)
                }
                .buttonStyle(.plain)
            }

            // Keyboard and Actions
            ZStack(alignment: .bottom) {
                keyboardGrid
                    .opacity(0.9)

                // Inline footer buttons overlaying row 4 slightly
                HStack(spacing: 8) {
                    Button {
                        withAnimation(UnifiedDesignSystem.Animation.standard) {
                            isComposing = false
                        }
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundColor(textColor)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(keyColor(isSpecial: true))
                            )
                    }
                    .buttonStyle(.plain)

                    Button(action: handleSaveSnippet) {
                        Text("Save")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(
                                        LinearGradient(
                                            colors: [UnifiedDesignSystem.Colors.ember, UnifiedDesignSystem.Colors.blaze],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 4)
                .padding(.bottom, 2)
            }
        }
    }

    // MARK: - Handlers

    private func handleComposeInput(_ text: String) {
        if composeFocus == .trigger {
            // Keep trigger formatted starting with &&
            if composeTrigger == "&&" && text == "&&" { return }
            composeTrigger += text
        } else {
            composeBody += text
        }
        composeError = nil
    }

    private func handleComposeDelete() {
        if composeFocus == .trigger {
            guard composeTrigger.count > 2 else { return } // Keep leading &&
            composeTrigger.removeLast()
        } else {
            guard !composeBody.isEmpty else { return }
            composeBody.removeLast()
        }
        composeError = nil
    }

    private func handleSaveSnippet() {
        let result = TextExpansionKeyboardComposer.add(
            rawTrigger: composeTrigger,
            body: composeBody,
            sourceDeviceID: "iOSKeyboard"
        )
        switch result {
        case .success:
            onReload()
            withAnimation(UnifiedDesignSystem.Animation.standard) {
                isComposing = false
            }
        case .failure(let error):
            composeError = error.localizedDescription
        }
    }

    // MARK: - Color adaptors

    private var keyboardBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.08, green: 0.08, blue: 0.10) // Rich dark charcoal
            : Color(red: 0.94, green: 0.95, blue: 0.96) // Apple light keyboard gray
    }

    private var blurBackground: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.24)
            : Color.white.opacity(0.6)
    }

    private func keyColor(isSpecial: Bool) -> Color {
        if colorScheme == .dark {
            return isSpecial
                ? Color(red: 0.16, green: 0.16, blue: 0.19) // Dark special key
                : Color(red: 0.26, green: 0.26, blue: 0.31) // Dark letter key
        } else {
            return isSpecial
                ? Color(red: 0.81, green: 0.83, blue: 0.86) // Light special key
                : Color.white // Light letter key
        }
    }

    private var textColor: Color {
        colorScheme == .dark ? .white : .black
    }
}

// MARK: - Horizontal Snippet Bar

struct HorizontalSnippetBar: View {
    let snippets: [TextExpansionSnippet]
    let onInsert: (TextExpansionSnippet) -> Void
    let onAddSnippet: () -> Void

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        HStack(spacing: 0) {
            // Brand Logo on the left
            Image("KeyboardLogo")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .foregroundColor(UnifiedDesignSystem.Colors.ember)
                .shadow(color: UnifiedDesignSystem.Colors.ember.opacity(colorScheme == .dark ? 0.8 : 0.2), radius: 4)
                .padding(.horizontal, 10)

            Divider()
                .frame(height: 24)
                .background(UnifiedDesignSystem.Colors.border.opacity(0.3))

            // Horizontally scrollable snippets
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(snippets) { snippet in
                        Button {
                            onInsert(snippet)
                        } label: {
                            HStack(spacing: 4) {
                                Text("&&")
                                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                                    .foregroundColor(UnifiedDesignSystem.Colors.ember)
                                Text(snippet.trigger)
                                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                                    .foregroundColor(textColor)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .stroke(
                                        UnifiedDesignSystem.Colors.ember.opacity(0.35),
                                        lineWidth: 1
                                    )
                                    .background(Capsule().fill(chipBackground))
                                    .shadow(color: UnifiedDesignSystem.Colors.ember.opacity(colorScheme == .dark ? 0.12 : 0), radius: 2)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // Plus button at the end
                    Button(action: onAddSnippet) {
                        Image(systemName: "plus")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundColor(.white)
                            .frame(width: 26, height: 26)
                            .background(
                                Circle()
                                    .fill(
                                        LinearGradient(
                                            colors: [UnifiedDesignSystem.Colors.ember, UnifiedDesignSystem.Colors.blaze],
                                            startPoint: .topLeading,
                                            endPoint: .bottomTrailing
                                        )
                                    )
                                    .shadow(color: UnifiedDesignSystem.Colors.ember.opacity(0.4), radius: 3)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 2)
                }
                .padding(.horizontal, 8)
            }
        }
    }

    private var textColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var chipBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.15, green: 0.15, blue: 0.18).opacity(0.8)
            : Color.white.opacity(0.9)
    }
}

// MARK: - Key Button Style

struct KeyboardKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(.interactiveSpring(response: 0.15, dampingFraction: 0.86), value: configuration.isPressed)
    }
}
