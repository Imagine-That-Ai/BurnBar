import OpenBurnBarCore
import SwiftUI

#if canImport(AppKit)
import AppKit
#endif

// MARK: - Nest Hub Settings Card (macOS)
//
// Brings the Google Nest Hub control surface to feature parity with the
// ULANZI TC001 Pixel Clock card and exceeds it with Hub-only features
// (theme, background mode, voice routine builder, audible cue, "open in
// browser"). Replaces the legacy `ProviderQuotaSmartHubsSection` block.
//
// Keeps the legacy "Nest Hub quota display" header string so existing
// ViewInspector tests + Settings deep-links remain intact.

struct NestHubSettingsCard: View {
    @Bindable var settingsManager: SettingsManager
    @State private var model: SmartHubDisplaySettingsModel
    @State private var copyToastTask: Task<Void, Never>?

    private let runtimeContext: OpenBurnBarRuntimeContext?

    init(
        settingsManager: SettingsManager,
        runtimeContext: OpenBurnBarRuntimeContext? = nil,
        model: SmartHubDisplaySettingsModel? = nil
    ) {
        self.settingsManager = settingsManager
        self.runtimeContext = runtimeContext
        let resolvedModel: SmartHubDisplaySettingsModel
        if let model {
            resolvedModel = model
        } else {
            let adapter = MacSmartHubDisplayOperationsAdapter(
                settingsManager: settingsManager,
                controller: runtimeContext?.smartHubBridgeController,
                repairCoordinator: runtimeContext?.smartDisplayRepairCoordinator
            )
            resolvedModel = SmartHubDisplaySettingsModel(
                enabled: settingsManager.smartHubQuotaDisplayEnabled,
                initialConfig: settingsManager.smartHubDisplayConfig,
                operations: adapter,
                onEnabledChange: { [weak settingsManager] enabled in
                    settingsManager?.smartHubQuotaDisplayEnabled = enabled
                }
            )
        }
        _model = State(initialValue: resolvedModel)
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                header
                if model.enabled {
                    previewSection
                    operationButtons
                    bridgeStatusRow
                    urlFields
                    layoutAndBackgroundRow
                    paletteAndThemeRow
                    timePeriodAndCadenceRow
                    brightnessAndScrollRow
                    audibleAndIdentifyRow
                    providerFilterRow
                    voiceRoutineHelper
                    helpText
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .onAppear {
            model.apply(
                enabled: settingsManager.smartHubQuotaDisplayEnabled,
                config: settingsManager.smartHubDisplayConfig
            )
        }
        .onChange(of: settingsManager.smartHubDisplayConfig) { _, newValue in
            model.apply(enabled: settingsManager.smartHubQuotaDisplayEnabled, config: newValue)
        }
        .onChange(of: settingsManager.smartHubQuotaDisplayEnabled) { _, newValue in
            if model.enabled != newValue {
                model.apply(enabled: newValue, config: settingsManager.smartHubDisplayConfig)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.whimsy.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: "display")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.whimsy)
            }

            VStack(alignment: .leading, spacing: 3) {
                // NOTE: this exact string is asserted by the existing
                // `test_devicesSettingsExposeNestHubControls` regression.
                Text("Nest Hub quota display")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Expose the provider quota dashboard on a Google Nest Hub or any DashCast-compatible smart display.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DesignSystem.Spacing.md)

            Toggle(
                "",
                isOn: Binding(
                    get: { model.enabled },
                    set: { model.toggleEnabled($0) }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Enable Nest Hub quota display")
        }
    }

    // MARK: - Preview

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Live preview")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            HStack {
                Spacer(minLength: 0)
                NestHubMiniPreview(config: model.config)
                    .frame(maxWidth: 360)
                    .padding(.vertical, DesignSystem.Spacing.xs)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Operation buttons

    private var operationButtons: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                operationButton(.repair, style: .prominent)
                operationButton(.test, style: .regular)
                operationButton(.identify, style: .regular)
                operationButton(.refresh, style: .regular)
                operationButton(.open, style: .regular)
                operationButton(.stop, style: .regular)
            }
            .disabled(model.isBusy)

