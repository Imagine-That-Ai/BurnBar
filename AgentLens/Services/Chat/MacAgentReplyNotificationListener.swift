@preconcurrency import AppKit
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
import FirebaseFunctions
import Foundation
import OpenBurnBarCore
import UserNotifications

private struct MacAgentReplyNotificationPayload: Sendable {
    let eventID: String
    let runtime: String
    let threadID: String
    let title: String
    let preview: String
    let deepLink: String?

    init?(documentID: String, data: [String: Any]) {
        let type = Self.string(data["type"]) ?? "agent_reply"
        guard type == "agent_reply" else { return nil }
        eventID = Self.string(data["eventId"]) ?? documentID
        runtime = Self.string(data["runtime"]) ?? "hermes"
        threadID = Self.string(data["threadId"]) ?? ""
        title = Self.string(data["title"]) ?? "Agent replied"
        preview = Self.string(data["preview"]) ?? ""
        deepLink = Self.string(data["deepLink"])
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard Self.string(userInfo["type"]) == "agent_reply" else { return nil }
        eventID = Self.string(userInfo["event_id"]) ?? UUID().uuidString
        runtime = Self.string(userInfo["runtime"]) ?? "hermes"
        threadID = Self.string(userInfo["thread_id"]) ?? ""
        title = Self.string(userInfo["title"]) ?? "Agent replied"
        preview = Self.string(userInfo["preview"]) ?? ""
        deepLink = Self.string(userInfo["deep_link"])
    }

    var notificationUserInfo: [String: String] {
        [
            "type": "agent_reply",
            "event_id": eventID,
            "runtime": runtime,
            "thread_id": threadID,
            "title": title,
            "preview": preview,
            "deep_link": deepLink ?? "openburnbar://assistants/\(runtime)?threadId=\(threadID)"
        ]
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}

private struct MacAgentNotificationReplyCommand: Sendable {
    let id: String
    let eventID: String
    let runtime: String
    let threadID: String
    let sealedReplyPayload: CloudVaultSealedPayload
    let deviceID: String?
    let status: String

    init?(documentID: String, data: [String: Any]) {
        id = Self.string(data["id"]) ?? documentID
        eventID = Self.string(data["eventId"]) ?? ""
        runtime = Self.string(data["runtime"]) ?? "hermes"
        threadID = Self.string(data["threadId"]) ?? ""
        guard let sealedReplyPayload = CloudVaultCrypto.sealedPayload(from: data["sealedReplyPayload"]) else { return nil }
        self.sealedReplyPayload = sealedReplyPayload
        deviceID = Self.string(data["deviceId"])
        status = Self.string(data["status"]) ?? "queued"

        guard !eventID.isEmpty,
              !threadID.isEmpty,
              status == "queued" else {
            return nil
        }
    }

    var payload: MacAgentReplyNotificationPayload {
        MacAgentReplyNotificationPayload(
            eventID: eventID,
            runtime: runtime,
            threadID: threadID,
            title: "Agent reply",
            preview: "Reply queued.",
            deepLink: nil
        )
    }

    private static func string(_ value: Any?) -> String? {
        switch value {
        case let string as String:
            return string
        case let number as NSNumber:
            return number.stringValue
        default:
            return nil
        }
    }
}

private struct MacAgentNotificationReplyPrivatePayload: Codable {
    let replyText: String
}

enum MacAgentNotificationReplySealer {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private static let decoder = JSONDecoder()

    static func sealedReplyMap(
        replyText: String,
        uid: String,
        replyID: String,
        keyData: Data,
        vaultKeyID: String
    ) throws -> [String: Any] {
        let payload = try encoder.encode(MacAgentNotificationReplyPrivatePayload(replyText: replyText))
        let aadContext = try CloudVaultAADContext(
            uid: uid,
            collection: "agent_notification_replies",
            docID: replyID,
            field: "sealedReplyPayload"
        )
        let sealed = try CloudVaultCrypto.sealPayload(
            payload,
            keyData: keyData,
            vaultKeyID: vaultKeyID,
            aadContext: aadContext
        )
        return CloudVaultCrypto.sealedPayloadDictionary(sealed)
    }

