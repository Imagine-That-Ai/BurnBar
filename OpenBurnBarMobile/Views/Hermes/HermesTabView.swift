import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Navigation
//
// Hermes is now a two-level flow:
//   1. `HermesConversationListView` — the tab landing. Lists every Hermes
//      session exposed by the connected host and provides a mercury FAB for
//      starting a new chat.
//   2. `HermesChatView` — the thread UI (welcome block, runtime rail, prompt
//      carousel, streaming bubbles, input bar). Pushed from the list via the
//      enclosing `NavigationStack`.
//
// `HermesChatRoute` is the value-typed destination both surfaces use, so push
// works on iPhone and iPad with system navigation chrome.

enum HermesChatRoute: Hashable {
    /// Resume a previously persisted Hermes session.
    case existing(sessionID: String)
    /// Start a fresh chat (clears `service.messages` and `selectedSessionID`).
    case new
}

// MARK: - Hermes Mobile Setup

enum HermesMobileSetupStep: Int, CaseIterable, Identifiable {
    case keepMacReady
    case chooseHost
    case startChat

    var id: Int { rawValue }
    var number: Int { rawValue + 1 }

    var title: String {
        switch self {
        case .keepMacReady: return "Keep your Mac ready"
        case .chooseHost: return "Pick a Hermes host"
        case .startChat: return "Start chatting"
        }
    }

    var detail: String {
        switch self {
        case .keepMacReady:
            return "OpenBurnBar on macOS should be signed in, running, and set to allow Hermes Remote Relay."
        case .chooseHost:
            return "Use Remote Relay away from home; use a direct LAN/VPN URL only when your device can reach the Mac."
        case .startChat:
            return "Ask about spend, sessions, quota pressure, or anything your connected Hermes runtime can answer."
        }
    }

    var systemImage: String {
        switch self {
        case .keepMacReady: return "macbook.and.iphone"
        case .chooseHost: return "antenna.radiowaves.left.and.right"
        case .startChat: return "bubble.left.and.bubble.right.fill"
        }
    }
}

enum HermesMobileSetupWizardState {
    static let completionKey = "com.openburnbar.mobile.hermesSetupWizardCompleted"
}

private struct HermesMobileSetupWizardView: View {
    @Binding var isPresented: Bool
    @Binding var hasCompletedSetup: Bool
    let onOpenConnections: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.lg) {
                    header

                    VStack(spacing: 10) {
                        ForEach(HermesMobileSetupStep.allCases) { step in
                            setupStepRow(step)
                        }
                    }

                    Button {
                        complete()
                    } label: {
                        Text("Start Chatting")
                            .font(MobileTheme.Typography.body)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.aurora(.hermes, fullWidth: true))

                    Button {
                        onOpenConnections()
                    } label: {
                        Label("Open Connections", systemImage: "network")
                            .font(MobileTheme.Typography.caption)
                            .fontWeight(.semibold)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(MobileTheme.hermesAureate)
                    .frame(maxWidth: .infinity)
                }
                .padding(AuroraDesign.Layout.cardInset)
            }
            .background(AuroraBackdrop())
            .navigationTitle("Hermes Setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { isPresented = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var header: some View {
        AuroraGlassCard(variant: .hermes, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack(spacing: 12) {
                    Text("☿")
                        .font(.system(size: 44, weight: .bold))
                        .foregroundStyle(AuroraDesign.Gradients.mercuryFoil)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Hermes in 1-2-3")
                            .font(MobileTheme.Typography.title)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text("One Mac host. One connection. One chat.")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                Text("For iPhone and iPad, Hermes works by talking to your Mac's local runtime directly on LAN/VPN or through your private Remote Relay.")
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func setupStepRow(_ step: HermesMobileSetupStep) -> some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(AuroraDesign.Gradients.mercuryFoil)
                    .frame(width: 34, height: 34)
                Text("\(step.number)")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Image(systemName: step.systemImage)
                        .font(.system(size: 12, weight: .bold))
                    Text(step.title)
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                }
                .foregroundStyle(MobileTheme.Colors.textPrimary)

                Text(step.detail)
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(MobileTheme.Colors.surfaceElevated.opacity(0.78))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MobileTheme.hermesAureate.opacity(0.22), lineWidth: 0.5)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(step.number): \(step.title). \(step.detail)")
    }

    private func complete() {
        hasCompletedSetup = true
        isPresented = false
    }
}

// MARK: - Hermes Conversation List View

struct HermesConversationListView: View {
    @Bindable var service: HermesService
    let dashboardSnapshot: DashboardStore?

    @State private var showConnectionSheet = false
    @State private var showRuntimeSheet = false
    @State private var showModelPicker = false
    @State private var showSetupWizard = false
    @State private var didAutoPresentSetupWizard = false
    @State private var libraryStore = HermesCloudLibraryStore()
    @State private var selectedLibrarySession: HermesLibrarySession?
    @AppStorage(HermesMobileSetupWizardState.completionKey) private var hasCompletedHermesSetupWizard = false

    init(service: HermesService, dashboardSnapshot: DashboardStore? = nil) {
        self.service = service
        self.dashboardSnapshot = dashboardSnapshot
    }

