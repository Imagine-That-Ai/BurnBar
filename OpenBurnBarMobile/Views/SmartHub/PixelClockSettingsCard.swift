import OpenBurnBarCore
import SwiftUI

// MARK: - Pixel Clock Settings Card (iOS / iPadOS)
//
// Lives inside the existing "Smart Display" section of
// `iPadDevicesSettingsView` (which is reached from both the iPhone
// SettingsHub and the iPad sidebar Devices destination). Mirrors the
// macOS surface using MobileTheme tokens.

struct PixelClockSettingsCard: View {
    @Bindable var smartHubStore: SmartHubStore
    @State private var model: PixelClockSettingsModel
    @State private var carouselTick: Int = 0
    @State private var previewTimerTask: Task<Void, Never>?
    @State private var customizeExpanded = false
    @State private var advancedExpanded = false
    @State private var didAutoPrepare = false

    init(
        smartHubStore: SmartHubStore,
        model: PixelClockSettingsModel? = nil
    ) {
        self.smartHubStore = smartHubStore
        if let model {
            _model = State(initialValue: model)
        } else {
            let adapter = MobilePixelClockOperationsAdapter(store: smartHubStore)
            let initial = smartHubStore.config?.pixelClock ?? .disabled
            _model = State(initialValue: PixelClockSettingsModel(
                initialConfig: initial,
                operations: adapter,
                setupRetryAttempts: 150,
                setupRetryIntervalNanoseconds: 2_000_000_000
            ))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
            header

            if model.config.enabled {
                preview
                primarySetupPanel
                customizationDisclosure
                advancedDisclosure
            }
        }
        // See NestHubSettingsCard for the same fix — without this, any
        // wide child (long button label, fixed-size badge) makes the
        // VStack grow past the form row and centre, clipping on both
        // edges on iPhone.
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
            if let cached = smartHubStore.config?.pixelClock {
                model.apply(config: cached)
            }
            startCarousel()
        }
        .onDisappear {
            previewTimerTask?.cancel()
            previewTimerTask = nil
        }
        .onChange(of: smartHubStore.config?.pixelClock) { _, newValue in
            guard let newValue, newValue != model.config else { return }
            model.apply(config: newValue)
        }
        .task(id: model.config.enabled) {
            await autoPrepareIfNeeded()
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: MobileTheme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(MobileTheme.ember.opacity(0.18))
                Image(systemName: "rectangle.grid.3x2.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(MobileTheme.ember)
            }
            .frame(width: 30, height: 30)

            VStack(alignment: .leading, spacing: 1) {
                Text("ULANZI TC001 Pixel Clock")
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                Text("AWTRIX-powered LED matrix display")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }

            Spacer(minLength: MobileTheme.Spacing.sm)

            Toggle(
                "",
                isOn: Binding(
                    get: { model.config.enabled },
                    set: { setEnabled($0) }
                )
            )
            .labelsHidden()
            .tint(MobileTheme.ember)
            .accessibilityLabel("Enable Pixel Clock")
        }
    }

    // MARK: - Automatic setup

    private var primarySetupPanel: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            if !smartHubStore.hasLiveMacBridge {
                Label(smartHubStore.bridgeFreshnessMessage, systemImage: "desktopcomputer")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(alignment: .center, spacing: MobileTheme.Spacing.sm) {
                setupStatusIcon
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.setupStatusTitle)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(model.setupNeedsAttention ? MobileTheme.Colors.warning : MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let result = model.setupResult,
                       let serverHost = result.suggestedServerHost,
                       let serverPort = result.suggestedServerPort {
                        Text("Simulator target: \(serverHost):\(serverPort)")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                    }
                }
            }

            HStack(spacing: MobileTheme.Spacing.sm) {
                Button {
                    Task { await model.setupAutomatically() }
                } label: {
                    HStack(spacing: 8) {
                        if model.isBusy {
                            ProgressView().scaleEffect(0.72)
                        } else {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 13, weight: .semibold))
                        }
                        Text(model.setupPrimaryTitle)
                            .font(MobileTheme.Typography.caption)
                            .fontWeight(.semibold)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule(style: .continuous).fill(MobileTheme.ember))
                    .foregroundStyle(Color.white)
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy || !smartHubStore.hasLiveMacBridge)
                .accessibilityLabel(model.setupPrimaryTitle)

                if let flasherURL = model.setupResult?.flasherURL,
                   let url = URL(string: flasherURL) {
                    Link(destination: url) {
                        Label("Flash", systemImage: "bolt.badge.automatic.fill")
                            .font(MobileTheme.Typography.caption)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .background(Capsule(style: .continuous).fill(MobileTheme.surface))
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(MobileTheme.border, lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .accessibilityLabel("Open AWTRIX flasher")
                }
            }
        }
        .padding(MobileTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(setupStatusColor.opacity(0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .stroke(setupStatusColor.opacity(0.35), lineWidth: 0.5)
        )
    }

    private var setupStatusIcon: some View {
        Image(systemName: model.isBusy ? "arrow.triangle.2.circlepath" : model.setupStatusSymbolName)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(setupStatusColor)
            .frame(width: 28, height: 28)
            .background(Circle().fill(setupStatusColor.opacity(0.14)))
            .accessibilityHidden(true)
    }

    private var setupStatusColor: Color {
        if model.operationState.failureMessage != nil {
            return MobileTheme.Colors.error
        }
        return model.setupNeedsAttention ? MobileTheme.Colors.warning : MobileTheme.Colors.success
    }

    private var customizationDisclosure: some View {
        DisclosureGroup(isExpanded: $customizeExpanded) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                pickerRow
                spinnerControls
                completionAlerts
                periodAndCadence
                brightnessAndScroll
                providerChips
            }
            .padding(.top, MobileTheme.Spacing.xs)
        } label: {
            Label("Customize display", systemImage: "slider.horizontal.3")
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
        }
    }

    private var advancedDisclosure: some View {
        DisclosureGroup(isExpanded: $advancedExpanded) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                hostRow
                firmwareWarningIfAny
                operationButtons
            }
            .padding(.top, MobileTheme.Spacing.xs)
        } label: {
            Label("Advanced", systemImage: "wrench.and.screwdriver")
                .font(MobileTheme.Typography.caption)
                .fontWeight(.semibold)
                .foregroundStyle(MobileTheme.Colors.textMuted)
        }
    }

    // MARK: - Preview

    private var preview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Preview")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            PixelClockPreviewView(
                frame: PixelClockFramePresenter.makePreviewFrame(config: model.config, tick: carouselTick)
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, MobileTheme.Spacing.xs)
            .animation(MobileTheme.Animation.snappy, value: carouselTick)
        }
    }

    // MARK: - Operation buttons

    private var operationButtons: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.xs) {
            HStack(spacing: MobileTheme.Spacing.sm) {
                operationButton(.probe, prominent: true)
                operationButton(.test, prominent: false)
                operationButton(.push, prominent: false)
            }
            HStack(spacing: MobileTheme.Spacing.sm) {
                operationButton(.remove, prominent: false)
                Spacer(minLength: 0)
                feedbackBadge
            }
        }
        .disabled(model.isBusy || !smartHubStore.hasLiveMacBridge)
    }

    private func operationButton(
        _ kind: PixelClockOperationKind,
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
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(prominent ? MobileTheme.ember : MobileTheme.surface)
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

    // MARK: - Host row

    private var hostRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Host")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            HStack(spacing: MobileTheme.Spacing.sm) {
                TextField(
                    "192.168.68.92",
                    text: Binding(
                        get: { model.config.host },
                        set: { model.updateHost($0) }
                    )
                )
                .font(MobileTheme.Typography.monoSmall)
                .keyboardType(.URL)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .padding(MobileTheme.Spacing.sm)
                .background(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                        .fill(MobileTheme.surface)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                        .stroke(MobileTheme.border, lineWidth: 0.5)
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
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(firmwareColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(firmwareColor.opacity(0.14))
        .clipShape(Capsule())
        .accessibilityLabel("Firmware status \(model.firmware.displayName)")
    }

    private var firmwareColor: Color {
        switch model.firmware {
        case .awtrixReady:           return MobileTheme.Colors.success
        case .stockUlanziFirmware,
             .unreachable,
             .unsupported,
             .error:                 return MobileTheme.Colors.warning
        case .unknown:                return MobileTheme.Colors.textMuted
        }
    }

    @ViewBuilder
    private var firmwareWarningIfAny: some View {
        if let warning = model.firmwareWarningMessage {
            Label(warning, systemImage: "exclamationmark.triangle.fill")
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(MobileTheme.Colors.warning)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Layout + Palette

    private var pickerRow: some View {
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
                    ForEach(PixelClockLayout.allCases, id: \.self) { layout in
                        Label(layout.displayName, systemImage: layout.iconName).tag(layout)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Palette")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Picker(
                    "Palette",
                    selection: Binding(
                        get: { model.config.palette },
                        set: { model.updatePalette($0) }
                    )
                ) {
                    ForEach(PixelClockPalette.allCases, id: \.self) { palette in
                        Text(palette.displayName).tag(palette)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
            }
        }
    }

    private var spinnerControls: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Working spinner")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
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
                .labelsHidden()
                .pickerStyle(.menu)
            }

            HStack(spacing: MobileTheme.Spacing.sm) {
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

    private var completionAlerts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Agent completion alerts")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            Toggle(
                "Clock sound",
                isOn: Binding(
                    get: { model.config.completionClockSoundEnabled },
                    set: { model.updateCompletionClockSoundEnabled($0) }
                )
            )
            .tint(MobileTheme.ember)
            Toggle(
                "Device notifications",
                isOn: Binding(
                    get: { model.config.completionLocalNotificationsEnabled },
                    set: { model.updateCompletionLocalNotificationsEnabled($0) }
                )
            )
            .tint(MobileTheme.ember)
        }
        .font(MobileTheme.Typography.caption)
    }

    private func pixelColorField(title: String, text: Binding<String>) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(hex: text.wrappedValue))
                .frame(width: 10, height: 10)
            TextField("#52D6FF", text: text)
                .font(MobileTheme.Typography.monoSmall)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .frame(minWidth: 72)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .fill(MobileTheme.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.sm, style: .continuous)
                .stroke(MobileTheme.border, lineWidth: 0.5)
        )
        .accessibilityLabel(title)
    }

    // MARK: - Time period + Cadence

    private var periodAndCadence: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Time period")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
                Picker(
                    "Time period",
                    selection: Binding(
                        get: { model.config.timePeriod },
                        set: { model.updateTimePeriod($0) }
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
                Text("Update cadence")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
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

    // MARK: - Brightness + Scroll speed

    private var brightnessAndScroll: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Brightness")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                    Spacer()
                    Text(brightnessDisplayText)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                Slider(
                    value: Binding(
                        get: { Double(model.config.clampedBrightness ?? PixelClockConfig.safeDefaultBrightness) },
                        set: { model.updateBrightness(Int($0)) }
                    ),
                    in: Double(PixelClockConfig.minimumVisibleBrightness)...Double(PixelClockConfig.safeMaximumBrightness),
                    step: 5
                ) {
                    Text("Brightness")
                } minimumValueLabel: {
                    Image(systemName: "sun.min.fill")
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                } maximumValueLabel: {
                    Image(systemName: "sun.max.fill")
                        .foregroundStyle(MobileTheme.amber)
                }
                .tint(MobileTheme.ember)
                .accessibilityLabel("Brightness")
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Scroll speed")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                    Spacer()
                    Text("\(model.config.clampedScrollSpeed)%")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
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
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                } maximumValueLabel: {
                    Image(systemName: "hare.fill")
                        .foregroundStyle(MobileTheme.whimsy)
                }
                .tint(MobileTheme.ember)
                .accessibilityLabel("Scroll speed")
            }
        }
    }

    private var brightnessDisplayText: String {
        "\(model.config.clampedBrightness ?? PixelClockConfig.safeDefaultBrightness)"
    }

    // MARK: - Provider chips

    private var providerChips: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Providers to show")
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(MobileTheme.Colors.textMuted)
            let columns = [GridItem(.adaptive(minimum: 88), spacing: MobileTheme.Spacing.sm)]
            LazyVGrid(columns: columns, alignment: .leading, spacing: MobileTheme.Spacing.sm) {
                ForEach(model.availableProviders, id: \.self) { provider in
                    Button {
                        model.toggleProvider(provider)
                    } label: {
                        chipLabel(for: provider)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Toggle provider \(chipText(for: provider))")
                    .accessibilityAddTraits(model.isProviderSelected(provider) ? .isSelected : [])
                }
            }
        }
    }

    private func chipLabel(for provider: AgentProvider) -> some View {
        let isSelected = model.isProviderSelected(provider)
        let color = MobileTheme.Colors.primary(for: provider)
        return HStack(spacing: 6) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
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

    // MARK: - Operations

    private func dispatch(_ kind: PixelClockOperationKind) async {
        switch kind {
        case .flash:  await model.flashAndFinishSetup()
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
        // Opening this screen should refresh status without locking the user
        // into the several-minute setup watcher. The long one-click flow runs
        // only from the explicit setup action or when the display is enabled.
        await model.prepare()
    }

    // MARK: - Preview tick

    private func startCarousel() {
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
