import SwiftUI
import OpenBurnBarKernel

// MARK: - Composer Controls
//
// Five subviews bundled in one file because they share visual treatment and
// always render together inside the composer column:
//   • MissionTitlePromptFields — the title + prompt text fields
//   • MissionDepthDial — three-option segmented control (light / standard / deep)
//   • MissionApprovalLever — two-option segmented control + caption
//   • MissionPermissionsRow — Commands + File Edits toggle rows with risk hint
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
            MissionSectionHeader(
                title: "Brief",
                trailing: prompt.isEmpty ? nil : "\(prompt.count) chars"
            )

            TextField("Title — e.g. Tighten the cache reset path", text: $title)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
                .padding(.vertical, 11)
                .focused($titleFocused)
                .background {
                    RoundedRectangle(cornerRadius: MissionChrome.controlCorner, style: .continuous)
                        .fill(MissionChrome.fieldFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: MissionChrome.controlCorner, style: .continuous)
                        .strokeBorder(
                            titleFocused ? MissionChrome.accent.opacity(0.8) : MissionChrome.hairlineColor,
                            lineWidth: titleFocused ? 1 : MissionChrome.hairline
                        )
                }
                .animation(UnifiedDesignSystem.Animation.snappy, value: titleFocused)

            TextEditor(text: $prompt)
                .textEditorStyle(.plain)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($promptFocused)
                .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
                .padding(.vertical, UnifiedDesignSystem.Spacing.sm)
                .frame(minHeight: 96, maxHeight: 160)
                .background {
                    RoundedRectangle(cornerRadius: MissionChrome.controlCorner, style: .continuous)
                        .fill(MissionChrome.fieldFill)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: MissionChrome.controlCorner, style: .continuous)
                        .strokeBorder(
                            promptFocused ? MissionChrome.accent.opacity(0.8) : MissionChrome.hairlineColor,
                            lineWidth: promptFocused ? 1 : MissionChrome.hairline
                        )
                }
                .overlay(alignment: .topLeading) {
                    if prompt.isEmpty {
                        Text("What should the agent do? Be specific — the brief becomes the prompt verbatim.")
                            .font(.system(size: 14, weight: .regular, design: .rounded))
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                            .lineLimit(3)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.horizontal, UnifiedDesignSystem.Spacing.sm + 5)
                            .padding(.vertical, UnifiedDesignSystem.Spacing.sm + 8)
                            .allowsHitTesting(false)
                    }
                }
                .animation(UnifiedDesignSystem.Animation.snappy, value: promptFocused)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Segmented option (shared by depth + approval)

private struct MissionSegmentedOption: Identifiable {
    let id: String
    let title: String
    let tint: Color?
}

private struct MissionSegmentedControl: View {
    let options: [MissionSegmentedOption]
    let selectedID: String
    let onSelect: (String) -> Void