    var body: some View {
        ZStack {
            AuroraBackdrop()

            Group {
                if service.sessions.isEmpty && libraryStore.sessions.isEmpty {
                    emptyState
                } else {
                    conversationList
                }
            }

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    newChatFAB
                        .padding(.trailing, AuroraDesign.Layout.cardInset)
                        .padding(.bottom, AuroraDesign.Layout.cardInset)
                }
            }
        }
        .navigationTitle("Hermes")
        .navigationBarTitleDisplayMode(.large)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showConnectionSheet = true
                    } label: {
                        Label("Connections", systemImage: "network")
                    }
                    Button {
                        showModelPicker = true
                    } label: {
                        Label("Switch model", systemImage: "cpu")
                    }
                    Button {
                        showRuntimeSheet = true
                    } label: {
                        Label("Runtime", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        showSetupWizard = true
                    } label: {
                        Label("Setup Guide", systemImage: "list.number")
                    }
                    Divider()
                    Button {
                        Task { await service.refreshRuntime() }
                    } label: {
                        Label("Re-check connection", systemImage: "arrow.clockwise")
                    }
                    Button {
                        Task { await libraryStore.refresh() }
                    } label: {
                        Label("Refresh Library", systemImage: "icloud.and.arrow.down")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(MobileTheme.hermesAureate)
                }
            }
        }
        .sheet(isPresented: $showConnectionSheet) {
            HermesConnectionSheet(service: service)
        }
        .sheet(isPresented: $showRuntimeSheet) {
            HermesRuntimeSheet(service: service)
        }
        .sheet(isPresented: $showModelPicker) {
            HermesModelPickerSheet(service: service)
        }
        .sheet(item: $selectedLibrarySession) { session in
            HermesLibraryTranscriptSheet(store: libraryStore, session: session)
        }
        .sheet(isPresented: $showSetupWizard) {
            HermesMobileSetupWizardView(
                isPresented: $showSetupWizard,
                hasCompletedSetup: $hasCompletedHermesSetupWizard,
                onOpenConnections: {
                    showSetupWizard = false
                    showConnectionSheet = true
                }
            )
        }
        .navigationDestination(for: HermesChatRoute.self) { route in
            HermesChatView(
                service: service,
                dashboardSnapshot: dashboardSnapshot,
                route: route
            )
        }
        .task {
            service.loadHistory()
            async let reachability: Void = service.checkReachability()
            async let library: Void = libraryStore.refresh()
            _ = await (reachability, library)
        }
        .onAppear {
            presentSetupWizardIfNeeded()
        }
    }

    private func presentSetupWizardIfNeeded() {
        guard !AppStoreScreenshotMode.isEnabled else { return }
        guard !hasCompletedHermesSetupWizard else { return }
        guard !didAutoPresentSetupWizard else { return }
        didAutoPresentSetupWizard = true
        showSetupWizard = true
    }

    // MARK: - Conversation List

    private var conversationList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if !sortedSessions.isEmpty {
                    librarySectionHeader("Live Hermes Host", systemImage: "antenna.radiowaves.left.and.right")
                    ForEach(sortedSessions) { session in
                        NavigationLink(value: HermesChatRoute.existing(sessionID: session.id)) {
                            ConversationRow(
                                session: session,
                                isActive: service.selectedSessionID == session.id
                            )
                        }
                        .buttonStyle(.plain)
                        .simultaneousGesture(
                            TapGesture().onEnded { HapticBus.sheetOpen() }
                        )
                    }
                }

                if !sortedLibrarySessions.isEmpty {
                    librarySectionHeader("Imported Library", systemImage: "books.vertical.fill")
                        .padding(.top, sortedSessions.isEmpty ? 0 : 10)
                    ForEach(sortedLibrarySessions) { session in
                        Button {
                            HapticBus.sheetOpen()
                            selectedLibrarySession = session
                        } label: {
                            HermesLibraryRow(session: session)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if let error = libraryStore.lastError, !error.isEmpty {
                    Text("Cloud library unavailable: \(error)")
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.warning)
                        .padding(.top, 4)
                }
            }
            .padding(.horizontal, AuroraDesign.Layout.cardInset)
            .padding(.bottom, 96) // FAB clearance
            .padding(.top, 4)
        }
        .scrollDismissesKeyboard(.interactively)
        .refreshable {
            HapticBus.refreshStarted()
            async let runtime: Void = service.refreshRuntime()
            async let library: Void = libraryStore.refresh()
            _ = await (runtime, library)
            HapticBus.refreshFinished()
        }
        .animation(AuroraDesign.Motion.auroraSpring, value: service.sessions.map(\.id))
    }

    private var sortedSessions: [HermesSessionSummary] {
        service.sessions.sorted {
            ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast)
        }
    }

    private var sortedLibrarySessions: [HermesLibrarySession] {
        libraryStore.sessions.sorted {
            ($0.lastActiveAt ?? .distantPast) > ($1.lastActiveAt ?? .distantPast)
        }
    }

    private func librarySectionHeader(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(MobileTheme.Typography.caption)
            .fontWeight(.semibold)
            .foregroundStyle(MobileTheme.Colors.textSecondary)
            .padding(.top, 2)
            .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Empty State

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: MobileTheme.Spacing.lg) {
                AuroraGlassCard(variant: .hermes, cornerRadius: AuroraDesign.Shape.heroCorner) {
                    VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                        HStack(spacing: 12) {
                            Text("☿")
                                .font(.system(size: 38, weight: .bold))
                                .foregroundStyle(AuroraDesign.Gradients.mercuryFoil)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("No conversations yet")
                                    .font(MobileTheme.Typography.title)
                                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                                Text("Hermes is your AI fleet's runtime co-pilot.")
                                    .font(MobileTheme.Typography.caption)
                                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                            }
                            Spacer()
                        }
                        Text("Start a new chat to ask about today's burn, project breakdowns, quota pressure, or session details. Sessions persist on the connected Hermes host.")
                            .font(MobileTheme.Typography.body)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        NavigationLink(value: HermesChatRoute.new) {
                            HStack(spacing: 8) {
                                Image(systemName: "plus.bubble.fill")
                                    .font(.system(size: 14, weight: .bold))
                                Text("Start your first conversation")
                                    .font(MobileTheme.Typography.body)
                                    .fontWeight(.semibold)
                            }
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .padding(.vertical, 12)
                            .background(
                                Capsule().fill(AuroraDesign.Gradients.mercuryFoil)
                            )
                            .shadow(color: MobileTheme.hermesAureate.opacity(0.4), radius: 12, y: 4)
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 4)
                    }
                }
                .padding(.horizontal, AuroraDesign.Layout.cardInset)
                .padding(.top, MobileTheme.Spacing.xl)

                if let relay = service.suggestedRelayConnection,
                   service.selectedConnection.id != relay.id {
                    connectRelayCard(relay)
                        .padding(.horizontal, AuroraDesign.Layout.cardInset)
                }

                if let runtimeErrorText = service.runtimeErrorText {
                    AuroraGlassCard(variant: .urgent) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Hermes is offline", systemImage: "exclamationmark.triangle.fill")
                                .font(MobileTheme.Typography.body)
                                .fontWeight(.semibold)
                                .foregroundStyle(MobileTheme.warning)
                            Text(runtimeErrorText)
                                .font(MobileTheme.Typography.caption)
                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                Task { await service.refreshRuntime() }
                            } label: {
                                Label("Re-check connection", systemImage: "arrow.clockwise")
                                    .font(MobileTheme.Typography.caption)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(MobileTheme.hermesAureate)
                        }
                    }
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                }

                Spacer(minLength: 96) // FAB clearance
            }
        }
        .refreshable {
            HapticBus.refreshStarted()
            await service.refreshRuntime()
            HapticBus.refreshFinished()
        }
    }

    private func connectRelayCard(_ relay: HermesConnectionRecord) -> some View {
        AuroraGlassCard(variant: .hermes, cornerRadius: AuroraDesign.Shape.standardCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                Label("Use \(relay.displayName)", systemImage: "macbook.and.iphone")
                    .font(MobileTheme.Typography.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)

                Text("You're signed in to the same OpenBurnBar account on this iPhone/iPad and your Mac. Grant permission here to route Hermes chats through your Mac over private Remote Relay.")
                    .font(MobileTheme.Typography.caption)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    HapticBus.primaryAction()
                    if !service.connectToSuggestedRelay() {
                        showConnectionSheet = true
                    }
                } label: {
                    Label("Connect to my Mac", systemImage: "checkmark.shield.fill")
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.aurora(.hermes, fullWidth: true))
                .accessibilityHint("Selects the available Mac Hermes Remote Relay for this device.")
            }
        }
    }

    // MARK: - FAB

    private var newChatFAB: some View {
        NavigationLink(value: HermesChatRoute.new) {
            ZStack {
                Circle()
                    .fill(AuroraDesign.Gradients.mercuryFoil)
                    .frame(width: 56, height: 56)
                    .shadow(color: MobileTheme.hermesAureate.opacity(0.45), radius: 14, y: 6)
                Image(systemName: "plus")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
            }
            .overlay(
                Circle().stroke(.white.opacity(0.18), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start new Hermes conversation")
        .simultaneousGesture(
            TapGesture().onEnded { HapticBus.primaryAction() }
        )
    }
}

// MARK: - Conversation Row

private struct ConversationRow: View {
    let session: HermesSessionSummary
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.title?.nilIfBlank ?? "New Conversation")
                    .font(MobileTheme.Typography.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(titleColor)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let lastActiveAt = session.lastActiveAt {
                    Text(lastActiveAt, style: .relative)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(secondaryColor.opacity(0.85))
                        .lineLimit(1)
                }
            }

            if let preview = session.preview?.nilIfBlank {
                Text(preview)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(secondaryColor)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            HStack(spacing: 8) {
                modelChip
                messageChip
                if session.isActive {
                    activeChip
                }
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(rowBackground)
        .overlay(rowBorder)
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: - Chips

    private var modelChip: some View {
        HStack(spacing: 6) {
            Text("☿")
                .font(.system(size: 10, weight: .bold))
            Text(session.model?.nilIfBlank ?? "hermes")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
                .lineLimit(1)
        }
        .foregroundStyle(chipForeground)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(chipFill))
        .overlay(Capsule().stroke(chipStroke, lineWidth: 0.5))
    }

    private var messageChip: some View {
        HStack(spacing: 6) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 10, weight: .bold))
            Text("\(session.messageCount)")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(secondaryColor)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(MobileTheme.Colors.surface.opacity(isActive ? 0.18 : 0.5)))
        .overlay(Capsule().stroke(MobileTheme.Colors.border.opacity(isActive ? 0.0 : 0.4), lineWidth: 0.5))
    }

    private var activeChip: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isActive ? .white : MobileTheme.success)
                .frame(width: 7, height: 7)
            Text("Active")
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(isActive ? .white : MobileTheme.success)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(
                isActive
                    ? AnyShapeStyle(.white.opacity(0.18))
                    : AnyShapeStyle(MobileTheme.success.opacity(0.12))
            )
        )
    }

    // MARK: - Row Chrome

    @ViewBuilder
    private var rowBackground: some View {
        if isActive {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(AuroraDesign.Gradients.mercuryFoil)
                .shadow(color: MobileTheme.hermesAureate.opacity(0.35), radius: 12, y: 6)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.85))
        }
    }

    @ViewBuilder
    private var rowBorder: some View {
        if isActive {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        } else {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MobileTheme.Colors.border.opacity(0.45), lineWidth: 0.5)
        }
    }

    // MARK: - Color Tokens

    private var titleColor: Color {
        isActive ? .white : MobileTheme.Colors.textPrimary
    }

    private var secondaryColor: Color {
        isActive ? .white.opacity(0.82) : MobileTheme.Colors.textSecondary
    }

    private var chipForeground: Color {
        isActive ? .white : MobileTheme.hermesAureate
    }

    private var chipFill: AnyShapeStyle {
        isActive
            ? AnyShapeStyle(.white.opacity(0.18))
            : AnyShapeStyle(MobileTheme.hermesAureate.opacity(0.12))
    }

    private var chipStroke: Color {
        isActive
            ? .white.opacity(0.32)
            : MobileTheme.hermesAureate.opacity(0.3)
    }
}

