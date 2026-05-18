import AppKit
import SwiftUI

// MARK: - BurnBarTopRail
//
// Redesigned dashboard top bar — composable primitives that render as a single
// rail (for the #Preview) or as discrete toolbar sections (live in the macOS
// toolbar via DashboardToolbar.swift).
//
//   [ back · 🔥 OpenBurnBar · Agents·Models ]   [ 🔍 omnibar (⌘K) ]   [ range · unit · BURN hero · actions ]
//
// Modernization themes for this iteration:
//
//   • Brand coherence — the wordmark now reads "OpenBurnBar" instead of the
//     legacy "BURNBAR" stamp; the flame keeps its ember/amber gradient.
//   • Search as a first-class citizen — the omnibar is centered, adopts
//     Liquid Glass on macOS 26+, and reveals an inline scope row +
//     recent-search popover when focused (⌘K from anywhere).
//   • Liquid Glass with graceful fallback — `glassEffect(_:in:)` and
//     `sharedBackgroundVisibility` are used on macOS 26+, falling back to
//     `.ultraThinMaterial` / rounded-rect strokes on older releases.
//   • Symbol effects + numeric content transition for live feedback on
//     scanning, recount, and the BURN headline.

// MARK: - Shared types

enum BurnRailViewMode: String, CaseIterable, Identifiable {
    case agents, models
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
    var systemImage: String {
        switch self {
        case .agents: return "sparkles"
        case .models: return "cube.transparent"
        }
    }
}

enum BurnRailUnit: String, CaseIterable, Identifiable {
    case tokens, cost
    var id: String { rawValue }
    var glyph: String {
        switch self {
        case .tokens: return "number"
        case .cost:   return "dollarsign"
        }
    }
    var label: String {
        switch self {
        case .tokens: return "Tokens"
        case .cost:   return "Cost"
        }
    }
}

enum BurnRailSearchScope: String, CaseIterable, Identifiable {
    case all, sessions, projects, models
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all:       return "All"
        case .sessions:  return "Sessions"
        case .projects:  return "Projects"
        case .models:    return "Models"
        }
    }
    var systemImage: String {
        switch self {
        case .all:       return "sparkle.magnifyingglass"
        case .sessions:  return "bubble.left.and.bubble.right"
        case .projects:  return "folder"
        case .models:    return "cube"
        }
    }
    /// Compose a query that prefixes the search with the scope token.
    func qualify(_ query: String) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard self != .all else { return trimmed }
        return "in:\(rawValue) \(trimmed)"
    }
}

struct BurnRailTelemetry {
    var headlineValue: String   // e.g. "1.79B" or "$284.12"
    var headlineSuffix: String? // e.g. "tok"
    var deltaPercent: Double?   // signed vs. previous period
    var sparkline: [Double]     // 0...1 normalized
    var isLive: Bool
}

// MARK: - Top-level composed rail (preview / standalone use)

struct BurnBarTopRail: View {
    @Binding var viewMode: BurnRailViewMode
    @Binding var unit: BurnRailUnit
    @Binding var searchText: String

    let rangeLabel: String
    let canGoBack: Bool
    let isScanning: Bool
    let telemetry: BurnRailTelemetry

    var onBack: () -> Void = {}
    var onRangeTap: () -> Void = {}
    var onSearchSubmit: (String) -> Void = { _ in }
    var onImport: () -> Void = {}
    var onRecount: () -> Void = {}
    var onSettings: () -> Void = {}

    @FocusState private var searchFocused: Bool

    var body: some View {
        HStack(spacing: 14) {
            BurnRailIdentitySection(
                viewMode: $viewMode,
                canGoBack: canGoBack,
                onBack: onBack
            )

            Spacer(minLength: 12)

            BurnRailSearchOmnibar(
                text: $searchText,
                focused: $searchFocused,
                onSubmit: onSearchSubmit
            )
            .frame(maxWidth: 380)

            Spacer(minLength: 12)

            BurnRailContextSection(
                unit: $unit,
                rangeLabel: rangeLabel,
                onRangeTap: onRangeTap
            )

            BurnRailTelemetryHero(telemetry: telemetry)

            BurnRailActionsSection(
                isScanning: isScanning,
                onImport: onImport,
                onRecount: onRecount,
                onSettings: onSettings
            )
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .frame(minHeight: 56)
        .background(railBackground)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignSystem.Colors.borderSubtle.opacity(0.6))
                .frame(height: 0.5)
        }
    }

    private var railBackground: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            LinearGradient(
                colors: [
                    .clear,
                    DesignSystem.Colors.ember.opacity(0.022),
                    DesignSystem.Colors.blaze.opacity(0.032)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            Rectangle()
                .fill(Color.white.opacity(0.0125))
                .blendMode(.overlay)
        }
    }
}

