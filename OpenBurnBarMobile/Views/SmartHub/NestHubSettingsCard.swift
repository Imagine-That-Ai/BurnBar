import OpenBurnBarCore
import SwiftUI
import UIKit

// MARK: - Nest Hub Settings Card (iOS / iPadOS)
//
// Brings the Google Nest Hub card to parity with the Pixel Clock card
// on mobile and exposes the Hub-only features (theme, background mode,
// audible cue, identify-on-refresh) using `MobileTheme` tokens.
//
// All edits forward through `SmartHubStore`, which writes to the same
// Firestore doc the Mac listens for — so the user can drive a Hub
// connected to their Mac from the iPhone.

struct NestHubSettingsCard: View {
    @Bindable var smartHubStore: SmartHubStore
    @State private var model: SmartHubDisplaySettingsModel
    @State private var copyMessage: String?

    init(
        smartHubStore: SmartHubStore,
        model: SmartHubDisplaySettingsModel? = nil
    ) {
        self.smartHubStore = smartHubStore
        if let model {
            _model = State(initialValue: model)
        } else {
            let adapter = MobileSmartHubDisplayOperationsAdapter(store: smartHubStore)
            _model = State(initialValue: SmartHubDisplaySettingsModel(
                enabled: smartHubStore.config?.enabled ?? false,
                initialConfig: smartHubStore.displayConfig,
                operations: adapter
            ))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            header

            if model.enabled {
                preview
                operationButtons
                bridgeStatus
                pickers
                periodAndCadence
                brightnessAndScroll
                toggles
                providerChips
                voiceRoutineHelper
            }
        }
        // Without an explicit maxWidth the VStack grows to its widest
        // child. On iPhone the action buttons row was ~440pt — wider
        // than the form row, so the whole card centred inside the row
        // and hung off both edges. Pinning to the parent width keeps
        // every section anchored to the leading edge.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(MobileTheme.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(MobileTheme.surfaceElevated)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .stroke(MobileTheme.borderSubtle, lineWidth: 0.5)
        )
        .onAppear {
            model.apply(
                enabled: smartHubStore.config?.enabled ?? false,
                config: smartHubStore.displayConfig
            )
        }
        .onChange(of: smartHubStore.config?.displayConfig) { _, newValue in
            guard let newValue, newValue != model.config else { return }
            model.apply(enabled: smartHubStore.config?.enabled ?? false, config: newValue)
        }
        .onChange(of: smartHubStore.config?.enabled) { _, newValue in
            guard let newValue, newValue != model.enabled else { return }
            model.apply(enabled: newValue, config: smartHubStore.displayConfig)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: MobileTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MobileTheme.whimsy.opacity(0.18))
                Image(systemName: "display")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MobileTheme.whimsy)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("Nest Hub quota display")
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                if let host = smartHubStore.config?.sourceDeviceName {
                    Text(smartHubStore.hasLiveMacBridge ? "Bridge running on \(host)" : "Bridge offline on \(host)")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(smartHubStore.hasLiveMacBridge ? MobileTheme.Colors.textMuted : MobileTheme.Colors.warning)
                } else {
                    Text("DashCast-compatible smart display")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }

            Spacer(minLength: MobileTheme.Spacing.sm)

            Toggle(
                "",
                isOn: Binding(
                    get: { model.enabled },
                    set: { model.toggleEnabled($0) }
                )
            )
            .labelsHidden()
            .tint(MobileTheme.whimsy)
            .accessibilityLabel("Enable Nest Hub quota display")
        }
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preview")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            NestHubMiniPreview(config: model.config)
                .frame(maxWidth: .infinity)
                .padding(.vertical, MobileTheme.Spacing.xs)
        }
    }

    // MARK: - Operation buttons

    private var operationButtons: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
            // Flow layout so the six action chips wrap onto multiple
            // rows on narrow iPhones instead of overflowing the form row.
            // On iPad they still fit on one line.
            NestHubFlowLayout(
                horizontalSpacing: MobileTheme.Spacing.sm,
                verticalSpacing: MobileTheme.Spacing.xs
            ) {
                operationButton(.repair, prominent: true)
                operationButton(.test, prominent: false)
                operationButton(.identify, prominent: false)
                operationButton(.refresh, prominent: false)
                operationButton(.open, prominent: false)
                operationButton(.stop, prominent: false)
            }
            feedbackBadge
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .disabled(model.isBusy || !smartHubStore.hasLiveMacBridge)
    }

    private func operationButton(
        _ kind: SmartHubDisplayOperationKind,
        prominent: Bool
    ) -> some View {
        let isInflight = model.inflightOperation == kind
        return Button {
            Task { await dispatch(kind) }
        } label: {
            HStack(spacing: 6) {
                if isInflight {
                    ProgressView().scaleEffect(0.7)
                } else {
                    Image(systemName: kind.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                }
                Text(isInflight ? kind.inFlightLabel : kind.displayName)
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(prominent ? MobileTheme.whimsy : MobileTheme.surface)
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(prominent ? Color.clear : MobileTheme.border, lineWidth: 0.5)
            )
            .foregroundStyle(prominent
                ? Color.white
                : MobileTheme.Colors.textPrimary
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(kind.displayName)
    }

    private var feedbackBadge: some View {
        Group {
            if let failure = model.operationState.failureMessage {
                Label(failure, systemImage: "exclamationmark.triangle.fill")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.error)
                    .lineLimit(2)
                    .multilineTextAlignment(.trailing)
            } else if case .succeeded(let kind, _) = model.operationState {
                Label("\(kind.displayName) ok", systemImage: "checkmark.circle.fill")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.success)
            }
        }
    }

    private var bridgeStatus: some View {
        HStack(spacing: MobileTheme.Spacing.sm) {
            Image(systemName: model.bridgeStatusSymbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(bridgeColor)
            Text(smartHubStore.hasLiveMacBridge ? model.bridgeStatusMessage : smartHubStore.bridgeFreshnessMessage)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle((model.bridgeStatusIsWarning || !smartHubStore.hasLiveMacBridge)
                    ? MobileTheme.Colors.warning
                    : MobileTheme.Colors.textSecondary
                )
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, MobileTheme.Spacing.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(bridgeColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .stroke(bridgeColor.opacity(0.4), lineWidth: 0.5)
        )
    }

    private var bridgeColor: Color {
        if !smartHubStore.hasLiveMacBridge { return MobileTheme.Colors.warning }
        if model.bridgeStatusIsWarning { return MobileTheme.Colors.warning }
        switch model.bridgeStatus {
        case .bound:          return MobileTheme.Colors.success
        case .waitingForData: return MobileTheme.whimsy
        default:              return MobileTheme.Colors.textMuted
        }
    }

    // MARK: - Pickers

    private var pickers: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Layout")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Picker(
                    "Layout",
                    selection: Binding(
                        get: { model.config.layout },
                        set: { model.updateLayout($0) }
                    )
                ) {
                    ForEach(SmartHubDisplayLayout.allCases, id: \.self) { layout in
                        Label(layout.displayName, systemImage: layout.iconName).tag(layout)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Background mode")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Picker(
                    "Background mode",
                    selection: Binding(
                        get: { model.config.background },
                        set: { model.updateBackground($0) }
                    )
                ) {
                    ForEach(SmartHubDisplayBackground.allCases, id: \.self) { background in
                        Label(background.displayName, systemImage: background.iconName).tag(background)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Palette")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                HStack(spacing: 8) {
                    paletteSwatch(for: model.config.palette)
                    Picker(
                        "Palette",
                        selection: Binding(
                            get: { model.config.palette },
                            set: { model.updatePalette($0) }
                        )
                    ) {
                        ForEach(SmartHubDisplayPalette.allCases, id: \.self) { palette in
                            Text(palette.displayName).tag(palette)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Theme")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Picker(
                    "Theme",
                    selection: Binding(
                        get: { model.config.theme },
                        set: { model.updateTheme($0) }
                    )
                ) {
                    ForEach(SmartHubDisplayTheme.allCases, id: \.self) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    // MARK: - Period + cadence

    private var periodAndCadence: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Time period")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Picker(
                    "Time period",
                    selection: Binding<SmartHubTimePeriod>(
                        get: { smartHubStore.config?.timePeriod ?? .rolling5h },
                        set: { newValue in
                            Task { await smartHubStore.updateTimePeriod(newValue) }
                        }
                    )
                ) {
                    ForEach(SmartHubTimePeriod.allCases, id: \.self) { period in
                        Text(period.shortLabel).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Refresh cadence")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Picker(
                    "Refresh cadence",
                    selection: Binding(
                        get: { model.config.clampedRefreshCadence },
                        set: { model.updateRefreshCadence($0) }
                    )
                ) {
                    Text("Every 5s").tag(5)
                    Text("Every 10s").tag(10)
                    Text("Every 30s").tag(30)
                    Text("Every minute").tag(60)
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    // MARK: - Brightness + scroll

    private var brightnessAndScroll: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Brightness")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                    Spacer()
                    Text("\(Int(model.config.clampedBrightness * 100))%")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Slider(
                    value: Binding(
                        get: { model.config.clampedBrightness },
                        set: { model.updateBrightness($0) }
                    ),
                    in: 0.2...1.0
                ) {
                    Text("Brightness")
                } minimumValueLabel: {
                    Image(systemName: "sun.min.fill")
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                } maximumValueLabel: {
                    Image(systemName: "sun.max.fill")
                        .foregroundStyle(MobileTheme.amber)
                }
                .tint(MobileTheme.whimsy)
                .accessibilityLabel("Brightness")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Carousel page duration")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                    Spacer()
                    Text("\(model.config.clampedScrollSpeed)s")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.config.clampedScrollSpeed) },
                        set: { model.updateScrollSpeed(Int($0)) }
                    ),
                    in: 3...30,
                    step: 1
                ) {
                    Text("Page duration")
                } minimumValueLabel: {
                    Image(systemName: "hare.fill")
                        .foregroundStyle(MobileTheme.whimsy)
                } maximumValueLabel: {
                    Image(systemName: "tortoise.fill")
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                .tint(MobileTheme.whimsy)
                .accessibilityLabel("Page duration")
            }
        }
    }

    // MARK: - Toggles

    private var toggles: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
            Toggle(
                isOn: Binding(
                    get: { model.config.audibleCue },
                    set: { model.updateAudibleCue($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Audible chime on refresh")
                        .font(MobileTheme.Typography.body)
                    Text("Plays a soft tone on the Hub each time fresh data arrives.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
            .tint(MobileTheme.whimsy)

            Toggle(
                isOn: Binding(
                    get: { model.config.identifyOnRefresh },
                    set: { model.updateIdentifyOnRefresh($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identify on refresh")
                        .font(MobileTheme.Typography.body)
                    Text("Pings the voice routine endpoint so Google can speak the latest totals.")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }
            .tint(MobileTheme.whimsy)
        }
    }

    // MARK: - Provider chips

    private var providerChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Providers to show")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Spacer()
                if model.hasExplicitProviderFilter {
                    Button("Reset to all") { model.resetProviderFilter() }
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.whimsy)
                }
            }

            let columns = [GridItem(.adaptive(minimum: 88), spacing: MobileTheme.Spacing.sm)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                ForEach(model.availableProviders, id: \.self) { provider in
                    chip(for: provider)
                }
            }
        }
    }

    private func chip(for provider: AgentProvider) -> some View {
        let isSelected = model.isProviderSelected(provider)
        let color = MobileTheme.Colors.primary(for: provider)
        return Button {
            model.toggleProvider(provider)
        } label: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(chipText(for: provider))
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(isSelected ? MobileTheme.Colors.textPrimary : MobileTheme.Colors.textSecondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected ? color.opacity(0.22) : MobileTheme.surface)
            )
            .overlay(
                Capsule()
                    .stroke(isSelected ? color.opacity(0.55) : MobileTheme.border, lineWidth: 0.7)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Toggle provider \(chipText(for: provider))")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func chipText(for provider: AgentProvider) -> String {
        switch provider {
        case .claudeCode: return "Claude"
        case .factory:    return "Factory"
        case .codex:      return "Codex"
        case .copilot:    return "Copilot"
        case .minimax:    return "MiniMax"
        case .zai:        return "Z.ai"
        case .cursor:     return "Cursor"
        case .warp:       return "Warp"
        case .ollama:     return "Ollama"
        case .kimi:       return "Kimi"
        default:          return provider.rawValue
        }
    }

    // MARK: - Voice routine helper

    private var voiceRoutineHelper: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
            Text("Voice routine deep-link")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            HStack(spacing: MobileTheme.Spacing.sm) {
                Text(curlSnippet)
                    .font(MobileTheme.Typography.monoTiny)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, MobileTheme.Spacing.sm)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                            .fill(MobileTheme.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                            .stroke(MobileTheme.border, lineWidth: 0.5)
                    )
                Button("Copy") {
                    UIPasteboard.general.string = curlSnippet
                    copyMessage = "Command copied."
                }
                .buttonStyle(.bordered)
            }
            if let copyMessage {
                Text(copyMessage)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.success)
            }
        }
    }

    private var curlSnippet: String {
        let url = smartHubStore.config?.voiceRefreshURL?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !url.isEmpty else {
            return "curl -X POST http://127.0.0.1:8787/voice-refresh"
        }
        return "curl -X POST \(url)"
    }

    @ViewBuilder
    private func paletteSwatch(for palette: SmartHubDisplayPalette) -> some View {
        if palette.isRainbow {
            Circle()
                .fill(
                    LinearGradient(
                        colors: SmartHubDisplayPalette.rainbowFlag.map { Color(hex: $0) },
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                )
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(MobileTheme.Colors.border.opacity(0.4), lineWidth: 0.5))
        } else {
            Circle()
                .fill(Color(hex: palette.primaryHex))
                .frame(width: 14, height: 14)
                .overlay(Circle().stroke(MobileTheme.Colors.border.opacity(0.4), lineWidth: 0.5))
        }
    }

    // MARK: - Dispatch

    private func dispatch(_ kind: SmartHubDisplayOperationKind) async {
        switch kind {
        case .test:     await model.test()
        case .identify: await model.identify()
        case .repair:   await model.repair()
        case .refresh:  await model.refresh()
        case .stop:     await model.stop()
        case .open:     await model.open()
        }
    }
}

