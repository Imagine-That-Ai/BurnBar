import SwiftUI
import OpenBurnBarCore
import OpenBurnBarMedia
import FirebaseAuth

// Resize handle, thread routing, pinned route, runtime-history sidebar, coordinator selection.
// Extracted from HermesSquareSplitLayout.swift (god-file decomposition) — same module, verbatim.

struct HermesSquareResizeHandle: View {
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(DesignSystemColors.borderSubtle.opacity(isHovering ? 0.95 : 0.7))
            .frame(width: 10)
            .overlay {
                Capsule()
                    .fill(DesignSystemColors.textMuted.opacity(isHovering ? 0.55 : 0.28))
                    .frame(width: 3, height: 44)
            }
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
    }
}

enum HermesSquareThreadRouting {
    static func runtime(for item: ThreadInboxItem) -> AssistantRuntimeID? {
        AgentIdentity.builtInRuntime(from: item.agentURI)
    }

    static func rawThreadID(from inboxID: String) -> String {
        inboxID.split(separator: ":", maxSplits: 1).last.map(String.init) ?? inboxID
    }
}

@MainActor
enum HermesSquarePinnedRoute {
    static func route(
        for uri: String,
        registry: AgentIdentityRegistry,
        visibleTiles: [AssistantRuntimeID]
    ) -> HermesSquareSplitLayout.DetailRoute? {
        if uri.hasPrefix(AgentIdentityRegistry.pairedMacURIPrefix) {
            let connectionID = String(uri.dropFirst(AgentIdentityRegistry.pairedMacURIPrefix.count))
            return .mercuryLive(connectionID)
        }
        guard let identity = registry.identity(for: uri) else { return nil }
        if let runtime = identity.runtimeID, visibleTiles.contains(runtime) {
            return .runtimeNative(runtime)
        }
        return .brandZone(uri)
    }
}

struct HermesSquareRuntimeHistorySidebar: View {
    let runtime: AssistantRuntimeID
    let missionHost: MobileMissionConsoleHost
    let onBack: () -> Void
    let onOpenThread: (ThreadInboxItem) -> Void

    @State private var inbox: ThreadInboxStore
    @State private var historyStore = MobileChatHistoryStore.shared
    @State private var registry = AgentIdentityRegistry.shared

    @State private var renameTargetItem: ThreadInboxItem?
    @State private var newTitleText: String = ""
    @State private var isShowingRenameAlert: Bool = false

    init(
        runtime: AssistantRuntimeID,
        missionHost: MobileMissionConsoleHost,
        onBack: @escaping () -> Void,
        onOpenThread: @escaping (ThreadInboxItem) -> Void
    ) {
        self.runtime = runtime
        self.missionHost = missionHost
        self.onBack = onBack
        self.onOpenThread = onOpenThread
        _inbox = State(initialValue: ThreadInboxStore(
            historyStore: MobileChatHistoryStore.shared,
            cliReader: .shared,
            missionHost: missionHost
        ))
    }

