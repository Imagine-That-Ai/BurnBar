import Foundation
import SwiftUI

// cmux-style tiling for the Chat workspace.
//
// The right-side conversation viewer is modeled as a binary split tree. Each leaf
// owns ONE conversation via its own `ChatSessionController`; splits divide the space
// along an axis by a draggable fraction. Exactly one leaf is the "primary" leaf — it
// reuses the app-wide `ChatSessionController` so the single-pane experience and every
// other surface that holds that controller are unchanged. Every other pane gets a
// controller built with `persistsViewState: false`, so panes never write the global
// chat UserDefaults keys; the workspace owns all pane persistence as one JSON blob.

/// Orientation of a split. `.horizontal` divides width — two panes side by side (⌘D).
/// `.vertical` divides height — two panes stacked (⌘⇧D).
enum PaneSplitAxis: String, Codable, Sendable {
    case horizontal
    case vertical
}

/// A suggested drop region within a pane while a chat chip is dragged over it —
/// the cmux/tmux drag-to-split affordance. `.center` loads the dragged thread INTO
/// the pane (replacing its conversation); the four edges split the pane along the
/// matching axis and drop the thread into a NEW pane on that side.
enum PaneDropZone: Equatable, Sendable {
    case center, leading, trailing, top, bottom

    /// Fraction of a pane's short edge that counts as an "edge" (split) region.
    /// Points closer than this to any edge suggest a split; the interior loads.
    static let edgeInset: Double = 0.30

    /// Classify a drop point (in the pane's local coordinates, top-left origin)
    /// into a zone. Corners resolve to the nearest edge.
    static func classify(_ point: CGPoint, in size: CGSize, edgeInset: Double = edgeInset) -> PaneDropZone {
        guard size.width > 0, size.height > 0 else { return .center }
        let fx = min(max(point.x / size.width, 0), 1)
        let fy = min(max(point.y / size.height, 0), 1)
        let left = fx, right = 1 - fx, top = fy, bottom = 1 - fy
        let nearest = min(left, right, top, bottom)
        guard nearest <= edgeInset else { return .center }
        if nearest == left { return .leading }
        if nearest == right { return .trailing }
        if nearest == top { return .top }
        return .bottom
    }

    /// The split axis this zone implies, or `nil` for `.center` (load, don't split).
    var splitAxis: PaneSplitAxis? {
        switch self {
        case .center: return nil
        case .leading, .trailing: return .horizontal
        case .top, .bottom: return .vertical
        }
    }

    /// Whether the new pane takes the leading slot (left/top) of the new split.
    var placesNewLeafFirst: Bool { self == .leading || self == .top }

    /// Unit rect (0...1 in both axes) the suggestion overlay highlights — the space
    /// the dropped thread would occupy.
    var highlightUnitRect: CGRect {
        switch self {
        case .center: return CGRect(x: 0, y: 0, width: 1, height: 1)
        case .leading: return CGRect(x: 0, y: 0, width: 0.5, height: 1)
        case .trailing: return CGRect(x: 0.5, y: 0, width: 0.5, height: 1)
        case .top: return CGRect(x: 0, y: 0, width: 1, height: 0.5)
        case .bottom: return CGRect(x: 0, y: 0.5, width: 1, height: 0.5)
        }
    }

    var symbolName: String {
        switch self {
        case .center: return "arrow.down.to.line.compact"
        case .leading: return "rectangle.lefthalf.inset.filled"
        case .trailing: return "rectangle.righthalf.inset.filled"
        case .top: return "rectangle.tophalf.inset.filled"
        case .bottom: return "rectangle.bottomhalf.inset.filled"
        }
    }

    var hint: String { self == .center ? "Open here" : "New pane" }
}

/// One conversation pane: a stable identity plus its own controller. `isPrimary` marks
/// the single leaf that reuses the app-wide controller.
@MainActor
final class PaneLeaf: Identifiable {
    nonisolated let id: UUID
    let controller: ChatSessionController
    let isPrimary: Bool

    init(id: UUID = UUID(), controller: ChatSessionController, isPrimary: Bool = false) {
        self.id = id
        self.controller = controller
        self.isPrimary = isPrimary
    }
}