private struct HermesLibraryRow: View {
    let session: HermesLibrarySession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(session.title.nilIfBlank ?? "Hermes conversation")
                    .font(MobileTheme.Typography.headline)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let lastActiveAt = session.lastActiveAt {
                    Text(lastActiveAt, style: .relative)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
            }

            Text(session.preview)
                .font(MobileTheme.Typography.body)
                .foregroundStyle(MobileTheme.Colors.textSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 8) {
                Label(session.sourceLabel, systemImage: session.source == .firebase ? "cloud.fill" : "icloud.fill")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.hermesAureate)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(MobileTheme.hermesAureate.opacity(0.12)))

                Label("\(session.messageCount)", systemImage: "bubble.left.and.bubble.right")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)

                Spacer()

                Text("Read-only")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(MobileTheme.Colors.surface.opacity(0.82))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(MobileTheme.Colors.border.opacity(0.7), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct HermesLibraryTranscriptSheet: View {
    let store: HermesCloudLibraryStore
    let session: HermesLibrarySession

    @Environment(\.dismiss) private var dismiss
    @State private var transcript = ""
    @State private var errorText: String?
    @State private var isLoading = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                    AuroraGlassCard(variant: .hermes, cornerRadius: AuroraDesign.Shape.standardCorner) {
                        VStack(alignment: .leading, spacing: 8) {
                            Label(session.sourceLabel, systemImage: session.source == .firebase ? "cloud.fill" : "icloud.fill")
                                .font(MobileTheme.Typography.caption)
                                .fontWeight(.semibold)
                                .foregroundStyle(MobileTheme.hermesAureate)
                            Text(session.title)
                                .font(MobileTheme.Typography.title)
                                .foregroundStyle(MobileTheme.Colors.textPrimary)
                            Text("Imported transcript. Connect to your Mac relay to continue live in Hermes.")
                                .font(MobileTheme.Typography.caption)
                                .foregroundStyle(MobileTheme.Colors.textSecondary)
                        }
                    }

                    if isLoading {
                        ProgressView("Loading transcript…")
                            .frame(maxWidth: .infinity)
                    } else if let errorText {
                        Text(errorText)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.error)
                    } else {
                        Text(transcript.isEmpty ? "No transcript body was found for this imported session." : transcript)
                            .font(MobileTheme.Typography.body)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(AuroraDesign.Layout.cardInset)
            }
            .background(AuroraBackdrop())
            .navigationTitle("Hermes Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await loadTranscript() }
    }

    private func loadTranscript() async {
        isLoading = true
        defer { isLoading = false }
        do {
            transcript = try await store.transcript(for: session)
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
    }
}

// MARK: - Hermes Chat View

struct HermesChatView: View {
    @Bindable var service: HermesService
    let dashboardSnapshot: DashboardStore?
    let route: HermesChatRoute

    @State private var input: String = ""
    @State private var showClearConfirm = false
    @State private var showConnectionSheet = false
    @State private var showRuntimeSheet = false
    @State private var showModelPicker = false
    @State private var showSetupWizard = false
    @State private var didAutoPresentSetupWizard = false
    @AppStorage(HermesMobileSetupWizardState.completionKey) private var hasCompletedHermesSetupWizard = false
    @FocusState private var inputFocused: Bool
    @Namespace private var bubbleNamespace

    init(
        service: HermesService,
        dashboardSnapshot: DashboardStore? = nil,
        route: HermesChatRoute = .new
    ) {
        self.service = service
        self.dashboardSnapshot = dashboardSnapshot
        self.route = route
    }

    var body: some View {
        ZStack {
            AuroraBackdrop()
            VStack(spacing: 0) {
                connectionPill
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .padding(.bottom, 6)

                relaySuggestionBanner
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .padding(.bottom, service.hasPendingRelaySuggestion ? 8 : 0)

                runtimeRail
                    .padding(.bottom, 8)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 16) {
                            if service.messages.isEmpty {
                                welcomeBlock
                            } else {
                                ForEach(service.messages) { message in
                                    HermesMessageBubble(message: message)
                                        .id(message.id)
                                }
                                if service.isStreaming {
                                    HStack {
                                        MercuryThinkingIndicator()
                                            .padding(.leading, 8)
                                        Spacer()
                                    }
                                    .id("thinking")
                                }
                            }
                        }
                        .padding(.horizontal, AuroraDesign.Layout.cardInset)
                        .padding(.bottom, 12)
                    }
                    .scrollDismissesKeyboard(.interactively)
                    .onChange(of: service.messages.count) { _, _ in
                        if let last = service.messages.last {
                            withAnimation(AuroraDesign.Motion.auroraSpring) {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .onChange(of: service.isStreaming) { _, streaming in
                        if streaming {
                            withAnimation(AuroraDesign.Motion.auroraSpring) {
                                proxy.scrollTo("thinking", anchor: .bottom)
                            }
                        }
                    }
                }

                if service.messages.isEmpty || input.isEmpty {
                    promptCarousel
                        .padding(.bottom, 4)
                }

                inputBar
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .padding(.bottom, 8)
            }
            // Reserve bottom space so the floating AuroraNavigationTray
            // never overlaps content. The tray is pillHeight(50) + bottomInset(14)
            // = 64pt; we add a comfortable 70pt so content lands above it.
            .padding(.bottom, 70)
        }
        .navigationTitle(navigationTitleText)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showConnectionSheet = true
                    } label: {
                        Label("Connections", systemImage: "network")
                    }
                    Button {
                        showRuntimeSheet = true
                    } label: {
                        Label("Runtime", systemImage: "slider.horizontal.3")
                    }
                    Button {
                        showSetupWizard = true
                    } label: {
                        Label("Setup Guide", systemImage: "list.number")
                    }
                    Divider()
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("Clear chat", systemImage: "trash")
                    }
                    .disabled(service.messages.isEmpty)
                    Button {
                        Task { await service.refreshRuntime() }
                    } label: {
                        Label("Re-check connection", systemImage: "arrow.clockwise")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(MobileTheme.hermesAureate)
                }
            }
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    inputFocused = false
                }
            }
        }
        .alert("Clear chat?", isPresented: $showClearConfirm) {
            Button("Cancel", role: .cancel) {}
            Button("Clear", role: .destructive) {
                withAnimation(AuroraDesign.Motion.auroraSpring) { service.clearChat() }
            }
        } message: {
            Text("This removes the entire conversation history.")
        }
        .sheet(isPresented: $showConnectionSheet) {
            HermesConnectionSheet(service: service)
        }
        .sheet(isPresented: $showRuntimeSheet) {
            HermesRuntimeSheet(service: service)
        }
        .sheet(isPresented: $showModelPicker) {
            HermesModelPickerSheet(service: service)
        }
        .sheet(isPresented: $showSetupWizard) {
            HermesMobileSetupWizardView(
                isPresented: $showSetupWizard,
                hasCompletedSetup: $hasCompletedHermesSetupWizard,
                onOpenConnections: {
                    showSetupWizard = false
                    showConnectionSheet = true
                }
            )
        }
        .task(id: route) { await applyRoute() }
        .task {
            // Idempotent: refreshRuntime coalesces concurrent callers and loads
            // both remote relay discovery and selected-host reachability.
            await service.refreshRuntime()
        }
        .onAppear {
            presentSetupWizardIfNeeded()
        }
    }

    private func presentSetupWizardIfNeeded() {
        guard !AppStoreScreenshotMode.isEnabled else { return }
        guard !hasCompletedHermesSetupWizard else { return }
        guard !didAutoPresentSetupWizard else { return }
        didAutoPresentSetupWizard = true
        showSetupWizard = true
    }

    // MARK: - Route Binding

    private func applyRoute() async {
        switch route {
        case .new:
            if !service.messages.isEmpty || service.selectedSessionID != nil {
                service.startNewSession()
            }
        case .existing(let sessionID):
            guard service.selectedSessionID != sessionID else { return }
            if let summary = service.sessions.first(where: { $0.id == sessionID }) {
                await service.resumeSession(summary)
            } else {
                // Sessions list may not be loaded yet; refresh and try again once.
                await service.refreshRuntime()
                if let summary = service.sessions.first(where: { $0.id == sessionID }) {
                    await service.resumeSession(summary)
                }
            }
        }
    }

    private var navigationTitleText: String {
        switch route {
        case .new:
            return service.selectedSessionID.map(service.sessionTitle(for:)) ?? "New Conversation"
        case .existing(let id):
            return service.sessionTitle(for: id)
        }
    }

    // MARK: - Connection Pill

    private var connectionPill: some View {
        Button {
            showConnectionSheet = true
        } label: {
            HStack(spacing: 8) {
                Circle()
                    .fill(service.isReachable ? MobileTheme.success : MobileTheme.warning)
                    .frame(width: 8, height: 8)
                    .modifier(BreathingDot(active: service.isReachable))
                Text(connectionStatusText)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                    .foregroundStyle(service.isReachable ? MobileTheme.success : MobileTheme.warning)
                Spacer()
                Image(systemName: "chevron.down.circle.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(service.isReachable ? MobileTheme.success : MobileTheme.warning)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .auroraGlass(.compact, cornerRadius: 12)
        }
        .buttonStyle(.plain)
    }

    private var connectionStatusText: String {
        if !service.isReachable,
           service.selectedConnection.id == HermesConnectionRecord.localDefault.id,
           let relay = service.suggestedRelayConnection {
            return "Local offline · relay available · \(relay.displayName)"
        }
        let name = service.selectedConnection.displayName
        return service.isReachable ? "Hermes online · \(name)" : "Hermes offline · \(name)"
    }

    @ViewBuilder
    private var relaySuggestionBanner: some View {
        if let relay = service.suggestedRelayConnection,
           service.hasPendingRelaySuggestion {
            Button {
                HapticBus.primaryAction()
                if !service.connectToSuggestedRelay() {
                    showConnectionSheet = true
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "macbook.and.iphone")
                        .font(.system(size: 14, weight: .bold))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use \(relay.displayName)")
                            .font(MobileTheme.Typography.caption)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text("Route this chat through your signed-in Mac")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.system(size: 14, weight: .bold))
                }
                .foregroundStyle(MobileTheme.hermesAureate)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .auroraGlass(.compact, cornerRadius: 14)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Selects the available Mac Hermes Remote Relay for this chat.")
        }
    }

    private var runtimeRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Button {
                    showModelPicker = true
                } label: {
                    modelSelectorChip
                }
                .buttonStyle(.plain)
                Button {
                    showRuntimeSheet = true
                } label: {
                    runtimeChip(icon: "wrench.and.screwdriver", label: "\(service.profiles.count) profiles · \(service.jobs.count) jobs")
                }
                runtimeChip(icon: "flame.fill", label: "\(service.currentConversationTokenBurn.formatted()) tokens")
                if let selectedSessionID = service.selectedSessionID {
                    runtimeChip(icon: "bubble.left.and.bubble.right", label: "Resuming \(service.sessionTitle(for: selectedSessionID))")
                }
            }
            .padding(.horizontal, AuroraDesign.Layout.cardInset)
        }
    }

    private func runtimeChip(icon: String, label: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(label)
                .lineLimit(1)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(MobileTheme.hermesAureate)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(MobileTheme.hermesAureate.opacity(0.1)))
        .overlay(Capsule().stroke(MobileTheme.hermesAureate.opacity(0.24), lineWidth: 0.5))
    }

    private var modelSelectorChip: some View {
        let option = service.selectedModelOption
        let label = option?.displayName ?? service.selectedModelID ?? service.selectedConnection.advertisedModel ?? "Choose model"
        let provider = option?.agentProvider ?? hermesAgentProvider(for: service.selectedModelID ?? service.selectedConnection.advertisedModel ?? "hermes")
        return HStack(spacing: 6) {
            UnifiedProviderLogoView(provider: provider, size: 18, useFallbackColor: true)
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .lineLimit(1)
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
                Text("Switch model")
                    .lineLimit(1)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
            }
            Image(systemName: "chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(MobileTheme.Colors.textSecondary)
        }
        .foregroundStyle(MobileTheme.Colors.textPrimary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Capsule().fill(MobileTheme.Colors.surfaceElevated.opacity(0.72)))
        .overlay(Capsule().stroke(MobileTheme.hermesAureate.opacity(0.35), lineWidth: 0.7))
    }

    // MARK: - Welcome

    private var welcomeBlock: some View {
        AuroraGlassCard(variant: .hermes, cornerRadius: AuroraDesign.Shape.heroCorner) {
            VStack(alignment: .leading, spacing: MobileTheme.Spacing.md) {
                HStack(spacing: 12) {
                    Text("☿")
                        .font(.system(size: 38, weight: .bold))
                        .foregroundStyle(AuroraDesign.Gradients.mercuryFoil)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hermes")
                            .font(MobileTheme.Typography.title)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                        Text("Your AI fleet's runtime co-pilot")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                    }
                    Spacer()
                }
                Text("Ask questions about today's burn, project breakdowns, quota pressure, or session details. Responses use your live OpenBurnBar data as context.")
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                contextChips
            }
        }
    }

    @ViewBuilder
    private var contextChips: some View {
        if let snapshot = dashboardSnapshot, let totals = snapshot.windowTotals[.today] {
            HStack(spacing: 8) {
                contextChip(icon: "flame.fill", label: "Today", value: totals.costUsd.formatAsCost())
                contextChip(icon: "rectangle.stack", label: "Sessions", value: "\(totals.requests)")
                contextChip(icon: "number", label: "Tokens", value: totals.tokens.formatAsTokenVolume())
            }
        }
    }

    private func contextChip(icon: String, label: String, value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .bold))
            Text(label).font(MobileTheme.Typography.tiny)
            Text(value)
                .font(MobileTheme.Typography.tiny)
                .fontWeight(.semibold)
        }
        .foregroundStyle(MobileTheme.hermesAureate)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(MobileTheme.hermesAureate.opacity(0.12))
        )
        .overlay(
            Capsule().stroke(MobileTheme.hermesAureate.opacity(0.3), lineWidth: 0.5)
        )
    }

    // MARK: - Prompt Carousel

    private var promptCarousel: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(prompts, id: \.self) { prompt in
                    Button {
                        input = prompt
                        send()
                    } label: {
                        Text(prompt)
                            .font(MobileTheme.Typography.tiny)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .foregroundStyle(MobileTheme.hermesAureate)
                            .background(
                                Capsule().fill(MobileTheme.hermesAureate.opacity(0.12))
                            )
                            .overlay(
                                Capsule().stroke(MobileTheme.hermesAureate.opacity(0.35), lineWidth: 0.5)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(service.isStreaming)
                }
            }
            .padding(.horizontal, AuroraDesign.Layout.cardInset)
        }
        .opacity(service.isStreaming ? 0.45 : 1)
    }

    private var prompts: [String] {
        var list: [String] = [
            "Why did I burn so much today?",
            "Show my biggest sessions this week",
            "Forecast end-of-day spend",
            "Which provider has the lowest quota?",
            "Top 3 projects by cost"
        ]
        if let topProvider = dashboardSnapshot?.topProviders.first?.provider,
           let provider = AgentProvider.fromPersistedToken(topProvider) {
            list.append("How is \(provider.displayName) trending?")
        }
        return list
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            field
            sendButton
        }
        .padding(10)
        .auroraGlass(.hermes, cornerRadius: 18)
    }

    private var field: some View {
        TextField("Ask Hermes…", text: $input, axis: .vertical)
            .font(MobileTheme.Typography.body)
            .focused($inputFocused)
            .submitLabel(.send)
            .onSubmit(send)
            .lineLimit(1...5)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(MobileTheme.Colors.surface.opacity(0.7))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(
                                inputFocused ? MobileTheme.hermesAureate : MobileTheme.Colors.border.opacity(0.4),
                                lineWidth: inputFocused ? 1 : 0.5
                            )
                    )
            )
    }

    private var sendButton: some View {
        Button(action: send) {
            ZStack {
                Circle()
                    .fill(input.isEmpty
                          ? AnyShapeStyle(MobileTheme.Colors.surface.opacity(0.6))
                          : AnyShapeStyle(AuroraDesign.Gradients.mercuryFoil))
                    .frame(width: 38, height: 38)
                    .shadow(color: MobileTheme.hermesAureate.opacity(input.isEmpty ? 0 : 0.4), radius: 10)
                Image(systemName: "arrow.up")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(input.isEmpty ? MobileTheme.Colors.textMuted : .white)
            }
        }
        .buttonStyle(.plain)
        .disabled(input.isEmpty || service.isStreaming)
        .accessibilityLabel("Send")
    }

    // MARK: - Actions

    private func send() {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !service.isStreaming else { return }
        HapticBus.send()
        input = ""
        inputFocused = false
        service.sendMessage(trimmed, context: dashboardContextPrompt)
    }

    private var dashboardContextPrompt: String? {
        guard let snapshot = dashboardSnapshot else { return nil }
        var lines = ["OpenBurnBar mobile context for this Hermes turn:"]
        if let totals = snapshot.windowTotals[.today] {
            lines.append("Today: \(totals.costUsd.formatAsCost()), \(totals.tokens.formatAsTokenVolume()) tokens, \(totals.requests) requests.")
        }
        if let week = snapshot.windowTotals[.sevenDays] {
            lines.append("7 days: \(week.costUsd.formatAsCost()), \(week.tokens.formatAsTokenVolume()) tokens, \(week.requests) requests.")
        }
        if !snapshot.topProviders.isEmpty {
            let providers = snapshot.topProviders.prefix(5).map { summary in
                "\(summary.provider): \(summary.totalTokens.formatAsTokenVolume()) tokens"
            }.joined(separator: "; ")
            lines.append("Top providers: \(providers).")
        }
        return lines.joined(separator: "\n")
    }
}