    var body: some View {
        HStack(spacing: 4) {
            ForEach(options) { option in
                let isSelected = option.id == selectedID
                Button { onSelect(option.id) } label: {
                    Text(option.title)
                        .font(.system(size: 13, weight: isSelected ? .semibold : .medium, design: .rounded))
                        .foregroundStyle(
                            isSelected
                                ? (option.tint ?? UnifiedDesignSystem.Colors.textPrimary)
                                : UnifiedDesignSystem.Colors.textSecondary
                        )
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background {
                            if isSelected {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(UnifiedDesignSystem.Colors.surfaceElevated)
                                    .shadow(color: Color.black.opacity(0.18), radius: 2, y: 1)
                            }
                        }
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(3)
        .background {
            RoundedRectangle(cornerRadius: MissionChrome.controlCorner, style: .continuous)
                .fill(MissionChrome.cardFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: MissionChrome.controlCorner, style: .continuous)
                .strokeBorder(MissionChrome.hairlineColor, lineWidth: MissionChrome.hairline)
        }
        .animation(UnifiedDesignSystem.Animation.snappy, value: selectedID)
    }
}

// MARK: - Depth

public struct MissionDepthDial: View {
    @Binding public var depth: MissionConsoleDepth

    public init(depth: Binding<MissionConsoleDepth>) {
        self._depth = depth
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            MissionFieldLabel("Depth")

            MissionSegmentedControl(
                options: MissionConsoleDepth.allCases.map {
                    MissionSegmentedOption(id: $0.id, title: $0.displayName, tint: nil)
                },
                selectedID: depth.id,
                onSelect: { id in
                    if let match = MissionConsoleDepth.allCases.first(where: { $0.id == id }) {
                        depth = match
                    }
                }
            )

            Text(depth.subtitle)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                .animation(UnifiedDesignSystem.Animation.snappy, value: depth)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Approval mode

public struct MissionApprovalLever: View {
    @Binding public var mode: MissionConsoleApprovalMode

    public init(mode: Binding<MissionConsoleApprovalMode>) {
        self._mode = mode
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            MissionFieldLabel("Approvals")

            MissionSegmentedControl(
                options: [
                    MissionSegmentedOption(
                        id: MissionConsoleApprovalMode.existingPolicy.id,
                        title: "Existing policy",
                        tint: nil
                    ),
                    MissionSegmentedOption(
                        id: MissionConsoleApprovalMode.requireApproval.id,
                        title: "Ask me first",
                        tint: UnifiedDesignSystem.Colors.warning
                    ),
                ],
                selectedID: mode.id,
                onSelect: { id in
                    if let match = MissionConsoleApprovalMode.allCases.first(where: { $0.id == id }) {
                        mode = match
                    }
                }
            )

            Text(mode.caption)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
                .animation(UnifiedDesignSystem.Animation.snappy, value: mode)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Permissions

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
            MissionFieldLabel("Permissions")

            MissionConsoleCard {
                VStack(spacing: 0) {
                    permissionRow(
                        label: "Commands",
                        subtitle: "Allow shell execution",
                        glyph: "terminal.fill",
                        isOn: $commandsAllowed
                    )
                    MissionRowDivider(indent: 46)
                    permissionRow(
                        label: "File edits",
                        subtitle: "Allow code writes",
                        glyph: "doc.fill.badge.plus",
                        isOn: $fileEditsAllowed
                    )
                }
            }

            if commandsAllowed && fileEditsAllowed {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Highest blast radius — the agent can run anything and rewrite files.")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .foregroundStyle(UnifiedDesignSystem.Colors.warning)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(UnifiedDesignSystem.Animation.snappy, value: commandsAllowed && fileEditsAllowed)
    }

    private func permissionRow(
        label: String,
        subtitle: String,
        glyph: String,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: UnifiedDesignSystem.Spacing.md) {
            Image(systemName: glyph)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOn.wrappedValue ? UnifiedDesignSystem.Colors.warning : UnifiedDesignSystem.Colors.textMuted)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                Text(subtitle)
                    .font(.system(size: 12, weight: .regular, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            }

            Spacer(minLength: 0)

            Toggle("", isOn: isOn)
                .labelsHidden()
                .tint(UnifiedDesignSystem.Colors.warning)
        }
        .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
        .padding(.vertical, 10)
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
            MissionFieldLabel("Project")

            HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                Image(systemName: "folder")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)

                TextField("~/Projects/Foo — optional", text: $project)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .focused($isFocused)

                if !project.isEmpty {
                    Button { project = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 14))
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Clear project")
                }
            }
            .padding(.horizontal, UnifiedDesignSystem.Spacing.md)
            .padding(.vertical, 11)
            .background {
                RoundedRectangle(cornerRadius: MissionChrome.controlCorner, style: .continuous)
                    .fill(MissionChrome.fieldFill)
            }
            .overlay {
                RoundedRectangle(cornerRadius: MissionChrome.controlCorner, style: .continuous)
                    .strokeBorder(
                        isFocused ? MissionChrome.accent.opacity(0.8) : MissionChrome.hairlineColor,
                        lineWidth: isFocused ? 1 : MissionChrome.hairline
                    )
            }
            .animation(UnifiedDesignSystem.Animation.snappy, value: isFocused)
            .frame(maxWidth: .infinity, alignment: .leading)

            if isFocused && !filteredSuggestions.isEmpty {
                suggestionsRow
            } else if !(recentProjects + knownProjects).isEmpty && project.isEmpty {
                quickRow
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .scrollClipDisabled(false)
    }

    private var quickRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                Text("Recent")
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                ForEach(Array((recentProjects + knownProjects).uniqueOrderPreserving.prefix(8)), id: \.self) { name in
                    suggestionChip(name)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .scrollClipDisabled(false)
    }

    private func suggestionChip(_ name: String) -> some View {
        Button { project = name } label: {
            Text(name)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background {
                    Capsule().fill(MissionChrome.cardFill)
                }
                .overlay {
                    Capsule().strokeBorder(MissionChrome.hairlineColor, lineWidth: MissionChrome.hairline)
                }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Helpers

private extension Sequence where Element: Hashable {
    var uniqueOrderPreserving: [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
