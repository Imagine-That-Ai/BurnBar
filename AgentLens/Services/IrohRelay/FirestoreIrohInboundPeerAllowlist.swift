import FirebaseCore
import FirebaseFirestore
import Foundation
import OpenBurnBarIrohRelay

/// Loads NodeIds that may dial the Mac iroh host for a given connection.
enum FirestoreIrohInboundPeerAllowlist {
    static func load(uid: String, connectionId: String) async -> IrohInboundPeerPolicy {
        guard FirebaseApp.app() != nil else {
            return IrohInboundPeerPolicy(allowedPeerNodeIds: [])
        }

        let db = Firestore.firestore()
        var allowed = Set<String>()

        let controllers = try? await db
            .collection("users").document(uid)
            .collection("iroh_pairing").document(connectionId)
            .collection("controllers")
            .getDocuments()
        for doc in controllers?.documents ?? [] {
            if let peer = trimmedString(doc.data()["peerNodeId"]) {
                allowed.insert(peer)
            } else if !doc.documentID.isEmpty {
                allowed.insert(doc.documentID)
            }
        }

        let irohControllers = try? await db
            .collection("users").document(uid)
            .collection("iroh_pairing").document(connectionId)
            .collection("iroh_controllers")
            .getDocuments()
        for doc in irohControllers?.documents ?? [] {
            if let peer = trimmedString(doc.data()["irohPeerNodeId"]) {
                allowed.insert(peer)
            } else if !doc.documentID.isEmpty {
                allowed.insert(doc.documentID)
            }
        }

        return IrohInboundPeerPolicy(allowedPeerNodeIds: allowed)
    }

    private static func trimmedString(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
