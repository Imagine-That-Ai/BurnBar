import SwiftUI
import OpenBurnBarCore

// MARK: - Keyboard View
/// A custom SwiftUI keyboard that precisely mirrors the native Apple iOS
/// keyboard aesthetic: system font, standard key geometry, inset ASDF row,
/// and correct shadow/color treatment in both light and dark modes.
///
/// Additions over stock iOS: a horizontal snippet bar at the top with the
/// BurnBar logo & a '+' button for inline snippet composition.
struct KeyboardView: View {
    let snippets: [TextExpansionSnippet]
    let suggestions: [String]
    let onInsertText: (String) -> Void
    let onDeleteBackward: () -> Void
    let onAdvanceToNextInputMode: () -> Void
    let onSnippetUsed: (TextExpansionSnippet) -> Void
    let onSuggestionSelected: (String) -> Void
    let onComposeStateChanged: (Bool) -> Void
    let onReload: () -> Void

    @State private var isShifted = false
    @State private var isComposing = false
    @State private var composeTrigger = "&&"
    @State private var composeBody = ""
    @State private var composeFocus: ComposeField = .trigger
    @State private var composeError: String? = nil

    // Repeat-delete state
    @State private var isDeletePressed = false
    @State private var deleteTimer: Timer?
    @State private var deleteCount = 0

    // Swipe typing state
    @State private var isSwiping = false
    @State private var swipeWord: String = ""
    private let swipeEngine = SwipeTypingEngine()

    @Environment(\.colorScheme) private var colorScheme

    // MARK: - Constants (matches native iOS keyboard metrics)
    private enum Metrics {
        static let keyHeight: CGFloat = 42
        static let keyCornerRadius: CGFloat = 5
        static let rowSpacing: CGFloat = 10
        static let keySpacing: CGFloat = 6
        static let horizontalPadding: CGFloat = 3
        static let topPadding: CGFloat = 8
        static let bottomPadding: CGFloat = 4
        static let snippetBarHeight: CGFloat = 42
    }

    enum ComposeField {
        case trigger
        case body
    }

