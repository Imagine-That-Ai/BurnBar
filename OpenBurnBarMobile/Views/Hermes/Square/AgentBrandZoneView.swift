import SwiftUI
import OpenBurnBarCore

// MARK: - Agent Brand Zone (Hermes Square §6.3)
//
// Per-agent canonical page — the "WeChat brand zone" applied to agents.
// Hero strip, quick actions, capability pills, last-7-days strip,
// persona slots, about / source / version / scopes.
//
// Persistence/networking lives in `AgentBrandZoneStore` and
// `AgentSubscriptionTopicStore` (Services); this view renders state and
// sends intents only (audit wave 4, item 15).

struct AgentBrandZoneView: View {
    let identity: AgentIdentity
    @Bindable var registry: AgentIdentityRegistry
    let missionHost: MobileMissionConsoleHost
    let onOpenRuntimeThread: ((AssistantRuntimeID) -> Void)?
    let onOpenRuntimeList: ((AssistantRuntimeID) -> Void)?

    @Environment(\.motionStore) private var motionStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showDispatchSheet = false
    @State private var showForwardSheet = false
    @State private var showSubscribeSheet = false
    @State private var dispatchPreset: AgentBrandDispatchPreset = .manual
    @State private var forwardContext: AgentForwardContextSnapshot?
    @State private var isPreparingForward = false
    @State private var statusMessage: String?
    @State private var brandZoneStore = AgentBrandZoneStore()
    @State private var subscriptionTopicStore = AgentSubscriptionTopicStore.shared

    private var accent: Color { Color(hex: identity.paletteHex) }

    /// How much the hero avatar drifts at full device tilt. Subtle — we
    /// want the parallax to be felt, not seen.
    private let heroParallaxIntensity: CGFloat = 10

