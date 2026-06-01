import FirebaseFirestore
import Foundation
import OpenBurnBarIrohRelay

/// Loads NodeIds that may dial the Mac iroh host for a given connection.
enum FirestoreIrohInboundPeerAllowlist {
    static func load(uid: String, connectionId: String) async -> IrohInboundPeerPolicy {
        let db = Firestore.firestore()
        var allowed = Set<String>()

        let controllers = try? await db
            .collection("users").document(uid)
            .collection("iroh_pairing").document(connectionId)
            .collection("controllers")
            .getDocuments()
        for doc in controllers?.documents ?? [] {
            if let peer = doc.data()["peerNodeId"] as? String, !peer.isEmpty {
                allowed.insert(peer)
            } else if !doc.documentID.isEmpty {
                allowed.insert(doc.documentID)
            }
        }

        return IrohInboundPeerPolicy(allowedPeerNodeIds: allowed)
    }
}