    var body: some View {
        VStack(spacing: 0) {
            // 1. Snippet bar or Autocorrect suggestion bar
            if !suggestions.isEmpty && !isComposing {
                suggestionBar
                    .frame(height: Metrics.snippetBarHeight)
            } else {
                snippetBar
                    .frame(height: Metrics.snippetBarHeight)
            }

            Divider()
                .background(separatorColor)

            // 2. Keyboard body
            ZStack {
                if isComposing {
                    composeOverlay
                        .transition(.move(edge: .top).combined(with: .opacity))
                } else {
                    keyboardGrid
                }
            }
            .padding(.top, Metrics.topPadding)
            .padding(.bottom, Metrics.bottomPadding)
            .padding(.horizontal, Metrics.horizontalPadding)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .background(keyboardBackground)
        .onChange(of: isComposing) { _, newValue in
            onComposeStateChanged(newValue)
        }
    }

    // MARK: - QWERTY Grid

    private var keyboardGrid: some View {
        GeometryReader { geometry in
            VStack(spacing: Metrics.rowSpacing) {
                // Row 1: Q W E R T Y U I O P
                letterRow(["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"])

            // Row 2: A S D F G H J K L (inset by half-key)
            letterRow(["a", "s", "d", "f", "g", "h", "j", "k", "l"])
                .padding(.horizontal, 18)

            // Row 3: Shift + Z X C V B N M + Delete
            HStack(spacing: Metrics.keySpacing) {
                // Shift
                actionKey(
                    content: AnyView(
                        Image(systemName: isShifted ? "shift.fill" : "shift")
                            .font(.system(size: 16, weight: .medium))
                    ),
                    width: 42,
                    isHighlighted: isShifted,
                    action: { isShifted.toggle() }
                )

                // Z through M
                ForEach(["z", "x", "c", "v", "b", "n", "m"], id: \.self) { char in
                    characterKey(char)
                }

                // Delete — supports press-and-hold with accelerating repeat
                repeatDeleteKey
            }

            // Row 4: Globe + && + Space + Return
            HStack(spacing: Metrics.keySpacing) {
                // Globe / Next Keyboard
                actionKey(
                    content: AnyView(
                        Image(systemName: "globe")
                            .font(.system(size: 16, weight: .medium))
                    ),
                    width: 42,
                    action: onAdvanceToNextInputMode
                )

                // && trigger key
                actionKey(
                    content: AnyView(
                        Text("&&")
                            .font(.system(size: 15, weight: .medium))
                    ),
                    width: 42,
                    action: {
                        if isComposing {
                            handleComposeInput("&&")
                        } else {
                            onInsertText("&&")
                        }
                    }
                )

                // Space bar — takes the lion's share of remaining width
                spaceBar
                    .layoutPriority(1)

                // Return — fixed width to match Apple keyboard (~88pt)
                actionKey(
                    content: AnyView(
                        Text("return")
                            .font(.system(size: 15, weight: .medium))
                    ),
                    width: 88,
                    isHighlighted: isComposing && composeFocus == .body,
                    action: {
                        if isComposing {
                            if composeFocus == .trigger {
                                composeFocus = .body
                            } else {
                                handleSaveSnippet()
                            }
                        } else {
                            onInsertText("\n")
                        }
                    }
                )
            }
            }
            .simultaneousGesture(swipeTypingGesture(gridSize: geometry.size))
        }
        .frame(height: Metrics.keyHeight * 4 + Metrics.rowSpacing * 3)
    }

    // MARK: - Key Components

    /// Standard letter key — white in light mode, dark gray in dark mode.
    private func characterKey(_ char: String) -> some View {
        let label = isShifted ? char.uppercased() : char
        return Button {
            KeyboardHaptics.keyPress()
            if isComposing {
                handleComposeInput(label)
            } else {
                onInsertText(label)
            }
        } label: {
            Text(label)
                .font(.system(size: 22.5, weight: .light))
                .foregroundColor(textColor)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.keyHeight)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.keyCornerRadius, style: .continuous)
                        .fill(letterKeyColor)
                        .shadow(color: keyShadowColor, radius: 0, x: 0, y: 1)
                )
        }
        .buttonStyle(AppleKeyButtonStyle())
    }

    /// Row of equally-spaced letter keys.
    private func letterRow(_ keys: [String]) -> some View {
        HStack(spacing: Metrics.keySpacing) {
            ForEach(keys, id: \.self) { key in
                characterKey(key)
            }
        }
    }

    /// Action key — darker background (shift, delete, globe, return, etc.).
    private func actionKey(
        content: AnyView,
        width: CGFloat?,
        isHighlighted: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: {
            KeyboardHaptics.specialKeyPress()
            action()
        }) {
            content
                .foregroundColor(isHighlighted ? .white : textColor)
                .frame(height: Metrics.keyHeight)
                .frame(width: width)
                .frame(maxWidth: width == nil ? .infinity : nil)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.keyCornerRadius, style: .continuous)
                        .fill(isHighlighted ? Color.accentColor : specialKeyBackground)
                        .shadow(color: keyShadowColor, radius: 0, x: 0, y: 1)
                )
        }
        .buttonStyle(AppleKeyButtonStyle())
    }

    /// Space bar — wider, letter-key color.
    private var spaceBar: some View {
        Button {
            KeyboardHaptics.keyPress()
            if isComposing {
                handleComposeInput(" ")
            } else {
                onInsertText(" ")
            }
        } label: {
            Text("space")
                .font(.system(size: 15, weight: .medium))
                .foregroundColor(textColor)
                .frame(maxWidth: .infinity)
                .frame(height: Metrics.keyHeight)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.keyCornerRadius, style: .continuous)
                        .fill(letterKeyColor)
                        .shadow(color: keyShadowColor, radius: 0, x: 0, y: 1)
                )
        }
        .buttonStyle(AppleKeyButtonStyle())
    }

    // MARK: - Repeat-Press Delete Key

    /// Delete key that supports press-and-hold with accelerating repeat rate.
    /// Starts at 150ms/delete, accelerates to 20ms/delete over ~30 deletions.
    private var repeatDeleteKey: some View {
        Image(systemName: "delete.left")
            .font(.system(size: 16, weight: .medium))
            .foregroundColor(textColor)
            .frame(width: 42, height: Metrics.keyHeight)
            .background(
                RoundedRectangle(cornerRadius: Metrics.keyCornerRadius, style: .continuous)
                    .fill(specialKeyBackground)
                    .shadow(color: keyShadowColor, radius: 0, x: 0, y: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: Metrics.keyCornerRadius, style: .continuous))
            .brightness(isDeletePressed ? -0.1 : 0)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isDeletePressed else { return }
                        isDeletePressed = true
                        performDelete()
                        startRepeatDelete()
                    }
                    .onEnded { _ in
                        isDeletePressed = false
                        stopRepeatDelete()
                    }
            )
    }

    private func performDelete() {
        KeyboardHaptics.specialKeyPress()
        if isComposing {
            handleComposeDelete()
        } else {
            onDeleteBackward()
        }
    }

    private func startRepeatDelete() {
        deleteCount = 0
        // Initial delay before repeating starts (like Apple: ~0.4s)
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [self] _ in
            scheduleNextDelete()
        }
    }

    private func scheduleNextDelete() {
        guard isDeletePressed else { return }
        deleteCount += 1
        performDelete()

        // Accelerating rate
        let interval: TimeInterval
        switch deleteCount {
        case 0..<5:   interval = 0.12
        case 5..<15:  interval = 0.07
        case 15..<30: interval = 0.04
        default:      interval = 0.02  // Max speed
        }

        deleteTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [self] _ in
            scheduleNextDelete()
        }
    }

    private func stopRepeatDelete() {
        deleteTimer?.invalidate()
        deleteTimer = nil
        deleteCount = 0
    }

    // MARK: - Swipe Typing Gesture

    /// Creates a drag gesture that tracks finger movement across the keyboard
    /// grid and resolves the swipe path into a word when released.
    private func swipeTypingGesture(gridSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                if !isSwiping {
                    isSwiping = true
                    swipeEngine.beginSwipe()
                }
                swipeEngine.trackPoint(value.location, in: gridSize)
            }
            .onEnded { _ in
                guard isSwiping else { return }
                isSwiping = false
                let results = swipeEngine.resolve()
                if let bestMatch = results.first {
                    KeyboardHaptics.selectionPress()
                    onInsertText(bestMatch + " ")
                }
            }
    }


    // MARK: - Snippet Bar

    private var snippetBar: some View {
        HStack(spacing: 0) {
            // BurnBar logo
            Image("KeyboardLogo")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 20, height: 20)
                .foregroundColor(UnifiedDesignSystem.Colors.ember)
                .padding(.horizontal, 10)

            Divider()
                .frame(height: 22)
                .background(separatorColor)

            // Scrollable snippet pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(snippets) { snippet in
                        Button {
                            KeyboardHaptics.selectionPress()
                            onInsertText(snippet.body)
                            onSnippetUsed(snippet)
                        } label: {
                            HStack(spacing: 3) {
                                Text("&&")
                                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                                    .foregroundColor(UnifiedDesignSystem.Colors.ember)
                                Text(snippet.trigger)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundColor(textColor)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(snippetChipBackground)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(separatorColor, lineWidth: 0.5)
                            )
                        }
                        .buttonStyle(.plain)
                    }

                    // Add snippet button
                    Button(action: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            composeTrigger = "&&"
                            composeBody = ""
                            composeFocus = .trigger
                            composeError = nil
                            isComposing = true
                        }
                    }) {
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 24, height: 24)
                            .background(
                                Circle()
                                    .fill(UnifiedDesignSystem.Colors.ember)
                            )
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 2)
                }
                .padding(.horizontal, 8)
            }
        }
        .background(snippetBarBackground)
    }

    // MARK: - Autocorrect Suggestion Bar

    /// Native Apple-style autocorrect bar with up to 3 suggestions
    /// separated by thin dividers.
    private var suggestionBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(suggestions.enumerated()), id: \.offset) { index, suggestion in
                if index > 0 {
                    Divider()
                        .frame(height: 24)
                        .background(separatorColor)
                }

                Button {
                    KeyboardHaptics.selectionPress()
                    onSuggestionSelected(suggestion)
                } label: {
                    Text(suggestion)
                        .font(.system(size: 15, weight: index == 0 ? .semibold : .regular))
                        .foregroundColor(textColor)
                        .frame(maxWidth: .infinity)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .background(snippetBarBackground)
    }

    // MARK: - Compose Overlay

    private var composeOverlay: some View {
        VStack(spacing: 8) {
            // Header
            HStack {
                Text("New Snippet")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(textColor)

                Spacer()

                if let composeError {
                    Text(composeError)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(UnifiedDesignSystem.Colors.error)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 2)

            // Fields
            HStack(spacing: 8) {
                composeField(
                    label: "TRIGGER",
                    value: composeTrigger.isEmpty ? "&&" : composeTrigger,
                    isEmpty: composeTrigger.isEmpty,
                    isFocused: composeFocus == .trigger,
                    width: 90
                ) {
                    composeFocus = .trigger
                }

                composeField(
                    label: "EXPANDS TO",
                    value: composeBody.isEmpty ? "Enter text…" : composeBody,
                    isEmpty: composeBody.isEmpty,
                    isFocused: composeFocus == .body,
                    width: nil
                ) {
                    composeFocus = .body
                }
            }

            // Reduced keyboard (3 letter rows) + dedicated action row
            VStack(spacing: Metrics.rowSpacing) {
                // Row 1: Q W E R T Y U I O P
                letterRow(["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"])

                // Row 2: A S D F G H J K L
                letterRow(["a", "s", "d", "f", "g", "h", "j", "k", "l"])
                    .padding(.horizontal, 18)

                // Row 3: Shift + Z X C V B N M + Delete
                HStack(spacing: Metrics.keySpacing) {
                    actionKey(
                        content: AnyView(
                            Image(systemName: isShifted ? "shift.fill" : "shift")
                                .font(.system(size: 16, weight: .medium))
                        ),
                        width: 42,
                        isHighlighted: isShifted,
                        action: { isShifted.toggle() }
                    )

                    ForEach(["z", "x", "c", "v", "b", "n", "m"], id: \.self) { char in
                        characterKey(char)
                    }

                    actionKey(
                        content: AnyView(
                            Image(systemName: "delete.left")
                                .font(.system(size: 16, weight: .medium))
                        ),
                        width: 42,
                        action: { handleComposeDelete() }
                    )
                }

                // Row 4: Cancel + Space + Save (replaces bottom row)
                HStack(spacing: Metrics.keySpacing) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            isComposing = false
                        }
                    } label: {
                        Text("Cancel")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(textColor)
                            .frame(width: 80)
                            .frame(height: Metrics.keyHeight)
                            .background(
                                RoundedRectangle(cornerRadius: Metrics.keyCornerRadius, style: .continuous)
                                    .fill(specialKeyBackground)
                                    .shadow(color: keyShadowColor, radius: 0, x: 0, y: 1)
                            )
                    }
                    .buttonStyle(AppleKeyButtonStyle())

                    // Space bar for typing
                    Button {
                        handleComposeInput(" ")
                    } label: {
                        Text("space")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundColor(textColor)
                            .frame(maxWidth: .infinity)
                            .frame(height: Metrics.keyHeight)
                            .background(
                                RoundedRectangle(cornerRadius: Metrics.keyCornerRadius, style: .continuous)
                                    .fill(letterKeyColor)
                                    .shadow(color: keyShadowColor, radius: 0, x: 0, y: 1)
                            )
                    }
                    .buttonStyle(AppleKeyButtonStyle())
                    .layoutPriority(1)

                    Button(action: handleSaveSnippet) {
                        Text("Save")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundColor(.white)
                            .frame(width: 80)
                            .frame(height: Metrics.keyHeight)
                            .background(
                                RoundedRectangle(cornerRadius: Metrics.keyCornerRadius, style: .continuous)
                                    .fill(UnifiedDesignSystem.Colors.ember)
                                    .shadow(color: keyShadowColor, radius: 0, x: 0, y: 1)
                            )
                    }
                    .buttonStyle(AppleKeyButtonStyle())
                }
            }
        }
    }

    private func composeField(
        label: String,
        value: String,
        isEmpty: Bool,
        isFocused: Bool,
        width: CGFloat?,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(UnifiedDesignSystem.Colors.textMuted)
                Text(value)
                    .font(.system(size: 13, weight: isEmpty ? .regular : .medium, design: label == "TRIGGER" ? .monospaced : .default))
                    .foregroundColor(isEmpty ? .gray : textColor)
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(width: width, alignment: .leading)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(composeFieldBackground)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(
                        isFocused ? UnifiedDesignSystem.Colors.ember : Color.clear,
                        lineWidth: 1.5
                    )
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Handlers

    private func handleComposeInput(_ text: String) {
        if composeFocus == .trigger {
            if composeTrigger == "&&" && text == "&&" { return }
            composeTrigger += text
        } else {
            composeBody += text
        }
        composeError = nil
    }

    private func handleComposeDelete() {
        if composeFocus == .trigger {
            guard composeTrigger.count > 2 else { return }
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
            withAnimation(.easeInOut(duration: 0.2)) {
                isComposing = false
            }
        case .failure(let error):
            composeError = error.localizedDescription
        }
    }

    // MARK: - Native iOS Keyboard Colors

    /// Main keyboard background — matches iOS system keyboard exactly.
    private var keyboardBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.11, green: 0.11, blue: 0.12)
            : Color(red: 0.82, green: 0.84, blue: 0.86)
    }

    /// Letter key fill — white in light, medium gray in dark.
    private var letterKeyColor: Color {
        colorScheme == .dark
            ? Color(red: 0.40, green: 0.40, blue: 0.43)
            : Color.white
    }

    /// Special key fill — darker gray in both modes.
    private var specialKeyBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.26, green: 0.26, blue: 0.28)
            : Color(red: 0.68, green: 0.71, blue: 0.74)
    }

    /// Key bottom shadow — subtle 1pt drop matching native keys.
    private var keyShadowColor: Color {
        colorScheme == .dark
            ? Color.black.opacity(0.5)
            : Color.black.opacity(0.3)
    }

    private var textColor: Color {
        colorScheme == .dark ? .white : .black
    }

    private var separatorColor: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.12)
            : Color.black.opacity(0.12)
    }

    private var snippetBarBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.13, green: 0.13, blue: 0.14)
            : Color(red: 0.87, green: 0.88, blue: 0.90)
    }

    private var snippetChipBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.22, green: 0.22, blue: 0.24)
            : Color.white.opacity(0.9)
    }

    private var composeFieldBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.18, green: 0.18, blue: 0.20)
            : Color.white.opacity(0.7)
    }
}

// MARK: - Apple-Native Key Button Style
/// Mimics the native iOS keyboard press behavior: slight brightness shift,
/// no scale transform, instant feedback.
struct AppleKeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
            .brightness(configuration.isPressed ? -0.1 : 0)
            .animation(.easeOut(duration: 0.05), value: configuration.isPressed)
    }
}
