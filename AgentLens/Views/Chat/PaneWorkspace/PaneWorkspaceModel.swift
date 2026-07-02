import Foundation
import SwiftUI
import OpenBurnBarCore
#if canImport(AppKit)
import AppKit
#endif

// cmux-style tiling for the Chat workspace.
//
// A workspace is a set of tabs. Each tab owns one binary split tree. Exactly one
// leaf across all tabs is primary: it reuses the app-wide ChatSessionController.
// Every other leaf has an isolated controller with persistsViewState == false.

enum PaneSplitAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

enum PaneEdge: String, Codable, Sendable {
    case leading
    case trailing
    case top
    case bottom

    var splitAxis: PaneSplitAxis {
        switch self {
        case .leading, .trailing: return .horizontal
        case .top, .bottom: return .vertical
        }
    }

    var movedLeafComesFirst: Bool {
        switch self {
        case .leading, .top: return true
        case .trailing, .bottom: return false
        }
    }
}

enum PaneColorToken: String, Codable, CaseIterable, Identifiable, Sendable {
    case whimsy
    case aureate
    case ember
    case amber
    case success
    case frost

    var id: String { rawValue }

    @MainActor
    var color: Color {
        switch self {
        case .whimsy: return DesignSystem.Colors.whimsy
        case .aureate: return DesignSystem.Colors.hermesAureate
        case .ember: return DesignSystem.Colors.ember
        case .amber: return DesignSystem.Colors.amber
        case .success: return DesignSystem.Colors.success
        case .frost: return DesignSystem.Colors.frost
        }
    }
}

enum ChatStreamSettleOutcome: Equatable, Sendable {
    case completed
    case failed(cancelled: Bool)

    var isCancelled: Bool {
        if case .failed(let cancelled) = self { return cancelled }
        return false
    }

    var isFailure: Bool {
        if case .failed(let cancelled) = self { return !cancelled }
        return false
    }
}

@MainActor
@Observable
final class PaneLeaf: Identifiable {
    nonisolated let id: UUID
    let controller: ChatSessionController
    let isPrimary: Bool
    var customTitle: String?
    var colorToken: PaneColorToken?
    var unseenCompletionAt: Date?
    var alertsEnabled: Bool

    init(
        id: UUID = UUID(),
        controller: ChatSessionController,
        isPrimary: Bool = false,
        customTitle: String? = nil,
        colorToken: PaneColorToken? = nil,
        unseenCompletionAt: Date? = nil,
        alertsEnabled: Bool = true
    ) {
        self.id = id
        self.controller = controller
        self.isPrimary = isPrimary
        self.customTitle = customTitle
        self.colorToken = colorToken
        self.unseenCompletionAt = unseenCompletionAt
        self.alertsEnabled = alertsEnabled
    }
}

@MainActor
@Observable
final class PaneSplitNode: Identifiable {
    nonisolated let id: UUID
    var axis: PaneSplitAxis
    var fraction: Double
    var first: PaneNode
    var second: PaneNode

    init(id: UUID = UUID(), axis: PaneSplitAxis, fraction: Double, first: PaneNode, second: PaneNode) {
        self.id = id
        self.axis = axis
        self.fraction = fraction
        self.first = first
        self.second = second
    }
}

enum PaneNode: Identifiable {
    case leaf(PaneLeaf)
    case split(PaneSplitNode)

    nonisolated var id: UUID {
        switch self {
        case .leaf(let leaf): return leaf.id
        case .split(let split): return split.id
        }
    }
}

@MainActor
@Observable
final class ChatWorkspaceTab: Identifiable {
    nonisolated let id: UUID
    var title: String?
    var colorToken: PaneColorToken?
    var root: PaneNode
    var activeLeafID: UUID
    var zoomedPaneID: UUID?

    init(
        id: UUID = UUID(),
        title: String? = nil,
        colorToken: PaneColorToken? = nil,
        root: PaneNode,
        activeLeafID: UUID,
        zoomedPaneID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.colorToken = colorToken
        self.root = root
        self.activeLeafID = activeLeafID
        self.zoomedPaneID = zoomedPaneID
    }

    var leaves: [PaneLeaf] { PaneWorkspaceModel.collectLeaves(root) }
    var paneCount: Int { leaves.count }
    var hasUnseenCompletion: Bool { leaves.contains { $0.unseenCompletionAt != nil } }
    var isStreaming: Bool { leaves.contains { $0.controller.isStreaming || $0.controller.isSendBusy } }

    var activeLeaf: PaneLeaf? {
        leaves.first { $0.id == activeLeafID }
    }
}

// MARK: - Persisted snapshots

indirect enum PaneLayoutSnapshot: Codable {
    case leaf(paneID: UUID, threadID: String, isPrimary: Bool)
    case split(axis: PaneSplitAxis, fraction: Double, first: PaneLayoutSnapshot, second: PaneLayoutSnapshot)
}

struct PaneWorkspaceSnapshot: Codable {
    let root: PaneLayoutSnapshot
    let activePaneID: UUID
}

struct PaneLeafSnapshotV2: Codable {
    let paneID: UUID
    let threadID: String
    let isPrimary: Bool
    let title: String?
    let colorToken: PaneColorToken?
    let backend: String?
    let model: String?
    let viewMode: String?
    let unseenAt: Date?
    let alertsEnabled: Bool
}

