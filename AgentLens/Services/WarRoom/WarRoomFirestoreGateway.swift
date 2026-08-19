import FirebaseFirestore
import Foundation

// MARK: - War Room Firestore gateway

/// The one place the War Room resolves a Firestore handle.
///
/// Every War Room collection hangs off `users/{uid}`, and every surface that
/// reads one needs the same two things right: the owning uid in the path, and
/// the collection name spelled exactly as `firestore.rules` allows. Resolving
/// the global handle at four call sites meant four chances to get either wrong,
/// and a typo'd collection name fails as a permission denial at runtime rather
/// than as a compile error.
///
/// This is the same sanctioned-gateway shape as `CloudSyncFirestoreGateway` and
/// `ComputerUseFirestoreGateway`: it owns the handle so its callers do not.
enum WarRoomFirestoreGateway {

    /// `hermes_bodies` — one document per Mac that has published an identity.
    static func bodies(uid: String) -> CollectionReference {
        userScope(uid: uid).collection("hermes_bodies")
    }

    /// A single machine's body document.
    static func body(uid: String, bodyID: String) -> DocumentReference {
        bodies(uid: uid).document(bodyID)
    }

    /// `war_wire_grants` — one document per ordered machine pair the user has
    /// consented to link.
    static func grants(uid: String) -> CollectionReference {
        userScope(uid: uid).collection("war_wire_grants")
    }

    private static func userScope(uid: String) -> DocumentReference {
        Firestore.firestore().collection("users").document(uid)
    }
}
