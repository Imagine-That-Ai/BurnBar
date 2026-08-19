import SwiftUI
import OpenBurnBarKernel

// MARK: - Plasma model selector
//
// The control that replaced the flat `Menu` on every chat surface: a living
// plasma orb that opens the ghostly liquid-glass bubble holding the three-rung
// cascade (`PlasmaModelLadder`).
//
// The bubble opens on rung 3 — the model — because that is what a *model*
// selector is for, and making the common case cost two extra clicks would be a
// worse control no matter how it looked. The breadcrumb above the rows keeps
// all three rungs one click away, which is strictly more reachable than the old
// menu: agent switching used to live in a different control entirely.

struct PlasmaModelSelector: View {
    @Bindable var controller: ChatSessionController
    var labelWidth: CGFloat = 120

    @State private var isOpen = false
    @State private var level: PlasmaLadderLevel = .model
    @State private var groupID: String?
    @State private var isHovering = false
    @State private var quotaService = ProviderQuotaService.shared

    private var settingsManager: SettingsManager { controller.settingsManager }
    private var backend: ChatBackendID { controller.chatBackend }
    private var catalog: CLIRuntimeModelCatalogCache { controller.agentDeck.modelCatalog }
    private var presenceModel: AgentPresenceModel { controller.agentDeck.presence }
    private var tint: Color { backend.sigilTint }

    var body: some View {
        Button(action: open) {
            label
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("Model: \(modelLabel)")
        .accessibilityHint("Opens the agent, provider and model ladder")
        .accessibilityAddTraits(.isButton)
        .popoverTooltip("Model for \(backend.displayName). Each agent remembers its own choice.")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            bubble
                .presentationBackground(.clear)
        }
        .task(id: backend) {
            await catalog.refreshIfNeeded(
                runtime: ChatEngineModelMenu.cliRuntime(for: backend),
                settingsManager: settingsManager
            )
        }
        .task(id: controller.isElderWandActive) {
            if controller.isElderWandActive {
                await controller.probeBurnBarGatewayAvailability()
            }
        }
        .onChange(of: backend) { _, _ in groupID = nil }
    }

    // MARK: Trigger