indirect enum PaneLayoutSnapshotV2: Codable {
    case leaf(PaneLeafSnapshotV2)
    case split(axis: PaneSplitAxis, fraction: Double, first: PaneLayoutSnapshotV2, second: PaneLayoutSnapshotV2)
}

struct WorkspaceTabSnapshotV2: Codable {
    let tabID: UUID
    let title: String?
    let colorToken: PaneColorToken?
    let root: PaneLayoutSnapshotV2
    let activePaneID: UUID
    let zoomedPaneID: UUID?
}

struct PaneWorkspaceSnapshotV2: Codable {
    let version: Int
    let tabs: [WorkspaceTabSnapshotV2]
    let selectedTabID: UUID
}

// MARK: - Workspace model

@MainActor
@Observable
final class PaneWorkspaceModel {
    static let minFraction: Double = 0.15
    static let maxFraction: Double = 0.85
    static let udPaneLayout = "paneWorkspace.layoutTree"

    private static var sharedInstance: PaneWorkspaceModel?

    var tabs: [ChatWorkspaceTab]
    var selectedTabID: UUID
    var draggingPaneID: UUID?

    @ObservationIgnored var primaryDidInitialLoad = false
    @ObservationIgnored var closedTabStack: [WorkspaceTabSnapshotV2] = []
    @ObservationIgnored let dataStore: DataStore
    @ObservationIgnored let settingsManager: SettingsManager
    @ObservationIgnored let primaryController: ChatSessionController
    @ObservationIgnored let defaults: UserDefaults
    @ObservationIgnored let alertCenter: ChatPaneAlertCenter
    @ObservationIgnored var mountedViewCount = 0
    @ObservationIgnored var isAppFrontmost: () -> Bool = {
        #if canImport(AppKit)
        NSApp.isActive
        #else
        true
        #endif
    }

    init(
        tabs: [ChatWorkspaceTab],
        selectedTabID: UUID,
        dataStore: DataStore,
        settingsManager: SettingsManager,
        primaryController: ChatSessionController,
        defaults: UserDefaults = .standard,
        alertCenter: ChatPaneAlertCenter = ChatPaneAlertCenter()
    ) {
        self.tabs = tabs
        self.selectedTabID = tabs.contains { $0.id == selectedTabID } ? selectedTabID : (tabs.first?.id ?? selectedTabID)
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.primaryController = primaryController
        self.defaults = defaults
        self.alertCenter = alertCenter
        installSettleHooks()
    }

    convenience init(
        root: PaneNode,
        activeLeafID: UUID,
        dataStore: DataStore,
        settingsManager: SettingsManager,
        primaryController: ChatSessionController,
        defaults: UserDefaults = .standard,
        alertCenter: ChatPaneAlertCenter = ChatPaneAlertCenter()
    ) {
        let tab = ChatWorkspaceTab(root: root, activeLeafID: activeLeafID)
        self.init(
            tabs: [tab],
            selectedTabID: tab.id,
            dataStore: dataStore,
            settingsManager: settingsManager,
            primaryController: primaryController,
            defaults: defaults,
            alertCenter: alertCenter
        )
    }

    // MARK: Shared instance

    static func shared(
        primaryController: ChatSessionController,
        dataStore: DataStore,
        settingsManager: SettingsManager,
        alertCenter: ChatPaneAlertCenter = ChatPaneAlertCenter()
    ) -> PaneWorkspaceModel {
        if let sharedInstance, sharedInstance.primaryController === primaryController {
            return sharedInstance
        }
        let restored = restore(
            primaryController: primaryController,
            dataStore: dataStore,
            settingsManager: settingsManager,
            alertCenter: alertCenter
        )
        sharedInstance = restored
        return restored
    }

    static func resetSharedForTesting() {
        sharedInstance = nil
    }

    // MARK: Compatibility proxies and derived state

    var selectedTab: ChatWorkspaceTab {
        if let tab = tabs.first(where: { $0.id == selectedTabID }) {
            return tab
        }
        if tabs.isEmpty {
            let leaf = PaneLeaf(controller: primaryController, isPrimary: true)
            let tab = ChatWorkspaceTab(root: .leaf(leaf), activeLeafID: leaf.id)
            tabs = [tab]
            selectedTabID = tab.id
            return tab
        }
        selectedTabID = tabs[0].id
        return tabs[0]
    }

    var root: PaneNode {
        get { selectedTab.root }
        set { selectedTab.root = newValue }
    }

    var activeLeafID: UUID {
        get { selectedTab.activeLeafID }
        set { selectedTab.activeLeafID = newValue }
    }

    var leaves: [PaneLeaf] { selectedTab.leaves }
    var allLeaves: [PaneLeaf] { tabs.flatMap(\.leaves) }
    var paneCount: Int { selectedTab.paneCount }
    var isTiled: Bool { paneCount > 1 }
    var boundThreadIDs: Set<String> { Set(allLeaves.map { $0.controller.activeThreadID }) }
    var unseenThreadIDs: Set<String> {
        Set(allLeaves.filter { $0.unseenCompletionAt != nil }.map { $0.controller.activeThreadID })
    }

    var activeController: ChatSessionController {
        leaf(activeLeafID)?.controller ?? primaryController
    }

    func leaf(_ id: UUID) -> PaneLeaf? {
        selectedTab.leaves.first { $0.id == id }
    }