    /// The gradient backdrop moves opposite to the avatar at half the
    /// intensity for a layered, depth-of-field feel.
    private let backdropParallaxIntensity: CGFloat = 6

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                hero
                quickActions
                capabilities
                lastSevenDays
                personas
                about
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
        }
        .background(AuroraBackdrop().ignoresSafeArea())
        .navigationTitle(identity.displayName)
        .navigationBarTitleDisplayMode(.inline)
        // Acquire / release the motion stream while this brand zone is
        // on-screen so the gyroscope only runs when we're actually
        // rendering the parallax.
        .onAppear { motionStore.acquire(reduceMotion: reduceMotion) }
        .onDisappear { motionStore.release() }
        .task {
            subscriptionTopicStore.bootstrap()
            await subscriptionTopicStore.refresh()
        }
        .sheet(isPresented: $showDispatchSheet) {
            AgentBrandDispatchSheet(
                identity: identity,
                missionHost: missionHost,
                preset: dispatchPreset
            ) { message in
                statusMessage = message
            }
        }
        .sheet(isPresented: $showForwardSheet) {
            AgentBrandForwardSheet(
                source: identity,
                registry: registry,
                context: forwardContext
            ) { destination, note in
                Task {
                    let result = await brandZoneStore.forward(
                        source: identity,
                        destination: destination,
                        context: forwardContext,
                        note: note,
                        missionHost: missionHost,
                        directThreadHandoffAvailable: onOpenRuntimeThread != nil
                    )
                    switch result.resolution {
                    case .openRuntimeThread(let runtime):
                        onOpenRuntimeThread?(runtime)
                    case .openRuntimeList(let runtime):
                        onOpenRuntimeList?(runtime)
                    case .none:
                        break
                    }
                    statusMessage = result.message
                }
            }
        }
        .sheet(isPresented: $showSubscribeSheet) {
            AgentBrandSubscribeSheet(
                identity: identity,
                existingTopic: subscriptionTopicStore.topic(agentURI: identity.id)
            ) { action in
                Task {
                    let message = await brandZoneStore.performSubscriptionAction(action, identity: identity)
                    statusMessage = message
                }
            }
        }
        .alert("Agent action", isPresented: Binding(
            get: { statusMessage != nil },
            set: { if !$0 { statusMessage = nil } }
        )) {
            Button("OK", role: .cancel) { statusMessage = nil }
        } message: {
            Text(statusMessage ?? "")
        }
    }

    // MARK: Hero

    private var hero: some View {
        HStack(spacing: 14) {
            ZStack {
                // Backdrop gradient ring drifts opposite to the avatar
                // for a depth-of-field layered feel. Honors Reduce
                // Motion via the modifier.
                Circle()
                    .fill(
                        RadialGradient(
                            colors: [accent.opacity(0.32), accent.opacity(0.06), .clear],
                            center: .center,
                            startRadius: 4,
                            endRadius: 56
                        )
                    )
                    .frame(width: 92, height: 92)
                    .offset(parallaxOffset(intensity: -backdropParallaxIntensity))
                // Real brand logo (bundled asset) replaces the gradient
                // disc + glyph for built-in runtimes. User-installed
                // agents whose vendor doesn't match a known provider
                // fall back to the gradient-and-glyph treatment inside
                // `HermesSquareAgentAvatar`.
                HermesSquareAgentAvatar(
                    identity: identity,
                    size: 64,
                    showAvailability: false,
                    ringStroke: true
                )
                .offset(parallaxOffset(intensity: heroParallaxIntensity))
            }
            .frame(width: 92, height: 92)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(identity.displayName)
                        .font(.title2.bold())
                        .foregroundStyle(DesignSystemColors.textPrimary)
                    Text(identity.tier.displayLabel)
                        .font(.caption2.bold())
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(accent.opacity(0.18)))
                        .foregroundStyle(accent)
                }
                HStack(spacing: 6) {
                    Circle()
                        .fill(availabilityColor)
                        .frame(width: 7, height: 7)
                    Text(identity.availability.displayLabel)
                        .font(.caption.monospaced())
                        .foregroundStyle(DesignSystemColors.textMuted)
                }
                if let tagline = identity.tagline {
                    Text(tagline)
                        .font(.callout)
                        .foregroundStyle(DesignSystemColors.textSecondary)
                }
            }
            Spacer()
        }
    }

    private var availabilityColor: Color {
        switch identity.availability {
        case .online:    return DesignSystemColors.success
        case .degraded:  return DesignSystemColors.warning
        case .offline:   return DesignSystemColors.error
        case .unknown:   return DesignSystemColors.textMuted
        }
    }

    /// CGSize derived from the shared `MotionStore`'s tilt. Reduce Motion
    /// zeroes this out automatically.
    private func parallaxOffset(intensity: CGFloat) -> CGSize {
        guard !reduceMotion else { return .zero }
        return CGSize(
            width: motionStore.tilt.width * intensity,
            height: motionStore.tilt.height * intensity
        )
    }

    // MARK: Quick actions

    private var quickActions: some View {
        HStack(spacing: 8) {
            quickAction(label: "New thread", systemImage: "plus.bubble", action: handleNewThread)
            quickAction(label: "Dispatch", systemImage: "paperplane.fill", action: handleDispatch)
            quickAction(
                label: isPreparingForward ? "Loading…" : "Forward",
                systemImage: "arrowshape.turn.up.right.fill",
                action: handleForward
            )
            quickAction(label: "Subscribe", systemImage: "bell.fill", action: handleSubscribe)
        }
    }

    private func quickAction(label: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.callout)
                    .foregroundStyle(accent)
                Text(label)
                    .font(.caption2.bold())
                    .foregroundStyle(DesignSystemColors.textPrimary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(DesignSystemColors.surface.opacity(0.6))
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: Capability pills

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Capabilities")
                .font(.caption.bold())
                .foregroundStyle(DesignSystemColors.textSecondary)
            let pills = identity.capabilities.displayPills
            if pills.isEmpty {
                Text("No declared capabilities yet.")
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
            } else {
                AgentBrandFlowLayout(spacing: 6) {
                    ForEach(pills, id: \.self) { pill in
                        Text(pill)
                            .font(.caption.bold())
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(
                                Capsule().fill(accent.opacity(0.14))
                            )
                            .foregroundStyle(accent)
                    }
                }
            }
        }
    }

    // MARK: Last 7 days

    private var lastSevenDays: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Last 7 days")
                .font(.caption.bold())
                .foregroundStyle(DesignSystemColors.textSecondary)
            if let stats = identity.lastSevenDays {
                HStack(spacing: 16) {
                    statBlock(label: "Threads", value: "\(stats.threadCount)")
                    statBlock(label: "Missions", value: "\(stats.missionCount)")
                    statBlock(label: "Burn", value: MissionConsoleFormatting.cost(stats.burnUSD))
                    statBlock(label: "Success", value: String(format: "%.0f%%", stats.successRate * 100))
                }
            } else {
                Text("No telemetry yet — start a thread or dispatch a mission.")
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
            }
        }
    }

    private func statBlock(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(DesignSystemColors.textMuted)
            Text(value).font(.callout.bold()).foregroundStyle(DesignSystemColors.textPrimary)
        }
    }

    // MARK: Personas

    private var personas: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Personas")
                .font(.caption.bold())
                .foregroundStyle(DesignSystemColors.textSecondary)
            if identity.personas.isEmpty {
                Text("Default persona only.")
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
            } else {
                ForEach(identity.personas) { persona in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(persona.name).font(.callout.bold())
                                    .foregroundStyle(DesignSystemColors.textPrimary)
                                if persona.isDefault {
                                    Text("default")
                                        .font(.caption2.bold())
                                        .padding(.horizontal, 6)
                                        .padding(.vertical, 1)
                                        .background(Capsule().fill(accent.opacity(0.16)))
                                        .foregroundStyle(accent)
                                }
                            }
                            Text(persona.description)
                                .font(.caption)
                                .foregroundStyle(DesignSystemColors.textMuted)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(DesignSystemColors.surface.opacity(0.5))
                    )
                }
            }
        }
    }

    // MARK: About

    private var about: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("About")
                .font(.caption.bold())
                .foregroundStyle(DesignSystemColors.textSecondary)
            VStack(alignment: .leading, spacing: 4) {
                row(label: "URI", value: identity.id)
                row(label: "Install", value: identity.installSource.displayLabel)
                row(label: "Transport", value: identity.dispatchTransport.displayLabel)
                if let lastRefreshedAt = identity.lastRefreshedAt {
                    row(label: "Last refreshed", value: MissionConsoleFormatting.relativeTime(lastRefreshedAt))
                }
            }
        }
    }

    private func row(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(label)
                .font(.caption.bold())
                .foregroundStyle(DesignSystemColors.textMuted)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .foregroundStyle(DesignSystemColors.textSecondary)
                .multilineTextAlignment(.leading)
            Spacer()
        }
    }

    // MARK: - Quick-action handlers (intent dispatch only)

    private func handleNewThread() {
        guard let runtime = identity.runtimeID else {
            dispatchPreset = .newThread
            showDispatchSheet = true
            return
        }
        switch runtime {
        case .hermes, .pi:
            if let onOpenRuntimeThread {
                onOpenRuntimeThread(runtime)
                HapticBus.primaryAction()
            } else {
                dispatchPreset = .newThread
                showDispatchSheet = true
            }
        case .claude, .codex, .openClaw, .droid, .forge, .antigravity, .grok, .cursorAgent, .openClaude, .omp,
             .junie, .fx:
            dispatchPreset = .newThread
            showDispatchSheet = true
        }
    }

    private func handleDispatch() {
        dispatchPreset = .manual
        showDispatchSheet = true
        HapticBus.primaryAction()
    }

    private func handleForward() {
        guard AgentBrandZoneStore.runtimeToken(for: identity) != nil else {
            statusMessage = "Forward isn't available for this agent transport yet."
            return
        }
        guard !isPreparingForward else { return }
        isPreparingForward = true
        HapticBus.primaryAction()
        Task {
            forwardContext = await brandZoneStore.forwardContextSnapshot(for: identity)
            isPreparingForward = false
            showForwardSheet = true
        }
    }

    private func handleSubscribe() {
        showSubscribeSheet = true
        HapticBus.primaryAction()
    }

    private func runtimeToken(for identity: AgentIdentity) -> String? {
        if let runtime = identity.runtimeID {
            return runtime.rawValue
        }
        switch identity.dispatchTransport {
        case .macRelay(let runtime):
            return runtime.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlankPreservingWhitespace
        case .nativeRelay, .httpGateway, .mcpServer:
            return nil
        }
    }

    private func performForward(to destination: AgentIdentity, note: String) async -> String {
        let prompt = AgentBrandQuickActionComposer.forwardPrompt(
            source: identity,
            destination: destination,
            context: forwardContext,
            note: note
        )

        if let runtime = destination.runtimeID,
           [.hermes, .pi].contains(runtime),
           let onOpenRuntimeThread {
            AssistantPendingPrompt.shared.stash(assistant: runtime, prompt: prompt)
            onOpenRuntimeThread(runtime)
            return "Forwarded to \(destination.displayName) and opened a new thread."
        }

        guard let runtimeID = runtimeToken(for: destination) else {
            return "Couldn't resolve a dispatch runtime for \(destination.displayName)."
        }

        let request = MissionConsoleDispatchRequest(
            title: "Forward · \(identity.displayName) → \(destination.displayName)",
            prompt: prompt,
            kind: .diligence,
            runtimeID: runtimeID,
            targetProject: nil,
            depth: .standard,
            approvalMode: .existingPolicy,
            commandsAllowed: false,
            fileEditsAllowed: false
        )
        switch await missionHost.dispatch(request) {
        case .dispatched(let missionID):
            if let runtime = destination.runtimeID {
                onOpenRuntimeList?(runtime)
            }
            return "Forwarded to \(destination.displayName). Mission queued (\(missionID))."
        case .failed(let message):
            return "Forward failed: \(message)"
        }
    }

}