// MARK: - Section: Identity (back + flame + view mode)

struct BurnRailIdentitySection: View {
    @Binding var viewMode: BurnRailViewMode
    var canGoBack: Bool = false
    var onBack: () -> Void = {}

    var body: some View {
        HStack(spacing: 10) {
            if canGoBack {
                Button(action: onBack) {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Back")
            }

            BurnRailBrandMark()

            BurnRailDivider()

            BurnRailViewModeSegmented(viewMode: $viewMode)
        }
    }
}

// MARK: - Brand mark
//
// Replaces the legacy all-caps "BURNBAR" stamp with a more brand-coherent
// "OpenBurnBar" wordmark. The flame retains the ember→amber gradient and a
// subtle pulse when hovered; the wordmark uses a rounded, mixed-case treatment
// that reads as a product name instead of a system stamp.

private struct BurnRailBrandMark: View {
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            ZStack {
                if hover {
                    Image(systemName: "flame.fill")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(DesignSystem.Colors.ember.opacity(0.35))
                        .blur(radius: 4)
                        .transition(.opacity)
                }
                Image(systemName: "flame.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.primaryGradient)
            }
            .frame(width: 18, height: 18)

            HStack(spacing: 0) {
                Text("Open")
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                Text("BurnBar")
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }
            .font(.system(size: 12.5, weight: .semibold, design: .rounded))
            .tracking(0.2)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("OpenBurnBar")
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .animation(DesignSystem.Animation.hover, value: hover)
    }
}

private struct BurnRailViewModeSegmented: View {
    @Binding var viewMode: BurnRailViewMode

    var body: some View {
        HStack(spacing: 4) {
            ForEach(BurnRailViewMode.allCases) { mode in
                item(mode)
            }
        }
        .padding(2)
        .background(segmentedBackground)
    }