// MARK: - Hermes Connection Sheet

private struct HermesConnectionSheet: View {
    @Bindable var service: HermesService
    @Environment(\.dismiss) private var dismiss

    @State private var displayName = "Hermes Host"
    @State private var endpointURL = "http://192.168.1.2:8642"
    @State private var bearerToken = ""
    @State private var isWorking = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Use Remote Relay away from home", systemImage: "antenna.radiowaves.left.and.right")
                            .font(MobileTheme.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.hermesAureate)
                        Text("Same account is not enough by itself: your iPhone/iPad must choose the Mac relay host, and your Mac must be online with Remote Relay enabled.")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        if let relay = service.suggestedRelayConnection,
                           service.selectedConnection.id != relay.id {
                            Button {
                                if service.connectToSuggestedRelay() {
                                    dismiss()
                                } else {
                                    errorText = service.lastError
                                }
                            } label: {
                                Label("Connect to my Mac", systemImage: "checkmark.shield.fill")
                                    .font(MobileTheme.Typography.body)
                                    .fontWeight(.semibold)
                            }
                            .buttonStyle(.aurora(.hermes, fullWidth: true))
                            .padding(.top, 4)
                        } else if service.suggestedRelayConnection == nil {
                            Label("No Mac relay found yet", systemImage: "moon.zzz")
                                .font(MobileTheme.Typography.caption)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                                .padding(.top, 2)
                        }
                    }
                    .padding(.vertical, 4)
                }

                Section("Active Host") {
                    ForEach(service.connections) { connection in
                        Button {
                            if service.selectConnection(connection) {
                                dismiss()
                            } else {
                                errorText = service.lastError
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(connection.displayName)
                                        .font(MobileTheme.Typography.body)
                                        .fontWeight(.semibold)
                                    Text(connectionSubtitle(connection))
                                        .font(MobileTheme.Typography.tiny)
                                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                                }
                                Spacer()
                                Text(connection.status.rawValue.capitalized)
                                    .font(MobileTheme.Typography.tiny)
                                    .foregroundStyle(connection.status == .online ? MobileTheme.success : MobileTheme.warning)
                                if connection.id == service.selectedConnection.id {
                                    Image(systemName: "checkmark.circle.fill")
                                        .foregroundStyle(MobileTheme.hermesAureate)
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            if connection.id != HermesConnectionRecord.localDefault.id {
                                Button(role: .destructive) {
                                    Task { await revoke(connection) }
                                } label: {
                                    Label("Revoke", systemImage: "trash")
                                }
                            }
                        }
                    }
                }

                if let runtimeErrorText = service.runtimeErrorText {
                    Section {
                        Text(runtimeErrorText)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.error)
                        Button {
                            Task { await service.refreshConnections() }
                        } label: {
                            Label("Retry Connection Discovery", systemImage: "arrow.clockwise")
                        }
                    }
                }

                Section {
                    TextField("Display name", text: $displayName)
                    TextField("Hermes URL", text: $endpointURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("API_SERVER_KEY (optional)", text: $bearerToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    if !endpointURL.isEmpty, HermesService.validatedEndpointURL(endpointURL) == nil {
                        Text("Use HTTPS, or HTTP only for localhost/private LAN Hermes hosts.")
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.error)
                    }
                    Button {
                        Task { await addDirectConnection() }
                    } label: {
                        Label(isWorking ? "Registering…" : "Register and Connect", systemImage: "link.badge.plus")
                    }
                    .disabled(isWorking || displayName.isEmpty || HermesService.validatedEndpointURL(endpointURL) == nil)
                } header: {
                    Text("Add LAN/VPN Direct Host")
                } footer: {
                    Text("Use this for LAN/VPN/public HTTPS hosts. For cell signal away from home, keep OpenBurnBar running on your signed-in Mac and select its Remote Relay connection above; the Hermes API key stays on the Mac.")
                }

                if let errorText {
                    Section {
                        Text(errorText)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.error)
                    }
                }
            }
            .navigationTitle("Hermes Connections")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await service.refreshConnections() }
        }
    }

    private func addDirectConnection() async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await service.addDirectConnection(
                displayName: displayName,
                endpointURL: endpointURL,
                bearerToken: bearerToken
            )
            dismiss()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func revoke(_ connection: HermesConnectionRecord) async {
        isWorking = true
        errorText = nil
        defer { isWorking = false }
        do {
            try await service.revokeConnection(connection)
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func connectionSubtitle(_ connection: HermesConnectionRecord) -> String {
        if connection.mode == .relayLink {
            return "Remote Relay · works over cell signal"
        }
        return connection.endpointURL ?? connection.mode.rawValue
    }
}

// MARK: - Hermes Runtime Sheet

private struct HermesRuntimeSheet: View {
    @Bindable var service: HermesService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let runtimeErrorText = service.runtimeErrorText {
                    Section {
                        Text(runtimeErrorText)
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.error)
                        Button {
                            Task { await service.refreshRuntime() }
                        } label: {
                            Label("Retry Runtime Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                }

                Section("Models") {
                    if service.modelOptions.isEmpty {
                        Text("No models discovered")
                    } else {
                        ForEach(service.modelOptions) { option in
                            HermesModelPickerRow(
                                option: option,
                                isSelected: service.selectedModelID == option.modelID,
                                isFavorite: service.isFavoriteModel(option)
                            ) {
                                service.selectModel(option)
                                HapticBus.primaryAction()
                                dismiss()
                            } onToggleFavorite: {
                                service.toggleFavoriteModel(option)
                                HapticBus.toggle()
                            }
                        }
                    }
                }

                Section("Profiles") {
                    if service.profiles.isEmpty {
                        Text("No profiles discovered")
                    } else {
                        ForEach(service.profiles) { profile in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(profile.name)
                                    .font(MobileTheme.Typography.body)
                                Text([profile.provider, profile.model].compactMap { $0 }.joined(separator: " · "))
                                    .font(MobileTheme.Typography.tiny)
                                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                            }
                        }
                    }
                }

                Section("Jobs") {
                    if service.jobs.isEmpty {
                        Text("No scheduled jobs discovered")
                    } else {
                        ForEach(service.jobs) { job in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(job.name ?? job.prompt)
                                        .font(MobileTheme.Typography.body)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(job.enabled ? job.state : "disabled")
                                        .font(MobileTheme.Typography.tiny)
                                        .foregroundStyle(job.enabled ? MobileTheme.success : MobileTheme.Colors.textMuted)
                                }
                                if let nextRunAt = job.nextRunAt {
                                    Text("Next run \(nextRunAt.formatted(date: .abbreviated, time: .shortened))")
                                        .font(MobileTheme.Typography.tiny)
                                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Hermes Runtime")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await service.refreshRuntime() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await service.refreshRuntime() }
        }
    }
}

// MARK: - Hermes Model Picker

struct HermesModelPickerSheet: View {
    @Bindable var service: HermesService
    @Environment(\.dismiss) private var dismiss

    private var groupedModels: [(provider: String, options: [HermesRuntimeModelOption])] {
        Dictionary(grouping: service.modelOptions, by: \.providerName)
            .map { (provider: $0.key, options: $0.value.sorted { $0.displayName < $1.displayName }) }
            .sorted { $0.provider < $1.provider }
    }

    private var favoriteModels: [HermesRuntimeModelOption] {
        service.favoriteModelOptions
    }

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackdrop(density: .subtle)
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        currentModelCard
                        if service.modelOptions.isEmpty {
                            emptyModelsCard
                        } else {
                            if !favoriteModels.isEmpty {
                                favoriteGroup
                            }
                            ForEach(groupedModels, id: \.provider) { group in
                                providerGroup(group)
                            }
                        }
                    }
                    .padding(AuroraDesign.Layout.cardInset)
                    .padding(.bottom, 24)
                }
            }
            .navigationTitle("Switch Model")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task { await service.refreshRuntime() }
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .accessibilityLabel("Refresh Hermes models")
                }
            }
            .task { await service.refreshRuntime() }
        }
    }

    private var currentModelCard: some View {
        let option = service.selectedModelOption
        let provider = option?.agentProvider ?? hermesAgentProvider(for: service.selectedModelID ?? service.selectedConnection.advertisedModel ?? "hermes")
        let title = option?.displayName ?? service.selectedModelID ?? service.selectedConnection.advertisedModel ?? "Automatic"
        let subtitle = option?.providerName ?? provider.displayName
        return AuroraGlassCard(variant: .hermes, cornerRadius: 18) {
            HStack(spacing: 12) {
                UnifiedProviderLogoView(provider: provider, size: 42, useFallbackColor: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(MobileTheme.Typography.headline)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .lineLimit(1)
                }
                Spacer()
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(MobileTheme.success)
            }
        }
    }

    private var emptyModelsCard: some View {
        AuroraGlassCard(variant: .standard, cornerRadius: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(MobileTheme.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text("No models discovered")
                        .font(MobileTheme.Typography.body)
                        .fontWeight(.semibold)
                        .foregroundStyle(MobileTheme.Colors.textPrimary)
                    Text("Refresh after Hermes is online. The selected relay can still use its advertised default model.")
                        .font(MobileTheme.Typography.caption)
                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func providerGroup(_ group: (provider: String, options: [HermesRuntimeModelOption])) -> some View {
        let provider = hermesAgentProvider(for: group.options.first?.providerID ?? group.provider)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                UnifiedProviderLogoView(provider: provider, size: 24, useFallbackColor: true)
                Text(group.provider)
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                Spacer()
                Text("\(group.options.count)")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            ForEach(group.options) { option in
                HermesModelPickerRow(
                    option: option,
                    isSelected: service.selectedModelID == option.modelID,
                    isFavorite: service.isFavoriteModel(option)
                ) {
                    service.selectModel(option)
                    HapticBus.primaryAction()
                    dismiss()
                } onToggleFavorite: {
                    service.toggleFavoriteModel(option)
                    HapticBus.toggle()
                }
            }
        }
    }

    private var favoriteGroup: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "star.fill")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(MobileTheme.amber)
                Text("Favorites")
                    .font(MobileTheme.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(MobileTheme.Colors.textSecondary)
                Spacer()
                Text("\(favoriteModels.count)")
                    .font(MobileTheme.Typography.tiny)
                    .foregroundStyle(MobileTheme.Colors.textMuted)
            }
            ForEach(favoriteModels) { option in
                HermesModelPickerRow(
                    option: option,
                    isSelected: service.selectedModelID == option.modelID,
                    isFavorite: true
                ) {
                    service.selectModel(option)
                    HapticBus.primaryAction()
                    dismiss()
                } onToggleFavorite: {
                    service.toggleFavoriteModel(option)
                    HapticBus.toggle()
                }
            }
        }
    }
}

