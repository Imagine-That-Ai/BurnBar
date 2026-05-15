import SwiftUI

// MARK: - Composer Controls
//
// Five subviews bundled in one file because they share visual treatment and
// always render together inside the composer column:
//   • MissionTitlePromptFields — the title + prompt text fields
//   • MissionDepthDial — three-stop arc dial (light / standard / deep)
//   • MissionApprovalLever — existing-policy ↔ require-approval lever
//   • MissionPermissionsRow — Commands + File Edits toggles with risk hint
//   • MissionProjectField — autocomplete over knownProjects

// MARK: - Title + prompt

public struct MissionTitlePromptFields: View {
    @Binding public var title: String
    @Binding public var prompt: String
    @FocusState private var titleFocused: Bool
    @FocusState private var promptFocused: Bool

    public init(title: Binding<String>, prompt: Binding<String>) {
        self._title = title
        self._prompt = prompt
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.md) {
            sectionHeader

            VStack(alignment: .leading, spacing: 6) {
                fieldLabel("TITLE")
                TextField("e.g. Tighten the cache reset path", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
                    .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
                    .focused($titleFocused)
                    .background {
                        RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                            .fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.6))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                            .strokeBorder(
                                titleFocused
                                    ? UnifiedDesignSystem.Colors.ember.opacity(0.85)
                                    : UnifiedDesignSystem.Colors.borderSubtle.opacity(0.7),
                                lineWidth: titleFocused ? 1.2 : 0.6
                            )
                    }
                    .animation(UnifiedDesignSystem.Animation.hover, value: titleFocused)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    fieldLabel("MISSION BRIEF")
                    Spacer()
                    Text("\(prompt.count) chars")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                }
                TextEditor(text: $prompt)
                    .textEditorStyle(.plain)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    .scrollContentBackground(.hidden)
                    .focused($promptFocused)
                    .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
                    .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
                    .frame(minHeight: 110, maxHeight: 180)
                    .background {
                        RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                            .fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.6))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                            .strokeBorder(
                                promptFocused
                                    ? UnifiedDesignSystem.Colors.ember.opacity(0.85)
                                    : UnifiedDesignSystem.Colors.borderSubtle.opacity(0.7),
                                lineWidth: promptFocused ? 1.2 : 0.6
                            )
                    }
                    .overlay(alignment: .topLeading) {
                        if prompt.isEmpty {
                            Text("What should the agent do? Be specific — the brief becomes the prompt verbatim.")
                                .font(.system(size: 14, weight: .regular, design: .rounded))
                                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                                .padding(.horizontal, UnifiedDesignSystem.Spacing.sm + 5)
                                .padding(.vertical, UnifiedDesignSystem.Spacing.sm + 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .animation(UnifiedDesignSystem.Animation.hover, value: promptFocused)
            }
        }
    }

    private var sectionHeader: some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
            Text("03 · BRIEF")
                .font(.system(size: 10, weight: .bold, design: .monospaced))
                .tracking(2.4)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            Rectangle()
                .fill(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1.5)
            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
    }
}

// MARK: - Depth dial

public struct MissionDepthDial: View {
    @Binding public var depth: MissionConsoleDepth

    public init(depth: Binding<MissionConsoleDepth>) {
        self._depth = depth
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            fieldLabel("DEPTH")

            HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                ForEach(MissionConsoleDepth.allCases) { stop in
                    stopButton(stop)
                }
            }
        }
    }

    private func stopButton(_ stop: MissionConsoleDepth) -> some View {
        let isSelected = stop == depth
        return Button { depth = stop } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    depthGlyph(for: stop, isSelected: isSelected)
                    Text(stop.displayName)
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(isSelected ? UnifiedDesignSystem.Colors.textPrimary : UnifiedDesignSystem.Colors.textSecondary)
                }
                Text(stop.subtitle)
                    .font(.system(size: 9, weight: .medium, design: .rounded))
                    .foregroundStyle(isSelected ? UnifiedDesignSystem.Colors.textSecondary : UnifiedDesignSystem.Colors.textMuted)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
            .padding(.vertical, 8)
            .background {
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                    .fill(isSelected ? UnifiedDesignSystem.Colors.surfaceElevated : UnifiedDesignSystem.Colors.surface.opacity(0.5))
            }
            .overlay {
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                    .strokeBorder(
                        isSelected
                            ? UnifiedDesignSystem.Colors.amber.opacity(0.9)
                            : UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6),
                        lineWidth: isSelected ? 1.2 : 0.5
                    )
            }
            .animation(UnifiedDesignSystem.Animation.standard, value: isSelected)
        }
        .buttonStyle(.plain)
    }

    private func depthGlyph(for stop: MissionConsoleDepth, isSelected: Bool) -> some View {
        HStack(spacing: 2) {
            ForEach(0..<3) { i in
                Circle()
                    .fill(
                        i <= stop.ordinal && isSelected
                            ? UnifiedDesignSystem.Colors.amber
                            : i <= stop.ordinal
                                ? UnifiedDesignSystem.Colors.textSecondary
                                : UnifiedDesignSystem.Colors.borderSubtle.opacity(0.7)
                    )
                    .frame(width: 5, height: 5)
            }
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1.5)
            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
    }
}