    private var segmentedBackground: some View {
        Group {
            if #available(macOS 26.0, *) {
                Capsule(style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.35))
            } else {
                Capsule(style: .continuous)
                    .fill(DesignSystem.Colors.surface.opacity(0.5))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
                    )
            }
        }
    }

    private func item(_ mode: BurnRailViewMode) -> some View {
        let active = viewMode == mode
        return Button {
            withAnimation(DesignSystem.Animation.snappy) { viewMode = mode }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: mode.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(
                        active
                            ? AnyShapeStyle(DesignSystem.Colors.primaryGradient)
                            : AnyShapeStyle(DesignSystem.Colors.textSecondary.opacity(0.8))
                    )
                Text(mode.label)
                    .font(.system(size: 11.5, weight: active ? .semibold : .medium, design: .rounded))
                    .foregroundStyle(
                        active
                            ? DesignSystem.Colors.textPrimary
                            : DesignSystem.Colors.textSecondary.opacity(0.9)
                    )
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4.5)
            .background(
                Capsule(style: .continuous)
                    .fill(active
                          ? AnyShapeStyle(DesignSystem.Colors.primaryGradient.opacity(0.18))
                          : AnyShapeStyle(Color.clear))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(active
                            ? DesignSystem.Colors.ember.opacity(0.4)
                            : Color.clear, lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(active ? mode.label : "Switch to \(mode.label)")
    }
}

// MARK: - Section: Search Omnibar
//
// Beautiful inline search field. Resting state shows the magnifying glass +
// placeholder + ⌘K hint chip. Focused state lifts with an ember-tinted glow,
// reveals a scope row + recent-search popover, and routes ⌘K from anywhere
// in the window to focus the field.

struct BurnRailSearchOmnibar: View {
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    let onSubmit: (String) -> Void
    var onScopeChange: ((BurnRailSearchScope) -> Void)? = nil

    @State private var hover = false
    @State private var scope: BurnRailSearchScope = .all
    @State private var showSuggestions = false
    @AppStorage("burnRailSearch.recents.v1") private var recentsJSON: String = "[]"

    private static let recentsLimit = 6

    var body: some View {
        HStack(spacing: 8) {
            scopeBadge

            TextField("", text: $text, prompt: Text("Search sessions, projects, models…")
                .foregroundColor(DesignSystem.Colors.textMuted))
                .textFieldStyle(.plain)
                .font(.system(size: 12.5, weight: .regular, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textPrimary)
                .focused($focused)
                .submitLabel(.search)
                .onSubmit(submit)

            if !text.isEmpty {
                Button {
                    text = ""
                    focused = true
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11, weight: .regular))
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .buttonStyle(.plain)
                .transition(.scale.combined(with: .opacity))
                .help("Clear")
            }

            if !focused && text.isEmpty {
                ShortcutChip(keys: ["⌘", "K"])
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(omnibarSurface)
        .clipShape(Capsule(style: .continuous))
        .overlay(omnibarStroke)
        .shadow(
            color: focused ? DesignSystem.Colors.ember.opacity(0.22) : .clear,
            radius: focused ? 10 : 0, y: focused ? 2 : 0
        )
        .animation(DesignSystem.Animation.gentle, value: focused)
        .animation(DesignSystem.Animation.snappy, value: text.isEmpty)
        .animation(DesignSystem.Animation.snappy, value: scope)
        .onHover { hover = $0 }
        .contentShape(Capsule(style: .continuous))
        .onTapGesture { focused = true }
        .background(globalShortcut)
        .help("Search conversations (⌘K)")
        .onChange(of: focused) { _, isFocused in
            showSuggestions = isFocused
        }
        .popover(isPresented: $showSuggestions, attachmentAnchor: .rect(.bounds), arrowEdge: .bottom) {
            BurnRailSearchSuggestionsPopover(
                scope: $scope,
                recents: recents,
                onPickRecent: { query in
                    text = query
                    submit()
                },
                onClearRecents: { writeRecents([]) },
                onScopeChange: { newScope in
                    onScopeChange?(newScope)
                }
            )
            .frame(minWidth: 340)
        }
    }

    // MARK: Scope badge

    @ViewBuilder
    private var scopeBadge: some View {
        if scope == .all {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(
                    focused
                        ? AnyShapeStyle(DesignSystem.Colors.primaryGradient)
                        : AnyShapeStyle(DesignSystem.Colors.textSecondary)
                )
                .animation(DesignSystem.Animation.snappy, value: focused)
        } else {
            Button {
                scope = .all
                onScopeChange?(.all)
                focused = true
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: scope.systemImage)
                        .font(.system(size: 9.5, weight: .semibold))
                    Text(scope.label)
                        .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .opacity(0.7)
                }
                .foregroundStyle(DesignSystem.Colors.ember)
                .padding(.horizontal, 7)
                .padding(.vertical, 2.5)
                .background(
                    Capsule(style: .continuous)
                        .fill(DesignSystem.Colors.ember.opacity(0.14))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(DesignSystem.Colors.ember.opacity(0.35), lineWidth: 0.5)
                )
                .contentShape(Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
            .transition(.scale.combined(with: .opacity))
            .help("Remove scope filter")
        }
    }

    // MARK: Surface

    @ViewBuilder
    private var omnibarSurface: some View {
        if #available(macOS 26.0, *) {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .opacity(focused ? 1.0 : (hover ? 0.85 : 0.7))
        } else {
            Capsule(style: .continuous)
                .fill(
                    focused
                        ? DesignSystem.Colors.surfaceElevated.opacity(0.88)
                        : DesignSystem.Colors.surface.opacity(hover ? 0.7 : 0.5)
                )
        }
    }

    private var omnibarStroke: some View {
        Capsule(style: .continuous)
            .strokeBorder(
                focused
                    ? AnyShapeStyle(DesignSystem.Colors.primaryGradient.opacity(0.55))
                    : AnyShapeStyle(DesignSystem.Colors.border.opacity(0.45)),
                lineWidth: focused ? 1.0 : 0.5
            )
    }

    // MARK: Cmd-K global shortcut
    //
    // Invisible button outside the field's event chain so the shortcut works
    // regardless of focus.
    private var globalShortcut: some View {
        Button(action: { focused = true }) { EmptyView() }
            .buttonStyle(.plain)
            .keyboardShortcut("k", modifiers: .command)
            .opacity(0)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
    }

    // MARK: Submission + recents

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        pushRecent(trimmed)
        onSubmit(scope.qualify(trimmed))
    }

    private var recents: [String] {
        guard let data = recentsJSON.data(using: .utf8),
              let list = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return list
    }

    private func pushRecent(_ query: String) {
        var next = recents.filter { $0.caseInsensitiveCompare(query) != .orderedSame }
        next.insert(query, at: 0)
        if next.count > Self.recentsLimit { next.removeLast(next.count - Self.recentsLimit) }
        writeRecents(next)
    }

    private func writeRecents(_ list: [String]) {
        if let data = try? JSONEncoder().encode(list),
           let json = String(data: data, encoding: .utf8) {
            recentsJSON = json
        }
    }
}

// MARK: - Search suggestions popover

private struct BurnRailSearchSuggestionsPopover: View {
    @Binding var scope: BurnRailSearchScope
    let recents: [String]
    let onPickRecent: (String) -> Void
    let onClearRecents: () -> Void
    let onScopeChange: (BurnRailSearchScope) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Scopes row
            VStack(alignment: .leading, spacing: 6) {
                Text("Scope")
                    .font(.system(size: 9.5, weight: .bold, design: .rounded))
                    .tracking(1.0)
                    .foregroundStyle(DesignSystem.Colors.textMuted)

                HStack(spacing: 6) {
                    ForEach(BurnRailSearchScope.allCases) { s in
                        scopeChip(s)
                    }
                }
            }

            Divider().opacity(0.4)

            // Recents
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Recent")
                        .font(.system(size: 9.5, weight: .bold, design: .rounded))
                        .tracking(1.0)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Spacer()
                    if !recents.isEmpty {
                        Button("Clear", action: onClearRecents)
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .buttonStyle(.plain)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }

                if recents.isEmpty {
                    HStack(spacing: 6) {
                        Image(systemName: "clock")
                            .font(.system(size: 10))
                        Text("Your recent searches will appear here.")
                            .font(.system(size: 11.5, design: .rounded))
                    }
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(.vertical, 4)
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(recents, id: \.self) { query in
                            Button {
                                onPickRecent(query)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: "clock.arrow.circlepath")
                                        .font(.system(size: 10.5, weight: .semibold))
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                    Text(query)
                                        .font(.system(size: 12, weight: .regular, design: .rounded))
                                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                    Spacer(minLength: 6)
                                    Image(systemName: "arrow.up.left")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(DesignSystem.Colors.textMuted.opacity(0.7))
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .background(
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .fill(Color.clear)
                            )
                        }
                    }
                }
            }
        }
        .padding(12)
    }

    private func scopeChip(_ s: BurnRailSearchScope) -> some View {
        let active = scope == s
        return Button {
            withAnimation(DesignSystem.Animation.snappy) {
                scope = s
                onScopeChange(s)
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: s.systemImage)
                    .font(.system(size: 10, weight: .semibold))
                Text(s.label)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            .foregroundStyle(active ? DesignSystem.Colors.ember : DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(active
                          ? DesignSystem.Colors.ember.opacity(0.14)
                          : DesignSystem.Colors.surface.opacity(0.55))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(active
                            ? DesignSystem.Colors.ember.opacity(0.35)
                            : DesignSystem.Colors.border.opacity(0.45),
                            lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(active ? "Active scope" : "Scope to \(s.label)")
    }
}

private struct ShortcutChip: View {
    let keys: [String]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(keys, id: \.self) { k in
                Text(k)
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .frame(minWidth: 14, minHeight: 14)
                    .padding(.horizontal, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(DesignSystem.Colors.surface.opacity(0.9))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .stroke(DesignSystem.Colors.border.opacity(0.6), lineWidth: 0.5)
                    )
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Section: Workspace Context
//
// Lives in the principal toolbar slot. Anchors the rail in *where you are* and
// *what's happening right now* — a route name + state caption that doubles as
// editorial context for the current tab.

struct BurnRailWorkspaceContextPill: View {
    let routeName: String
    let stateCaption: String
    let helpText: String

    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: "circle.dotted")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.ember.opacity(0.85))
                Text(routeName.uppercased())
                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                    .tracking(0.9)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
            }

            Text(stateCaption)
                .font(.system(size: 11, weight: .medium, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)

            mercuryHairline
                .frame(height: 0.75)
                .padding(.top, 1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(pillBackground)
        .overlay(
            Capsule(style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(hover ? 0.7 : 0.45), lineWidth: 0.5)
        )
        .clipShape(Capsule(style: .continuous))
        .help(helpText)
        .onHover { hover = $0 }
        .animation(DesignSystem.Animation.hover, value: hover)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Workspace \(routeName)")
        .accessibilityValue(stateCaption)
    }

    @ViewBuilder
    private var pillBackground: some View {
        if #available(macOS 26.0, *) {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .opacity(hover ? 0.95 : 0.78)
        } else {
            Capsule(style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(hover ? 0.78 : 0.55))
        }
    }

    private var mercuryHairline: some View {
        LinearGradient(
            colors: [
                DesignSystem.Colors.hermesMercury.opacity(0.0),
                DesignSystem.Colors.hermesMercury.opacity(0.5),
                DesignSystem.Colors.hermesAureate.opacity(0.65),
                DesignSystem.Colors.hermesMercury.opacity(0.5),
                DesignSystem.Colors.hermesMercury.opacity(0.0)
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

// MARK: - Time range menu chip
//
// Public counterpart of the private menu chip in `DashboardToolbar.swift` —
// the live toolbar in `DashboardToolbarContent.swift` reaches for this so the
// macOS-toolbar `ToolbarItem` can render a calendar pill with the same visual
// language as the rest of the BurnRail primitives.

struct BurnRailTimeRangeMenuChip: View {
    @Binding var selected: TimeRange
    @State private var hover = false

    var body: some View {
        Menu {
            ForEach(TimeRange.allCases) { range in
                Button {
                    selected = range
                } label: {
                    if selected == range {
                        Label(range.displayName, systemImage: "checkmark")
                    } else {
                        Text(range.displayName)
                    }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "calendar")
                    .font(.system(size: 10, weight: .semibold))
                Text(selected.displayName)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .opacity(0.7)
            }
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(hover
                          ? DesignSystem.Colors.ember.opacity(0.08)
                          : DesignSystem.Colors.surface.opacity(0.35))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.55), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { hover = $0 }
        .animation(DesignSystem.Animation.hover, value: hover)
        .help("Filter time range — currently \(selected.displayName)")
    }
}

#if DEBUG
#Preview("Workspace context pill — Quota near edge") {
    BurnRailWorkspaceContextPill(
        routeName: "Quota",
        stateCaption: "5 plans · 2 near edge · next reset in 3 hours",
        helpText: "Subscription Vault — every connected provider's quota."
    )
    .padding(20)
    .background(DesignSystem.Colors.background)
}

#Preview("Workspace context pill — Overview") {
    BurnRailWorkspaceContextPill(
        routeName: "Overview",
        stateCaption: "12 providers · 1,492 sessions in window",
        helpText: "All providers + models in the current time window."
    )
    .padding(20)
    .background(DesignSystem.Colors.background)
}
#endif

// MARK: - Section: Context (range + unit)

struct BurnRailContextSection: View {
    @Binding var unit: BurnRailUnit
    let rangeLabel: String
    var onRangeTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            BurnRailFilterChip(
                symbol: "calendar",
                label: rangeLabel,
                trailing: "chevron.down",
                action: onRangeTap
            )
            BurnRailUnitToggle(unit: $unit)
        }
    }
}

private struct BurnRailFilterChip: View {
    let symbol: String
    let label: String
    let trailing: String?
    let action: () -> Void
    @State private var hover = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(label)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 8, weight: .bold))
                        .opacity(0.7)
                }
            }
            .foregroundStyle(DesignSystem.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule(style: .continuous)
                    .fill(hover
                          ? DesignSystem.Colors.ember.opacity(0.08)
                          : DesignSystem.Colors.surface.opacity(0.35))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(DesignSystem.Colors.border.opacity(0.55), lineWidth: 0.5)
            )
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { hover = $0 }
        .animation(DesignSystem.Animation.hover, value: hover)
    }
}

