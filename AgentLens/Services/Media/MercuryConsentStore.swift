import Combine
import Foundation

/// Mac-side Mercury mirror consent ledger.
///
/// A mirror auto-accept grant is scoped to the verified iroh connection and,
/// when present, the viewer device / phone-control peer identifiers from the
/// request. The old global "always allow" bit is retired on startup because it
/// did not bind consent to a device.
@MainActor
final class MercuryConsentStore: ObservableObject {
    struct MirrorAutoAcceptGrant: Codable, Equatable, Identifiable {
        var id: String { key }
        let key: String
        let connectionId: String
        let viewerDeviceId: String?
        let controlAuthorityPeerNodeId: String?
        let requesterName: String
        let grantedAt: Date
        let expiresAt: Date
        var lastUsedAt: Date?
    }

    private static let legacyAlwaysAllowKey = "mercuryAlwaysAllowMyIPhoneToMirror"
    private static let rememberAcceptedPeersKey = "mercuryRememberAcceptedMirrorPeers"
    private static let grantsKey = "mercuryMirrorAutoAcceptGrants.v2"
    private static let grantTTL: TimeInterval = 30 * 24 * 60 * 60

    @Published var rememberAcceptedMirrorPeers: Bool {
        didSet {
            defaults.set(rememberAcceptedMirrorPeers, forKey: Self.rememberAcceptedPeersKey)
        }
    }

    @Published private(set) var grants: [MirrorAutoAcceptGrant]

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.rememberAcceptedMirrorPeers = defaults.bool(forKey: Self.rememberAcceptedPeersKey)
        self.grants = Self.decodeGrants(defaults.data(forKey: Self.grantsKey))
        if defaults.object(forKey: Self.legacyAlwaysAllowKey) != nil {
            defaults.removeObject(forKey: Self.legacyAlwaysAllowKey)
            self.rememberAcceptedMirrorPeers = false
        }
        pruneExpired()
    }

    var activeGrantCount: Int {
        pruneExpired()
        return grants.count
    }

    func canAutoAccept(
        connectionId: String,
        viewerDeviceId: String?,
        controlAuthorityPeerNodeId: String?,
        remotePeerNodeId: String?,
        now: Date = Date()
    ) -> Bool {
        guard Self.peerNodeIDsMatch(
            declaredPeerNodeId: controlAuthorityPeerNodeId,
            remotePeerNodeId: remotePeerNodeId
        ) else {
            return false
        }
        pruneExpired(now: now)
        let key = Self.grantKey(
            connectionId: connectionId,
            viewerDeviceId: viewerDeviceId,
            controlAuthorityPeerNodeId: controlAuthorityPeerNodeId
        )
        guard let index = grants.firstIndex(where: { $0.key == key && $0.expiresAt > now }) else {
            return false
        }
        grants[index].lastUsedAt = now
        persist()
        return true
    }

    func rememberAcceptedPeer(
        connectionId: String,
        viewerDeviceId: String?,
        controlAuthorityPeerNodeId: String?,
        remotePeerNodeId: String?,
        requesterName: String,
        now: Date = Date()
    ) {
        guard rememberAcceptedMirrorPeers else { return }
        guard Self.peerNodeIDsMatch(
            declaredPeerNodeId: controlAuthorityPeerNodeId,
            remotePeerNodeId: remotePeerNodeId
        ) else {
            return
        }
        let key = Self.grantKey(
            connectionId: connectionId,
            viewerDeviceId: viewerDeviceId,
            controlAuthorityPeerNodeId: controlAuthorityPeerNodeId
        )
        let grant = MirrorAutoAcceptGrant(
            key: key,
            connectionId: connectionId,
            viewerDeviceId: viewerDeviceId?.nilIfEmpty(),
            controlAuthorityPeerNodeId: Self.canonicalPeerNodeID(controlAuthorityPeerNodeId),
            requesterName: requesterName.nilIfEmpty() ?? "Mirror peer",
            grantedAt: now,
            expiresAt: now.addingTimeInterval(Self.grantTTL),
            lastUsedAt: nil
        )
        grants.removeAll { $0.key == key }
        grants.append(grant)
        persist()
    }

    func revokeAllMirrorAutoAcceptGrants() {
        grants.removeAll()
        persist()
    }

    private func pruneExpired(now: Date = Date()) {
        let before = grants.count
        grants.removeAll { $0.expiresAt <= now }
        if grants.count != before {
            persist()
        }
    }

    private func persist() {
        let data = try? JSONEncoder().encode(grants)
        defaults.set(data, forKey: Self.grantsKey)
    }

    private static func decodeGrants(_ data: Data?) -> [MirrorAutoAcceptGrant] {
        guard let data else { return [] }
        return (try? JSONDecoder().decode([MirrorAutoAcceptGrant].self, from: data)) ?? []
    }

    private static func grantKey(
        connectionId: String,
        viewerDeviceId: String?,
        controlAuthorityPeerNodeId: String?
    ) -> String {
        [
            connectionId.nilIfEmpty() ?? "_",
            viewerDeviceId?.nilIfEmpty() ?? "_",
            canonicalPeerNodeID(controlAuthorityPeerNodeId) ?? "_"
        ].joined(separator: "|")
    }

    private static func peerNodeIDsMatch(
        declaredPeerNodeId: String?,
        remotePeerNodeId: String?
    ) -> Bool {
        guard let declared = canonicalPeerNodeID(declaredPeerNodeId),
              let remote = canonicalPeerNodeID(remotePeerNodeId) else {
            return false
        }
        return declared == remote
    }

    private static func canonicalPeerNodeID(_ value: String?) -> String? {
        value?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .nilIfEmpty()
    }
}

private extension String {
    func nilIfEmpty() -> String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
