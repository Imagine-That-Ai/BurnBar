import Foundation

public struct MobileInboxSelectionState: Sendable, Equatable {
    public var selectedID: String?
    public var pendingFocusID: String?
    public var filter: String
    public var searchQuery: String
    public var focusRequestToken: Int

    public init(
        selectedID: String? = nil,
        pendingFocusID: String? = nil,
        filter: String = "active",
        searchQuery: String = "",
        focusRequestToken: Int = 0
    ) {
        self.selectedID = selectedID
        self.pendingFocusID = pendingFocusID
        self.filter = filter
        self.searchQuery = searchQuery
        self.focusRequestToken = focusRequestToken
    }
}

/// Cold/warm inbox focus. Source: iOS `AIInboxStore.focus` / `reconcileSelection`.
public enum MobileInboxSelectionPolicy {
    public static func focus(
        state: MobileInboxSelectionState,
        itemID: String?,
        recordIDs: [String]
    ) -> MobileInboxSelectionState {
        var next = state
        next.filter = "active"
        next.searchQuery = ""
        next.focusRequestToken += 1
        if let itemID {
            next.selectedID = itemID
            next.pendingFocusID = recordIDs.contains(itemID) ? nil : itemID
        }
        return next
    }

    public static func reconcile(
        state: MobileInboxSelectionState,
        visibleIDs: [String],
        recordIDs: [String]
    ) -> MobileInboxSelectionState {
        var next = state
        guard let selectedID = next.selectedID else { return next }
        if let pending = next.pendingFocusID {
            guard recordIDs.contains(pending) else { return next }
            next.pendingFocusID = nil
        }
        if visibleIDs.contains(selectedID) == false {
            next.selectedID = visibleIDs.first
        }
        return next
    }
}