    func leafAnywhere(_ id: UUID) -> PaneLeaf? {
        allLeaves.first { $0.id == id }
    }

    func tab(containing leafID: UUID) -> ChatWorkspaceTab? {
        tabs.first { tab in tab.leaves.contains { $0.id == leafID } }
    }

    func displayTitle(for tab: ChatWorkspaceTab) -> String {
        if let title = tab.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        if let leaf = tab.activeLeaf {
            let threadTitle = threadTitle(for: leaf.controller.activeThreadID)
            if !threadTitle.isEmpty { return threadTitle }
            return leaf.customTitle ?? leaf.controller.chatBackend.displayName
        }
        if let idx = tabs.firstIndex(where: { $0.id == tab.id }) {
            return "Tab \(idx + 1)"
        }
        return "Tab"
    }

    func threadTitle(for threadID: String) -> String {
        primaryController.historyThreads.first { $0.id == threadID }?.title ?? ""
    }

    // MARK: Selection and tabs

    func setActive(_ id: UUID) {
        guard leaf(id) != nil else { return }
        selectedTab.activeLeafID = id
        markSeenIfVisible(id)
        persist()
    }

    func selectTab(_ id: UUID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        selectedTabID = id
        if let active = selectedTab.activeLeaf {
            markSeenIfVisible(active.id)
        }
        persist()
    }

    func selectAdjacentTab(offset: Int) {
        guard tabs.count > 1, let idx = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        let next = (idx + offset + tabs.count) % tabs.count
        selectTab(tabs[next].id)
    }

    func focusAdjacentPane(offset: Int) {
        let visibleLeaves = leaves
        guard visibleLeaves.count > 1,
              let idx = visibleLeaves.firstIndex(where: { $0.id == activeLeafID })
        else { return }
        let next = (idx + offset + visibleLeaves.count) % visibleLeaves.count
        setActive(visibleLeaves[next].id)
    }

    func newTab(bindingThreadID: String? = nil) {
        let trimmedThreadID = bindingThreadID?.trimmingCharacters(in: .whitespacesAndNewlines)
        let threadID = trimmedThreadID.nilIfEmpty ?? UUID().uuidString
        let controller = makePaneController(threadID: threadID, source: activeController)
        let leaf = PaneLeaf(controller: controller)
        installSettleHook(for: leaf)
        let tab = ChatWorkspaceTab(root: .leaf(leaf), activeLeafID: leaf.id)
        tabs.append(tab)
        selectedTabID = tab.id
        if bindingThreadID == nil {
            Task { [dataStore] in _ = try? await dataStore.createChatThread(id: threadID) }
        }
        persist()
    }

    func closeTab(_ id: UUID? = nil) {
        let tabID = id ?? selectedTabID
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let closing = tabs[index]
        if closing.leaves.contains(where: \.isPrimary) {
            closePrimaryTab(at: index)
            return
        }

        pushClosedTabSnapshot(closing)
        closing.leaves.forEach { $0.controller.teardownForPaneClose() }
        tabs.remove(at: index)
        if selectedTabID == tabID {
            selectedTabID = tabs[min(index, tabs.count - 1)].id
        }
        persist()
    }

    private func closePrimaryTab(at index: Int) {
        let closing = tabs[index]
        let survivorIndex = index == 0 ? 1 : index - 1
        let survivorTab = tabs[survivorIndex]
        guard let survivor = survivorTab.activeLeaf ?? survivorTab.leaves.first else { return }
        guard !survivor.controller.isSendBusy else {
            selectedTabID = survivorTab.id
            survivorTab.activeLeafID = survivor.id
            persist()
            return
        }

        pushClosedTabSnapshot(closing)
        let survivorThread = survivor.controller.activeThreadID
        let survivorTitle = survivor.customTitle
        let survivorColor = survivor.colorToken
        let survivorUnseen = survivor.unseenCompletionAt
        let survivorAlerts = survivor.alertsEnabled

        primaryController.teardownForPaneClose()
        primaryController.copyPaneConversationControls(from: survivor.controller)
        survivor.controller.teardownForPaneClose()
        primaryController.openHistoryThread(survivorThread)

        let rehomed = PaneLeaf(
            id: survivor.id,
            controller: primaryController,
            isPrimary: true,
            customTitle: survivorTitle,
            colorToken: survivorColor,
            unseenCompletionAt: survivorUnseen,
            alertsEnabled: survivorAlerts
        )
        installSettleHook(for: rehomed)
        survivorTab.root = Self.replaceLeafNode(survivor.id, in: survivorTab.root, with: .leaf(rehomed))
        survivorTab.activeLeafID = rehomed.id

        closing.leaves.filter { !$0.isPrimary }.forEach { $0.controller.teardownForPaneClose() }
        tabs.remove(at: index)
        selectedTabID = survivorTab.id
        persist()
    }

    func reopenClosedTab() {
        guard let snapshot = closedTabStack.popLast() else { return }
        let tab = buildTab(from: snapshot, allowPrimary: false)
        tabs.append(tab)
        selectedTabID = tab.id
        installSettleHooks()
        persist()
    }

