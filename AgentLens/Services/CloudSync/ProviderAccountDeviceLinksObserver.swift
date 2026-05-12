@preconcurrency import FirebaseFirestore
import Foundation
import OpenBurnBarCore

// MARK: - Provider Account Device Links Observer (macOS)
//
// Listens to `users/{uid}/provider_accounts/{accountId}/device_links` for every
// account this Mac knows about and surfaces a lightweight `[accountID: count]`
// projection that `ProvidersSettingsView` can render as a "On N devices" chip.
//
// The data shape mirrors `ProviderAccountDeviceLinkDoc` defined in
// `functions/src/types.ts`. Reads are owner-scoped (rules in
// `firestore.rules` enforce same-uid). Writes are admin-only.

@MainActor
final class ProviderAccountDeviceLinksObserver: ObservableObject {

    struct Link: Identifiable, Hashable, Sendable {
        let id: String
        let deviceID: String
        let accountID: String
        let providerID: String
        let capability: DeviceLinkCapability
        let lastObservedAt: Date?
        let status: String
        let label: String?
        let platform: String?
    }

    @Published private(set) var linksByAccount: [String: [Link]] = [:]

    private let accountManager: AccountManaging
    private var listener: ListenerRegistration?
    private var attachedUID: String?
    private var pollTask: Task<Void, Never>?

    init(accountManager: AccountManaging) {
        self.accountManager = accountManager
    }

    deinit {
        listener?.remove()
        listener = nil
        pollTask?.cancel()
        pollTask = nil
    }

    func start() {
        if pollTask == nil {
            pollTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.attachIfPossible()
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                }
            }
        }
        attachIfPossible()
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
        listener?.remove()
        listener = nil
        attachedUID = nil
        linksByAccount.removeAll()
    }

    func links(for accountID: String) -> [Link] {
        linksByAccount[accountID] ?? []
    }

    // MARK: - Internal

    private func attachIfPossible() {
        guard accountManager.isFirebaseAvailable, let uid = accountManager.currentUID else {
            listener?.remove()
            listener = nil
            attachedUID = nil
            linksByAccount.removeAll()
            return
        }
        guard attachedUID != uid else { return }
        attachedUID = uid
        listener?.remove()

        let db = Firestore.firestore()
        listener = db
            .collection("users").document(uid)
            .collection("provider_account_device_links")
            .addSnapshotListener { [weak self] snapshot, _ in
                guard let self else { return }
                Task { @MainActor in
                    self.consume(snapshot?.documents ?? [])
                }
            }
    }

    private func consume(_ docs: [QueryDocumentSnapshot]) {
        var bucket: [String: [Link]] = [:]
        for doc in docs {
            let data = doc.data()
            guard let accountID = data["accountID"] as? String,
                  let deviceID = data["deviceID"] as? String else { continue }
            let capabilityRaw = (data["capability"] as? String) ?? DeviceLinkCapability.use.rawValue
            let capability = DeviceLinkCapability(rawValue: capabilityRaw) ?? .use
            let status = (data["status"] as? String) ?? "active"
            let label = data["deviceDisplayName"] as? String
            let platform = data["platform"] as? String
            let providerID = (data["providerID"] as? String) ?? ""
            let lastObserved: Date? = {
                if let ts = data["lastObservedAt"] as? Timestamp { return ts.dateValue() }
                if let iso = data["lastObservedAt"] as? String {
                    return ISO8601DateFormatter().date(from: iso)
                }
                return nil
            }()
            let link = Link(
                id: doc.documentID,
                deviceID: deviceID,
                accountID: accountID,
                providerID: providerID,
                capability: capability,
                lastObservedAt: lastObserved,
                status: status,
                label: label,
                platform: platform
            )
            bucket[accountID, default: []].append(link)
        }
        linksByAccount = bucket
    }
}