struct HermesModelPickerRow: View {
    let option: HermesRuntimeModelOption
    let isSelected: Bool
    let isFavorite: Bool
    let onSelect: () -> Void
    let onToggleFavorite: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 12) {
                    UnifiedProviderLogoView(provider: option.agentProvider, size: 30, useFallbackColor: true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(option.displayName)
                            .font(MobileTheme.Typography.body)
                            .fontWeight(.semibold)
                            .foregroundStyle(MobileTheme.Colors.textPrimary)
                            .lineLimit(1)
                        Text(option.modelID)
                            .font(MobileTheme.Typography.tiny)
                            .foregroundStyle(MobileTheme.Colors.textMuted)
                            .lineLimit(1)
                    }
                    Spacer()
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(MobileTheme.success)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Use \(option.displayName)")
            .accessibilityValue(isSelected ? "Selected" : option.providerName)

            Button(action: onToggleFavorite) {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(isFavorite ? MobileTheme.amber : MobileTheme.Colors.textMuted)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(MobileTheme.Colors.surfaceElevated.opacity(0.75)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isFavorite ? "Remove \(option.displayName) from favorites" : "Add \(option.displayName) to favorites")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(isSelected ? MobileTheme.hermesAureate.opacity(0.16) : MobileTheme.Colors.surfaceElevated.opacity(0.62))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(isSelected ? MobileTheme.hermesAureate.opacity(0.6) : MobileTheme.Colors.border.opacity(0.45), lineWidth: isSelected ? 1 : 0.5)
        )
    }
}