            if let failure = model.operationState.failureMessage {
                Label(failure, systemImage: "xmark.octagon")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .succeeded(let kind, _) = model.operationState {
                Text("\(kind.displayName) completed.")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.success)
            }
        }
    }

    private func operationButton(
        _ kind: SmartHubDisplayOperationKind,
        style: GlassButton.Style
    ) -> some View {
        let isInflight = model.inflightOperation == kind
        return GlassButton(
            title: isInflight ? kind.inFlightLabel : kind.displayName,
            icon: isInflight ? "ellipsis" : kind.symbolName,
            style: style
        ) {
            Task { await dispatch(kind) }
        }
        .accessibilityLabel(kind.displayName)
    }

    // MARK: - Bridge status

    private var bridgeStatusRow: some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            Image(systemName: model.bridgeStatusSymbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(bridgeStatusColor)
            Text(model.bridgeStatusMessage)
                .font(DesignSystem.Typography.tiny)
                .foregroundStyle(model.bridgeStatusIsWarning
                    ? DesignSystem.Colors.warning
                    : DesignSystem.Colors.textSecondary
                )
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(bridgeStatusColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .stroke(bridgeStatusColor.opacity(0.4), lineWidth: 0.5)
        )
    }

    private var bridgeStatusColor: Color {
        if model.bridgeStatusIsWarning { return DesignSystem.Colors.warning }
        switch model.bridgeStatus {
        case .bound:          return DesignSystem.Colors.success
        case .waitingForData: return DesignSystem.Colors.whimsy
        default:              return DesignSystem.Colors.textMuted
        }
    }

    // MARK: - URL fields

    private var urlFields: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            urlField(
                title: "Dashboard URL",
                text: $settingsManager.smartHubQuotaDashboardURL,
                placeholder: "http://127.0.0.1:8787/render.html"
            )
            urlField(
                title: "Refresh endpoint",
                text: $settingsManager.smartHubQuotaRefreshURL,
                placeholder: "http://127.0.0.1:8787/refresh"
            )
            urlField(
                title: "Voice routine endpoint",
                text: $settingsManager.smartHubQuotaVoiceRefreshURL,
                placeholder: "http://127.0.0.1:8787/voice-refresh"
            )
        }
    }

    @ViewBuilder
    private func urlField(
        title: String,
        text: Binding<String>,
        placeholder: String
    ) -> some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text(title)
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            TextField(placeholder, text: text)
                .font(DesignSystem.Typography.monoSmall)
                .textFieldStyle(.plain)
                .padding(DesignSystem.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .fill(DesignSystem.Colors.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                        .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                )
        }
    }

    // MARK: - Layout + background

    private var layoutAndBackgroundRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Layout")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
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
                .pickerStyle(.menu)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Background mode")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
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
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    // MARK: - Palette + theme

    private var paletteAndThemeRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Palette")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Picker(
                    "Palette",
                    selection: Binding(
                        get: { model.config.palette },
                        set: { model.updatePalette($0) }
                    )
                ) {
                    ForEach(SmartHubDisplayPalette.allCases, id: \.self) { palette in
                        HStack {
                            Circle()
                                .fill(Color(hex: palette.primaryHex))
                                .frame(width: 10, height: 10)
                            Text(palette.displayName)
                        }
                        .tag(palette)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Theme")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
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
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    // MARK: - Time period + refresh cadence

    private var timePeriodAndCadenceRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Time period")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Picker(
                    "Time period",
                    selection: $settingsManager.smartHubQuotaTimePeriod
                ) {
                    ForEach(SmartHubTimePeriod.allCases, id: \.self) { period in
                        Text(period.shortLabel).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Refresh cadence")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
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

    // MARK: - Brightness + scroll speed

    private var brightnessAndScrollRow: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Brightness")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Spacer()
                    Text("\(Int(model.config.clampedBrightness * 100))%")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
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
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } maximumValueLabel: {
                    Image(systemName: "sun.max.fill")
                        .foregroundStyle(DesignSystem.Colors.amber)
                }
                .accessibilityLabel("Brightness")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Carousel page duration")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Spacer()
                    Text("\(model.config.clampedScrollSpeed)s")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
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
                        .foregroundStyle(DesignSystem.Colors.whimsy)
                } maximumValueLabel: {
                    Image(systemName: "tortoise.fill")
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                .accessibilityLabel("Carousel page duration")
            }
        }
    }

    // MARK: - Audible + identify

    private var audibleAndIdentifyRow: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Toggle(
                isOn: Binding(
                    get: { model.config.audibleCue },
                    set: { model.updateAudibleCue($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Audible chime on refresh")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Plays a soft tone on the Hub each time fresh data arrives.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
            Toggle(
                isOn: Binding(
                    get: { model.config.identifyOnRefresh },
                    set: { model.updateIdentifyOnRefresh($0) }
                )
            ) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Identify on refresh")
                        .font(DesignSystem.Typography.body)
                        .foregroundStyle(DesignSystem.Colors.textPrimary)
                    Text("Pings the voice routine endpoint so Google can speak the latest totals.")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
            }
        }
    }

    // MARK: - Provider filter

    private var providerFilterRow: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack {
                Text("Providers to show")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Spacer()
                if model.hasExplicitProviderFilter {
                    Button("Reset to all") { model.resetProviderFilter() }
                        .buttonStyle(.link)
                        .font(DesignSystem.Typography.tiny)
                }
            }

            NestHubProviderChipRow(
                providers: model.availableProviders,
                isSelected: { model.isProviderSelected($0) },
                toggle: { model.toggleProvider($0) }
            )
        }
    }

    // MARK: - Voice routine helper

    private var voiceRoutineHelper: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Voice routine deep-link")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            HStack(spacing: DesignSystem.Spacing.sm) {
                Text(curlSnippet)
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.horizontal, DesignSystem.Spacing.sm)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .fill(DesignSystem.Colors.surface)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                            .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
                    )
                Button("Copy") {
                    copySnippet()
                }
                .buttonStyle(.bordered)
            }
            if let message = model.lastClipboardMessage {
                Text(message)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.success)
            }
        }
    }

    private var curlSnippet: String {
        let url = settingsManager.smartHubQuotaVoiceRefreshURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !url.isEmpty else {
            return "curl -X POST http://127.0.0.1:8787/voice-refresh"
        }
        return "curl -X POST \(url)"
    }

    private func copySnippet() {
        #if canImport(AppKit)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(curlSnippet, forType: .string)
        model.lastClipboardMessage = "Voice routine command copied."
        scheduleToastClear()
        #endif
    }

    private func scheduleToastClear() {
        copyToastTask?.cancel()
        copyToastTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if Task.isCancelled { return }
            model.lastClipboardMessage = nil
        }
    }

    private var helpText: some View {
        Text("For Google Assistant, bind the phrase \"quota refresh\" to the voice routine endpoint from Google Home, Home Assistant, IFTTT, or another webhook bridge.")
            .font(DesignSystem.Typography.tiny)
            .foregroundStyle(DesignSystem.Colors.textMuted)
            .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Provider Chip Row

private struct NestHubProviderChipRow: View {
    let providers: [AgentProvider]
    let isSelected: (AgentProvider) -> Bool
    let toggle: (AgentProvider) -> Void

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 88), spacing: DesignSystem.Spacing.sm)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            ForEach(providers, id: \.self) { provider in
                NestHubProviderChip(
                    provider: provider,
                    isSelected: isSelected(provider),
                    toggle: { toggle(provider) }
                )
            }
        }
    }
}

private struct NestHubProviderChip: View {
    let provider: AgentProvider
    let isSelected: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 6) {
                Circle()
                    .fill(DesignSystem.Colors.primary(for: provider))
                    .frame(width: 8, height: 8)
                Text(shortLabel)
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(isSelected
                ? DesignSystem.Colors.textPrimary
                : DesignSystem.Colors.textSecondary
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(isSelected
                        ? DesignSystem.Colors.primary(for: provider).opacity(0.20)
                        : DesignSystem.Colors.surface
                    )
            )
            .overlay(
                Capsule()
                    .stroke(
                        isSelected
                            ? DesignSystem.Colors.primary(for: provider).opacity(0.6)
                            : DesignSystem.Colors.border,
                        lineWidth: 0.7
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Toggle provider \(shortLabel)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var shortLabel: String {
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
}