    private var label: some View {
        HStack(spacing: 5) {
            PlasmaOrb(
                tint: tint,
                size: 16,
                motion: .orbSecondary,
                isAnimating: orbIsAlive
            )
            Text(modelLabel)
                .font(.system(size: 9.5, weight: .semibold, design: .rounded))
                // Never the agent tint. The Containment Law
                // (`DashboardChatWorkspaceToolbar.swift:23`) keeps `sigilTint`
                // off body text, and it is right to: several of the twelve are
                // mid-tones that miss 4.5:1 against the app background at 9.5pt.
                // The orb one gap to the left is already a saturated blob of
                // exactly this colour, so the identity is not lost — only the
                // illegibility is.
                .foregroundStyle(DesignSystem.Colors.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: labelWidth, alignment: .leading)
            Image(systemName: "chevron.down")
                .font(.system(size: 7, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .rotationEffect(.degrees(isOpen ? 180 : 0))
        }
        .contentShape(Rectangle())
        .fixedSize()
        .animation(DesignSystem.Animation.snappy, value: isOpen)
        .animation(DesignSystem.Animation.snappy, value: modelLabel)
    }

    /// Idle chrome stays still (see `PlasmaSelectorChrome`); the orb comes to
    /// life while the ladder is open, while the pointer is on it, and while the
    /// agent is actually answering.
    private var orbIsAlive: Bool {
        isOpen || isHovering || controller.isStreaming
    }

    var modelLabel: String {
        AgentSigil.modelLabel(
            backend: backend,
            effectiveModel: controller.effectiveChatModel(for: backend),
            selectedHermesFamily: settingsManager.selectedHermesModel,
            isElderWandActive: controller.isElderWandActive
        )
    }

    // MARK: Bubble

    private var bubble: some View {
        // Derive the whole ladder exactly once. `groups` walks the live catalog
        // and regroups it, and the bubble's morph re-evaluates this closure at
        // 30fps, so a computed property read from six call sites would rebuild
        // the catalog hundreds of times a second for a popover that is showing
        // a static list.
        let snapshot = LadderSnapshot(selector: self)
        return PlasmaGhostBubble(tint: tint) {
            VStack(alignment: .leading, spacing: 10) {
                breadcrumb(snapshot)
                header(snapshot)
                if let notice = snapshot.notice {
                    noticeRow(notice)
                }
                body(snapshot)
            }
            .padding(16)
            .frame(width: 356)
        }
        .padding(10)
        .transition(.scale(scale: 0.88).combined(with: .opacity))
    }

    /// Everything the open bubble needs, resolved in one pass.
    ///
    /// `@MainActor` because it reads the controller and the catalog cache, both
    /// of which are main-actor isolated. Without it the initializer is
    /// `nonisolated` and hands main-actor state across an isolation boundary.
    @MainActor
    struct LadderSnapshot {
        let groups: [PlasmaProviderGroup]
        let activeGroup: PlasmaProviderGroup?
        let selection: String
        let notice: String?
        let choices: [PlasmaChoice]
        /// Rung 1's orbs, with the live status of every route.
        let routes: [PlasmaRouteState]

        init(selector: PlasmaModelSelector) {
            let all = selector.buildGroups()
            let selection = selector.currentSelection
            let resolved = PlasmaModelLadder.resolvedGroupID(
                preferred: selector.groupID,
                selection: selection,
                groups: all
            )
            let group = resolved.flatMap { id in all.first { $0.id == id } }
            self.groups = all
            self.activeGroup = group
            self.selection = selection
            self.routes = selector.buildRoutes()
            self.notice = selector.buildNotice(groups: all, routes: routes)
            // Only the model rung renders a choice list. Building one for the
            // other two cost a `ProviderQuotaChip.resolve` per enabled backend
            // for rows nothing draws.
            self.choices = selector.level == .model
                ? selector.buildChoices(groups: all, activeGroup: group, selection: selection)
                : []
        }
    }

    /// Three plasma chips — agent › provider › model — so the whole ladder is
    /// visible and reachable no matter which rung the body is showing.
    private func breadcrumb(_ snapshot: LadderSnapshot) -> some View {
        let providerID = snapshot.activeGroup?.id ?? "unknown"
        let providerName = snapshot.activeGroup?.displayName ?? "Provider"
        let model = modelLabel
        return HStack(spacing: 4) {
            crumb(.agent, tint: tint, text: backend.shortLabel) {
                AgentMark(backend: backend, size: 11)
            }
            crumbArrow
            crumb(.provider, tint: providerTint(providerID), text: providerName) {
                ProxyProviderLogoView(catalogProviderID: providerID, providerName: providerName, size: 11)
            }
            crumbArrow
            crumb(.model, tint: DesignSystem.Colors.colorForModel(model), text: model) {
                // Still: an 11pt orb's sub-pixel drift is invisible, and it
                // would be a fourth concurrent timeline behind an open popover.
                PlasmaOrb(
                    tint: DesignSystem.Colors.colorForModel(model),
                    size: 11,
                    motion: .orbPrimary,
                    isAnimating: false
                )
            }
            Spacer(minLength: 0)
        }
    }

    private var crumbArrow: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(DesignSystem.Colors.textMuted)
    }

    private func crumb<Mark: View>(
        _ target: PlasmaLadderLevel,
        tint: Color,
        text: String,
        @ViewBuilder mark: () -> Mark
    ) -> some View {
        let isCurrent = level == target
        return Button {
            withAnimation(DesignSystem.Animation.gentle) { level = target }
        } label: {
            HStack(spacing: 4) {
                mark()
                Text(text)
                    .font(.system(size: 9.5, weight: isCurrent ? .bold : .medium, design: .rounded))
                    .foregroundStyle(isCurrent ? DesignSystem.Colors.textPrimary : DesignSystem.Colors.textMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 72, alignment: .leading)
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                Capsule(style: .continuous)
                    .fill(isCurrent ? tint.opacity(0.16) : .clear)
            }
            .overlay {
                if isCurrent {
                    Capsule(style: .continuous).strokeBorder(tint.opacity(0.45), lineWidth: 1)
                }
            }
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Rung \(target.rawValue), \(text)")
        .accessibilityAddTraits(isCurrent ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private func header(_ snapshot: LadderSnapshot) -> some View {
        let back = backTarget(groupCount: snapshot.groups.count)
        HStack(spacing: 8) {
            PlasmaStepHeader(step: level.rawValue, title: stepTitle(snapshot))
            Spacer(minLength: 0)
            if let back {
                PlasmaBackPill(title: back == .agent ? "\(backend.displayName) (change)" : "Providers") {
                    withAnimation(DesignSystem.Animation.gentle) { level = back }
                }
            }
        }
    }

    private func stepTitle(_ snapshot: LadderSnapshot) -> String {
        switch level {
        case .agent: return "Choose the agent"
        case .provider: return "Providers on \(backend.displayName)"
        case .model: return "\(snapshot.activeGroup?.displayName ?? backend.displayName) models"
        }
    }

    private func backTarget(groupCount: Int) -> PlasmaLadderLevel? {
        switch level {
        case .agent: return nil
        case .provider: return .agent
        case .model: return PlasmaModelLadder.levelBehindModels(groupCount: groupCount)
        }
    }

    // MARK: Body
    //
    // The two upper rungs are constellations and the model rung is a list, and
    // that split is the asset applied with judgement rather than transcribed.
    // Routes and providers are a handful of *identities* — few, stable, and
    // recognised by their logo — which is exactly what a field of labelled orbs
    // is good at. A model catalog is forty near-identical strings that differ
    // in their suffix (`-20250219`, `-thinking`, `-fast`); those are read, not
    // recognised, and reading them in a drifting orb field would be miserable.

    @ViewBuilder
    private func body(_ snapshot: LadderSnapshot) -> some View {
        switch level {
        case .agent:
            routeConstellation(snapshot)
        case .provider:
            providerConstellation(snapshot)
        case .model:
            rows(snapshot)
        }
    }

    private func routeConstellation(_ snapshot: LadderSnapshot) -> some View {
        ScrollView {
            PlasmaConstellation(
                items: snapshot.routes.map { state in
                    PlasmaConstellationItem(
                        id: state.route.backend.rawValue,
                        name: state.route.backend.shortLabel,
                        mark: .backend(state.route.backend),
                        tint: state.route.tint,
                        // A healthy gateway shows where it is; a broken one
                        // shows what is wrong with it. Reporting `:8642` for an
                        // offline Hermes defeats the only job this rung has.
                        detail: state.status.isUsable
                            ? (state.route.endpointLabel ?? state.status.word)
                            : state.status.word,
                        status: PlasmaOrbStatus(color: state.status.indicatorColor, style: state.status.dotStyle),
                        statusWord: routeStatusPhrase(state),
                        isImpaired: !state.status.isUsable
                    )
                },
                selectedID: backend.rawValue,
                isAnimating: true,
                onSelect: { item in
                    guard let candidate = ChatBackendID(rawValue: item.id) else { return }
                    choose(agent: candidate)
                }
            )
            .padding(.vertical, 4)
        }
        .frame(height: Self.bodyHeight)
        .scrollIndicators(.never)
    }

    private func providerConstellation(_ snapshot: LadderSnapshot) -> some View {
        ScrollView {
            PlasmaConstellation(
                items: snapshot.groups.map { group in
                    PlasmaConstellationItem(
                        id: group.id,
                        name: group.displayName,
                        mark: .providerID(group.id),
                        tint: providerTint(group.id),
                        // Where the tokens are billed outranks how many models
                        // there are; the flat menu buried this mid-string.
                        detail: group.sourceSummary
                            ?? "\(group.entries.count) model\(group.entries.count == 1 ? "" : "s")",
                        status: nil,
                        statusWord: group.sourceSummary
                    )
                },
                selectedID: snapshot.activeGroup?.id,
                isAnimating: true,
                onSelect: { item in
                    guard let group = snapshot.groups.first(where: { $0.id == item.id }) else { return }
                    choose(provider: group)
                }
            )
            .padding(.vertical, 4)
        }
        .frame(height: Self.bodyHeight)
        .scrollIndicators(.never)
    }

    /// The words under a route orb: what is wrong, and what fixes it.
    private func routeStatusPhrase(_ state: PlasmaRouteState) -> String {
        guard let remedy = state.status.remedy else {
            return state.route.kind == .gateway
                ? "\(state.status.word) · \(state.modelCount) models"
                : state.status.word
        }
        return "\(state.status.word) — \(remedy)"
    }

    private func rows(_ snapshot: LadderSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(snapshot.choices) { choice in
                    PlasmaGlassRow(
                        title: choice.title,
                        subtitle: choice.subtitle,
                        tint: choice.tint,
                        isActive: choice.isActive,
                        isDisabled: choice.isDisabled,
                        action: choice.action,
                        leading: { PlasmaChoiceMark(choice: choice, size: 18) },
                        trailing: {
                            HStack(spacing: 4) {
                                if choice.isActive {
                                    PlasmaTag(text: "✓ ACTIVE", emphasis: .active, tint: choice.tint)
                                }
                                if let badge = choice.badge {
                                    PlasmaTag(text: badge)
                                }
                                if let presence = choice.presence {
                                    AgentPresenceDot(presence: presence, tint: choice.tint, size: 5)
                                }
                                if choice.leadsDeeper {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }
                            }
                        }
                    )
                }
            }
            .padding(.trailing, 2)
        }
        .frame(height: Self.bodyHeight)
        .scrollIndicators(.never)
    }

    /// Both bodies are the same height so flipping modes does not resize the
    /// bubble under the pointer.
    private static var bodyHeight: CGFloat { 268 }

    private func noticeRow(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "info.circle")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(DesignSystem.Colors.textMuted)
            Text(text)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(DesignSystem.Colors.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Choices

    private func buildChoices(
        groups: [PlasmaProviderGroup],
        activeGroup: PlasmaProviderGroup?,
        selection: String
    ) -> [PlasmaChoice] {
        switch level {
        case .agent:
            return agentChoices()
        case .provider:
            return automaticRow(selection) + providerChoices(groups, active: activeGroup)
        case .model:
            return automaticRow(selection) + modelChoices(activeGroup, selection: selection)
        }
    }

    /// Gated by the ladder's own rule rather than open-coded, so the helper
    /// that documents itself as the single source of truth actually is one.
    private func automaticRow(_ selection: String) -> [PlasmaChoice] {
        guard PlasmaModelLadder.showsAutomaticRow(on: level) else { return [] }
        return [automaticChoice(selection: selection)]
    }

    private func agentChoices() -> [PlasmaChoice] {
        let enabled = settingsManager.enabledChatBackends
        guard !enabled.isEmpty else {
            return [
                PlasmaChoice(
                    id: "__plasma_no_agents",
                    title: "Enable agents in Settings → Chat",
                    subtitle: "No agent is switched on for this window",
                    tint: DesignSystem.Colors.warning,
                    iconName: "exclamationmark.triangle",
                    action: {
                        isOpen = false
                        AppCommandRouter.shared.openSettings?()
                    }
                )
            ]
        }
        return enabled.map { candidate in
            let presence = presenceModel.presence(for: candidate)
            return PlasmaChoice(
                id: candidate.rawValue,
                title: candidate.displayName,
                subtitle: agentSubtitle(candidate, presence: presence),
                tint: candidate.sigilTint,
                backend: candidate,
                presence: presence,
                isActive: candidate == backend,
                action: { choose(agent: candidate) }
            )
        }
    }

    private func providerChoices(_ groups: [PlasmaProviderGroup], active: PlasmaProviderGroup?) -> [PlasmaChoice] {
        groups.map { group in
            PlasmaChoice(
                id: group.id,
                title: group.displayName,
                // Where the tokens are billed is the fact the flat menu buried
                // mid-string; the model count is the consolation prize.
                subtitle: group.sourceSummary ?? "\(group.entries.count) model\(group.entries.count == 1 ? "" : "s")",
                tint: providerTint(group.id),
                providerID: group.id,
                badge: group.sourceSummary == nil ? nil : "\(group.entries.count)",
                isActive: group.id == active?.id,
                leadsDeeper: true,
                action: { choose(provider: group) }
            )
        }
    }

    private func modelChoices(_ group: PlasmaProviderGroup?, selection: String) -> [PlasmaChoice] {
        // A catalog can advertise its own empty-id "default" row, which means
        // exactly what the synthetic Automatic choice above already means.
        (group?.entries ?? []).filter { !$0.id.isEmpty }.map { entry in
            PlasmaChoice(
                id: entry.id,
                title: entry.title,
                subtitle: entry.detail,
                tint: DesignSystem.Colors.colorForModel(entry.id),
                providerID: entry.providerID,
                isActive: entry.id == selection,
                isDisabled: entry.isDisabled,
                action: { choose(modelID: entry.id) }
            )
        }
    }

    private func automaticChoice(selection: String) -> PlasmaChoice {
        // A Hermes *family* is a route, not a pinned model: `choose(provider:)`
        // writes it through `applyHermesModelSelection` and leaves the model
        // selection empty. `orphanCandidate` then suppresses it, so without
        // this no row on the model rung would read as active at all.
        let isFamilyRoute = backend == .hermes && !selection.isEmpty && orphanCandidate.isEmpty
        return PlasmaChoice(
            id: PlasmaModelLadder.automaticChoiceID,
            title: backend == .hermes ? "Automatic (gateway picks)" : "Automatic (\(backend.displayName) decides)",
            subtitle: "Clears the pinned model for \(backend.displayName)",
            tint: tint,
            iconName: "sparkles",
            isActive: selection.isEmpty || isFamilyRoute,
            action: { choose(modelID: "") }
        )
    }

    // MARK: Data

    private var currentSelection: String {
        controller.chatModelSelection(for: backend).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func buildGroups() -> [PlasmaProviderGroup] {
        let base: [PlasmaProviderGroup]
        let note: String
        if let runtime = ChatEngineModelMenu.cliRuntime(for: backend) {
            base = PlasmaModelLadder.groups(fromCLI: catalog.options(for: runtime) ?? [])
            note = "Not advertised by this Mac"
        } else {
            base = PlasmaModelLadder.groups(fromGateway: controller.chatModelCatalog(for: backend))
            note = "Not advertised by this gateway"
        }
        return PlasmaModelLadder.includingOrphanedSelection(base, selection: orphanCandidate, note: note)
    }

    /// A Hermes selection that parses as a *family* is a route, not a model, so
    /// it must never be reported as an unadvertised model id.
    private var orphanCandidate: String {
        let selection = currentSelection
        if backend == .hermes,
           selection == ChatSessionController.hermesCanonicalModelAlias || HermesModelID(rawValue: selection) != nil {
            return ""
        }
        return selection
    }

    /// Rung 1's contents, each route carrying whatever we honestly know about it.
    private func buildRoutes() -> [PlasmaRouteState] {
        PlasmaRouteCatalog.routes(forEnabled: settingsManager.enabledChatBackends).map { route in
            PlasmaRouteState(
                route: route,
                status: status(for: route),
                modelCount: route.kind == .gateway ? controller.chatModelCatalog(for: route.backend).count : 0
            )
        }
    }

    private func status(for route: PlasmaRoute) -> PlasmaRouteStatus {
        guard route.kind == .gateway else { return .ready }
        let available: Bool
        let rejected: Bool
        switch route.backend {
        case .hermes:
            available = controller.hermesAvailable
            rejected = controller.hermesCatalogAuthRejected
        case .openclaw:
            available = controller.openClawAvailable
            rejected = false
        case .piAgent:
            available = controller.piAgentAvailable
            rejected = false
        default:
            return .ready
        }
        // BurnBar probes the *active* gateway, not every enabled one, so a
        // route we have never contacted reports "not probed" rather than
        // "offline". Claiming a gateway is down because we never called it
        // would send the user to restart a server that was fine.
        let hasProbed = route.backend == backend || available || rejected
        return .resolve(probe: PlasmaRouteProbe(
            isAvailable: available,
            isAuthRejected: rejected,
            hasProbed: hasProbed
        ))
    }

    private func buildNotice(groups: [PlasmaProviderGroup], routes: [PlasmaRouteState]) -> String? {
        // A broken *active* route outranks an empty catalog, because it is the
        // cause of it.
        if let active = routes.first(where: { $0.route.backend == backend }),
           let remedy = active.status.remedy {
            return "\(backend.displayName) is \(active.status.word). \(remedy)"
        }
        if let runtime = ChatEngineModelMenu.cliRuntime(for: backend) {
            guard (catalog.options(for: runtime) ?? []).isEmpty else { return nil }
            if let error = catalog.error(for: runtime), !error.isEmpty {
                return "Mac catalog unavailable: \(error)"
            }
            return "Loading this Mac's \(backend.displayName) catalog…"
        }
        guard controller.chatModelCatalog(for: backend).isEmpty else { return nil }
        return "\(backend.displayName) has not advertised a live catalog yet. Refresh the gateway before sending."
    }

    private func agentSubtitle(_ candidate: ChatBackendID, presence: AgentPresence) -> String {
        var parts = [candidate.kindLabel, presence.word]
        if let provider = candidate.agentProvider,
           let resolution = ProviderQuotaChip.resolve(
            provider: provider,
            style: .full,
            displayName: candidate.displayName,
            service: quotaService,
            cumulative: settingsManager.cumulativeAcrossAccounts
           ) {
            parts.append("\(resolution.text) left")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Actions

    private func open() {
        groupID = PlasmaModelLadder.resolvedGroupID(
            preferred: groupID,
            selection: currentSelection,
            groups: buildGroups()
        )
        level = .model
        isOpen = true
    }

    private func choose(agent candidate: ChatBackendID) {
        controller.agentDeck.switcher.select(candidate, controller: controller, settingsManager: settingsManager)
        // `groupID` is cleared by `.onChange(of: backend)`, which also covers
        // switches that originate outside this control. Clearing it here too
        // would hide which one is load-bearing when `select` declines.
        //
        // `select` can decline (an unconfigured Hermes opens its wizard
        // instead), so the ladder follows the backend that actually won.
        let next = PlasmaModelLadder.levelAfterChoosingAgent(groupCount: buildGroups().count)
        withAnimation(DesignSystem.Animation.gentle) { level = next }
    }

    private func choose(provider group: PlasmaProviderGroup) {
        groupID = group.id
        // Hermes routes by family, so picking its provider rung pins the route
        // the same way `HermesModelStrip` does — one write path, not two.
        if backend == .hermes, let family = ChatSessionController.hermesFamilyHint(for: group.id) {
            settingsManager.applyHermesModelSelection(family)
        }
        withAnimation(DesignSystem.Animation.gentle) { level = .model }
    }

    private func choose(modelID id: String) {
        if backend == .hermes, id.isEmpty {
            settingsManager.applyHermesModelSelection(nil)
        }
        controller.setChatModelSelection(id, for: backend)
        Analytics.shared.track(.chatModelSelected, [
            "backend": .string(backend.rawValue),
            "model_id": .string(id)
        ])
        isOpen = false
    }

    // MARK: Provider identity

    private func providerTint(_ providerID: String) -> Color {
        guard let provider = AgentProvider.fromCatalogProviderID(providerID) else {
            return ProviderBrand.colorForProviderID(providerID)
        }
        return DesignSystem.Colors.primary(for: provider)
    }
}
