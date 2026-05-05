import SwiftUI
import OpenBurnBarCore

// MARK: - Hermes Tab View
//
// Hermes promoted to a first-class tab. Welcome thread, quick-prompt rail,
// streaming chat with rich tool cards, and the always-visible connection
// pill.

struct HermesTabView: View {
    @Bindable var service: HermesService
    let dashboardSnapshot: DashboardStore?

    @State private var input: String = ""
    @State private var showClearConfirm = false
    @State private var showConnectionSheet = false
    @State private var showHistorySheet = false
    @State private var showRuntimeSheet = false
    @FocusState private var inputFocused: Bool
    @Namespace private var bubbleNamespace

    init(service: HermesService, dashboardSnapshot: DashboardStore? = nil) {
        self.service = service
        self.dashboardSnapshot = dashboardSnapshot
    }

    var body: some View {
        ZStack {
            AuroraBackdrop()
            VStack(spacing: 0) {
                connectionPill
                    .padding(.horizontal, AuroraDesign.Layout.cardInset)
                    .padding(.bottom, 6)

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
                        showHistorySheet = true
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    Button {
                        showRuntimeSheet = true
                    } label: {
                        Label("Runtime", systemImage: "slider.horizontal.3")
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
        .sheet(isPresented: $showHistorySheet) {
            HermesHistorySheet(service: service)
        }
        .sheet(isPresented: $showRuntimeSheet) {
            HermesRuntimeSheet(service: service)
        }
        .task {
            service.loadHistory()
            await service.checkReachability()
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
        let name = service.selectedConnection.displayName
        return service.isReachable ? "Hermes online · \(name)" : "Hermes offline · \(name)"
    }

    private var runtimeRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Menu {
                    if service.modelOptions.isEmpty {
                        Text("No models discovered")
                    } else {
                        ForEach(service.modelOptions) { option in
                            Button(option.displayName) {
                                service.selectedModelID = option.modelID
                            }
                        }
                    }
                } label: {
                    runtimeChip(
                        icon: "cpu",
                        label: service.selectedModelID ?? service.selectedConnection.advertisedModel ?? "Model"
                    )
                }
                Button {
                    showHistorySheet = true
                } label: {
                    runtimeChip(icon: "clock.arrow.circlepath", label: "\(service.sessions.count) sessions")
                }
                Button {
                    showRuntimeSheet = true
                } label: {
                    runtimeChip(icon: "wrench.and.screwdriver", label: "\(service.profiles.count) profiles · \(service.jobs.count) jobs")
                }
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
                        Text("For cell signal, keep OpenBurnBar running on your Mac, sign in with this account, and enable Hermes Remote Relay in Mac Settings. Then select the Remote Relay host below.")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
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

// MARK: - Hermes History Sheet

private struct HermesHistorySheet: View {
    @Bindable var service: HermesService
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let selectedSessionID = service.selectedSessionID {
                    Section {
                        Button {
                            service.startNewSession()
                            dismiss()
                        } label: {
                            Label("Start New Hermes Session", systemImage: "plus.bubble")
                        }
                        Text("Currently resuming \(service.sessionTitle(for: selectedSessionID)).")
                            .font(MobileTheme.Typography.caption)
                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                    }
                }

                if service.sessions.isEmpty {
                    ContentUnavailableView(
                        "No Hermes History",
                        systemImage: "clock",
                        description: Text("History appears here when the connected Hermes host exposes session metadata.")
                    )
                } else {
                    ForEach(service.sessions) { session in
                        Button {
                            Task {
                                await service.resumeSession(session)
                                dismiss()
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(session.title ?? "Hermes Session")
                                        .font(MobileTheme.Typography.body)
                                        .fontWeight(.semibold)
                                    Spacer()
                                    if service.selectedSessionID == session.id {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(MobileTheme.hermesAureate)
                                    }
                                }
                                if let preview = session.preview {
                                    Text(preview)
                                        .font(MobileTheme.Typography.caption)
                                        .foregroundStyle(MobileTheme.Colors.textSecondary)
                                        .lineLimit(2)
                                }
                                HStack(spacing: 10) {
                                    if let model = session.model {
                                        Label(model, systemImage: "cpu")
                                    }
                                    Label("\(session.messageCount) messages", systemImage: "text.bubble")
                                    if let lastActiveAt = session.lastActiveAt {
                                        Text(lastActiveAt, style: .relative)
                                    }
                                }
                                .font(MobileTheme.Typography.tiny)
                                .foregroundStyle(MobileTheme.Colors.textMuted)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Hermes History")
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
                            Button {
                                service.selectedModelID = option.modelID
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(option.displayName)
                                            .font(MobileTheme.Typography.body)
                                        Text(option.providerName)
                                            .font(MobileTheme.Typography.tiny)
                                            .foregroundStyle(MobileTheme.Colors.textSecondary)
                                    }
                                    Spacer()
                                    if service.selectedModelID == option.modelID {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(MobileTheme.hermesAureate)
                                    }
                                }
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