extension HermesService {
    var selectedModelOption: HermesRuntimeModelOption? {
        guard let selectedModelID else { return nil }
        return modelOptions.first { $0.modelID == selectedModelID }
    }
}

extension HermesRuntimeModelOption {
    var agentProvider: AgentProvider {
        hermesAgentProvider(for: [providerID, providerName, modelID].joined(separator: " "))
    }
}

func hermesAgentProvider(for raw: String) -> AgentProvider {
    let lower = raw.lowercased()
    if lower.contains("openai") || lower.contains("gpt") { return .openAI }
    if lower.contains("anthropic") || lower.contains("claude") { return .claudeCode }
    if lower.contains("minimax") || lower.contains("abab") { return .minimax }
    if lower.contains("zai") || lower.contains("z.ai") || lower.contains("glm") { return .zai }
    if lower.contains("kimi") || lower.contains("moonshot") { return .kimi }
    if lower.contains("deepseek") { return .openClaw }
    if lower.contains("google") || lower.contains("gemini") { return .geminiCLI }
    if lower.contains("meta") || lower.contains("llama") || lower.contains("qwen") { return .ollama }
    if lower.contains("codex") { return .codex }
    if lower.contains("hermes") { return .hermes }
    return .openClaw
}

// MARK: - Hermes Message Bubble