struct BurnRailUnitToggle: View {
    @Binding var unit: BurnRailUnit

    var body: some View {
        HStack(spacing: 0) {
            ForEach(BurnRailUnit.allCases) { u in
                segment(u)
            }
        }
        .padding(2)
        .background(
            Capsule(style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.45))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.5), lineWidth: 0.5)
        )
    }

    private func segment(_ u: BurnRailUnit) -> some View {
        let active = unit == u
        return Button {
            withAnimation(DesignSystem.Animation.snappy) { unit = u }
        } label: {
            Image(systemName: u.glyph)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(
                    active
                        ? DesignSystem.Colors.textPrimary
                        : DesignSystem.Colors.textMuted
                )
                .frame(width: 24, height: 18)
                .background(
                    Capsule(style: .continuous)
                        .fill(active
                              ? AnyShapeStyle(DesignSystem.Colors.primaryGradient.opacity(0.18))
                              : AnyShapeStyle(Color.clear))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(active
                                ? DesignSystem.Colors.ember.opacity(0.35)
                                : Color.clear, lineWidth: 0.5)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(u.label)
    }
}

// MARK: - Section: Telemetry hero

struct BurnRailTelemetryHero: View {
    let telemetry: BurnRailTelemetry

    var body: some View {
        HStack(spacing: 12) {
            BurnRailLivePulseDot(isLive: telemetry.isLive)

            VStack(alignment: .leading, spacing: 1) {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text("BURN")
                        .font(.system(size: 9, weight: .bold, design: .rounded))
                        .tracking(1.3)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    if let delta = telemetry.deltaPercent {
                        BurnRailDeltaChip(percent: delta)
                    }
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(telemetry.headlineValue)
                        .font(.system(size: 17, weight: .bold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                        .contentTransition(.numericText())
                        .animation(DesignSystem.Animation.gentle, value: telemetry.headlineValue)
                    if let suffix = telemetry.headlineSuffix {
                        Text(suffix)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                            .baselineOffset(1)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("BURN")
            .accessibilityValue(telemetry.headlineValue + (telemetry.headlineSuffix.map { " " + $0 } ?? ""))

            BurnRailSparkline(samples: telemetry.sparkline)
                .frame(width: 64, height: 22)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(heroSurface)
        .overlay(
            Capsule(style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.45), lineWidth: 0.5)
        )
        .clipShape(Capsule(style: .continuous))
    }

    @ViewBuilder
    private var heroSurface: some View {
        if #available(macOS 26.0, *) {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .opacity(0.7)
        } else {
            Capsule(style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.55))
        }
    }
}

// MARK: - Section: Actions (import / recount / settings)

struct BurnRailActionsSection: View {
    let isScanning: Bool
    var onImport: () -> Void = {}
    var onRecount: () -> Void = {}
    var onSettings: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            BurnRailGhostIconButton(
                symbol: isScanning ? "arrow.triangle.2.circlepath" : "tray.and.arrow.down",
                help: isScanning ? "Importing sessions…" : "Import sessions from logs",
                spinning: isScanning,
                action: onImport
            )
            BurnRailCapsuleDivider()
            BurnRailGhostIconButton(
                symbol: "arrow.counterclockwise",
                help: "Recount totals",
                action: onRecount
            )
            BurnRailCapsuleDivider()
            BurnRailGhostIconButton(
                symbol: "gearshape",
                help: "Settings",
                action: onSettings
            )
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .background(actionsSurface)
        .overlay(
            Capsule(style: .continuous)
                .stroke(DesignSystem.Colors.border.opacity(0.4), lineWidth: 0.5)
        )
        .clipShape(Capsule(style: .continuous))
    }

    @ViewBuilder
    private var actionsSurface: some View {
        if #available(macOS 26.0, *) {
            Capsule(style: .continuous)
                .fill(.regularMaterial)
                .opacity(0.65)
        } else {
            Capsule(style: .continuous)
                .fill(DesignSystem.Colors.surface.opacity(0.4))
        }
    }
}

// MARK: - Primitives

private struct BurnRailDivider: View {
    var body: some View {
        Rectangle()
            .fill(DesignSystem.Colors.border.opacity(0.5))
            .frame(width: 1, height: 16)
            .opacity(0.8)
    }
}

private struct BurnRailLivePulseDot: View {
    let isLive: Bool
    @State private var pulse = false

    var body: some View {
        ZStack {
            Circle()
                .fill(DesignSystem.Colors.ember.opacity(0.35))
                .frame(width: 18, height: 18)
                .scaleEffect(pulse ? 1.0 : 0.5)
                .opacity(pulse ? 0 : 0.7)
            Circle()
                .fill(isLive ? DesignSystem.Colors.ember : DesignSystem.Colors.textMuted)
                .frame(width: 7, height: 7)
                .shadow(color: DesignSystem.Colors.ember.opacity(isLive ? 0.65 : 0),
                        radius: 4, y: 0)
        }
        .frame(width: 18, height: 18)
        .onAppear {
            guard isLive else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

private struct BurnRailDeltaChip: View {
    let percent: Double

    var body: some View {
        let isUp = percent >= 0
        HStack(spacing: 2) {
            Image(systemName: isUp ? "arrowtriangle.up.fill" : "arrowtriangle.down.fill")
                .font(.system(size: 7, weight: .bold))
            Text(String(format: "%.1f%%", abs(percent)))
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .monospacedDigit()
        }
        .foregroundStyle(isUp ? DesignSystem.Colors.amber : DesignSystem.Colors.success)
        .padding(.horizontal, 5)
        .padding(.vertical, 1.5)
        .background(
            Capsule().fill((isUp ? DesignSystem.Colors.amber : DesignSystem.Colors.success)
                .opacity(0.12))
        )
    }
}

private struct BurnRailSparkline: View {
    let samples: [Double]

    var body: some View {
        GeometryReader { geo in
            ZStack {
                sparkPath(in: geo.size, closed: true)
                    .fill(
                        LinearGradient(
                            colors: [
                                DesignSystem.Colors.ember.opacity(0.35),
                                DesignSystem.Colors.ember.opacity(0.0)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
                sparkPath(in: geo.size, closed: false)
                    .stroke(
                        DesignSystem.Colors.primaryGradient,
                        style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin: .round)
                    )
                if let last = samples.last {
                    let x = geo.size.width
                    let y = geo.size.height * (1 - CGFloat(clamp(last)))
                    Circle()
                        .fill(DesignSystem.Colors.ember)
                        .frame(width: 3, height: 3)
                        .position(x: x - 1.5, y: y)
                        .shadow(color: DesignSystem.Colors.ember.opacity(0.8), radius: 2)
                }
            }
        }
    }

    private func sparkPath(in size: CGSize, closed: Bool) -> Path {
        guard samples.count > 1 else { return Path() }
        let step = size.width / CGFloat(samples.count - 1)
        var path = Path()
        for (i, v) in samples.enumerated() {
            let x = CGFloat(i) * step
            let y = size.height * (1 - CGFloat(clamp(v)))
            if i == 0 { path.move(to: CGPoint(x: x, y: y)) }
            else { path.addLine(to: CGPoint(x: x, y: y)) }
        }
        if closed {
            path.addLine(to: CGPoint(x: size.width, y: size.height))
            path.addLine(to: CGPoint(x: 0, y: size.height))
            path.closeSubpath()
        }
        return path
    }

    private func clamp(_ v: Double) -> Double { min(max(v, 0), 1) }
}

private struct BurnRailGhostIconButton: View {
    let symbol: String
    let help: String
    var spinning: Bool = false
    let action: () -> Void
    @State private var hover = false
    @State private var spin = false
    @State private var pressTrigger = 0

    var body: some View {
        Button {
            pressTrigger &+= 1
            action()
        } label: {
            symbolView
                .frame(width: 26, height: 22)
                .background(
                    Capsule(style: .continuous)
                        .fill(hover ? DesignSystem.Colors.ember.opacity(0.10) : Color.clear)
                )
                .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hover = $0 }
        .animation(DesignSystem.Animation.hover, value: hover)
        .onChange(of: spinning) { _, newValue in
            if newValue {
                withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                    spin = true
                }
            } else {
                spin = false
            }
        }
    }

    @ViewBuilder
    private var symbolView: some View {
        if #available(macOS 14.0, *) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    hover
                        ? DesignSystem.Colors.textPrimary
                        : DesignSystem.Colors.textSecondary
                )
                .rotationEffect(.degrees(spinning && spin ? 360 : 0))
                .symbolEffect(.bounce, value: pressTrigger)
        } else {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(
                    hover
                        ? DesignSystem.Colors.textPrimary
                        : DesignSystem.Colors.textSecondary
                )
                .rotationEffect(.degrees(spinning && spin ? 360 : 0))
        }
    }
}

private struct BurnRailCapsuleDivider: View {
    var body: some View {
        Rectangle()
            .fill(DesignSystem.Colors.border.opacity(0.35))
            .frame(width: 0.5, height: 14)
    }
}

// MARK: - Sparkline data helper

enum BurnRailSparklineBuilder {
    /// Bucket usage rows into N normalized samples (0...1) across the given range.
    /// If `range` is nil (All Time), uses the min/max of the rows themselves.
    static func buildSamples(
        from usages: [TokenUsage],
        range: ClosedRange<Date>?,
        bucketCount: Int = 24
    ) -> [Double] {
        guard !usages.isEmpty else { return Array(repeating: 0, count: bucketCount) }
        let lower: Date
        let upper: Date
        if let r = range {
            lower = r.lowerBound
            upper = r.upperBound
        } else {
            let times = usages.map(\.startTime)
            lower = times.min() ?? Date()
            upper = times.max() ?? Date()
        }
        let span = max(upper.timeIntervalSince(lower), 1)
        var buckets = Array(repeating: 0.0, count: bucketCount)
        for u in usages {
            let t = u.startTime
            guard t >= lower, t <= upper else { continue }
            let frac = t.timeIntervalSince(lower) / span
            var idx = Int(frac * Double(bucketCount))
            if idx >= bucketCount { idx = bucketCount - 1 }
            if idx < 0 { idx = 0 }
            buckets[idx] += Double(u.totalTokens)
        }
        let maxVal = buckets.max() ?? 0
        guard maxVal > 0 else { return buckets.map { _ in 0 } }
        return buckets.map { $0 / maxVal }
    }
}

// MARK: - Preview

#if DEBUG
private struct BurnBarTopRailPreviewHost: View {
    @State private var viewMode: BurnRailViewMode = .agents
    @State private var unit: BurnRailUnit = .tokens
    @State private var search: String = ""
    @State private var range: String = "Today"
    @State private var scanning: Bool = false
    @State private var headline: String = "1.79"

    private var sparkSamples: [Double] {
        [0.12, 0.18, 0.14, 0.22, 0.31, 0.28, 0.41, 0.38,
         0.52, 0.49, 0.61, 0.58, 0.72, 0.66, 0.78, 0.74,
         0.81, 0.79, 0.86, 0.83, 0.91, 0.88, 0.95, 0.97]
    }

    var body: some View {
        VStack(spacing: 0) {
            BurnBarTopRail(
                viewMode: $viewMode,
                unit: $unit,
                searchText: $search,
                rangeLabel: range,
                canGoBack: true,
                isScanning: scanning,
                telemetry: BurnRailTelemetry(
                    headlineValue: "\(headline)B",
                    headlineSuffix: "tok",
                    deltaPercent: 4.2,
                    sparkline: sparkSamples,
                    isLive: true
                ),
                onBack: {},
                onRangeTap: { range = (range == "Today") ? "Last 7d" : "Today" },
                onSearchSubmit: { _ in },
                onImport: { scanning.toggle() },
                onRecount: { headline = (headline == "1.79") ? "1.83" : "1.79" },
                onSettings: {}
            )
            ZStack {
                DesignSystem.Colors.background.ignoresSafeArea()
                Text("Dashboard content").foregroundStyle(.secondary)
            }
            .frame(height: 240)
        }
        .frame(width: 1100)
    }
}

#Preview("BurnBar Top Rail — Dark") {
    BurnBarTopRailPreviewHost()
        .preferredColorScheme(.dark)
}

#Preview("BurnBar Top Rail — Light") {
    BurnBarTopRailPreviewHost()
        .preferredColorScheme(.light)
}
#endif