private enum AgentBrandDispatchPreset {
    case manual
    case newThread
}

private struct AgentBrandDispatchSheet: View {
    @Environment(\.dismiss) private var dismiss

    let identity: AgentIdentity
    let missionHost: MobileMissionConsoleHost
    let preset: AgentBrandDispatchPreset
    let onFinished: (String) -> Void

    @State private var title: String
    @State private var prompt: String
    @State private var kind: MissionConsoleKind = .diligence
    @State private var depth: MissionConsoleDepth = .standard
    @State private var approvalMode: MissionConsoleApprovalMode = .existingPolicy
    @State private var commandsAllowed: Bool = false
    @State private var fileEditsAllowed: Bool = false
    @State private var dispatching: Bool = false
    @State private var inlineError: String?

    init(
        identity: AgentIdentity,
        missionHost: MobileMissionConsoleHost,
        preset: AgentBrandDispatchPreset,
        onFinished: @escaping (String) -> Void
    ) {
        self.identity = identity
        self.missionHost = missionHost
        self.preset = preset
        self.onFinished = onFinished
        switch preset {
        case .manual:
            _title = State(initialValue: "")
            _prompt = State(initialValue: "")
        case .newThread:
            _title = State(initialValue: "New \(identity.displayName) thread")
            _prompt = State(initialValue: AgentBrandQuickActionComposer.newThreadKickoffPrompt(for: identity))
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Brief")) {
                    TextField("Title (optional)", text: $title)
                    TextEditor(text: $prompt)
                        .frame(minHeight: 100)
                        .overlay(alignment: .topLeading) {
                            if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("What should \(identity.displayName) do?")
                                    .foregroundStyle(DesignSystemColors.textMuted)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                            }
                        }
                }

