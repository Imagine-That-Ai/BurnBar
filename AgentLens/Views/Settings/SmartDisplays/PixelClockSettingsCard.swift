import OpenBurnBarCore
import SwiftUI

// MARK: - Pixel Clock Settings Card (macOS)
//
// Pairs with `ProviderQuotaSmartHubsSection` (Nest Hub) inside the new
// "Smart Displays" group in DevicesAndSyncSettingsView. Controls the
// ULANZI TC001 Pixel Clock when AWTRIX firmware is detected and surfaces
// honest warnings otherwise.

struct PixelClockSettingsCard: View {
    @Bindable var settingsManager: SettingsManager
    @State private var model: PixelClockSettingsModel
    @State private var carouselTick: Int = 0
    @State private var previewTimerTask: Task<Void, Never>?
    @State private var customizeExpanded = false
    @State private var advancedExpanded = false
    @State private var didAutoPrepare = false

    private let runtimeContext: OpenBurnBarRuntimeContext?

    init(
        settingsManager: SettingsManager,
        runtimeContext: OpenBurnBarRuntimeContext? = nil,
        model: PixelClockSettingsModel? = nil
    ) {
        self.settingsManager = settingsManager
        self.runtimeContext = runtimeContext
        let resolvedModel: PixelClockSettingsModel
        if let model {
            resolvedModel = model
        } else {
            let adapter = MacPixelClockOperationsAdapter(
                settingsManager: settingsManager,
                controller: runtimeContext?.pixelClockController
            )
            resolvedModel = PixelClockSettingsModel(
                initialConfig: settingsManager.pixelClockConfig,
                operations: adapter
            )
        }
        _model = State(initialValue: resolvedModel)
    }

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
                header
                if model.config.enabled {
                    previewSection
                    primarySetupPanel
                    customizationDisclosure
                    advancedDisclosure
                }
            }
            .padding(DesignSystem.Spacing.lg)
        }
        .onAppear {
            model.apply(config: settingsManager.pixelClockConfig)
            startCarouselTimer()
        }
        .onDisappear {
            previewTimerTask?.cancel()
            previewTimerTask = nil
        }
        .onChange(of: settingsManager.pixelClockConfig) { _, newValue in
            if newValue != model.config {
                model.apply(config: newValue)
            }
        }
        .task(id: model.config.enabled) {
            await autoPrepareIfNeeded()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                    .fill(DesignSystem.Colors.ember.opacity(0.14))
                    .frame(width: 38, height: 38)
                Image(systemName: "rectangle.grid.3x2.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.ember)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("ULANZI TC001 Pixel Clock")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Show live OpenBurnBar quota on a Pixel Clock running AWTRIX firmware.")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: DesignSystem.Spacing.md)

            Toggle(
                "",
                isOn: Binding(
                    get: { model.config.enabled },
                    set: { newValue in setEnabled(newValue) }
                )
            )
            .toggleStyle(.switch)
            .labelsHidden()
            .accessibilityLabel("Enable Pixel Clock")
        }
    }

    // MARK: - Automatic setup

    private var primarySetupPanel: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(alignment: .center, spacing: DesignSystem.Spacing.md) {
                setupStatusIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.setupStatusTitle)
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(model.setupNeedsAttention ? DesignSystem.Colors.warning : DesignSystem.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let result = model.setupResult,
                       let serverHost = result.suggestedServerHost,
                       let serverPort = result.suggestedServerPort {
                        Text("Simulator target: \(serverHost):\(serverPort)")
                            .font(DesignSystem.Typography.tiny)
                            .foregroundStyle(DesignSystem.Colors.textMuted)
                    }
                }
                Spacer(minLength: 0)
            }

            HStack(spacing: DesignSystem.Spacing.sm) {
                GlassButton(
                    title: model.setupPrimaryTitle,
                    icon: model.isBusy ? "ellipsis" : "wand.and.stars",
                    style: .prominent
                ) {
                    Task { await model.setupAutomatically() }
                }
                .disabled(model.isBusy)

                if let flasherURL = model.setupResult?.flasherURL,
                   let url = URL(string: flasherURL) {
                    Link(destination: url) {
                        Label("Flash AWTRIX", systemImage: "bolt.badge.automatic.fill")
                            .font(DesignSystem.Typography.caption)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(DesignSystem.Colors.whimsy)
                    .accessibilityLabel("Open AWTRIX flasher")
                }
            }
        }
        .padding(DesignSystem.Spacing.md)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .fill(setupStatusColor.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.md, style: .continuous)
                .stroke(setupStatusColor.opacity(0.35), lineWidth: 0.6)
        )
    }

    private var setupStatusIcon: some View {
        Image(systemName: model.isBusy ? "arrow.triangle.2.circlepath" : model.setupStatusSymbolName)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(setupStatusColor)
            .frame(width: 28, height: 28)
            .background(Circle().fill(setupStatusColor.opacity(0.12)))
            .accessibilityHidden(true)
    }

    private var setupStatusColor: Color {
        if model.operationState.failureMessage != nil {
            return DesignSystem.Colors.error
        }
        return model.setupNeedsAttention ? DesignSystem.Colors.warning : DesignSystem.Colors.success
    }

    private var customizationDisclosure: some View {
        DisclosureGroup(isExpanded: $customizeExpanded) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                layoutAndPaletteRow
                spinnerRow
                completionAlertsRow
                timePeriodAndCadenceRow
                brightnessAndScrollRow
                providerFilterRow
            }
            .padding(.top, DesignSystem.Spacing.sm)
        } label: {
            Label("Customize display", systemImage: "slider.horizontal.3")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textSecondary)
        }
    }

    private var advancedDisclosure: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
                firmwareRow
                operationButtons
            }
            .padding(.top, DesignSystem.Spacing.sm)
        } label: {
            Label("Advanced", systemImage: "wrench.and.screwdriver")
                .font(DesignSystem.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(DesignSystem.Colors.textMuted)
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
                PixelClockPreviewView(
                    frame: PixelClockFramePresenter.makePreviewFrame(config: model.config, tick: carouselTick)
                )
                .frame(maxWidth: 320)
                .padding(.vertical, DesignSystem.Spacing.xs)
                .animation(DesignSystem.Animation.snappy, value: carouselTick)
                Spacer(minLength: 0)
            }
        }
    }

    // MARK: - Operation buttons

    private var operationButtons: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            HStack(spacing: DesignSystem.Spacing.sm) {
                operationButton(.probe, style: .prominent)
                operationButton(.test, style: .regular)
                operationButton(.push, style: .regular)
                operationButton(.remove, style: .regular)
            }
            .disabled(model.isBusy)

            if let warning = model.firmwareWarningMessage {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

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
        _ kind: PixelClockOperationKind,
        style: GlassButton.Style
    ) -> some View {
        let isInflight = model.inflightOperation == kind
        return GlassButton(
            title: isInflight ? kind.inFlightLabel : kind.displayName,
            icon: isInflight ? "ellipsis" : kind.symbolName,
            style: style
        ) {
            Task { await runOperation(kind) }
        }
        .accessibilityLabel(kind.displayName)
    }

    // MARK: - Firmware row

    private var firmwareRow: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Host")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            HStack(spacing: DesignSystem.Spacing.sm) {
                TextField(
                    "192.168.68.92",
                    text: Binding(
                        get: { model.config.host },
                        set: { newValue in model.updateHost(newValue) }
                    )
                )
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
                .accessibilityLabel("Pixel Clock host or IP address")

                firmwareBadge
            }
        }
    }

    private var firmwareBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: model.firmware.symbolName)
                .font(.system(size: 11, weight: .semibold))
            Text(model.firmware.displayName)
                .font(DesignSystem.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(firmwareBadgeColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(firmwareBadgeColor.opacity(0.12))
        .clipShape(Capsule())
        .accessibilityLabel("Firmware status \(model.firmware.displayName)")
    }

    private var firmwareBadgeColor: Color {
        switch model.firmware {
        case .awtrixReady:          return DesignSystem.Colors.success
        case .stockUlanziFirmware,
             .unreachable,
             .unsupported,
             .error:                 return DesignSystem.Colors.warning
        case .unknown:               return DesignSystem.Colors.textMuted
        }
    }

    // MARK: - Layout + Palette

    private var layoutAndPaletteRow: some View {
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
                    ForEach(PixelClockLayout.allCases, id: \.self) { layout in
                        Label(layout.displayName, systemImage: layout.iconName).tag(layout)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

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
                    ForEach(PixelClockPalette.allCases, id: \.self) { palette in
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
        }
    }

    private var spinnerRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Working spinner")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Picker(
                    "Working spinner",
                    selection: Binding(
                        get: { model.config.workingSpinnerStyle },
                        set: { model.updateWorkingSpinnerStyle($0) }
                    )
                ) {
                    ForEach(PixelClockSpinnerStyle.allCases, id: \.self) { style in
                        Label(style.displayName, systemImage: style.iconName).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Spinner colors")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                HStack(spacing: DesignSystem.Spacing.xs) {
                    pixelColorField(
                        title: "Primary spinner color",
                        text: Binding(
                            get: { model.config.workingSpinnerPrimaryHex },
                            set: { model.updateWorkingSpinnerPrimaryHex($0) }
                        )
                    )
                    pixelColorField(
                        title: "Secondary spinner color",
                        text: Binding(
                            get: { model.config.workingSpinnerSecondaryHex },
                            set: { model.updateWorkingSpinnerSecondaryHex($0) }
                        )
                    )
                }
            }
        }
    }

    private var completionAlertsRow: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            Text("Agent completion alerts")
                .font(DesignSystem.Typography.caption)
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Toggle(
                "Play provider sound on Pixel Clock",
                isOn: Binding(
                    get: { model.config.completionClockSoundEnabled },
                    set: { model.updateCompletionClockSoundEnabled($0) }
                )
            )
            Toggle(
                "Show local completion notifications",
                isOn: Binding(
                    get: { model.config.completionLocalNotificationsEnabled },
                    set: { model.updateCompletionLocalNotificationsEnabled($0) }
                )
            )
        }
        .font(DesignSystem.Typography.caption)
    }

    private func pixelColorField(title: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: text.wrappedValue))
                .frame(width: 10, height: 10)
            TextField("#52D6FF", text: text)
                .font(DesignSystem.Typography.monoSmall)
                .textFieldStyle(.plain)
                .frame(width: 78)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .fill(DesignSystem.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: DesignSystem.Radius.sm, style: .continuous)
                .stroke(DesignSystem.Colors.border, lineWidth: 0.5)
        )
        .accessibilityLabel(title)
    }

    // MARK: - Time period + Update cadence

    private var timePeriodAndCadenceRow: some View {
        HStack(alignment: .top, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Time period")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Picker(
                    "Time period",
                    selection: Binding(
                        get: { model.config.timePeriod },
                        set: { model.updateTimePeriod($0) }
                    )
                ) {
                    ForEach(SmartHubTimePeriod.allCases, id: \.self) { period in
                        Text(period.displayName).tag(period)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Update cadence")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Picker(
                    "Update cadence",
                    selection: Binding(
                        get: { model.config.clampedUpdateInterval },
                        set: { model.updateUpdateInterval($0) }
                    )
                ) {
                    Text("Every 15s").tag(15)
                    Text("Every 30s").tag(30)
                    Text("Every minute").tag(60)
                    Text("Every 5 minutes").tag(300)
                }
                .pickerStyle(.menu)
                .labelsHidden()
            }
        }
    }

    // MARK: - Brightness + Scroll

    private var brightnessAndScrollRow: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.md) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Brightness")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Spacer()
                    Text(brightnessDisplayText)
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.config.brightness ?? 160) },
                        set: { model.updateBrightness(Int($0)) }
                    ),
                    in: 0...255,
                    step: 5
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
                    Text("Scroll speed")
                        .font(DesignSystem.Typography.caption)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                    Spacer()
                    Text("\(model.config.clampedScrollSpeed)%")
                        .font(DesignSystem.Typography.tiny)
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.config.clampedScrollSpeed) },
                        set: { model.updateScrollSpeed(Int($0)) }
                    ),
                    in: 10...300,
                    step: 10
                ) {
                    Text("Scroll speed")
                } minimumValueLabel: {
                    Image(systemName: "tortoise.fill")
                        .foregroundStyle(DesignSystem.Colors.textMuted)
                } maximumValueLabel: {
                    Image(systemName: "hare.fill")
                        .foregroundStyle(DesignSystem.Colors.whimsy)
                }
                .accessibilityLabel("Scroll speed")
            }
        }
    }

    private var brightnessDisplayText: String {
        guard let brightness = model.config.brightness else { return "Auto" }
        return "\(brightness)"
    }

    // MARK: - Provider filter chips

    private var providerFilterRow: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack {
                Text("Providers to show")
                    .font(DesignSystem.Typography.caption)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                Spacer()
                if model.hasExplicitProviderFilter {
                    Button("Reset to all") {
                        for provider in model.availableProviders where !model.isProviderSelected(provider) {
                            model.toggleProvider(provider)
                        }
                        // After flipping non-selected to selected the filter becomes empty when
                        // the user reaches an "all selected" state — explicitly clear instead.
                        var next = settingsManager.pixelClockConfig
                        next.providerIDs = []
                        settingsManager.pixelClockConfig = next
                        model.apply(config: next)
                    }
                    .buttonStyle(.link)
                    .font(DesignSystem.Typography.tiny)
                }
            }

            FlowingChipRow(
                providers: model.availableProviders,
                isSelected: { model.isProviderSelected($0) },
                toggle: { model.toggleProvider($0) }
            )
        }
    }

    // MARK: - Operations

    private func runOperation(_ kind: PixelClockOperationKind) async {
        switch kind {
        case .probe:  await model.probe()
        case .test:   await model.test()
        case .push:   await model.push()
        case .remove: await model.remove()
        }
    }

    private func setEnabled(_ enabled: Bool) {
        if enabled {
            didAutoPrepare = true
            Task { await model.setupAutomatically() }
        } else {
            model.toggleEnabled(false)
            didAutoPrepare = false
        }
    }

    private func autoPrepareIfNeeded() async {
        guard model.config.enabled, !didAutoPrepare, model.firmware != .awtrixReady else { return }
        didAutoPrepare = true
        await model.setupAutomatically()
    }

    // MARK: - Preview Tick

    private func startCarouselTimer() {
        previewTimerTask?.cancel()
        previewTimerTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_400_000_000)
                if Task.isCancelled { break }
                carouselTick &+= 1
            }
        }
    }
}

// MARK: - Provider Chip Row

private struct FlowingChipRow: View {
    let providers: [AgentProvider]
    let isSelected: (AgentProvider) -> Bool
    let toggle: (AgentProvider) -> Void

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 88), spacing: DesignSystem.Spacing.sm)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: DesignSystem.Spacing.sm) {
            ForEach(providers, id: \.self) { provider in
                ProviderFilterChip(
                    provider: provider,
                    isSelected: isSelected(provider),
                    toggle: { toggle(provider) }
                )
            }
        }
    }
}

private struct ProviderFilterChip: View {
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
