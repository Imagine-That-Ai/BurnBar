import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OSLog

@MainActor
final class CLIAgentMissionRequestListener {
    struct ProcessingIdentity: Hashable {
        let documentID: String
        let status: String
        let approvalStatus: String

        init(documentID: String, data: [String: Any]) {
            self.documentID = documentID
            status = Self.normalized(data["status"], fallback: "pending")
            approvalStatus = Self.normalized(data["approvalStatus"], fallback: "none")
        }

        private static func normalized(_ value: Any?, fallback: String) -> String {
            guard let value = value as? String else { return fallback }
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return normalized.isEmpty ? fallback : normalized
        }
    }


    let accountManager: AccountManaging
    let settingsManager: SettingsManager
    let chatController: ChatSessionController
    let deviceTrustChecker: CLIAgentMissionDeviceTrustChecking
    let logger = Logger(subsystem: "com.openburnbar.app", category: "CLIAgentMissionRequestListener")
    var listener: ListenerRegistration?
    var listenerUID: String?
    var attachTask: Task<Void, Never>?
    private let processingQueue = SerialAsyncWorkQueue<QueryDocumentSnapshot, ProcessingIdentity> {
        ProcessingIdentity(documentID: $0.documentID, data: $0.data())
    }
    private var isStarted = false
    var lastAttachState: String?
    var missionEventSequences: [String: Int] = [:]

    init(
        accountManager: AccountManaging,
        settingsManager: SettingsManager,
        chatController: ChatSessionController,
        deviceTrustChecker: CLIAgentMissionDeviceTrustChecking = LiveCLIAgentMissionDeviceTrustChecker()
    ) {
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.chatController = chatController
        self.deviceTrustChecker = deviceTrustChecker
    }

    func start() {
        logger.info("mission listener start requested")
        isStarted = true
        processingQueue.start { [weak self] document in await self?.handle(document: document) }
        if attachTask == nil {
            attachTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    self?.attachIfPossible()
                    try? await Task.sleep(nanoseconds: 3_000_000_000) // try?-ok(cancellation only)
                }
            }
        }
        attachIfPossible()
    }

    func stop() {
        logger.info("mission listener stopped")
        isStarted = false
        attachTask?.cancel()
        attachTask = nil
        listener?.remove()
        listener = nil
        listenerUID = nil
        processingQueue.stop()
        missionEventSequences.removeAll()
    }

    func attachIfPossible() {
        guard isStarted else { return }
        guard accountManager.isFirebaseAvailable, let uid = accountManager.currentUID else {
            let state = "waiting firebase=\(accountManager.isFirebaseAvailable) uid=\(accountManager.currentUID == nil ? "nil" : "present")"
            if lastAttachState != state {
                logger.warning("mission listener \(state, privacy: .public)")
                lastAttachState = state
            }
            listener?.remove()
            listener = nil
            listenerUID = nil
            return
        }
        guard listenerUID != uid else { return }
        listener?.remove()
        listenerUID = uid
        lastAttachState = "attached"
        logger.info("mission listener attaching uidSuffix=\(uid.suffix(6), privacy: .public) device=\(self.accountManager.deviceId, privacy: .public)")
        listener = Firestore.firestore().collection("users").document(uid)
            .collection("cli_agent_mission_requests")
            .whereField("status", in: ["pending", "waiting_for_approval"])
            .addSnapshotListener { [weak self] snapshot, error in
                if let error {
                    Task { @MainActor [weak self] in
                        self?.logger.error("mission listener snapshot failed: \(error.localizedDescription, privacy: .public)")
                    }
                    return
                }
                let docs = snapshot?.documentChanges.compactMap { change -> QueryDocumentSnapshot? in
                    switch change.type {
                    case .added, .modified: change.document
                    case .removed: nil
                    }
                } ?? []
                guard !docs.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.logger.info("mission listener received \(docs.count, privacy: .public) changed docs")
                    self?.processDocs(docs)
                }
            }
    }

    static func isParkedPendingApproval(_ data: [String: Any]) -> Bool {
        let identity = ProcessingIdentity(documentID: "", data: data)
        guard identity.status == "waiting_for_approval",
              identity.approvalStatus == "pending" else { return false }
        guard let requestID = data["approvalRequestId"] as? String else { return false }
        return !requestID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func processDocs(_ docs: [QueryDocumentSnapshot]) {
        guard isStarted else { return }
        processingQueue.enqueue(docs)
    }
}