// MARK: - Approval lever

public struct MissionApprovalLever: View {
    @Binding public var mode: MissionConsoleApprovalMode

    public init(mode: Binding<MissionConsoleApprovalMode>) {
        self._mode = mode
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            fieldLabel("APPROVAL")

            HStack(spacing: 0) {
                option(.existingPolicy, glyph: "shield.checkered")
                option(.requireApproval, glyph: "hand.raised.fill")
            }
            .background {
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                    .fill(UnifiedDesignSystem.Colors.surface.opacity(0.5))
            }
            .overlay {
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                    .strokeBorder(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
            }
            .clipShape(RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous))

            Text(mode.caption)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .animation(UnifiedDesignSystem.Animation.snappy, value: mode)
        }
    }

    private func option(_ value: MissionConsoleApprovalMode, glyph: String) -> some View {
        let isSelected = mode == value
        return Button { mode = value } label: {
            HStack(spacing: 6) {
                Image(systemName: glyph)
                    .font(.system(size: 11, weight: .bold))
                Text(value.displayName)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .lineLimit(1)
            }
            .foregroundStyle(
                isSelected ? UnifiedDesignSystem.Colors.textPrimary : UnifiedDesignSystem.Colors.textSecondary
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 9)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                        .fill(
                            value == .requireApproval
                                ? AnyShapeStyle(UnifiedDesignSystem.Colors.hermesAureate.opacity(0.18))
                                : AnyShapeStyle(UnifiedDesignSystem.Colors.success.opacity(0.18))
                        )
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                        .strokeBorder(
                            value == .requireApproval
                                ? UnifiedDesignSystem.Colors.hermesAureate.opacity(0.7)
                                : UnifiedDesignSystem.Colors.success.opacity(0.7),
                            lineWidth: 1
                        )
                }
            }
            .animation(UnifiedDesignSystem.Animation.standard, value: isSelected)
        }
        .buttonStyle(.plain)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1.5)
            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
    }
}

// MARK: - Permissions row

public struct MissionPermissionsRow: View {
    @Binding public var commandsAllowed: Bool
    @Binding public var fileEditsAllowed: Bool

    public init(
        commandsAllowed: Binding<Bool>,
        fileEditsAllowed: Binding<Bool>
    ) {
        self._commandsAllowed = commandsAllowed
        self._fileEditsAllowed = fileEditsAllowed
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            fieldLabel("PERMISSIONS")
            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                toggleTile(
                    label: "Commands",
                    subtitle: "Allow shell execution",
                    glyph: "terminal.fill",
                    isOn: $commandsAllowed
                )
                toggleTile(
                    label: "File edits",
                    subtitle: "Allow code writes",
                    glyph: "doc.fill.badge.plus",
                    isOn: $fileEditsAllowed
                )
            }
            if commandsAllowed && fileEditsAllowed {
                HStack(spacing: 6) {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text("Highest blast radius — agent can run anything and rewrite files.")
                        .font(.system(size: 10, weight: .medium, design: .rounded))
                }
                .foregroundStyle(UnifiedDesignSystem.Colors.ember)
                .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
                .padding(.vertical, 5)
                .background {
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                        .fill(UnifiedDesignSystem.Colors.ember.opacity(0.12))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                        .strokeBorder(UnifiedDesignSystem.Colors.ember.opacity(0.4), lineWidth: 0.5)
                }
                .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
        .animation(UnifiedDesignSystem.Animation.standard, value: commandsAllowed && fileEditsAllowed)
    }