    var body: some View {
        ZStack {
            WebsiteBackgroundView(accent: .purple, visibility: .subtle)
                .environment(\.webglBackdropAncestorActive, true)
                .ignoresSafeArea()
            VStack(spacing: 0) {
                header
                ScrollView {
                    LazyVStack(spacing: 8) {
                        if rows.isEmpty {
                            emptyState
                        } else {
                            ForEach(rows) { item in
                                Button {
                                    onOpenThread(item)
                                } label: {
                                    HermesSquareThreadRow(item: item, registry: registry)
                                }
                                .buttonStyle(.plain)
                                .contextMenu {
                                    Button {
                                        renameTargetItem = item
                                        newTitleText = item.customTitle ?? item.title
                                        isShowingRenameAlert = true
                                    } label: {
                                        Label("Rename Conversation", systemImage: "pencil")
                                    }

                                    Menu("Label Color") {
                                        Button {
                                            updateThreadItemMetadata(item: item, labelColorHex: "#f59e0b")
                                        } label: {
                                            Label("Amber", systemImage: item.labelColorHex == "#f59e0b" ? "checkmark.circle.fill" : "circle")
                                        }
                                        Button {
                                            updateThreadItemMetadata(item: item, labelColorHex: "#14b8a6")
                                        } label: {
                                            Label("Teal", systemImage: item.labelColorHex == "#14b8a6" ? "checkmark.circle.fill" : "circle")
                                        }
                                        Button {
                                            updateThreadItemMetadata(item: item, labelColorHex: "#ef4444")
                                        } label: {
                                            Label("Red", systemImage: item.labelColorHex == "#ef4444" ? "checkmark.circle.fill" : "circle")
                                        }
                                        Button {
                                            updateThreadItemMetadata(item: item, labelColorHex: "#a855f7")
                                        } label: {
                                            Label("Purple", systemImage: item.labelColorHex == "#a855f7" ? "checkmark.circle.fill" : "circle")
                                        }
                                        Button {
                                            updateThreadItemMetadata(item: item, labelColorHex: "#10b981")
                                        } label: {
                                            Label("Emerald", systemImage: item.labelColorHex == "#10b981" ? "checkmark.circle.fill" : "circle")
                                        }
                                        Button {
                                            updateThreadItemMetadata(item: item, labelColorHex: "#NONE#")
                                        } label: {
                                            Label("None", systemImage: item.labelColorHex == nil ? "checkmark.circle.fill" : "circle")
                                        }
                                    }

                                    Button {
                                        updateThreadItemMetadata(item: item, isPinned: !item.isPinned)
                                    } label: {
                                        Label(item.isPinned ? "Unpin from Top" : "Pin to Top", systemImage: item.isPinned ? "pin.slash.fill" : "pin.fill")
                                    }

                                    Button {
                                        moveThreadItem(item, direction: .up)
                                    } label: {
                                        Label("Move Up", systemImage: "arrow.up")
                                    }

                                    Button {
                                        moveThreadItem(item, direction: .down)
                                    } label: {
                                        Label("Move Down", systemImage: "arrow.down")
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 12)
                }
                .refreshable {
                    await inbox.refresh()
                }
            }
        }
        .task {
            inbox.bind(historyStore: historyStore, missionHost: missionHost)
            await registry.refresh(hermesService: HermesService.shared, piService: PiService.shared, missionHost: missionHost)
            await inbox.refresh()
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename Conversation", isPresented: $isShowingRenameAlert) {
            TextField("New Title", text: $newTitleText)
            Button("Cancel", role: .cancel) {
                renameTargetItem = nil
            }
            Button("Rename") {
                if let item = renameTargetItem {
                    updateThreadItemMetadata(item: item, customTitle: newTitleText)
                }
                renameTargetItem = nil
            }
        } message: {
            Text("Enter a new title for this conversation.")
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                onBack()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DesignSystemColors.textPrimary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(DesignSystemColors.surface.opacity(0.85)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Agents")

            VStack(alignment: .leading, spacing: 2) {
                Text("\(runtime.displayName) History")
                    .font(.headline.bold())
                    .foregroundStyle(DesignSystemColors.textPrimary)
                Text("\(rows.count) conversations")
                    .font(.caption)
                    .foregroundStyle(DesignSystemColors.textMuted)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(DesignSystemColors.surface.opacity(0.55))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignSystemColors.borderSubtle.opacity(0.7))
                .frame(height: 0.5)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(DesignSystemColors.textMuted)
            Text("No \(runtime.displayName) conversations yet.")
                .font(.caption)
                .foregroundStyle(DesignSystemColors.textMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 48)
    }

    private var rows: [ThreadInboxItem] {
        let (service, _) = inbox.items.splitForInbox()
        return service.filter { item in
            HermesSquareThreadRouting.runtime(for: item) == runtime
        }
    }

    private enum MoveDirection {
        case up, down
    }

    private func updateThreadItemMetadata(
        item: ThreadInboxItem,
        customTitle: String? = nil,
        labelColorHex: String? = nil,
        isPinned: Bool? = nil,
        priorityOrder: Int? = nil
    ) {
        let parts = item.id.split(separator: ":", maxSplits: 1)
        guard parts.count == 2 else { return }
        let prefix = parts[0]
        let rawId = String(parts[1])

        if prefix == "cli" {
            Task {
                do {
                    try await CLIAgentChatReader.shared.updateSessionMetadata(
                        id: rawId,
                        customTitle: customTitle,
                        labelColorHex: labelColorHex,
                        isPinned: isPinned,
                        priorityOrder: priorityOrder
                    )
                    await inbox.refresh()
                } catch {
                    print("Error updating CLI session metadata: \(error)")
                }
            }
        } else if prefix == "hermes" || prefix == "pi" || prefix == "cliMirror" {
            MobileChatHistoryStore.shared.updateThreadMetadata(
                id: rawId,
                customTitle: customTitle,
                labelColorHex: labelColorHex,
                isPinned: isPinned,
                priorityOrder: priorityOrder
            )
            Task {
                await inbox.refresh()
            }
        }
    }

    private func moveThreadItem(_ item: ThreadInboxItem, direction: MoveDirection) {
        let conversations = rows.filter { $0.source != .missionGroup }
        guard let index = conversations.firstIndex(where: { $0.id == item.id }) else { return }

        var newConversations = conversations
        if direction == .up && index > 0 {
            newConversations.swapAt(index, index - 1)
        } else if direction == .down && index < conversations.count - 1 {
            newConversations.swapAt(index, index + 1)
        } else {
            return
        }

        for (i, element) in newConversations.enumerated() {
            let newPriority = i + 1
            if element.priorityOrder != newPriority {
                updateThreadItemMetadata(item: element, priorityOrder: newPriority)
            }
        }
    }
}

@MainActor
enum MercuryLiveCoordinatorSelection {
    static func shouldUse(
        activeConnectionID: String?,
        requestedConnectionID: String,
        phase: MediaControlStreamCoordinator.Phase
    ) -> Bool {
        switch phase {
        case .idle, .stopped, .failed:
            return false
        case .dialing, .live, .reconnecting:
            break
        }

        guard let activeConnectionID,
              !activeConnectionID.isEmpty else {
            return false
        }

        if activeConnectionID == requestedConnectionID {
            return true
        }

        // Legacy persisted pins can still route as `paired-mac:default`
        // before relay discovery hydrates. Once a real relay coordinator is
        // active, that coordinator is the concrete Mac target for the
        // virtual paired-Mac route.
        return requestedConnectionID.hasPrefix("paired-mac:")
            && !activeConnectionID.hasPrefix("paired-mac:")
    }
}