                Section(header: Text("Mission")) {
                    Picker("Kind", selection: $kind) {
                        ForEach(MissionConsoleKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    Picker("Depth", selection: $depth) {
                        ForEach(MissionConsoleDepth.allCases) { depth in
                            Text(depth.displayName).tag(depth)
                        }
                    }
                    Picker("Approvals", selection: $approvalMode) {
                        ForEach(MissionConsoleApprovalMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    Toggle("Allow shell commands", isOn: $commandsAllowed)
                    Toggle("Allow file edits", isOn: $fileEditsAllowed)
                }

                if let forecast {
                    Section(header: Text("Forecast")) {
                        HStack {
                            Text("Tokens")
                            Spacer()
                            Text(MissionConsoleFormatting.tokenRange(forecast.tokensLow, forecast.tokensHigh))
                                .monospacedDigit()
                        }
                        HStack {
                            Text("Cost")
                            Spacer()
                            Text(MissionConsoleFormatting.costRange(forecast.costLowUSD, forecast.costHighUSD))
                                .monospacedDigit()
                        }
                        HStack {
                            Text("ETA")
                            Spacer()
                            Text(MissionConsoleFormatting.durationRange(forecast.etaLow, forecast.etaHigh))
                                .monospacedDigit()
                        }
                    }
                }

                if let inlineError {
                    Section {
                        Text(inlineError)
                            .font(.caption)
                            .foregroundStyle(DesignSystemColors.error)
                    }
                }
            }
            .navigationTitle("Dispatch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if dispatching {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Dispatch") { Task { await dispatch() } }
                            .disabled(!canDispatch)
                    }
                }
            }
        }
    }

    private var runtimeID: String? {
        if let runtime = identity.runtimeID {
            return runtime.rawValue
        }
        if case .macRelay(let runtime) = identity.dispatchTransport {
            return runtime.trimmingCharacters(in: .whitespacesAndNewlines).nilIfBlankPreservingWhitespace
        }
        return nil
    }

    private var canDispatch: Bool {
        runtimeID != nil && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var runtimeForForecast: MissionConsoleRuntime? {
        guard let runtimeID else { return nil }
        if let existing = missionHost.snapshot.runtimes.first(where: { $0.id == runtimeID }) {
            return existing
        }
        return MissionConsoleRuntime(
            id: runtimeID,
            displayName: identity.displayName,
            callSign: String(runtimeID.prefix(3)).uppercased(),
            provider: .factory,
            availability: .unknown,
            recentMedianBurnUSD: nil,
            recentSampleSize: 0,
            tagline: identity.tagline,
            pricingFactor: 1.0
        )
    }

    private var forecast: MissionConsoleForecast? {
        guard let runtimeID, let runtime = runtimeForForecast else { return nil }
        let draft = MissionConsoleDispatchRequest(
            title: title.trimmedOrFallback("Mission"),
            prompt: prompt,
            kind: kind,
            runtimeID: runtimeID,
            targetProject: nil,
            depth: depth,
            approvalMode: approvalMode,
            commandsAllowed: commandsAllowed,
            fileEditsAllowed: fileEditsAllowed
        )
        return MissionConsoleForecastComputer.forecast(for: draft, runtime: runtime)
    }

    private func dispatch() async {
        guard let runtimeID else {
            inlineError = "This agent doesn't expose a dispatch runtime."
            return
        }
        dispatching = true
        inlineError = nil
        let request = MissionConsoleDispatchRequest(
            title: title.trimmedOrFallback("Mission · \(identity.displayName)"),
            prompt: prompt,
            kind: kind,
            runtimeID: runtimeID,
            targetProject: nil,
            depth: depth,
            approvalMode: approvalMode,
            commandsAllowed: commandsAllowed,
            fileEditsAllowed: fileEditsAllowed
        )
        let outcome = await missionHost.dispatch(request)
        dispatching = false
        switch outcome {
        case .dispatched(let missionID):
            onFinished("Dispatched to \(identity.displayName). Mission queued (\(missionID)).")
            dismiss()
        case .failed(let message):
            inlineError = message
        }
    }
}