    static func openReplyText(
        _ envelope: CloudVaultSealedPayload,
        uid: String,
        replyID: String,
        keyData: Data
    ) throws -> String {
        let aadContext = try CloudVaultAADContext(
            uid: uid,
            collection: "agent_notification_replies",
            docID: replyID,
            field: "sealedReplyPayload"
        )
        let payload = try CloudVaultCrypto.openPayload(envelope, keyData: keyData, aadContext: aadContext)
        return try decoder.decode(MacAgentNotificationReplyPrivatePayload.self, from: payload).replyText
    }
}

private extension MacAgentReplyNotificationPayload {
    init(eventID: String, runtime: String, threadID: String, title: String, preview: String, deepLink: String?) {
        self.eventID = eventID
        self.runtime = runtime
        self.threadID = threadID
        self.title = title
        self.preview = preview
        self.deepLink = deepLink
    }
}

@MainActor
final class MacAgentReplyNotificationListener: NSObject {
    static let shared = MacAgentReplyNotificationListener()

    private weak var chatController: ChatSessionController?
    private nonisolated(unsafe) var authHandle: AuthStateDidChangeListenerHandle?
    private var listener: ListenerRegistration?
    private var replyListener: ListenerRegistration?
    private var deliveredEventIDs = Set<String>()
    private var processedReplyIDs = Set<String>()
    private var started = false
    private let startMillis = Int64(Date().timeIntervalSince1970 * 1000)
    private let deviceIDKey = "agentReplyNotifications.macDeviceID"

