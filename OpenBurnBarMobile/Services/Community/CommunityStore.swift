import Foundation
import FirebaseAuth
import FirebaseFirestore
import OpenBurnBarCore

enum CommunityTimeWindow: String, CaseIterable, Identifiable, Sendable {
    case today
    case sevenDay = "7d"
    case thirtyDay = "30d"
    case ninetyDay = "90d"
    case allTime = "all_time"

    var id: String { rawValue }

    var label: String {
        switch self {
        case .today: "Today"
        case .sevenDay: "7d"
        case .thirtyDay: "30d"
        case .ninetyDay: "90d"
        case .allTime: "All"
        }
    }

    /// Leaderboard aggregation window keys (server).
    var leaderboardWindow: String {
        switch self {
        case .today: "today"
        case .sevenDay: "7d"
        case .thirtyDay: "30d"
        case .ninetyDay: "90d"
        case .allTime: "all_time"
        }
    }
}

enum CommunityStoreError: Error, LocalizedError {
    case notSignedIn
    case callableFailed(String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to use Community."
        case .callableFailed(let name): "Community action failed (\(name))."
        case .malformedResponse: "Unexpected server response."
        }
    }
}

@MainActor
@Observable
final class CommunityStore {
    var consentDoc: FirestoreCommunityConsentDoc?
    var profile: FirestoreCommunityProfileDoc?
    var shareSnapshot: FirestoreCommunityShareSnapshotDoc?
    var leaderboards: [FirestoreGeographyTier: FirestoreCommunityLeaderboardDoc] = [:]
    var isLoading = false
    var isSyncingConsent = false
    var errorMessage: String?
    var selectedWindow: CommunityTimeWindow = .sevenDay

    private let firestore = FirestoreRepository.shared
    private var listeners: [ListenerRegistration] = []



    var hasJoinedCommunity: Bool {
        consentDoc?.optedInAt?.isEmpty == false
    }

    func refresh(uid: String?) async {
        guard let uid, !uid.isEmpty else {
            stopListening()
            consentDoc = nil
            profile = nil
            shareSnapshot = nil
            leaderboards = [:]
            return
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        startListening(uid: uid)
        await fetchLeaderboards(uid: uid)
    }

    func stopListening() {
        listeners.forEach { $0.remove() }
        listeners.removeAll()
    }

    private func startListening(uid: String) {
        stopListening()
        let db = Firestore.firestore()

        let consentRef = db.collection("users").document(uid).collection("community").document("consent")
        listeners.append(consentRef.addSnapshotListener { [weak self] snap, error in
            Task { @MainActor in
                guard let self else { return }
                if let error { self.errorMessage = error.localizedDescription; return }
                guard let data = snap?.data() else {
                    self.consentDoc = nil
                    return
                }
                if let doc = self.firestore.decodeWithDocID(
                    FirestoreCommunityConsentDoc.self,
                    from: data,
                    docID: "consent"
                ) {
                    self.consentDoc = doc
                    CommunityConsentStore.shared.applyServerConsent(doc)
                }
            }
        })

        let profileRef = db.collection("users").document(uid).collection("community").document("profile")
        listeners.append(profileRef.addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                guard let self, let data = snap?.data() else {
                    self?.profile = nil
                    return
                }
                self.profile = self.firestore.decodeWithDocID(
                    FirestoreCommunityProfileDoc.self,
                    from: data,
                    docID: "profile"
                )
            }
        })

        let shareRef = db.collection("users").document(uid).collection("community").document("share_snapshot")
        listeners.append(shareRef.addSnapshotListener { [weak self] snap, _ in
            Task { @MainActor in
                guard let self, let data = snap?.data() else {
                    self?.shareSnapshot = nil
                    return
                }
                self.shareSnapshot = self.firestore.decodeWithDocID(
                    FirestoreCommunityShareSnapshotDoc.self,
                    from: data,
                    docID: "share_snapshot"
                )
            }
        })
    }

    func fetchLeaderboards(uid: String) async {
        guard let profile else {
            leaderboards = [:]
            return
        }
        let window = selectedWindow.leaderboardWindow
        var fetched: [FirestoreGeographyTier: FirestoreCommunityLeaderboardDoc] = [:]
        let tiers: [(FirestoreGeographyTier, String?)] = [
            (.city, profile.cityKey),
            (.region, profile.regionKey),
            (.country, profile.countryCode),
            (.world, "world"),
        ]
        let db = Firestore.firestore()
        for (tier, geoKey) in tiers {
            guard let geoKey, !geoKey.isEmpty else { continue }
            let docID = "\(window)_\(tier.rawValue)_\(geoKey)"
            do {
                let snap = try await db.collection("community_leaderboards").document(docID).getDocument()
                guard let data = snap.data(),
                      let doc = firestore.decodeWithDocID(
                        FirestoreCommunityLeaderboardDoc.self,
                        from: data,
                        docID: docID
                      ) else { continue }
                fetched[tier] = doc
            } catch {
                continue
            }
        }
        leaderboards = fetched
    }

    func syncJoin() async throws {
        isSyncingConsent = true
        defer { isSyncingConsent = false }
        let payload = CommunityConsentStore.shared.joinPayload(profile: profile)
        try await CommunityCallableClient.joinCommunity(payload: payload)
    }

    func revokeParticipation() async throws {
        isSyncingConsent = true
        defer { isSyncingConsent = false }
        try await CommunityCallableClient.revokeParticipation()
        CommunityConsentStore.shared.revokeAll()
    }
}

// MARK: - Presentation helpers

extension FirestoreCommunityLeaderboardDoc {
    /// First leaderboard tier with a usable board (not below k-anonymity), preferring city → world.
    static func resolvedBoard(
        for tiers: [FirestoreGeographyTier: FirestoreCommunityLeaderboardDoc]
    ) -> (tier: FirestoreGeographyTier, doc: FirestoreCommunityLeaderboardDoc)? {
        for tier in [FirestoreGeographyTier.city, .region, .country, .world] {
            guard let doc = tiers[tier], !doc.belowThreshold else { continue }
            return (tier, doc)
        }
        return nil
    }
}

extension FirestoreCommunityShareSnapshotDoc {
    func usage(for window: CommunityTimeWindow) -> FirestoreCommunityUsageTotal {
        switch window {
        case .today: windows.today
        case .sevenDay: windows.sevenDay
        case .thirtyDay: windows.thirtyDay
        case .ninetyDay: windows.ninetyDay
        case .allTime: windows.allTime
        }
    }
}