import SwiftUI
import OpenBurnBarCore

// MARK: - Fan-Out Composer Sheet (Hermes Square §6.4 / S2)
//
// The Wand experience: write a brief, choose your agents, optionally cast a
// routing wand (Headmaster's for best model, Pareto for best value), and
// dispatch the fleet. The UI is built around three principles:
//
//   1. VISIBLE CAPACITY — the user sees their tier's parallel-agent ladder
//      as glowing dots that fill as they select. Hitting the cap feels like
//      the room is full, not like an error.
//   2. THE WAND IS RITUAL — selecting a wand is a card-pick, not a picker.
//      The chosen wand radiates its crest color across the agent row.
//   3. HONESTY IS BEAUTIFUL — locked agents, tier caps, and upgrade paths
//      are rendered as desirable objects (dashed rings, foil edges), never
//      as greyed-out padlocks or error labels.

struct FanOutComposerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.cloudSubscriptionStore) private var cloudStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let registry: AgentIdentityRegistry
    let onDispatched: (CLIAgentMissionDispatcher.FanOutDispatchResult) -> Void

    // MARK: - State

    @State private var prompt: String = ""
    @State private var title: String = ""
    @State private var selectedRuntimes: Set<String> = ["claude", "codex", "hermes"]
    @State private var missionKind: MissionConsoleKind = .diligence
    @State private var depth: MissionConsoleDepth = .standard
    @State private var approvalMode: MissionConsoleApprovalMode = .existingPolicy
    @State private var commandsAllowed: Bool = false
    @State private var fileEditsAllowed: Bool = false
    @State private var mergeStrategy: MissionGroupMergeStrategy = .pickOne
    @State private var dispatching: Bool = false
    @State private var errorMessage: String?
    @State private var showWandPaywall: Bool = false
    @State private var wandSelector: WandPolicy.Selector? = nil
    @State private var showAdvanced: Bool = false
    @State private var appeared: Bool = false
    @FocusState private var promptFocused: Bool

    // MARK: - Tier

    private var cloudTier: CloudTier {
        cloudStore?.cloudTier ?? .none
    }
    private var isWandUnlocked: Bool {
        cloudTier.satisfies(.cloud)
    }
    private var maxParallel: Int {
        WandFanOut.maxParallel(for: cloudTier)
    }
    private var minRuntimes: Int {
        min(2, maxParallel)
    }

    // MARK: - Agents

    private var dispatchableAgents: [AgentIdentity] {
        registry.identities.filter { $0.tier == .service && $0.runtimeID != nil }
    }

    // MARK: - Forecast

    private var forecast: MissionGroupDocument.ForecastBand {
        let kindDefault = missionKind
        let depthDefault = depth
        let runtimes = selectedRuntimes
        let consoleApproval = approvalMode
        let cmdAllowed = commandsAllowed
        let fileAllowed = fileEditsAllowed
        let titleSnap = title.isEmpty ? "Wand cast" : title
        let promptSnap = prompt.isEmpty ? "—" : prompt
        let children: [MissionConsoleForecast] = runtimes.map { token in
            let draft = MissionConsoleDispatchRequest(
                title: titleSnap,
                prompt: promptSnap,
                kind: kindDefault,
                runtimeID: token,
                targetProject: nil,
                depth: depthDefault,
                approvalMode: consoleApproval,
                commandsAllowed: cmdAllowed,
                fileEditsAllowed: fileAllowed
            )
            let runtime = MissionConsoleRuntime(
                id: token, displayName: token.capitalized,
                callSign: String(token.prefix(3)).uppercased(), provider: .factory
            )
            return MissionConsoleForecastComputer.forecast(for: draft, runtime: runtime)
        }
        return MissionGroupForecastComputer.combine(children: children, parallelismLimit: runtimes.count)
    }

    // MARK: - Wand Visuals

    private var activeWandColor: Color {
        switch wandSelector {
        case .headmaster: return cloudTier.holoStops.first ?? DesignSystemColors.amber
        case .pareto:     return DesignSystemColors.success
        case nil:         return DesignSystemColors.textSecondary
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: MobileTheme.Spacing.lg) {
                    briefSection
                    capacityLadder
                    agentGrid
                    if isWandUnlocked {
                        wandSelectorSection
                    } else {
                        wandLockedTeaser
                    }
                    forecastSection
                    advancedToggle
                    if showAdvanced {
                        advancedSection
                    }
                    if let errorMessage {
                        errorBanner(errorMessage)
                    }
                }
                .padding(.horizontal, MobileTheme.Spacing.lg)
                .padding(.bottom, 120) // tab bar clearance
            }
            .background {
                RadialGradient(
                    colors: [
                        activeWandColor.opacity(appeared ? 0.06 : 0),
                        DesignSystemColors.background.opacity(0)
                    ],
                    center: UnitPoint(x: 0.5, y: 0.0),
                    startRadius: 0,
                    endRadius: 600
                )
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.6), value: wandSelector)
            }
            .scrollBounceBehavior(.basedOnSize)
            .navigationTitle("The Wand")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    castButton
                }
            }
            .sheet(isPresented: $showWandPaywall) {
                FeatureUnlockSheet(feature: GatedFeature.gatedFeature(.theWand))
            }
            .onAppear {
                guard !appeared else { return }
                appeared = true
                if selectedRuntimes.count > maxParallel {
                    selectedRuntimes = Set(Array(selectedRuntimes.prefix(maxParallel)))
                }
                withAnimation(.easeOut(duration: 0.5)) {
                    promptFocused = true
                }
            }
        }
    }

    // MARK: - Cast Button

    private var castButton: some View {
        Group {
            if dispatching {
                ProgressView()
                    .controlSize(.small)
            } else {
                Button {
                    Haptics.medium()
                    Task { await dispatch() }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: wandSelector != nil ? "wand.and.stars" : "paperplane.fill")
                            .font(.system(size: 12, weight: .bold))
                        Text(wandSelector != nil ? "Cast" : "Dispatch")
                            .fontWeight(.bold)
                    }
                }
                .disabled(!canDispatch)
                .tint(canDispatch ? activeWandColor : nil)
            }
        }
    }

    // MARK: - Brief Section

    private var briefSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            TextField("Title (optional)", text: $title, axis: .horizontal)
                .font(MobileTheme.Typography.headline)

            ZStack(alignment: .topLeading) {
                if prompt.isEmpty {
                    Text("Describe the mission for your fleet...")
                        .foregroundStyle(DesignSystemColors.textMuted)
                        .font(MobileTheme.Typography.body)
                        .padding(.top, 8)
                        .padding(.leading, 4)
                        .allowsHitTesting(false)
                }
                TextEditor(text: $prompt)
                    .focused($promptFocused)
                    .frame(minHeight: 88)
                    .scrollContentBackground(.hidden)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(DesignSystemColors.textPrimary)
            }
            .padding(MobileTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(DesignSystemColors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                            .stroke(
                                promptFocused
                                    ? activeWandColor.opacity(0.5)
                                    : DesignSystemColors.borderSubtle,
                                lineWidth: promptFocused ? 1.5 : 1
                            )
                    )
            )
            .animation(.easeInOut(duration: 0.25), value: promptFocused)
        }
    }

    // MARK: - Capacity Ladder

    private var capacityLadder: some View {
        HStack(spacing: 4) {
            ForEach(0..<max(maxParallel, 1), id: \.self) { index in
                let filled = index < selectedRuntimes.count
                Capsule()
                    .fill(
                        filled
                            ? AnyShapeStyle(activeWandColor.opacity(0.8))
                            : AnyShapeStyle(DesignSystemColors.borderSubtle)
                    )
                    .frame(height: 4)
                    .scaleEffect(filled && !reduceMotion ? 1.0 : 1.0, anchor: .leading)
                    .animation(
                        .spring(response: 0.35, dampingFraction: 0.7).delay(Double(index) * 0.03),
                        value: selectedRuntimes.count
                    )
            }
            if maxParallel < 16 {
                Text("\(selectedRuntimes.count)/\(maxParallel)")
                    .font(MobileTheme.Typography.tiny.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(DesignSystemColors.textSecondary)
                    .padding(.leading, 6)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Capacity: \(selectedRuntimes.count) of \(maxParallel) agents selected")
    }

    // MARK: - Agent Grid

    private var agentGrid: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 72), spacing: MobileTheme.Spacing.sm)], spacing: MobileTheme.Spacing.sm) {
            ForEach(dispatchableAgents, id: \.id) { identity in
                if let runtime = identity.runtimeID {
                    agentTile(identity: identity, runtime: runtime)
                }
            }
        }
    }

    private func agentTile(identity: AgentIdentity, runtime: AssistantRuntimeID) -> some View {
        let isSelected = selectedRuntimes.contains(runtime.rawValue)
        let accentColor = Color(hex: identity.paletteHex)
        return Button {
            toggleAgent(runtime.rawValue, accentColor: accentColor)
        } label: {
            VStack(spacing: 6) {
                ZStack {
                    if isSelected && !reduceMotion {
                        // Breathing halo when selected
                        Circle()
                            .stroke(accentColor.opacity(0.3), lineWidth: 2)
                            .scaleEffect(1.15)
                            .blur(radius: 1)
                    }
                    HermesSquareAgentAvatar(
                        identity: identity,
                        size: 46,
                        showAvailability: false,
                        ringStroke: isSelected
                    )
                    .scaleEffect(isSelected ? 1.05 : 1.0)

                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(.white, accentColor)
                            .offset(x: 16, y: 16)
                    }
                }
                .frame(width: 52, height: 52)

                Text(identity.displayName)
                    .font(MobileTheme.Typography.tiny.weight(isSelected ? .bold : .medium))
                    .foregroundStyle(isSelected ? DesignSystemColors.textPrimary : DesignSystemColors.textSecondary)
                    .lineLimit(1)
            }
            .frame(width: 72, height: 82)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .fill(isSelected ? accentColor.opacity(0.08) : DesignSystemColors.surface.opacity(0.5))
                    .overlay(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                            .stroke(
                                isSelected ? accentColor.opacity(0.4) : DesignSystemColors.borderSubtle.opacity(0.5),
                                lineWidth: isSelected ? 1.5 : 0.5
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(identity.displayName)\(isSelected ? ", selected" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : [.isButton])
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: isSelected)
    }

    private func toggleAgent(_ rawValue: String, accentColor: Color) {
        if selectedRuntimes.contains(rawValue) {
            if selectedRuntimes.count > minRuntimes {
                Haptics.selection()
                selectedRuntimes.remove(rawValue)
            }
        } else {
            if selectedRuntimes.count < maxParallel {
                Haptics.light()
                selectedRuntimes.insert(rawValue)
            } else {
                Haptics.warning()
                withAnimation(.easeInOut(duration: 0.3)) {
                    errorMessage = "Your plan allows up to \(maxParallel) agents in parallel."
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    withAnimation { errorMessage = nil }
                }
            }
        }
    }

    // MARK: - Wand Selector (Unlocked)

    private var wandSelectorSection: some View {
        VStack(alignment: .leading, spacing: MobileTheme.Spacing.sm) {
            HStack(spacing: 6) {
                Image(systemName: "wand.and.rays")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(DesignSystemColors.amber)
                Text("Routing Wand")
                    .font(MobileTheme.Typography.footnote.weight(.bold))
                    .foregroundStyle(DesignSystemColors.textSecondary)
                Spacer()
            }

            HStack(spacing: MobileTheme.Spacing.sm) {
                wandCard(
                    selector: nil,
                    title: "Manual",
                    subtitle: "Pick models yourself",
                    icon: "hand.tap",
                    colors: [DesignSystemColors.textMuted, DesignSystemColors.textMuted.opacity(0.5)]
                )
                wandCard(
                    selector: .headmaster,
                    title: "Headmaster's",
                    subtitle: "Best model wins",
                    icon: "crown.fill",
                    colors: cloudTier.holoStops
                )
                wandCard(
                    selector: .pareto,
                    title: "Pareto",
                    subtitle: "Best value per quota",
                    icon: "scalemass.fill",
                    colors: [DesignSystemColors.success, DesignSystemColors.success.opacity(0.5)]
                )
            }
        }
    }

    private func wandCard(
        selector: WandPolicy.Selector?,
        title: String,
        subtitle: String,
        icon: String,
        colors: [Color]
    ) -> some View {
        let isActive = wandSelector == selector
        let primaryColor = colors.first ?? DesignSystemColors.textSecondary
        return Button {
            Haptics.selection()
            withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                wandSelector = selector
            }
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(
                            RadialGradient(
                                colors: isActive ? [primaryColor.opacity(0.25), .clear] : [DesignSystemColors.surface.opacity(0.3), .clear],
                                center: .center,
                                startRadius: 0,
                                endRadius: 24
                            )
                        )
                        .frame(width: 44, height: 44)
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(isActive ? primaryColor : DesignSystemColors.textMuted)
                        .scaleEffect(isActive ? 1.1 : 1.0)
                }
                .if(!reduceMotion && isActive) { view in
                    view.overlay {
                        HoloSheenSweep(tint: primaryColor, period: 3.2, bandOpacity: 0.22)
                            .clipShape(RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous))
                    }
                }

                Text(title)
                    .font(MobileTheme.Typography.caption.weight(isActive ? .bold : .semibold))
                    .foregroundStyle(isActive ? DesignSystemColors.textPrimary : DesignSystemColors.textSecondary)
                    .lineLimit(1)

                Text(subtitle)
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(DesignSystemColors.textMuted)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, MobileTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                    .fill(isActive ? primaryColor.opacity(0.06) : DesignSystemColors.surface.opacity(0.4))
                    .overlay(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                            .stroke(
                                isActive ? primaryColor.opacity(0.4) : DesignSystemColors.borderSubtle.opacity(0.5),
                                lineWidth: isActive ? 1.5 : 0.5
                            )
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) wand: \(subtitle)")
        .accessibilityAddTraits(isActive ? [.isSelected, .isButton] : [.isButton])
    }

    // MARK: - Wand Locked Teaser

    private var wandLockedTeaser: some View {
        Button {
            Haptics.light()
            showWandPaywall = true
        } label: {
            HStack(spacing: MobileTheme.Spacing.sm) {
                ZStack {
                    Circle()
                        .fill(DesignSystemColors.amber.opacity(0.12))
                        .frame(width: 36, height: 36)
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(DesignSystemColors.amber)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cast a Wand")
                        .font(MobileTheme.Typography.caption.weight(.bold))
                        .foregroundStyle(DesignSystemColors.textPrimary)
                    Text("Route to the best model automatically")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(DesignSystemColors.textSecondary)
                }
                Spacer()
                Text("PRO")
                    .font(MobileTheme.Typography.tiny.weight(.heavy))
                    .foregroundStyle(DesignSystemColors.amber)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        Capsule().fill(DesignSystemColors.amber.opacity(0.12))
                    )
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystemColors.textMuted)
            }
            .padding(MobileTheme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                    .fill(DesignSystemColors.surface)
                    .overlay(
                        RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                            .stroke(DesignSystemColors.amber.opacity(0.2), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Unlock The Wand: route to the best model automatically. Cloud Pro required.")
    }

    // MARK: - Forecast

    private var forecastSection: some View {
        HStack(spacing: 0) {
            forecastMetric(
                label: "Tokens",
                value: MissionConsoleFormatting.tokenRange(forecast.tokensLow, forecast.tokensHigh),
                icon: "textformat"
            )
            Divider().frame(height: 32)
            forecastMetric(
                label: "Cost",
                value: MissionConsoleFormatting.costRange(forecast.costLowUSD, forecast.costHighUSD),
                icon: "dollarsign.circle"
            )
            Divider().frame(height: 32)
            forecastMetric(
                label: "ETA",
                value: MissionConsoleFormatting.durationRange(forecast.etaLow, forecast.etaHigh),
                icon: "clock"
            )
        }
        .padding(.vertical, MobileTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(DesignSystemColors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .stroke(DesignSystemColors.borderSubtle, lineWidth: 0.5)
                )
        )
    }

    private func forecastMetric(label: String, value: String, icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(DesignSystemColors.textMuted)
            Text(value)
                .font(MobileTheme.Typography.monoSmall.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(DesignSystemColors.textPrimary)
            Text(label)
                .font(MobileTheme.Typography.tiny)
                .foregroundStyle(DesignSystemColors.textMuted)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Advanced Toggle

    private var advancedToggle: some View {
        Button {
            Haptics.selection()
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                showAdvanced.toggle()
            }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                Text(showAdvanced ? "Hide options" : "Options")
                    .font(MobileTheme.Typography.caption.weight(.semibold))
                Image(systemName: "chevron.down")
                    .font(.system(size: 10, weight: .bold))
                    .rotationEffect(.degrees(showAdvanced ? 180 : 0))
            }
            .foregroundStyle(DesignSystemColors.textSecondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(showAdvanced ? "Hide advanced options" : "Show advanced options")
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        VStack(spacing: MobileTheme.Spacing.sm) {
            Picker("Kind", selection: $missionKind) {
                ForEach(MissionConsoleKind.allCases) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            Picker("Depth", selection: $depth) {
                ForEach(MissionConsoleDepth.allCases) { d in
                    Text(d.displayName).tag(d)
                }
            }
            Picker("Approvals", selection: $approvalMode) {
                ForEach(MissionConsoleApprovalMode.allCases) { m in
                    Text(m.displayName).tag(m)
                }
            }
            Toggle("Allow shell commands", isOn: $commandsAllowed)
            Toggle("Allow file edits", isOn: $fileEditsAllowed)
            Picker("Merge", selection: $mergeStrategy) {
                ForEach(MissionGroupMergeStrategy.allCases, id: \.self) { s in
                    Text(s.rawValue.capitalized).tag(s)
                }
            }
        }
        .padding(MobileTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                .fill(DesignSystemColors.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: MobileTheme.Radius.lg, style: .continuous)
                        .stroke(DesignSystemColors.borderSubtle, lineWidth: 0.5)
                )
        )
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .move(edge: .top)),
            removal: .opacity
        ))
    }

    // MARK: - Error Banner

    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(DesignSystemColors.warning)
            Text(message)
                .font(MobileTheme.Typography.caption)
                .foregroundStyle(DesignSystemColors.textSecondary)
            Spacer()
        }
        .padding(MobileTheme.Spacing.sm)
        .background(
            RoundedRectangle(cornerRadius: MobileTheme.Radius.md, style: .continuous)
                .fill(DesignSystemColors.warning.opacity(0.08))
        )
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    // MARK: - Logic

    private var canDispatch: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedRuntimes.count >= minRuntimes
            && selectedRuntimes.count <= maxParallel
    }

    private func dispatch() async {
        dispatching = true
        errorMessage = nil
        defer { dispatching = false }
        do {
            let runtimes = Array(selectedRuntimes)
            let dispatchParallelismLimit = min(maxParallel, max(1, runtimes.count))
            let result = try await CLIAgentMissionDispatcher.shared.dispatchFanOut(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                prompt: prompt,
                missionKind: missionKind.rawValue,
                runtimeTokens: runtimes,
                targetProject: nil,
                depth: depth.rawValue,
                approvalMode: approvalMode.rawValue,
                commandsAllowed: commandsAllowed,
                fileEditsAllowed: fileEditsAllowed,
                parallelismLimit: dispatchParallelismLimit,
                mergeStrategy: mergeStrategy,
                wandPolicy: wandSelector.map { WandPolicy(selector: $0, routedModels: [:]) }
            )
            Haptics.success()
            onDispatched(result)
            dismiss()
        } catch {
            Haptics.error()
            withAnimation {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - View Extension

private extension View {
    @ViewBuilder
    func `if`<Transform: View>(_ condition: Bool, transform: (Self) -> Transform) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }
}
