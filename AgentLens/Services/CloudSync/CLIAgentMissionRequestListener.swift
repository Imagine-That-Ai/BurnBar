import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore
import OSLog
@MainActor
final class CLIAgentMissionRequestListener {
    let accountManager: AccountManaging
    let settingsManager: SettingsManager
    let chatController: ChatSessionController
    let deviceTrustChecker: CLIAgentMissionDeviceTrustChecking
    /// This Mac's HermesBody id — the relay host's connection id, `nil` before
    /// it has one, which `MissionClaimGate` reads as "cannot prove I am the target".
    let localBodyIDProvider: @MainActor () -> String?
    let logger = Logger(subsystem: "com.openburnbar.app", category: "CLIAgentMissionRequestListener")
    var listener: ListenerRegistration?
    var listenerUID: String?
    var attachTask: Task<Void, Never>?
    private let processingQueue = SerialAsyncWorkQueue<QueryDocumentSnapshot, String> { CLIAgentMissionRequestListener.processingIdentity(documentID: $0.documentID, data: $0.data()) }
    private var isStarted = false
    var lastAttachState: String?
    var missionEventSequences: [String: Int] = [:]
    struct ClaimedMissionHandle {
        var hostWriteNonce: String
        var deviceId: String
    }
    var claimedMissions: [String: ClaimedMissionHandle] = [:]
    var inFlightExecutions: Set<String> = []
    init(
        accountManager: AccountManaging,
        settingsManager: SettingsManager,
        chatController: ChatSessionController,
        deviceTrustChecker: CLIAgentMissionDeviceTrustChecking = LiveCLIAgentMissionDeviceTrustChecker(),
        localBodyIDProvider: @escaping @MainActor () -> String? = { nil }
    ) {
        self.accountManager = accountManager
        self.settingsManager = settingsManager
        self.chatController = chatController
        self.deviceTrustChecker = deviceTrustChecker
        self.localBodyIDProvider = localBodyIDProvider
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
        claimedMissions.removeAll()
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
                let docs = snapshot?.documentChanges.compactMap { $0.type == .removed ? nil : $0.document } ?? []
                guard !docs.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.logger.info("mission listener received \(docs.count, privacy: .public) changed docs")
                    self?.processDocs(docs)
                }
            }
    }
    static func processingIdentity(documentID: String, data: [String: Any]) -> String { "\(documentID)\u{0}\(data["status"] as? String ?? "pending")\u{0}\(data["approvalStatus"] as? String ?? "none")" }
    func processDocs(_ docs: [QueryDocumentSnapshot]) {
        guard isStarted else { return }
        processingQueue.enqueue(docs)
    }
}
