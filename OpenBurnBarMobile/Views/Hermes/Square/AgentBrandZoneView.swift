import SwiftUI
import Observation
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import OpenBurnBarCore

// MARK: - Agent Brand Zone (Hermes Square §6.3)
//
// Per-agent canonical page — the "WeChat brand zone" applied to agents.
// Hero strip, quick actions, capability pills, last-7-days strip,
// persona slots, about / source / version / scopes.

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
    @State private var cliReader = CLIAgentChatReader.shared
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
        .background(EmberSurfaceBackground().ignoresSafeArea())
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
                    let message = await performForward(to: destination, note: note)
                    statusMessage = message
                }
            }
        }
        .sheet(isPresented: $showSubscribeSheet) {
            AgentBrandSubscribeSheet(
                identity: identity,
                existingTopic: subscriptionTopicStore.topic(agentURI: identity.id)
            ) { action in
                Task {
                    let message = await performSubscriptionAction(action)
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
                FlowLayout(spacing: 6) {
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
                    statBlock(label: "Threads",  value: "\(stats.threadCount)")
                    statBlock(label: "Missions", value: "\(stats.missionCount)")
                    statBlock(label: "Burn",     value: MissionConsoleFormatting.cost(stats.burnUSD))
                    statBlock(label: "Success",  value: String(format: "%.0f%%", stats.successRate * 100))
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

    // MARK: - Quick-action handlers

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
        case .claude, .codex, .openClaw:
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
        guard runtimeToken(for: identity) != nil else {
            statusMessage = "Forward isn't available for this agent transport yet."
            return
        }
        guard !isPreparingForward else { return }
        isPreparingForward = true
        HapticBus.primaryAction()
        Task {
            forwardContext = await forwardContextSnapshot()
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
            return runtime.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        case .nativeRelay, .httpGateway, .mcpServer:
            return nil
        }
    }

    private func forwardContextSnapshot() async -> AgentForwardContextSnapshot? {
        guard let runtime = identity.runtimeID else { return nil }
        switch runtime {
        case .hermes, .pi:
            guard let thread = MobileChatHistoryStore.shared.threads(for: runtime).first else { return nil }
            let preview = thread.preview.nilIfEmpty ?? thread.messages.last?.text.nilIfEmpty ?? "No preview available."
            return AgentForwardContextSnapshot(
                title: thread.title.nilIfEmpty ?? "(untitled)",
                preview: preview,
                sourceLabel: "mobile thread",
                updatedAt: thread.updatedAt
            )
        case .claude, .codex, .openClaw:
            guard let cliRuntime = CLIAgentRuntime(assistant: runtime) else { return nil }
            await cliReader.refresh()
            guard let session = cliReader.sessions(for: cliRuntime).first else { return nil }
            return AgentForwardContextSnapshot(
                title: session.title.nilIfEmpty ?? "(untitled)",
                preview: session.preview.nilIfEmpty ?? "No preview available.",
                sourceLabel: "Mac mirrored session",
                updatedAt: session.updatedAt
            )
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

    private func performSubscriptionAction(_ action: AgentBrandSubscribeSheet.Action) async -> String {
        do {
            switch action {
            case .subscribe(let cadence):
                let topic = try await subscriptionTopicStore.subscribe(agent: identity, cadence: cadence)
                return "Subscribed to \(topic.displayName)."
            case .unsubscribe:
                try await subscriptionTopicStore.unsubscribe(agentURI: identity.id)
                return "Unsubscribed from \(identity.displayName) updates."
            case .setMuted(let muted):
                try await subscriptionTopicStore.setMuted(agentURI: identity.id, muted: muted)
                return muted ? "Muted \(identity.displayName) updates." : "Unmuted \(identity.displayName) updates."
            }
        } catch {
            return error.localizedDescription
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
            return runtime.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
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
                        Text(context.preview)
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
    let onAction: (Action) -> Void

    @State private var cadence: AgentManifest.PushTopic.Cadence = .weekly

    enum Action {
        case subscribe(AgentManifest.PushTopic.Cadence)
        case unsubscribe
        case setMuted(Bool)
    }

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
                            onAction(.subscribe(cadence))
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }

    func trimmedOrFallback(_ fallback: String) -> String {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? fallback : trimmed
    }
}

struct AgentForwardContextSnapshot: Equatable, Sendable {
    let title: String
    let preview: String
    let sourceLabel: String
    let updatedAt: Date
}

enum AgentBrandQuickActionComposer {
    static let defaultSubscriptionTopicID = "agent-updates"

    static func defaultSubscriptionTopic(
        for identity: AgentIdentity,
        cadence: AgentManifest.PushTopic.Cadence,
        now: Date = Date()
    ) -> SubscriptionTopic {
        SubscriptionTopic(
            agentURI: identity.id,
            topicID: defaultSubscriptionTopicID,
            displayName: "\(identity.displayName) updates",
            description: identity.tier == .subscription
                ? "Scheduled updates from \(identity.displayName)."
                : "Mission and thread activity digests from \(identity.displayName).",
            cadence: cadence,
            consentGivenAt: now,
            isMuted: false,
            deliveryCountThisMonth: 0,
            lastDeliveredAt: nil
        )
    }

    static func newThreadKickoffPrompt(for identity: AgentIdentity) -> String {
        """
        Start a new \(identity.displayName) thread.
        1) Ask me for the exact objective, constraints, and success criteria.
        2) Confirm the target project/path before doing any tool actions.
        3) Wait for my go-ahead.
        """
    }

    static func forwardPrompt(
        source: AgentIdentity,
        destination: AgentIdentity,
        context: AgentForwardContextSnapshot?,
        note: String,
        now: Date = Date()
    ) -> String {
        let noteLine = note.trimmingCharacters(in: .whitespacesAndNewlines)
        let timestamp = iso8601String(from: now)

        var sections: [String] = []
        sections.append("Forwarded from \(source.displayName) to \(destination.displayName) at \(timestamp).")

        if let context {
            sections.append(
                """
                Source context (\(context.sourceLabel)):
                - Title: \(context.title)
                - Preview: \(context.preview)
                - Updated: \(iso8601String(from: context.updatedAt))
                """
            )
        } else {
            sections.append("No thread transcript was available from \(source.displayName); use this as a fresh continuation request.")
        }

        if !noteLine.isEmpty {
            sections.append("Operator note: \(noteLine)")
        }

        sections.append(
            """
            Continue this work as a new thread.
            If anything is ambiguous, ask concise clarifying questions first.
            """
        )

        return sections.joined(separator: "\n\n")
    }

    private static func iso8601String(from date: Date) -> String {
        ISO8601DateFormatter.string(
            from: date,
            timeZone: TimeZone(secondsFromGMT: 0) ?? .current,
            formatOptions: [.withInternetDateTime]
        )
    }
}

@MainActor
@Observable
final class AgentSubscriptionTopicStore {
    static let shared = AgentSubscriptionTopicStore()

    private(set) var topics: [SubscriptionTopic] = []
    private(set) var isLoading: Bool = false
    private(set) var lastError: String?

    private let firestoreProvider: () -> Firestore
    private var authListenerHandle: AuthStateDidChangeListenerHandle?
    private var topicsListener: ListenerRegistration?

    init(firestoreProvider: @escaping () -> Firestore = { Firestore.firestore() }) {
        self.firestoreProvider = firestoreProvider
    }

    func bootstrap() {
        guard authListenerHandle == nil else { return }
        guard FirebaseApp.app() != nil else {
            topics = []
            lastError = nil
            return
        }
        authListenerHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.restartRealtimeListener(uid: user?.uid)
            }
        }
        restartRealtimeListener(uid: Auth.auth().currentUser?.uid)
    }

    func refresh() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        guard FirebaseApp.app() != nil else {
            topics = []
            lastError = nil
            return
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            topics = []
            lastError = nil
            return
        }

        do {
            let snapshot = try await collection(uid: uid)
                .order(by: "consentGivenAt", descending: true)
                .getDocuments()
            topics = snapshot.documents.compactMap { Self.decodeTopic(documentID: $0.documentID, data: $0.data()) }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    func topic(
        agentURI: String,
        topicID: String = AgentBrandQuickActionComposer.defaultSubscriptionTopicID
    ) -> SubscriptionTopic? {
        topics.first { $0.agentURI == agentURI && $0.topicID == topicID }
    }

    func isSubscribed(
        agentURI: String,
        topicID: String = AgentBrandQuickActionComposer.defaultSubscriptionTopicID
    ) -> Bool {
        topic(agentURI: agentURI, topicID: topicID) != nil
    }

    func subscribe(
        agent: AgentIdentity,
        cadence: AgentManifest.PushTopic.Cadence
    ) async throws -> SubscriptionTopic {
        let topic = AgentBrandQuickActionComposer.defaultSubscriptionTopic(
            for: agent,
            cadence: cadence
        )
        try await upsert(topic)
        return topic
    }

    func upsert(_ topic: SubscriptionTopic) async throws {
        let uid = try currentUserID()
        var payload = Self.encodeTopic(topic)
        payload["updatedAt"] = FieldValue.serverTimestamp()
        try await collection(uid: uid).document(topic.id).setData(payload, merge: true)
        mergeLocal(topic)
        lastError = nil
    }

    func unsubscribe(
        agentURI: String,
        topicID: String = AgentBrandQuickActionComposer.defaultSubscriptionTopicID
    ) async throws {
        let uid = try currentUserID()
        let id = "\(agentURI):\(topicID)"
        try await collection(uid: uid).document(id).delete()
        topics.removeAll { $0.id == id }
        lastError = nil
    }

    func setMuted(
        agentURI: String,
        topicID: String = AgentBrandQuickActionComposer.defaultSubscriptionTopicID,
        muted: Bool
    ) async throws {
        let uid = try currentUserID()
        let id = "\(agentURI):\(topicID)"
        try await collection(uid: uid).document(id).setData([
            "isMuted": muted,
            "updatedAt": FieldValue.serverTimestamp()
        ], merge: true)

        guard let existing = topics.first(where: { $0.id == id }) else { return }
        let updated = SubscriptionTopic(
            agentURI: existing.agentURI,
            topicID: existing.topicID,
            displayName: existing.displayName,
            description: existing.description,
            cadence: existing.cadence,
            consentGivenAt: existing.consentGivenAt,
            isMuted: muted,
            deliveryCountThisMonth: existing.deliveryCountThisMonth,
            lastDeliveredAt: existing.lastDeliveredAt
        )
        mergeLocal(updated)
        lastError = nil
    }

    // MARK: - Internals

    private func restartRealtimeListener(uid: String?) {
        topicsListener?.remove()
        topicsListener = nil

        guard FirebaseApp.app() != nil, let uid else {
            topics = []
            lastError = nil
            return
        }

        topicsListener = collection(uid: uid)
            .order(by: "consentGivenAt", descending: true)
            .addSnapshotListener { [weak self] snapshot, error in
                Task { @MainActor in
                    if let error {
                        self?.lastError = error.localizedDescription
                        return
                    }
                    guard let snapshot else { return }
                    self?.topics = snapshot.documents.compactMap {
                        Self.decodeTopic(documentID: $0.documentID, data: $0.data())
                    }
                    self?.lastError = nil
                }
            }
    }

    private func currentUserID() throws -> String {
        guard FirebaseApp.app() != nil else {
            throw StoreError.firebaseUnavailable
        }
        guard let uid = Auth.auth().currentUser?.uid else {
            throw StoreError.notAuthenticated
        }
        return uid
    }

    private func mergeLocal(_ topic: SubscriptionTopic) {
        if let idx = topics.firstIndex(where: { $0.id == topic.id }) {
            topics[idx] = topic
        } else {
            topics.append(topic)
        }
        topics.sort {
            ($0.consentGivenAt ?? .distantPast) > ($1.consentGivenAt ?? .distantPast)
        }
    }

    private func collection(uid: String) -> CollectionReference {
        firestoreProvider()
            .collection("users").document(uid)
            .collection("subscription_topics")
    }

    private static func encodeTopic(_ topic: SubscriptionTopic) -> [String: Any] {
        [
            "agentURI": topic.agentURI,
            "topicID": topic.topicID,
            "displayName": topic.displayName,
            "description": topic.description,
            "cadence": topic.cadence.rawValue,
            "consentGivenAt": topic.consentGivenAt ?? NSNull(),
            "isMuted": topic.isMuted,
            "deliveryCountThisMonth": topic.deliveryCountThisMonth,
            "lastDeliveredAt": topic.lastDeliveredAt ?? NSNull()
        ]
    }

    private static func decodeTopic(documentID: String, data: [String: Any]) -> SubscriptionTopic? {
        let agentURI = (data["agentURI"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let topicID = (data["topicID"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let displayName = (data["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description = (data["description"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !agentURI.isEmpty, !topicID.isEmpty else { return nil }

        let cadenceRaw = (data["cadence"] as? String) ?? AgentManifest.PushTopic.Cadence.weekly.rawValue
        let cadence = AgentManifest.PushTopic.Cadence(rawValue: cadenceRaw) ?? .weekly
        let consentGivenAt = decodeDate(data["consentGivenAt"])
        let isMuted = (data["isMuted"] as? Bool) ?? false
        let deliveryCount = (data["deliveryCountThisMonth"] as? Int) ?? 0
        let lastDeliveredAt = decodeDate(data["lastDeliveredAt"])

        let topic = SubscriptionTopic(
            agentURI: agentURI,
            topicID: topicID,
            displayName: displayName.isEmpty ? documentID : displayName,
            description: description,
            cadence: cadence,
            consentGivenAt: consentGivenAt,
            isMuted: isMuted,
            deliveryCountThisMonth: deliveryCount,
            lastDeliveredAt: lastDeliveredAt
        )
        return topic
    }

    private static func decodeDate(_ raw: Any?) -> Date? {
        if raw is NSNull { return nil }
        if let ts = raw as? Timestamp { return ts.dateValue() }
        if let date = raw as? Date { return date }
        if let str = raw as? String {
            return ISO8601DateFormatter().date(from: str)
        }
        return nil
    }

    enum StoreError: LocalizedError {
        case firebaseUnavailable
        case notAuthenticated

        var errorDescription: String? {
            switch self {
            case .firebaseUnavailable:
                return "Firebase is not configured on this device."
            case .notAuthenticated:
                return "Sign in to manage subscription topics."
            }
        }
    }
}

// MARK: - Minimal FlowLayout shim (capability pills)

private struct FlowLayout: Layout {
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