    private func toggleTile(
        label: String,
        subtitle: String,
        glyph: String,
        isOn: Binding<Bool>
    ) -> some View {
        Button {
            isOn.wrappedValue.toggle()
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: glyph)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(
                        isOn.wrappedValue
                            ? UnifiedDesignSystem.Colors.warning
                            : UnifiedDesignSystem.Colors.textMuted
                    )
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 4) {
                        Text(label)
                            .font(.system(size: 11, weight: .semibold, design: .rounded))
                            .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        Text(isOn.wrappedValue ? "ON" : "OFF")
                            .font(.system(size: 8, weight: .bold, design: .monospaced))
                            .tracking(0.6)
                            .foregroundStyle(
                                isOn.wrappedValue
                                    ? UnifiedDesignSystem.Colors.warning
                                    : UnifiedDesignSystem.Colors.textMuted
                            )
                    }
                    Text(subtitle)
                        .font(.system(size: 10, weight: .regular, design: .rounded))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)
            }
            .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                    .fill(UnifiedDesignSystem.Colors.surface.opacity(0.55))
            }
            .overlay {
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm, style: .continuous)
                    .strokeBorder(
                        isOn.wrappedValue
                            ? UnifiedDesignSystem.Colors.warning.opacity(0.7)
                            : UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6),
                        lineWidth: isOn.wrappedValue ? 1.0 : 0.5
                    )
            }
            .animation(UnifiedDesignSystem.Animation.standard, value: isOn.wrappedValue)
        }
        .buttonStyle(.plain)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1.5)
            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
    }
}

// MARK: - Project field (autocomplete)

public struct MissionProjectField: View {
    @Binding public var project: String
    public let knownProjects: [String]
    public let recentProjects: [String]
    @FocusState private var isFocused: Bool

    public init(
        project: Binding<String>,
        knownProjects: [String],
        recentProjects: [String]
    ) {
        self._project = project
        self.knownProjects = knownProjects
        self.recentProjects = recentProjects
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            HStack {
                fieldLabel("PROJECT")
                Spacer()
                if !project.isEmpty {
                    Text(normalizedPath)
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                Image(systemName: "folder.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.hermesAureate)

                TextField("~/Projects/Foo or leave blank", text: $project)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    .focused($isFocused)

                if !project.isEmpty {
                    Button { project = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
            .padding(.vertical, 9)
            .background {
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                    .fill(UnifiedDesignSystem.Colors.surfaceElevated.opacity(0.6))
            }
            .overlay {
                RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.md, style: .continuous)
                    .strokeBorder(
                        isFocused
                            ? UnifiedDesignSystem.Colors.hermesAureate.opacity(0.85)
                            : UnifiedDesignSystem.Colors.borderSubtle.opacity(0.7),
                        lineWidth: isFocused ? 1.0 : 0.6
                    )
            }
            .animation(UnifiedDesignSystem.Animation.hover, value: isFocused)

            if isFocused && !filteredSuggestions.isEmpty {
                suggestionsRow
            } else if !recentProjects.isEmpty && project.isEmpty {
                quickRow
            }
        }
    }

    private var normalizedPath: String {
        let home = NSHomeDirectory()
        if project.hasPrefix("~") { return project }
        if project.hasPrefix(home) {
            return "~" + project.dropFirst(home.count)
        }
        return project
    }

    private var filteredSuggestions: [String] {
        if project.isEmpty {
            return Array((recentProjects + knownProjects).uniqueOrderPreserving.prefix(6))
        }
        let lowered = project.lowercased()
        return Array(
            (recentProjects + knownProjects)
                .uniqueOrderPreserving
                .filter { $0.lowercased().contains(lowered) }
                .prefix(6)
        )
    }

    private var suggestionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                ForEach(filteredSuggestions, id: \.self) { name in
                    suggestionChip(name)
                }
            }
        }
    }

    private var quickRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                Text("Recent")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .tracking(0.8)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                ForEach(Array(recentProjects.prefix(4)), id: \.self) { name in
                    suggestionChip(name)
                }
            }
        }
    }

    private func suggestionChip(_ name: String) -> some View {
        Button { project = name } label: {
            Text(name)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
                .padding(.vertical, 4)
                .background {
                    Capsule().fill(UnifiedDesignSystem.Colors.surface.opacity(0.7))
                }
                .overlay {
                    Capsule().strokeBorder(UnifiedDesignSystem.Colors.borderSubtle.opacity(0.6), lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold, design: .monospaced))
            .tracking(1.5)
            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
    }
}

// MARK: - Helpers

private extension Sequence where Element: Hashable {
    var uniqueOrderPreserving: [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