private struct AgentBrandForwardSheet: View {
    @Environment(\.dismiss) private var dismiss

    let source: AgentIdentity
    @Bindable var registry: AgentIdentityRegistry
    let context: AgentForwardContextSnapshot?
    let onForward: (AgentIdentity, String) -> Void

    @State private var destinationURI: String = ""
    @State private var note: String = ""

    private var destinations: [AgentIdentity] {
        registry.identities.filter { candidate in
            candidate.id != source.id && candidate.runtimeID != nil
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Destination")) {
                    Picker("Agent", selection: $destinationURI) {
                        ForEach(destinations, id: \.id) { identity in
                            Text(identity.displayName).tag(identity.id)
                        }
                    }
                    .onAppear {
                        if destinationURI.isEmpty {
                            destinationURI = destinations.first?.id ?? ""
                        }
                    }
                }

                if let context {
                    Section(header: Text("Source context")) {
                        Text(context.title)
                            .font(.callout.bold())
                        Text(HermesAtomParser.plainText(context.preview))
                            .font(.caption)
                            .foregroundStyle(DesignSystemColors.textMuted)
                        Text("Updated \(MissionConsoleFormatting.relativeTime(context.updatedAt))")
                            .font(.caption2)
                            .foregroundStyle(DesignSystemColors.textMuted)
                    }
                } else {
                    Section {
                        Text("No recent thread transcript found. We'll forward as a fresh continuation request.")
                            .font(.caption)
                            .foregroundStyle(DesignSystemColors.textMuted)
                    }
                }

                Section(header: Text("Operator note")) {
                    TextEditor(text: $note)
                        .frame(minHeight: 90)
                        .overlay(alignment: .topLeading) {
                            if note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                                Text("Optional instruction to include with the forward")
                                    .foregroundStyle(DesignSystemColors.textMuted)
                                    .padding(.top, 8)
                                    .padding(.leading, 4)
                            }
                        }
                }
            }
            .navigationTitle("Forward")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Forward") {
                        guard let destination = destinations.first(where: { $0.id == destinationURI }) else { return }
                        onForward(destination, note)
                        dismiss()
                    }
                    .disabled(destinations.isEmpty || destinationURI.isEmpty)
                }
            }
        }
    }
}