/// An internal split node. `@Observable` so live edits to `fraction` (divider drag) and
/// to the `first`/`second` child references (split / close re-flow) update only the
/// affected subtree.
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

/// A node in the tree: either a conversation leaf or a split. A value-type wrapper over
/// the `@Observable` class nodes, always stored in an observed `var`, so swapping a case
/// (split/close) is a tracked mutation.
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

// MARK: - Persisted snapshot

/// Codable mirror of the live tree. Controllers are not serialized; each leaf persists
/// only its bound `threadID`, rebuilt into a controller on restore.
indirect enum PaneLayoutSnapshot: Codable {
    case leaf(paneID: UUID, threadID: String, isPrimary: Bool)
    case split(axis: PaneSplitAxis, fraction: Double, first: PaneLayoutSnapshot, second: PaneLayoutSnapshot)
}

struct PaneWorkspaceSnapshot: Codable {
    let root: PaneLayoutSnapshot
    let activePaneID: UUID
}

// MARK: - Workspace model

@MainActor
@Observable
final class PaneWorkspaceModel {
    /// Minimum fraction of either child so no pane can be dragged to zero width/height.
    static let minFraction: Double = 0.15
    static let maxFraction: Double = 0.85
    static let udPaneLayout = "paneWorkspace.layoutTree"

    var root: PaneNode
    var activeLeafID: UUID

    /// Guards the primary pane's one-time slot-resolving load. The primary's
    /// `PaneConversationView` is recreated whenever a split/close re-parents it, but the
    /// global thread slot must be resolved only once — re-resolving on a recreation races
    /// the re-home performed by `closeActive`. Lives on the model so it survives view
    /// recreation (per-view `@State` would reset).
    @ObservationIgnored var primaryDidInitialLoad = false

    @ObservationIgnored let dataStore: DataStore
    @ObservationIgnored let settingsManager: SettingsManager
    @ObservationIgnored let primaryController: ChatSessionController

    init(
        root: PaneNode,
        activeLeafID: UUID,
        dataStore: DataStore,
        settingsManager: SettingsManager,
        primaryController: ChatSessionController
    ) {
        self.root = root
        self.activeLeafID = activeLeafID
        self.dataStore = dataStore
        self.settingsManager = settingsManager
        self.primaryController = primaryController
    }

    // MARK: Derived

    var leaves: [PaneLeaf] { Self.collectLeaves(root) }
    var paneCount: Int { leaves.count }
    var isTiled: Bool { paneCount > 1 }

    /// Threads currently shown in any pane — drives the left-rail "open in a pane" hint.
    var boundThreadIDs: Set<String> { Set(leaves.map { $0.controller.activeThreadID }) }

    func leaf(_ id: UUID) -> PaneLeaf? { leaves.first { $0.id == id } }

    /// The focused pane's controller; falls back to the app-wide controller. The screen
    /// toolbar binds here so it always drives the active pane.
    var activeController: ChatSessionController {
        leaf(activeLeafID)?.controller ?? primaryController
    }

    func setActive(_ id: UUID) {
        guard id != activeLeafID, leaf(id) != nil else { return }
        activeLeafID = id
        // Persist so the focused pane is restored on relaunch (the snapshot carries
        // activePaneID); split/close/bind already persist, but a plain focus change did not.
        persist()
    }

    // MARK: Mutations

    /// Split the active pane. Fully synchronous so a rapid second ⌘D / ⌘W can never race
    /// a half-built leaf: the new controller is bound to its thread the instant it exists
    /// (never the legacy thread), the tree swaps in one main-actor turn, and the DB row is
    /// created fire-and-forget (createChatThread is idempotent; saveChatMessage upserts).
    func splitActive(axis: PaneSplitAxis) {
        guard let target = leaf(activeLeafID) else { return }
        let newThreadID = UUID().uuidString
        let controller = makePaneController(threadID: newThreadID)
        let newLeaf = PaneLeaf(controller: controller)
        let newSplit = PaneSplitNode(
            axis: axis,
            fraction: 0.5,
            first: .leaf(target),
            second: .leaf(newLeaf)
        )
        replaceNode(withID: target.id, with: .split(newSplit))
        activeLeafID = newLeaf.id
        Task { [dataStore] in _ = try? await dataStore.createChatThread(id: newThreadID) }
        persist()
    }