    private var deviceID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIDKey), !existing.isEmpty {
            return existing
        }
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let seed = "\(host)-\(ProcessInfo.processInfo.globallyUniqueString)"
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
        let value = "mac-\(seed)"
        defaults.set(value, forKey: deviceIDKey)
        return value
    }

    func start(chatController: ChatSessionController) {
        self.chatController = chatController
        guard !started else {
            Task { await persistDeviceState(uid: Auth.auth().currentUser?.uid) }
            return
        }
        started = true

        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories([Self.agentReplyCategory])
        Task { await requestNotificationAuthorization() }

        authHandle = Auth.auth().addStateDidChangeListener { [weak self] _, user in
            Task { @MainActor in
                self?.restart(uid: user?.uid)
            }
        }
        restart(uid: Auth.auth().currentUser?.uid)

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(workspaceLifecycleDidChange),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    deinit {
        if let authHandle {
            Auth.auth().removeStateDidChangeListener(authHandle)
        }
        listener?.remove()
        replyListener?.remove()
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    @objc private func workspaceLifecycleDidChange() {
        Task { await persistDeviceState(uid: Auth.auth().currentUser?.uid) }
    }

    private func restart(uid: String?) {
        listener?.remove()
        listener = nil
        replyListener?.remove()
        replyListener = nil
        deliveredEventIDs.removeAll()
        processedReplyIDs.removeAll()
        Task { await persistDeviceState(uid: uid) }

        guard FirebaseApp.app() != nil, let uid else { return }
        listener = Firestore.firestore()
            .collection("users").document(uid)
            .collection("agent_notification_events")
            .whereField("createdAtMillis", isGreaterThan: startMillis - 5_000)
            .order(by: "createdAtMillis")
            .addSnapshotListener { [weak self] snapshot, error in
                guard error == nil else {
                    #if DEBUG
                    if let error { print("MacAgentReplyNotificationListener failed: \(error.localizedDescription)") }
                    #endif
                    return
                }
                guard let changes = snapshot?.documentChanges else { return }
                Task { @MainActor in
                    for change in changes where change.type == .added {
                        self?.handle(documentID: change.document.documentID, data: change.document.data())
                    }
                }
            }

        replyListener = Firestore.firestore()
            .collection("users").document(uid)
            .collection("agent_notification_replies")
            .whereField("status", isEqualTo: "queued")
            .addSnapshotListener { [weak self] snapshot, error in
                guard error == nil else {
                    #if DEBUG
                    if let error { print("MacAgentReplyCommandListener failed: \(error.localizedDescription)") }
                    #endif
                    return
                }
                guard let changes = snapshot?.documentChanges else { return }
                Task { @MainActor in
                    for change in changes where change.type == .added || change.type == .modified {
                        self?.handleReplyCommand(documentID: change.document.documentID, data: change.document.data())
                    }
                }
            }
    }

    private func handle(documentID: String, data: [String: Any]) {
        guard let payload = MacAgentReplyNotificationPayload(documentID: documentID, data: data),
              !deliveredEventIDs.contains(payload.eventID) else { return }
        deliveredEventIDs.insert(payload.eventID)

        if let chatController,
           chatController.activeThreadID == payload.threadID,
           MacAgentReplyNotificationListener.backend(for: payload.runtime) == chatController.chatBackend,
           NSApp.isActive {
            return
        }

        Task { await deliver(payload) }
    }

    private func deliver(_ payload: MacAgentReplyNotificationPayload) async {
        let center = UNUserNotificationCenter.current()
        let content = UNMutableNotificationContent()
        content.title = payload.title
        content.body = payload.preview
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = payload.notificationUserInfo

        let request = UNNotificationRequest(identifier: payload.eventID, content: content, trigger: nil)
        try? await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            center.add(request) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private func requestNotificationAuthorization() async {
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
    }

    private func persistDeviceState(uid: String?) async {
        guard FirebaseApp.app() != nil, let uid else { return }
        let runtime = chatController?.chatBackend.rawValue
        let threadID = chatController?.activeThreadID
        var payload: [String: Any] = [
            "deviceId": deviceID,
            "platform": "macos",
            "appLifecycle": NSApp.isActive ? "active" : "background",
            "agentNotificationsEnabled": true,
            "lastSeenAtMillis": Int64(Date().timeIntervalSince1970 * 1000),
            "updated_at_millis": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        if let runtime { payload["activeRuntime"] = runtime }
        if let threadID { payload["activeThreadId"] = threadID }
        try? await Firestore.firestore()
            .collection("users").document(uid)
            .collection("devices").document(deviceID)
            .setData(payload, merge: true)
    }

    private func handleResponse(
        payload: MacAgentReplyNotificationPayload?,
        actionIdentifier: String,
        replyText: String?
    ) async {
        guard let payload else { return }

        if actionIdentifier == Self.replyActionID {
            let reply = (replyText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty else { return }
            await submitReply(eventID: payload.eventID, replyText: reply)
            await routeInlineReply(payload: payload, replyText: reply)
            return
        }

        await open(payload: payload)
    }

    private func submitReply(eventID: String, replyText: String) async {
        let replyId = replyDocumentID(eventID: eventID, deviceID: deviceID)
        processedReplyIDs.insert(replyId)
        let callable = Functions.functions(region: "us-central1").httpsCallable("submitAgentNotificationReply")
        do {
            guard let uid = Auth.auth().currentUser?.uid else { return }
            let key = try await MacCloudVaultKeyAccess.keyForWriting(
                uid: uid,
                deviceId: AccountManager.shared.deviceId,
                firestore: Firestore.firestore()
            )
            _ = try await callable.call([
                "eventId": eventID,
                "sealedReplyPayload": try MacAgentNotificationReplySealer.sealedReplyMap(
                    replyText: replyText,
                    uid: uid,
                    replyID: replyId,
                    keyData: key.keyData,
                    vaultKeyID: key.vaultKeyID
                ),
                "vaultKeyID": key.vaultKeyID,
                "deviceId": deviceID,
                "clientReplyId": replyId
            ])
        } catch {
            processedReplyIDs.remove(replyId)
            AppLogger.sync.silentFailure("submitAgentNotificationReply", error: error)
        }
    }

    private func routeInlineReply(payload: MacAgentReplyNotificationPayload, replyText: String) async {
        await routeInlineReply(payload: payload, replyText: replyText, activate: true)
    }

    private func routeInlineReply(payload: MacAgentReplyNotificationPayload, replyText: String, activate: Bool) async {
        await open(payload: payload, activate: activate)
        guard let chatController else { return }
        chatController.inputText = replyText
        await chatController.send()
    }

    private func open(payload: MacAgentReplyNotificationPayload) async {
        await open(payload: payload, activate: true)
    }

    private func open(payload: MacAgentReplyNotificationPayload, activate: Bool) async {
        guard let chatController else { return }
        if let backend = Self.backend(for: payload.runtime), backend != chatController.chatBackend {
            chatController.setChatBackend(backend)
        }
        chatController.openOrCreateChatThread(id: payload.threadID)
        if activate {
            NSApp.activate(ignoringOtherApps: true)
        }
        await persistDeviceState(uid: Auth.auth().currentUser?.uid)
    }

    private func handleReplyCommand(documentID: String, data: [String: Any]) {
        guard let uid = Auth.auth().currentUser?.uid,
              let command = MacAgentNotificationReplyCommand(documentID: documentID, data: data),
              !processedReplyIDs.contains(command.id) else { return }
        processedReplyIDs.insert(command.id)

        Task {
            do {
                try await markReplyCommand(uid: uid, replyID: command.id, status: "processing", error: nil)
                guard let key = try await MacCloudVaultKeyAccess.keyForReading(
                    uid: uid,
                    deviceId: AccountManager.shared.deviceId,
                    firestore: Firestore.firestore()
                ) else {
                    throw CloudVaultAccessError.vaultKeyUnavailable
                }
                let replyText = try MacAgentNotificationReplySealer.openReplyText(
                    command.sealedReplyPayload,
                    uid: uid,
                    replyID: command.id,
                    keyData: key.keyData
                )
                await routeInlineReply(payload: command.payload, replyText: replyText, activate: false)
                try await markReplyCommand(uid: uid, replyID: command.id, status: "sent", error: nil)
            } catch {
                try? await markReplyCommand(uid: uid, replyID: command.id, status: "failed", error: error.localizedDescription)
            }
        }
    }

    private func markReplyCommand(uid: String, replyID: String, status: String, error: String?) async throws {
        var payload: [String: Any] = [
            "status": status,
            "processorDeviceId": deviceID,
            "processedAt": FieldValue.serverTimestamp(),
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if let error {
            payload["errorMessage"] = String(error.prefix(512))
        } else {
            payload["errorMessage"] = FieldValue.delete()
        }
        try await Firestore.firestore()
            .collection("users").document(uid)
            .collection("agent_notification_replies").document(replyID)
            .updateData(payload)
    }

    private func replyDocumentID(eventID: String, deviceID: String) -> String {
        "\(eventID)_\(safeID(deviceID))"
    }

    private func safeID(_ value: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        let scalars = value.unicodeScalars.map { allowed.contains($0) ? Character($0) : "_" }
        let sanitized = String(scalars)
        return String((sanitized.isEmpty ? "device" : sanitized).prefix(96))
    }

    private static func backend(for runtime: String) -> ChatBackendID? {
        switch runtime {
        case "pi", "pi_agent", "piagent":
            return .piAgent
        case "open_claw", "openclaw":
            return .openclaw
        default:
            return ChatBackendID(rawValue: runtime)
        }
    }

    private static let categoryID = "AGENT_REPLY"
    private static let replyActionID = "AGENT_REPLY_INLINE_REPLY"
    private static let openActionID = "AGENT_REPLY_OPEN"
    private static let agentReplyCategory: UNNotificationCategory = {
        let reply = UNTextInputNotificationAction(
            identifier: replyActionID,
            title: "Reply",
            options: [.authenticationRequired],
            textInputButtonTitle: "Send",
            textInputPlaceholder: "Reply to agent"
        )
        let open = UNNotificationAction(identifier: openActionID, title: "Open", options: [.foreground])
        return UNNotificationCategory(identifier: categoryID, actions: [reply, open], intentIdentifiers: [], options: [])
    }()
}

extension MacAgentReplyNotificationListener: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let payload = MacAgentReplyNotificationPayload(userInfo: notification.request.content.userInfo)
        guard payload != nil else { return [.banner, .sound] }
        return []
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let payload = MacAgentReplyNotificationPayload(userInfo: response.notification.request.content.userInfo)
        let actionIdentifier = response.actionIdentifier
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        await handleResponse(payload: payload, actionIdentifier: actionIdentifier, replyText: replyText)
    }
}