struct HermesMessageBubble: View {
    let message: HermesChatMessage

    var isUser: Bool { message.role == .user }

    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if isUser {
                Spacer(minLength: 48)
                userBubble
            } else {
                assistantStack
                Spacer(minLength: 48)
            }
        }
        .transition(.asymmetric(
            insertion: .move(edge: .bottom).combined(with: .opacity),
            removal: .opacity
        ))
    }

    private var userBubble: some View {
        Text(message.text)
            .font(MobileTheme.Typography.body)
            .foregroundStyle(MobileTheme.Colors.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(MobileTheme.Colors.surfaceElevated.opacity(0.85))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(MobileTheme.chatUserStroke, lineWidth: 1)
            )
    }

    @ViewBuilder
    private var assistantStack: some View {
        VStack(alignment: .leading, spacing: 4) {
            // "via Hermes" badge
            HStack(spacing: 4) {
                Text("☿")
                    .font(.system(size: 10, weight: .bold))
                Text("via Hermes")
                    .font(MobileTheme.Typography.tiny)
                    .fontWeight(.semibold)
            }
            .foregroundStyle(MobileTheme.hermesAureate)
            .padding(.leading, 6)

            if !message.text.isEmpty || message.toolCalls.isEmpty {
                Text(message.text)
                    .font(MobileTheme.Typography.body)
                    .foregroundStyle(message.isError ? MobileTheme.Colors.error : MobileTheme.Colors.textPrimary)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(MobileTheme.Colors.surface.opacity(0.85))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(message.isError ? AnyShapeStyle(MobileTheme.error) : AnyShapeStyle(AuroraDesign.Gradients.mercuryFoil), lineWidth: message.isError ? 1.5 : 1)
                    )
                    .overlay {
                        if !message.isError {
                            MercuryShimmerOverlay()
                                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        }
                    }
            }

            ForEach(message.toolCalls) { tool in
                HStack(spacing: 8) {
                    Image(systemName: "wrench.and.screwdriver.fill")
                        .font(.system(size: 11, weight: .bold))
                    Text(tool.name)
                        .font(MobileTheme.Typography.tiny)
                        .fontWeight(.semibold)
                    Spacer(minLength: 8)
                    Text(tool.status)
                        .font(MobileTheme.Typography.tiny)
                        .foregroundStyle(MobileTheme.Colors.textMuted)
                }
                .foregroundStyle(MobileTheme.hermesAureate)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(MobileTheme.Colors.surface.opacity(0.75))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(AuroraDesign.Gradients.mercuryFoil, lineWidth: 0.75)
                )
            }
        }
    }
}

// MARK: - Breathing Dot

private struct BreathingDot: ViewModifier {
    let active: Bool
    @State private var phase = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(active && phase ? 1.5 : 1.0)
            .opacity(active && phase ? 0.55 : 1.0)
            .animation(active ? .easeInOut(duration: 1.4).repeatForever(autoreverses: true) : .default, value: phase)
            .onAppear { phase = true }
    }
}

// MARK: - String helpers

private extension String {
    var nilIfBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