    /// Drag-to-split: split the leaf `id` along `axis`, loading an EXISTING thread into
    /// the freshly created pane. Mirrors `splitActive` but targets a specific leaf (the
    /// drop target, not necessarily the active one), positions the new pane on either
    /// side (`newLeafFirst` ⇒ left/top), and binds a dragged thread instead of minting a
    /// blank one. The thread already exists in the DB (it comes from the history rail), so
    /// no `createChatThread`; the new pane hydrates it in `onAppear`.
    func splitLeaf(_ id: UUID, axis: PaneSplitAxis, placingThreadID threadID: String, newLeafFirst: Bool) {
        guard let target = leaf(id) else { return }
        let controller = makePaneController(threadID: threadID)
        let newLeaf = PaneLeaf(controller: controller)
        let newSplit = newLeafFirst
            ? PaneSplitNode(axis: axis, fraction: 0.5, first: .leaf(newLeaf), second: .leaf(target))
            : PaneSplitNode(axis: axis, fraction: 0.5, first: .leaf(target), second: .leaf(newLeaf))
        replaceNode(withID: target.id, with: .split(newSplit))
        activeLeafID = newLeaf.id
        persist()
    }

    /// Close the active pane and re-flow its sibling into the freed space. The last pane
    /// is indestructible (caller routes single-pane ⌘W to the window). The primary leaf is
    /// re-homed onto the surviving sibling so the app-wide controller is always rendered.
    func closeActive() {
        guard paneCount > 1, let target = leaf(activeLeafID) else { return }
        guard let parent = Self.parentSplit(of: target.id, in: root) else { return }
        let siblingNode: PaneNode = parent.first.id == target.id ? parent.second : parent.first

        if target.isPrimary {
            let survivor = Self.firstLeaf(in: siblingNode)
            let survivorThread = survivor.controller.activeThreadID
            survivor.controller.teardownForPaneClose()
            primaryController.openHistoryThread(survivorThread)
            let rehomed = PaneLeaf(id: survivor.id, controller: primaryController, isPrimary: true)
            let newSibling = Self.replaceLeafNode(survivor.id, in: siblingNode, with: .leaf(rehomed))
            replaceNode(withID: parent.id, with: newSibling)
            activeLeafID = rehomed.id
        } else {
            target.controller.teardownForPaneClose()
            replaceNode(withID: parent.id, with: siblingNode)
            activeLeafID = Self.firstLeaf(in: siblingNode).id
        }
        persist()
    }

    /// Load a thread into a specific pane (drag-and-drop target). Only that pane changes.
    func bind(threadID: String, toLeaf id: UUID) {
        guard let leaf = leaf(id) else { return }
        leaf.controller.openHistoryThread(threadID)
        activeLeafID = id
        // openHistoryThread mutates activeThreadID after an await; the pane view's
        // .onChange(of: controller.activeThreadID) re-persists once it lands.
        persist()
    }

    func makePaneController(threadID: String) -> ChatSessionController {
        ChatSessionController(
            dataStore: dataStore,
            settingsManager: settingsManager,
            initialThreadID: threadID,
            persistsViewState: false
        )
    }

    // MARK: Persistence