private struct AgentBrandSubscribeSheet: View {
    @Environment(\.dismiss) private var dismiss

    let identity: AgentIdentity
    let existingTopic: SubscriptionTopic?
    let onAction: (AgentSubscriptionAction) -> Void

    @State private var cadence: AgentManifest.PushTopic.Cadence = .weekly
    @State private var deliveryMode: SkillRunDeliveryMode = .actionOnly

    var body: some View {
        NavigationStack {
            Form {
                if let existingTopic {
                    Section(header: Text("Current subscription")) {
                        Text(existingTopic.displayName)
                            .font(.callout.bold())
                        Text(existingTopic.description)
                            .font(.caption)
                            .foregroundStyle(DesignSystemColors.textMuted)
                        Picker("Delivery", selection: Binding(
                            get: { existingTopic.deliveryMode },
                            set: { newMode in
                                onAction(.setDeliveryMode(newMode))
                                dismiss()
                            }
                        )) {
                            ForEach(SkillRunDeliveryMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        Button(existingTopic.isMuted ? "Unmute updates" : "Mute updates") {
                            onAction(.setMuted(!existingTopic.isMuted))
                            dismiss()
                        }
                        Button("Unsubscribe", role: .destructive) {
                            onAction(.unsubscribe)
                            dismiss()
                        }
                    }
                } else {
                    Section(header: Text("Cadence")) {
                        Picker("Delivery cadence", selection: $cadence) {
                            Text("On demand").tag(AgentManifest.PushTopic.Cadence.onDemand)
                            Text("Daily").tag(AgentManifest.PushTopic.Cadence.daily)
                            Text("Weekly").tag(AgentManifest.PushTopic.Cadence.weekly)
                            Text("Monthly").tag(AgentManifest.PushTopic.Cadence.monthly)
                        }
                    }
                    Section(header: Text("Delivery")) {
                        Picker("Skill Run updates", selection: $deliveryMode) {
                            ForEach(SkillRunDeliveryMode.allCases) { mode in
                                Text(mode.displayName).tag(mode)
                            }
                        }
                        Text(deliveryMode.description)
                            .font(.caption)
                            .foregroundStyle(DesignSystemColors.textMuted)
                    }
                    Section {
                        Text("Subscription topics are stored in your account and shared with your paired Mac.")
                            .font(.caption)
                            .foregroundStyle(DesignSystemColors.textMuted)
                    }
                }
            }
            .navigationTitle("Subscribe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                if existingTopic == nil {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Subscribe") {
                            onAction(.subscribe(cadence, deliveryMode))
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

private extension String {

    func trimmedOrFallback(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

// MARK: - Minimal FlowLayout shim (capability pills)

private struct AgentBrandFlowLayout: Layout {
    var spacing: CGFloat

    init(spacing: CGFloat = 6) {
        self.spacing = spacing
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalHeight: CGFloat = 0
        var totalWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth + size.width > maxWidth {
                totalHeight += rowHeight + spacing
                totalWidth = max(totalWidth, rowWidth)
                rowWidth = size.width + spacing
                rowHeight = size.height
            } else {
                rowWidth += size.width + spacing
                rowHeight = max(rowHeight, size.height)
            }
        }
        totalHeight += rowHeight
        totalWidth = max(totalWidth, rowWidth)
        return CGSize(width: totalWidth, height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
