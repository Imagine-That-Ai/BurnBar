import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
import OSLog

@MainActor
final class CLIAgentMissionRequestListener {

    let accountManager: AccountManaging
    let settingsManager: SettingsManager
    let chatController: ChatSessionController
    let deviceTrustChecker: CLIAgentMissionDeviceTrustChecking
    let logger = Logger(subsystem: "com.openburnbar.app", category: "CLIAgentMissionRequestListener")
    var listener: ListenerRegistration?
    var listenerUID: String?
    var attachTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var queuedDocs: [QueryDocumentSnapshot] = []
    private var queuedDocIndex = 0
    private var processingGeneration: UInt = 0
    private var isStarted = false
    private var processingDocs = Set<String>()
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
        processingGeneration &+= 1
        attachTask?.cancel()
        attachTask = nil
        listener?.remove()
        listener = nil
        listenerUID = nil
        processingTask?.cancel()
        queuedDocs.removeAll()
        queuedDocIndex = 0
        processingDocs.removeAll()
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
                guard let docs = snapshot?.documents, !docs.isEmpty else { return }
                Task { @MainActor [weak self] in
                    self?.logger.info("mission listener received \(docs.count, privacy: .public) pending docs")
                    self?.processDocs(docs)
                }
            }
    }

    func processDocs(_ docs: [QueryDocumentSnapshot]) {
        guard isStarted else { return }
        for document in docs where processingDocs.insert(document.documentID).inserted {
            queuedDocs.append(document)
        }
        startProcessingQueueIfNeeded()
    }

    private func startProcessingQueueIfNeeded() {
        guard processingTask == nil, queuedDocIndex < queuedDocs.count else { return }
        let generation = processingGeneration
        processingTask = Task { @MainActor [weak self] in
            await self?.drainProcessingQueue(generation: generation)
        }
    }

    private func drainProcessingQueue(generation: UInt) async {
        while isStarted,
              generation == processingGeneration,
              !Task.isCancelled,
              queuedDocIndex < queuedDocs.count {
            let document = queuedDocs[queuedDocIndex]
            queuedDocIndex += 1
            await handle(document: document)
            if generation == processingGeneration {
                processingDocs.remove(document.documentID)
            }
        }

        if generation == processingGeneration, queuedDocIndex == queuedDocs.count {
            queuedDocs.removeAll(keepingCapacity: true)
            queuedDocIndex = 0
        }
        processingTask = nil
        if isStarted {
            startProcessingQueueIfNeeded()
        }
    }
}