    func persist() {
        let snapshot = PaneWorkspaceSnapshot(root: Self.snapshot(root), activePaneID: activeLeafID)
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: Self.udPaneLayout)
    }

    /// Rebuild the workspace from the persisted snapshot, or a single primary pane when
    /// none exists (today's behavior). Synchronous — no DB await — so the view can build
    /// it in `init` with no first-frame flash. Message hydration happens per-pane onAppear.
    static func restore(
        primaryController: ChatSessionController,
        dataStore: DataStore,
        settingsManager: SettingsManager
    ) -> PaneWorkspaceModel {
        func singlePrimary() -> PaneWorkspaceModel {
            let leaf = PaneLeaf(controller: primaryController, isPrimary: true)
            return PaneWorkspaceModel(
                root: .leaf(leaf),
                activeLeafID: leaf.id,
                dataStore: dataStore,
                settingsManager: settingsManager,
                primaryController: primaryController
            )
        }

        guard
            let data = UserDefaults.standard.data(forKey: udPaneLayout),
            let snapshot = try? JSONDecoder().decode(PaneWorkspaceSnapshot.self, from: data)
        else {
            return singlePrimary()
        }

        var primaryAssigned = false
        func build(_ node: PaneLayoutSnapshot) -> PaneNode {
            switch node {
            case .leaf(let paneID, let threadID, let isPrimary):
                if isPrimary && !primaryAssigned {
                    primaryAssigned = true
                    return .leaf(PaneLeaf(id: paneID, controller: primaryController, isPrimary: true))
                }
                let controller = ChatSessionController(
                    dataStore: dataStore,
                    settingsManager: settingsManager,
                    initialThreadID: threadID,
                    persistsViewState: false
                )
                return .leaf(PaneLeaf(id: paneID, controller: controller, isPrimary: false))
            case .split(let axis, let fraction, let first, let second):
                return .split(PaneSplitNode(
                    axis: axis,
                    fraction: min(maxFraction, max(minFraction, fraction)),
                    first: build(first),
                    second: build(second)
                ))
            }
        }

        var tree = build(snapshot.root)

        // Enforce exactly one primary leaf. Zero primaries (corrupt/edited blob) →
        // promote the first leaf, tearing down the pane controller built for it.
        if !primaryAssigned {
            let first = firstLeaf(in: tree)
            first.controller.teardownForPaneClose()
            let promoted = PaneLeaf(id: first.id, controller: primaryController, isPrimary: true)
            tree = replaceLeafNode(first.id, in: tree, with: .leaf(promoted))
        }

        let leafIDs = Set(collectLeaves(tree).map { $0.id })
        let active = leafIDs.contains(snapshot.activePaneID) ? snapshot.activePaneID : firstLeaf(in: tree).id

        return PaneWorkspaceModel(
            root: tree,
            activeLeafID: active,
            dataStore: dataStore,
            settingsManager: settingsManager,
            primaryController: primaryController
        )
    }

    // MARK: Tree helpers

    /// Replace the node with `id` (root or nested) with `newNode`, mutating in place so
    /// only the affected subtree re-renders.
    private func replaceNode(withID id: UUID, with newNode: PaneNode) {
        if root.id == id {
            root = newNode
            return
        }
        _ = Self.replaceChild(in: root, targetID: id, newNode: newNode)
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

    private static func replaceLeafNode(_ targetID: UUID, in node: PaneNode, with newNode: PaneNode) -> PaneNode {
        switch node {
        case .leaf(let leaf):
            return leaf.id == targetID ? newNode : node
        case .split(let split):
            split.first = replaceLeafNode(targetID, in: split.first, with: newNode)
            split.second = replaceLeafNode(targetID, in: split.second, with: newNode)
            return node
        }
    }

    private static func parentSplit(of leafID: UUID, in node: PaneNode) -> PaneSplitNode? {
        guard case .split(let split) = node else { return nil }
        if split.first.id == leafID || split.second.id == leafID { return split }
        return parentSplit(of: leafID, in: split.first) ?? parentSplit(of: leafID, in: split.second)
    }

    private static func firstLeaf(in node: PaneNode) -> PaneLeaf {
        switch node {
        case .leaf(let leaf): return leaf
        case .split(let split): return firstLeaf(in: split.first)
        }
    }

    private static func collectLeaves(_ node: PaneNode) -> [PaneLeaf] {
        switch node {
        case .leaf(let leaf): return [leaf]
        case .split(let split): return collectLeaves(split.first) + collectLeaves(split.second)
        }
    }

    private static func snapshot(_ node: PaneNode) -> PaneLayoutSnapshot {
        switch node {
        case .leaf(let leaf):
            return .leaf(paneID: leaf.id, threadID: leaf.controller.activeThreadID, isPrimary: leaf.isPrimary)
        case .split(let split):
            return .split(axis: split.axis, fraction: split.fraction, first: snapshot(split.first), second: snapshot(split.second))
        }
    }
}