    func renameTab(_ id: UUID, title: String?) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        tab.title = trimmedTitle.nilIfEmpty
        persist()
    }

    func setTabColor(_ id: UUID, colorToken: PaneColorToken?) {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.colorToken = colorToken
        persist()
    }

    func closeOtherTabs(keeping id: UUID) {
        let closingIDs = tabs.map(\.id).filter { $0 != id }
        closingIDs.forEach { closeTab($0) }
    }

    // MARK: Pane mutations

    func splitActive(axis: PaneSplitAxis) {
        guard let target = leaf(activeLeafID) else { return }
        selectedTab.zoomedPaneID = nil
        let newThreadID = UUID().uuidString
        let controller = makePaneController(threadID: newThreadID, source: target.controller)
        let newLeaf = PaneLeaf(controller: controller, colorToken: target.colorToken)
        installSettleHook(for: newLeaf)
        let newSplit = PaneSplitNode(
            axis: axis,
            fraction: 0.5,
            first: .leaf(target),
            second: .leaf(newLeaf)
        )
        replaceNode(withID: target.id, with: .split(newSplit))
        selectedTab.activeLeafID = newLeaf.id
        Task { [dataStore] in _ = try? await dataStore.createChatThread(id: newThreadID) }
        persist()
    }

    func closeActive() {
        guard paneCount > 1, let target = leaf(activeLeafID) else { return }
        guard let parent = Self.parentSplit(of: target.id, in: root) else { return }
        selectedTab.zoomedPaneID = nil
        let siblingNode: PaneNode = parent.first.id == target.id ? parent.second : parent.first

        if target.isPrimary {
            let survivor = Self.firstLeaf(in: siblingNode)
            guard !survivor.controller.isSendBusy else {
                selectedTab.activeLeafID = survivor.id
                persist()
                return
            }
            let survivorThread = survivor.controller.activeThreadID
            primaryController.teardownForPaneClose()
            primaryController.copyPaneConversationControls(from: survivor.controller)
            survivor.controller.teardownForPaneClose()
            primaryController.openHistoryThread(survivorThread)
            let rehomed = PaneLeaf(
                id: survivor.id,
                controller: primaryController,
                isPrimary: true,
                customTitle: survivor.customTitle,
                colorToken: survivor.colorToken,
                unseenCompletionAt: survivor.unseenCompletionAt,
                alertsEnabled: survivor.alertsEnabled
            )
            installSettleHook(for: rehomed)
            let newSibling = Self.replaceLeafNode(survivor.id, in: siblingNode, with: .leaf(rehomed))
            replaceNode(withID: parent.id, with: newSibling)
            selectedTab.activeLeafID = rehomed.id
        } else {
            target.controller.teardownForPaneClose()
            replaceNode(withID: parent.id, with: siblingNode)
            selectedTab.activeLeafID = Self.firstLeaf(in: siblingNode).id
        }
        persist()
    }

    @discardableResult
    func performCloseShortcut() -> Bool {
        if paneCount > 1 {
            closeActive()
            return true
        }
        if tabs.count > 1 {
            closeTab(selectedTabID)
            return true
        }
        return false
    }

    func bind(threadID: String, toLeaf id: UUID) {
        guard let leaf = leafAnywhere(id) else { return }
        leaf.controller.openHistoryThread(threadID)
        focusPane(id, inTab: tab(containing: id)?.id)
        persist()
    }

    @discardableResult
    func bindExistingThread(_ rawThreadID: String, toLeaf id: UUID) async -> Bool {
        let threadID = rawThreadID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !threadID.isEmpty, let target = leafAnywhere(id) else { return false }
        do {
            guard try await dataStore.chatThreadExists(id: threadID) else { return false }
            await target.controller.openHistoryThreadAsync(threadID)
            guard leafAnywhere(id) != nil else { return false }
            focusPane(id, inTab: tab(containing: id)?.id)
            persist()
            return true
        } catch {
            AppLogger.chat.silentFailure("chatThreadExists (pane drop)", error: error)
            return false
        }
    }

    func renamePane(_ id: UUID, title: String?) {
        guard let leaf = leafAnywhere(id) else { return }
        let trimmedTitle = title?.trimmingCharacters(in: .whitespacesAndNewlines)
        leaf.customTitle = trimmedTitle.nilIfEmpty
        persist()
    }

    func setPaneColor(_ id: UUID, colorToken: PaneColorToken?) {
        guard let leaf = leafAnywhere(id) else { return }
        leaf.colorToken = colorToken
        persist()
    }

    func setPaneAlertsEnabled(_ id: UUID, enabled: Bool) {
        guard let leaf = leafAnywhere(id) else { return }
        leaf.alertsEnabled = enabled
        persist()
    }

    func swapPanes(_ a: UUID, _ b: UUID) {
        guard a != b,
              let leafA = leafAnywhere(a),
              let leafB = leafAnywhere(b),
              let tabA = tab(containing: a),
              let tabB = tab(containing: b)
        else { return }
        tabA.zoomedPaneID = nil
        tabB.zoomedPaneID = nil
        if tabA.id == tabB.id {
            tabA.root = Self.swapLeaves(in: tabA.root, a: leafA, b: leafB)
        } else {
            tabA.root = Self.replaceLeafNode(a, in: tabA.root, with: .leaf(leafB))
            tabB.root = Self.replaceLeafNode(b, in: tabB.root, with: .leaf(leafA))
        }
        tabA.activeLeafID = b
        tabB.activeLeafID = a
        persist()
    }

    func movePane(_ id: UUID, toEdge edge: PaneEdge, of targetID: UUID) {
        guard id != targetID,
              let sourceTab = tab(containing: id),
              let targetTab = tab(containing: targetID),
              sourceTab.paneCount > 1,
              let detach = Self.detachingLeaf(id, from: sourceTab.root),
              let targetNode = Self.node(forLeafID: targetID, in: targetTab.root)
        else { return }
        sourceTab.root = detach.root
        sourceTab.zoomedPaneID = nil
        targetTab.zoomedPaneID = nil
        let movedNode = PaneNode.leaf(detach.leaf)
        let split = PaneSplitNode(
            axis: edge.splitAxis,
            fraction: 0.5,
            first: edge.movedLeafComesFirst ? movedNode : targetNode,
            second: edge.movedLeafComesFirst ? targetNode : movedNode
        )
        targetTab.root = Self.replaceLeafNode(targetID, in: targetTab.root, with: .split(split))
        sourceTab.activeLeafID = Self.firstLeaf(in: sourceTab.root).id
        targetTab.activeLeafID = id
        selectedTabID = targetTab.id
        persist()
    }

    func moveToNewTab(_ id: UUID) {
        guard let sourceTab = tab(containing: id),
              sourceTab.paneCount > 1,
              let detach = Self.detachingLeaf(id, from: sourceTab.root)
        else { return }
        sourceTab.root = detach.root
        sourceTab.activeLeafID = Self.firstLeaf(in: detach.root).id
        sourceTab.zoomedPaneID = nil
        let tab = ChatWorkspaceTab(root: .leaf(detach.leaf), activeLeafID: detach.leaf.id)
        tabs.append(tab)
        selectedTabID = tab.id
        persist()
    }

    func movePane(_ id: UUID, toTab targetTabID: UUID) {
        guard let sourceTab = tab(containing: id),
              let targetTab = tabs.first(where: { $0.id == targetTabID }),
              sourceTab.id != targetTab.id,
              sourceTab.paneCount > 1,
              let activeTarget = targetTab.activeLeaf,
              let detach = Self.detachingLeaf(id, from: sourceTab.root)
        else { return }
        sourceTab.root = detach.root
        sourceTab.activeLeafID = Self.firstLeaf(in: detach.root).id
        sourceTab.zoomedPaneID = nil
        targetTab.zoomedPaneID = nil
        let split = PaneSplitNode(
            axis: .horizontal,
            fraction: 0.5,
            first: .leaf(activeTarget),
            second: .leaf(detach.leaf)
        )
        targetTab.root = Self.replaceLeafNode(activeTarget.id, in: targetTab.root, with: .split(split))
        targetTab.activeLeafID = id
        selectedTabID = targetTab.id
        persist()
    }

    func toggleZoomActive() {
        guard paneCount > 1 else { return }
        selectedTab.zoomedPaneID = selectedTab.zoomedPaneID == activeLeafID ? nil : activeLeafID
        persist()
    }

    func clearZoom() {
        guard selectedTab.zoomedPaneID != nil else { return }
        selectedTab.zoomedPaneID = nil
        persist()
    }

    // MARK: Alerts and seen state

    func handleStreamSettled(leafID: UUID, outcome: ChatStreamSettleOutcome) {
        guard !outcome.isCancelled, let leaf = leafAnywhere(leafID), let tab = tab(containing: leafID) else { return }
        if isPaneVisible(leafID), selectedTab.activeLeafID == leafID, isAppFrontmost() {
            markSeen(leafID)
            return
        }
        leaf.unseenCompletionAt = Date()
        persist()
        guard leaf.alertsEnabled else { return }
        alertCenter.postCompletion(
            .init(
                paneID: leafID,
                tabID: tab.id,
                threadID: leaf.controller.activeThreadID,
                backendLabel: leaf.controller.chatBackend.displayName,
                title: leaf.customTitle ?? tab.title ?? threadTitle(for: leaf.controller.activeThreadID),
                preview: leaf.controller.messages.last?.content ?? "",
                isFailure: outcome.isFailure
            )
        )
    }

    func markSeen(_ leafID: UUID) {
        guard let leaf = leafAnywhere(leafID), leaf.unseenCompletionAt != nil else { return }
        leaf.unseenCompletionAt = nil
        alertCenter.withdraw(paneID: leafID)
        persist()
    }

    func markSeenIfVisible(_ leafID: UUID) {
        guard isPaneVisible(leafID) else { return }
        markSeen(leafID)
    }

    func isPaneVisible(_ leafID: UUID) -> Bool {
        guard mountedViewCount > 0, let tab = tab(containing: leafID), tab.id == selectedTabID else { return false }
        if let zoom = tab.zoomedPaneID, zoom != leafID { return false }
        return true
    }

    func jumpToMostRecentUnseen() {
        let unseen = allLeaves
            .compactMap { leaf -> (Date, UUID, UUID)? in
                guard let date = leaf.unseenCompletionAt, let tab = tab(containing: leaf.id) else { return nil }
                return (date, leaf.id, tab.id)
            }
            .max { $0.0 < $1.0 }
        guard let unseen else { return }
        focusPane(unseen.1, inTab: unseen.2)
    }

    func focusPane(_ paneID: UUID, inTab tabID: UUID? = nil) {
        let targetTabID = tabID ?? tab(containing: paneID)?.id
        guard let targetTabID, let targetTab = tabs.first(where: { $0.id == targetTabID }),
              targetTab.leaves.contains(where: { $0.id == paneID })
        else { return }
        selectedTabID = targetTabID
        targetTab.activeLeafID = paneID
        targetTab.zoomedPaneID = nil
        markSeenIfVisible(paneID)
        persist()
    }

    // MARK: Controller factory and hooks

    func makePaneController(
        threadID: String,
        source: ChatSessionController? = nil,
        backend: ChatBackendID? = nil,
        model: String? = nil,
        viewMode: ChatViewMode? = nil
    ) -> ChatSessionController {
        let sourceController = source ?? primaryController
        let selectedBackend = backend ?? sourceController.chatBackend
        let controller = ChatSessionController(
            dataStore: dataStore,
            settingsManager: settingsManager,
            memoryService: sourceController.memoryService,
            memoryExtractionEngine: sourceController.memoryExtractionEngine,
            initialThreadID: threadID,
            persistsViewState: false,
            initialBackend: selectedBackend
        )
        controller.copyPaneRuntimeBindings(from: sourceController)
        controller.copyPaneConversationControls(from: sourceController)
        controller.chatBackend = selectedBackend
        if let model, !model.isEmpty {
            controller.setChatModelSelection(model, for: selectedBackend)
        }
        if let viewMode {
            controller.chatViewMode = viewMode
        } else {
            controller.chatViewMode = selectedBackend.requiresCLIAssistantConsent ? .cli : .agent
        }
        return controller
    }

    private func installSettleHooks() {
        allLeaves.forEach { installSettleHook(for: $0) }
    }

    private func installSettleHook(for leaf: PaneLeaf) {
        leaf.controller.onStreamSettled = { [weak self, weak leaf] outcome in
            guard let self, let leaf else { return }
            self.handleStreamSettled(leafID: leaf.id, outcome: outcome)
        }
    }

    // MARK: Persistence

    func persist() {
        let snapshot = PaneWorkspaceSnapshotV2(
            version: 2,
            tabs: tabs.map { Self.snapshot($0) },
            selectedTabID: selectedTabID
        )
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.udPaneLayout)
    }

    static func restore(
        primaryController: ChatSessionController,
        dataStore: DataStore,
        settingsManager: SettingsManager,
        defaults: UserDefaults = .standard,
        alertCenter: ChatPaneAlertCenter = ChatPaneAlertCenter()
    ) -> PaneWorkspaceModel {
        func singlePrimary() -> PaneWorkspaceModel {
            let leaf = PaneLeaf(controller: primaryController, isPrimary: true)
            let tab = ChatWorkspaceTab(root: .leaf(leaf), activeLeafID: leaf.id)
            return PaneWorkspaceModel(
                tabs: [tab],
                selectedTabID: tab.id,
                dataStore: dataStore,
                settingsManager: settingsManager,
                primaryController: primaryController,
                defaults: defaults,
                alertCenter: alertCenter
            )
        }

        guard let data = defaults.data(forKey: udPaneLayout) else { return singlePrimary() }

        if let snapshot = try? JSONDecoder().decode(PaneWorkspaceSnapshotV2.self, from: data),
           snapshot.version == 2,
           !snapshot.tabs.isEmpty {
            let workspace = PaneWorkspaceModel(
                tabs: [],
                selectedTabID: snapshot.selectedTabID,
                dataStore: dataStore,
                settingsManager: settingsManager,
                primaryController: primaryController,
                defaults: defaults,
                alertCenter: alertCenter
            )
            workspace.tabs = snapshot.tabs.map { workspace.buildTab(from: $0, allowPrimary: true) }
            workspace.repairPrimaryInvariant()
            workspace.repairTabSelection()
            return workspace
        }

        if let snapshot = try? JSONDecoder().decode(PaneWorkspaceSnapshot.self, from: data) {
            let workspace = buildFromV1(
                snapshot,
                primaryController: primaryController,
                dataStore: dataStore,
                settingsManager: settingsManager,
                defaults: defaults,
                alertCenter: alertCenter
            )
            workspace.persist()
            return workspace
        }

        return singlePrimary()
    }

    private static func buildFromV1(
        _ snapshot: PaneWorkspaceSnapshot,
        primaryController: ChatSessionController,
        dataStore: DataStore,
        settingsManager: SettingsManager,
        defaults: UserDefaults,
        alertCenter: ChatPaneAlertCenter
    ) -> PaneWorkspaceModel {
        let workspace = PaneWorkspaceModel(
            tabs: [],
            selectedTabID: snapshot.activePaneID,
            dataStore: dataStore,
            settingsManager: settingsManager,
            primaryController: primaryController,
            defaults: defaults,
            alertCenter: alertCenter
        )
        var primaryAssigned = false
        let root = workspace.buildV1Node(snapshot.root, primaryAssigned: &primaryAssigned)
        let leafIDs = Set(collectLeaves(root).map(\.id))
        let active = leafIDs.contains(snapshot.activePaneID) ? snapshot.activePaneID : firstLeaf(in: root).id
        let tab = ChatWorkspaceTab(root: root, activeLeafID: active)
        workspace.tabs = [tab]
        workspace.selectedTabID = tab.id
        workspace.repairPrimaryInvariant()
        return workspace
    }

    private func buildV1Node(_ node: PaneLayoutSnapshot, primaryAssigned: inout Bool) -> PaneNode {
        switch node {
        case .leaf(let paneID, let threadID, let isPrimary):
            if isPrimary && !primaryAssigned {
                primaryAssigned = true
                return .leaf(PaneLeaf(id: paneID, controller: primaryController, isPrimary: true))
            }
            let controller = makePaneController(threadID: threadID, source: primaryController)
            return .leaf(PaneLeaf(id: paneID, controller: controller))
        case .split(let axis, let fraction, let first, let second):
            return .split(PaneSplitNode(
                axis: axis,
                fraction: Self.clampFraction(fraction),
                first: buildV1Node(first, primaryAssigned: &primaryAssigned),
                second: buildV1Node(second, primaryAssigned: &primaryAssigned)
            ))
        }
    }

    private func buildTab(from snapshot: WorkspaceTabSnapshotV2, allowPrimary: Bool) -> ChatWorkspaceTab {
        var primaryAssigned = !allowPrimary || allLeaves.contains(where: \.isPrimary)
        let root = buildV2Node(snapshot.root, primaryAssigned: &primaryAssigned)
        let leafIDs = Set(Self.collectLeaves(root).map(\.id))
        let active = leafIDs.contains(snapshot.activePaneID) ? snapshot.activePaneID : Self.firstLeaf(in: root).id
        let zoom = snapshot.zoomedPaneID.flatMap { leafIDs.contains($0) ? $0 : nil }
        return ChatWorkspaceTab(
            id: snapshot.tabID,
            title: snapshot.title,
            colorToken: snapshot.colorToken,
            root: root,
            activeLeafID: active,
            zoomedPaneID: zoom
        )
    }

    private func buildV2Node(_ node: PaneLayoutSnapshotV2, primaryAssigned: inout Bool) -> PaneNode {
        switch node {
        case .leaf(let snapshot):
            let backend = snapshot.backend.flatMap { ChatBackendID(rawValue: $0) }
            let viewMode = snapshot.viewMode.flatMap { ChatViewMode(rawValue: $0) }
            if snapshot.isPrimary && !primaryAssigned {
                primaryAssigned = true
                return .leaf(PaneLeaf(
                    id: snapshot.paneID,
                    controller: primaryController,
                    isPrimary: true,
                    customTitle: snapshot.title,
                    colorToken: snapshot.colorToken,
                    unseenCompletionAt: snapshot.unseenAt,
                    alertsEnabled: snapshot.alertsEnabled
                ))
            }
            let controller = makePaneController(
                threadID: snapshot.threadID,
                source: primaryController,
                backend: backend,
                model: snapshot.model,
                viewMode: viewMode
            )
            return .leaf(PaneLeaf(
                id: snapshot.paneID,
                controller: controller,
                customTitle: snapshot.title,
                colorToken: snapshot.colorToken,
                unseenCompletionAt: snapshot.unseenAt,
                alertsEnabled: snapshot.alertsEnabled
            ))
        case .split(let axis, let fraction, let first, let second):
            return .split(PaneSplitNode(
                axis: axis,
                fraction: Self.clampFraction(fraction),
                first: buildV2Node(first, primaryAssigned: &primaryAssigned),
                second: buildV2Node(second, primaryAssigned: &primaryAssigned)
            ))
        }
    }

    private func repairTabSelection() {
        if tabs.isEmpty {
            let leaf = PaneLeaf(controller: primaryController, isPrimary: true)
            let tab = ChatWorkspaceTab(root: .leaf(leaf), activeLeafID: leaf.id)
            tabs = [tab]
            selectedTabID = tab.id
        }
        if !tabs.contains(where: { $0.id == selectedTabID }) {
            selectedTabID = tabs[0].id
        }
        for tab in tabs {
            let leafIDs = Set(tab.leaves.map(\.id))
            if !leafIDs.contains(tab.activeLeafID), let first = tab.leaves.first {
                tab.activeLeafID = first.id
            }
            if let zoom = tab.zoomedPaneID, !leafIDs.contains(zoom) {
                tab.zoomedPaneID = nil
            }
        }
    }

    private func repairPrimaryInvariant() {
        var foundPrimary = false
        for tab in tabs {
            for leaf in tab.leaves where leaf.isPrimary {
                if !foundPrimary {
                    foundPrimary = true
                } else {
                    let demoted = PaneLeaf(
                        id: leaf.id,
                        controller: makePaneController(threadID: leaf.controller.activeThreadID, source: primaryController),
                        customTitle: leaf.customTitle,
                        colorToken: leaf.colorToken,
                        unseenCompletionAt: leaf.unseenCompletionAt,
                        alertsEnabled: leaf.alertsEnabled
                    )
                    installSettleHook(for: demoted)
                    tab.root = Self.replaceLeafNode(leaf.id, in: tab.root, with: .leaf(demoted))
                }
            }
        }

        if !foundPrimary, let firstTab = tabs.first, let first = firstTab.leaves.first {
            first.controller.teardownForPaneClose()
            let promoted = PaneLeaf(
                id: first.id,
                controller: primaryController,
                isPrimary: true,
                customTitle: first.customTitle,
                colorToken: first.colorToken,
                unseenCompletionAt: first.unseenCompletionAt,
                alertsEnabled: first.alertsEnabled
            )
            firstTab.root = Self.replaceLeafNode(first.id, in: firstTab.root, with: .leaf(promoted))
            firstTab.activeLeafID = promoted.id
        }
        installSettleHooks()
    }

    private func pushClosedTabSnapshot(_ tab: ChatWorkspaceTab) {
        closedTabStack.append(Self.snapshot(tab))
        if closedTabStack.count > 5 {
            closedTabStack.removeFirst(closedTabStack.count - 5)
        }
    }

    private static func snapshot(_ tab: ChatWorkspaceTab) -> WorkspaceTabSnapshotV2 {
        WorkspaceTabSnapshotV2(
            tabID: tab.id,
            title: tab.title,
            colorToken: tab.colorToken,
            root: snapshotV2(tab.root),
            activePaneID: tab.activeLeafID,
            zoomedPaneID: tab.zoomedPaneID
        )
    }

    private static func snapshotV2(_ node: PaneNode) -> PaneLayoutSnapshotV2 {
        switch node {
        case .leaf(let leaf):
            let backend = leaf.controller.chatBackend
            let model = leaf.controller.chatModelSelection(for: backend).nilIfEmpty
            return .leaf(PaneLeafSnapshotV2(
                paneID: leaf.id,
                threadID: leaf.controller.activeThreadID,
                isPrimary: leaf.isPrimary,
                title: leaf.customTitle,
                colorToken: leaf.colorToken,
                backend: backend.rawValue,
                model: model,
                viewMode: leaf.controller.chatViewMode.rawValue,
                unseenAt: leaf.unseenCompletionAt,
                alertsEnabled: leaf.alertsEnabled
            ))
        case .split(let split):
            return .split(
                axis: split.axis,
                fraction: split.fraction,
                first: snapshotV2(split.first),
                second: snapshotV2(split.second)
            )
        }
    }

    // MARK: Tree helpers

    private func replaceNode(withID id: UUID, with newNode: PaneNode) {
        if selectedTab.root.id == id {
            selectedTab.root = newNode
            return
        }
        _ = Self.replaceChild(in: selectedTab.root, targetID: id, newNode: newNode)
    }

    @discardableResult
    private static func replaceChild(in node: PaneNode, targetID: UUID, newNode: PaneNode) -> Bool {
        guard case .split(let split) = node else { return false }
        if split.first.id == targetID {
            split.first = newNode
            return true
        }
        if split.second.id == targetID {
            split.second = newNode
            return true
        }
        return replaceChild(in: split.first, targetID: targetID, newNode: newNode)
            || replaceChild(in: split.second, targetID: targetID, newNode: newNode)
    }

    static func replaceLeafNode(_ targetID: UUID, in node: PaneNode, with newNode: PaneNode) -> PaneNode {
        switch node {
        case .leaf(let leaf):
            return leaf.id == targetID ? newNode : node
        case .split(let split):
            split.first = replaceLeafNode(targetID, in: split.first, with: newNode)
            split.second = replaceLeafNode(targetID, in: split.second, with: newNode)
            return node
        }
    }

    static func parentSplit(of leafID: UUID, in node: PaneNode) -> PaneSplitNode? {
        guard case .split(let split) = node else { return nil }
        if split.first.id == leafID || split.second.id == leafID { return split }
        return parentSplit(of: leafID, in: split.first) ?? parentSplit(of: leafID, in: split.second)
    }

    static func firstLeaf(in node: PaneNode) -> PaneLeaf {
        switch node {
        case .leaf(let leaf): return leaf
        case .split(let split): return firstLeaf(in: split.first)
        }
    }

    static func collectLeaves(_ node: PaneNode) -> [PaneLeaf] {
        switch node {
        case .leaf(let leaf): return [leaf]
        case .split(let split): return collectLeaves(split.first) + collectLeaves(split.second)
        }
    }

    private static func node(forLeafID leafID: UUID, in node: PaneNode) -> PaneNode? {
        switch node {
        case .leaf(let leaf):
            return leaf.id == leafID ? node : nil
        case .split(let split):
            return Self.node(forLeafID: leafID, in: split.first) ?? Self.node(forLeafID: leafID, in: split.second)
        }
    }

    private static func swapLeaves(in node: PaneNode, a: PaneLeaf, b: PaneLeaf) -> PaneNode {
        switch node {
        case .leaf(let leaf):
            if leaf.id == a.id { return .leaf(b) }
            if leaf.id == b.id { return .leaf(a) }
            return node
        case .split(let split):
            split.first = swapLeaves(in: split.first, a: a, b: b)
            split.second = swapLeaves(in: split.second, a: a, b: b)
            return node
        }
    }

    private static func detachingLeaf(_ leafID: UUID, from node: PaneNode) -> (root: PaneNode, leaf: PaneLeaf)? {
        switch node {
        case .leaf:
            return nil
        case .split(let split):
            if split.first.id == leafID, case .leaf(let leaf) = split.first {
                return (split.second, leaf)
            }
            if split.second.id == leafID, case .leaf(let leaf) = split.second {
                return (split.first, leaf)
            }
            if let result = detachingLeaf(leafID, from: split.first) {
                split.first = result.root
                return (node, result.leaf)
            }
            if let result = detachingLeaf(leafID, from: split.second) {
                split.second = result.root
                return (node, result.leaf)
            }
            return nil
        }
    }

    private static func clampFraction(_ fraction: Double) -> Double {
        min(maxFraction, max(minFraction, fraction))
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}

private extension Optional where Wrapped == String {
    var nilIfEmpty: String? {
        switch self {
        case .some(let value): return value.nilIfEmpty
        case .none: return nil
        }
    }
}