// MARK: - Flow Layout
//
// Lays out children left-to-right, wrapping to a new row when the next
// child would exceed the proposed width. Used for the Nest Hub action
// chips so the row collapses gracefully on iPhone widths.

private struct NestHubFlowLayout: Layout {
    var horizontalSpacing: CGFloat
    var verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        let rows = layoutRows(maxWidth: maxWidth, subviews: subviews)
        let totalHeight = rows.reduce(into: CGFloat(0)) { acc, row in
            acc += row.height
        } + verticalSpacing * CGFloat(max(0, rows.count - 1))
        let widestRow = rows.map(\.width).max() ?? 0
        return CGSize(
            width: maxWidth.isFinite ? min(widestRow, maxWidth) : widestRow,
            height: totalHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout Void
    ) {
        let rows = layoutRows(maxWidth: bounds.width, subviews: subviews)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: size.width, height: size.height)
                )
                x += size.width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func layoutRows(maxWidth: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needsSpacing = !rows[rows.count - 1].indices.isEmpty
            let prospectiveWidth =
                rows[rows.count - 1].width
                + (needsSpacing ? horizontalSpacing : 0)
                + size.width
            if prospectiveWidth > maxWidth, needsSpacing {
                rows.append(Row())
            }
            var current = rows[rows.count - 1]
            if !current.indices.isEmpty {
                current.width += horizontalSpacing
            }
            current.indices.append(index)
            current.width += size.width
            current.height = max(current.height, size.height)
            rows[rows.count - 1] = current
        }
        return rows
    }
}
