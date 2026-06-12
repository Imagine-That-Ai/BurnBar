import Foundation

/// Normalizes iroh NodeId strings for set membership checks.
public enum IrohNodeIdNormalization {
    public static func canonical(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// Inbound peer binding: Mac host accepts only NodeIds on the user's allowlist.
public struct IrohInboundPeerPolicy: Sendable, Equatable {
    public let allowedPeerNodeIds: Set<String>

    public init(allowedPeerNodeIds: Set<String>) {
        self.allowedPeerNodeIds = Set(allowedPeerNodeIds.map(IrohNodeIdNormalization.canonical))
    }

    public func allows(remotePeerNodeId: String?) -> Bool {
        guard let remotePeerNodeId,
              !remotePeerNodeId.isEmpty else {
            return false
        }
        return allowedPeerNodeIds.contains(IrohNodeIdNormalization.canonical(remotePeerNodeId))
    }
}
