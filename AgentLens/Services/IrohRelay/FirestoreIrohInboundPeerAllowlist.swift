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

        let controllers: QuerySnapshot
        do {
            controllers = try await db
                .collection("users").document(uid)
                .collection("iroh_pairing").document(connectionId)
                .collection("controllers")
                .getDocuments()
        } catch {
            return IrohInboundPeerPolicy(allowedPeerNodeIds: [])
        }

        for doc in controllers.documents {
            if let peer = doc.data()["peerNodeId"] as? String, !peer.isEmpty {
                allowed.insert(peer)
            } else if !doc.documentID.isEmpty {
                allowed.insert(doc.documentID)
            }
        }

        // Bridge for the severed QUIC-NodeId registration pipeline: the
        // `publishIrohPeerNodeId` callable (and the Mac's `iroh_controllers`
        // read) were both removed in June 2026, after which `controllers/*`
        // only ever holds app-layer phone-control ids (`ios-phone-*` /
        // `ios-se-*`) that can never equal the QUIC peer NodeId iroh surfaces
        // — so a fresh allowlist admitted no phone at all and every Mercury
        // dial was rejected. Mobile clients still self-report their QUIC
        // NodeId to `devices/{deviceId}.irohPeerNodeId` before each dial
        // (`HermesIrohRelayTransport.persistIrohPeerNodeId`). Admit those —
        // but ONLY for devices whose escrow trustState is `trusted`, which is
        // server-controlled (clients cannot write trustState; approval goes
        // through the `approveEscrowDeviceTrust` callable). Fail-closed on
        // read errors, same as the controllers read above. Follow-up: restore
        // a server-verified registration callable and drop this bridge.
        do {
            let trustedEscrow = try await db
                .collection("users").document(uid)
                .collection("escrow_devices")
                .whereField("trustState", isEqualTo: "trusted")
                .getDocuments()
            let trustedDeviceIds = Set(trustedEscrow.documents.map { doc in
                (doc.data()["deviceId"] as? String) ?? doc.documentID
            })
            guard !trustedDeviceIds.isEmpty else {
                return IrohInboundPeerPolicy(allowedPeerNodeIds: allowed)
            }
            let devices = try await db
                .collection("users").document(uid)
                .collection("devices")
                .getDocuments()
            for doc in devices.documents {
                let data = doc.data()
                let deviceId = (data["deviceId"] as? String) ?? doc.documentID
                guard trustedDeviceIds.contains(deviceId),
                      let nodeId = data["irohPeerNodeId"] as? String,
                      !nodeId.isEmpty else {
                    continue
                }
                allowed.insert(nodeId)
            }
        } catch {
            AppLogger.network.error(
                "iroh_inbound_trusted_device_allowlist_load_failed",
                metadata: AppLogger.publicErrorMetadata(error)
            )
        }

        return IrohInboundPeerPolicy(allowedPeerNodeIds: allowed)
    }
}
