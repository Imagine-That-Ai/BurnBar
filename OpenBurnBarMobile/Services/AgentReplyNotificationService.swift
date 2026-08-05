import Foundation
import os.log
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import FirebaseMessaging
import OpenBurnBarCore
import SwiftUI
import UIKit
import UserNotifications

private let agentReplyNotificationLogger = Logger(subsystem: "com.openburnbar.mobile", category: "AgentReplyNotificationService")

struct AgentReplyNotificationBanner: Identifiable, Equatable {
    let id: String
    let title: String
    let preview: String
    let runtime: String
    let threadID: String
    let provider: AgentProvider?
    let deepLink: URL?
}

private struct AgentReplyNotificationPayload: Sendable {
    let type: String
    let eventID: String
    let runtime: String
    let threadID: String
    let title: String
    let preview: String
    let provider: AgentProvider?
    let deepLink: String?

    init(
        type: String,
        eventID: String,
        runtime: String,
        threadID: String,
        title: String,
        preview: String,
        provider: AgentProvider?,
        deepLink: String?
    ) {
        self.type = type
        self.eventID = eventID
        self.runtime = runtime
        self.threadID = threadID
        self.title = title
        self.preview = preview
        self.provider = provider
        self.deepLink = deepLink
    }

    init?(userInfo: [AnyHashable: Any]) {
        guard let type = Self.string(userInfo["type"]), type == "agent_reply" else { return nil }
        self.type = type
        eventID = Self.string(userInfo["event_id"]) ?? UUID().uuidString
        runtime = Self.string(userInfo["runtime"]) ?? "hermes"
        threadID = Self.string(userInfo["thread_id"]) ?? ""
        title = Self.string(userInfo["title"]) ?? "Agent replied"
        // Server-side previews are generic today, but any future plaintext
        // preview must land here markdown-free — banners render plain text.
        preview = HermesAtomParser.plainText(Self.string(userInfo["preview"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        provider = Self.string(userInfo["provider"]).flatMap(AgentProvider.init(rawValue:))
        deepLink = Self.string(userInfo["deep_link"])
    }

    var url: URL? {
        deepLink.flatMap(URL.init(string:)) ?? URL(string: "burnbar://assistants/\(runtime)?threadId=\(threadID)")
    }

    func withResolvedThreadID(_ threadID: String) -> AgentReplyNotificationPayload {
        AgentReplyNotificationPayload(
            type: type,
            eventID: eventID,
            runtime: runtime,
            threadID: threadID,
            title: title,
            preview: preview,
            provider: provider,
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

private struct AgentNotificationReplyPrivatePayload: Codable {
    let replyText: String
}

private enum AgentNotificationReplySealer {
    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    static func sealedReplyMap(
        replyText: String,
        uid: String,
        replyID: String,
        keyData: Data,
        vaultKeyID: String
    ) throws -> [String: Any] {
        let payload = try encoder.encode(AgentNotificationReplyPrivatePayload(replyText: replyText))
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
}

@MainActor
final class AgentReplyNotificationService: NSObject, ObservableObject {
    static let shared = AgentReplyNotificationService()

    @Published private(set) var banner: AgentReplyNotificationBanner?

    private let deviceIDKey = "agentReplyNotifications.deviceID"
    private var fcmToken: String?
    private var activeThreadID: String?
    private var activeRuntime: String?
    private var activeSurface: String?
    private var appLifecycle = "unknown"

    var deviceID: String {
        let defaults = UserDefaults.standard
        if let existing = defaults.string(forKey: deviceIDKey), !existing.isEmpty {
            return existing
        }
        let seed = UIDevice.current.identifierForVendor?.uuidString ?? UUID().uuidString
        let value = "ios-\(seed.lowercased())"
        defaults.set(value, forKey: deviceIDKey)
        return value
    }

    func configure(application: UIApplication) {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // Both push families register here rather than in separate `configure`
        // calls: `setNotificationCategories` REPLACES the whole set, so a second
        // registration elsewhere would silently drop the first one's actions.
        center.setNotificationCategories([Self.agentReplyCategory, Self.aiInboxCategory])
        Messaging.messaging().delegate = self
        requestAuthorizationAndRegister(application: application)
        updateLifecycle("active")
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) {
        Messaging.messaging().apnsToken = deviceToken
    }

    func updateLifecycle(_ lifecycle: String) {
        appLifecycle = lifecycle
        Task { await persistDeviceState() }
    }

    func setActiveChat(runtime: String?, threadID: String?, surface: String?) {
        activeRuntime = runtime
        activeThreadID = threadID
        activeSurface = surface
        Task { await persistDeviceState() }
    }

    func open(_ banner: AgentReplyNotificationBanner) {
        self.banner = nil
        // An inbox banner routes in-process. `UIApplication.open` on a
        // `burnbar://` URL from inside the app is a needless round trip through
        // the system, and on an in-app tap the app is by definition frontmost.
        if banner.runtime == AIInboxDeepLink.pushType {
            AIInboxDeepLink.open(itemID: banner.threadID)
            return
        }
        if let runtime = AssistantRuntimeID(rawValue: banner.runtime) {
            AssistantPendingThread.shared.stash(assistant: runtime, threadID: banner.threadID)
        }
        guard let deepLink = banner.deepLink else { return }
        UIApplication.shared.open(deepLink)
    }

    func dismissBanner() {
        banner = nil
    }

    func presentLocalReply(
        id: String,
        title: String,
        preview: String,
        runtime: String = AssistantRuntimeID.hermes.rawValue,
        threadID: String,
        provider: AgentProvider? = nil,
        deepLink: URL? = nil
    ) {
        let resolvedDeepLink = deepLink ?? URL(
            string: "burnbar://assistants/\(runtime)?threadId=\(threadID)"
        )
        // Notification banners and UNNotification bodies are plain-text
        // surfaces — flatten assistant markdown ("**Hello!**" → "Hello!")
        // before it reaches either of them.
        let preview = HermesAtomParser.plainText(preview)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        banner = AgentReplyNotificationBanner(
            id: id,
            title: title,
            preview: preview,
            runtime: runtime,
            threadID: threadID,
            provider: provider,
            deepLink: resolvedDeepLink
        )

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = preview
        content.sound = .default
        content.categoryIdentifier = "AGENT_REPLY"
        var userInfo: [String: String] = [
            "type": "agent_reply",
            "event_id": id,
            "runtime": runtime,
            "thread_id": threadID,
            "title": title,
            "preview": preview
        ]
        if let provider {
            userInfo["provider"] = provider.rawValue
        }
        if let deepLink = resolvedDeepLink?.absoluteString {
            userInfo["deep_link"] = deepLink
        }
        content.userInfo = userInfo
        let request = UNNotificationRequest(
            identifier: "burnbar.agent.local.\(id)",
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 0.1, repeats: false)
        )
        UNUserNotificationCenter.current().add(request) { _ in }
    }

    private func requestAuthorizationAndRegister(application: UIApplication) {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            guard granted else { return }
            DispatchQueue.main.async {
                application.registerForRemoteNotifications()
            }
        }
    }

    private func persistToken(_ token: String) {
        fcmToken = token
        Task { await persistDeviceState() }
    }

    /// The live system notification-authorization state for this install.
    /// `.authorized` and `.provisional` both deliver an alert/banner; every
    /// other status (`.denied`, `.notDetermined`, `.ephemeral`) means a push
    /// would be suppressed by the OS, so the cloud fan-out should not target it.
    private static func notificationsAuthorized() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        default:
            return false
        }
    }

    private func persistDeviceState() async {
        guard FirebaseAppAvailable.isConfigured,
              let uid = Auth.auth().currentUser?.uid else { return }
        // Report the REAL notification-permission state — never a hardcoded
        // `true`. When the user has denied (or not yet granted) authorization,
        // the cloud fan-out (`shouldSuppressForDevice`) must skip this device
        // instead of marking a silently-dropped push "sent". `.authorized` and
        // `.provisional` both deliver banners; anything else means no UI lands.
        let notificationsEnabled = await Self.notificationsAuthorized()
        var payload: [String: Any] = [
            "deviceId": deviceID,
            "platform": "ios",
            "appLifecycle": appLifecycle,
            "agentNotificationsEnabled": notificationsEnabled,
            "lastSeenAtMillis": Int64(Date().timeIntervalSince1970 * 1000),
            "updated_at_millis": Int64(Date().timeIntervalSince1970 * 1000)
        ]
        if let fcmToken { payload["fcm_token"] = fcmToken }
        if let activeThreadID { payload["activeThreadId"] = activeThreadID }
        if let activeRuntime { payload["activeRuntime"] = activeRuntime }
        if let activeSurface { payload["activeSurface"] = activeSurface }
        do {
            try await Firestore.firestore()
                .collection("users").document(uid)
                .collection("devices").document(deviceID)
                .setData(payload, merge: true)
        } catch {
            #if DEBUG
            agentReplyNotificationLogger.error("AgentReplyNotificationService device state write failed: \(error.localizedDescription, privacy: .public)")
            #endif
        }
    }

    private func handleNotificationPayload(_ payload: AgentReplyNotificationPayload?, foreground: Bool) -> UNNotificationPresentationOptions {
        guard let payload else {
            return [.banner, .sound]
        }
        if foreground, activeThreadID == payload.threadID, activeRuntime == payload.runtime {
            return []
        }
        banner = AgentReplyNotificationBanner(
            id: payload.eventID,
            title: payload.title,
            preview: payload.preview,
            runtime: payload.runtime,
            threadID: payload.threadID,
            provider: payload.provider,
            deepLink: payload.url
        )
        return foreground ? [] : [.banner, .sound]
    }

    private func handleResponse(
        payload: AgentReplyNotificationPayload?,
        actionIdentifier: String,
        replyText: String?
    ) async {
        guard let payload else { return }

        if actionIdentifier == Self.replyActionID {
            let reply = (replyText ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !reply.isEmpty else { return }
            await submitReply(eventID: payload.eventID, replyText: reply)
            await sendInlineReply(runtime: payload.runtime, threadID: payload.threadID, replyText: reply)
            return
        }

        if let runtime = AssistantRuntimeID(rawValue: payload.runtime) {
            AssistantPendingThread.shared.stash(assistant: runtime, threadID: payload.threadID)
        }
        if let deepLink = payload.url {
            await UIApplication.shared.open(deepLink)
        }
    }

    private func submitReply(eventID: String, replyText: String) async {
        let callable = Functions.functions(region: "us-central1").httpsCallable("submitAgentNotificationReply")
        do {
            guard let uid = Auth.auth().currentUser?.uid else { return }
            let key = try await MobileCloudVaultKeyAccess.keyForWriting(uid: uid)
            let replyId = "\(eventID)_\(deviceID)"
            _ = try await callable.call([
                "eventId": eventID,
                "sealedReplyPayload": try AgentNotificationReplySealer.sealedReplyMap(
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
            #if DEBUG
            agentReplyNotificationLogger.error("submitAgentNotificationReply failed: \(error.localizedDescription, privacy: .public)")
            #endif
        }
    }

    private func sendInlineReply(runtime: String, threadID: String, replyText: String) async {
        if let cliRuntime = CLIAgentRuntime(rawValue: runtime) {
            let history = MobileChatHistoryStore.shared
            history.bootstrap()
            let thread = history.thread(id: threadID) ?? MobileChatThread(
                id: threadID,
                runtime: cliRuntime.assistantRuntime.rawValue,
                title: cliRuntime.displayName,
                preview: "",
                modelName: nil,
                createdAt: Date(),
                updatedAt: Date(),
                messages: []
            )
            history.upsert(thread)
            let service = CLIAgentMobileChatService(
                runtime: cliRuntime,
                route: .mobile(thread),
                historyStore: history
            )
            await service.send(message: replyText)
            return
        }

        switch runtime {
        case AssistantRuntimeID.hermes.rawValue:
            // Send through the per-surface instance the main chat binds —
            // sending on `.shared` reached the model but the reply never
            // appeared in any visible transcript (no UI binds `.shared`).
            let hermes = HermesService.mainSurface ?? HermesService.shared
            hermes.loadMobileThread(id: threadID)
            hermes.selectedSessionID = threadID
            hermes.sendMessage(replyText)
        case AssistantRuntimeID.pi.rawValue, "piagent", "pi_agent":
            let history = MobileChatHistoryStore.shared
            history.bootstrap()
            let thread = history.thread(id: threadID) ?? MobileChatThread(
                id: threadID,
                runtime: AssistantRuntimeID.pi.rawValue,
                title: "Pi",
                preview: "",
                modelName: nil,
                createdAt: Date(),
                updatedAt: Date(),
                messages: []
            )
            history.upsert(thread)
            PiService.shared.loadThread(id: threadID)
            PiService.shared.send(prompt: replyText)
        default:
            break
        }
    }

    /// Foreground handling for an AI Inbox P1 push.
    ///
    /// Unlike an agent reply, an inbox alert has no "you are already looking at
    /// this" case to suppress: a P1 that fires while the user happens to have
    /// the app open is exactly the moment worth surfacing. It reuses the same
    /// banner so the two push families look identical in-app.
    private func handleInboxPayload(_ payload: AIInboxNotificationPayload, foreground: Bool) -> UNNotificationPresentationOptions {
        banner = AgentReplyNotificationBanner(
            id: payload.eventID,
            title: payload.title,
            preview: payload.body,
            runtime: AIInboxDeepLink.pushType,
            threadID: payload.itemID,
            provider: nil,
            deepLink: payload.deepLink
        )
        return foreground ? [] : [.banner, .sound]
    }

    private func openInboxItem(_ payload: AIInboxNotificationPayload) {
        // Post directly rather than routing through `UIApplication.open`: the
        // app is already frontmost when a notification response is delivered, so
        // an external open would round-trip through the URL handler for nothing.
        AIInboxDeepLink.open(itemID: payload.itemID)
    }

    private static let inboxOpenActionID = "AI_INBOX_OPEN"
    private static let aiInboxCategory: UNNotificationCategory = {
        // Open-only. There is nothing to reply TO — an inbox item is a finding,
        // not a message — and `submitAgentNotificationReply` refuses events
        // whose `replyEnabled` is false, which is what the inbox producer sets.
        let open = UNNotificationAction(identifier: inboxOpenActionID, title: "Open", options: [.foreground])
        return UNNotificationCategory(
            identifier: "AI_INBOX_ITEM",
            actions: [open],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }()

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
        return UNNotificationCategory(
            identifier: "AGENT_REPLY",
            actions: [reply, open],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
    }()
}

extension AgentReplyNotificationService: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        let userInfo = notification.request.content.userInfo
        if let inbox = AIInboxNotificationPayload(userInfo: userInfo) {
            return await MainActor.run { handleInboxPayload(inbox, foreground: true) }
        }
        let payload = AgentReplyNotificationPayload(userInfo: userInfo)
        return await MainActor.run {
            handleNotificationPayload(payload, foreground: true)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let userInfo = response.notification.request.content.userInfo
        if let inbox = AIInboxNotificationPayload(userInfo: userInfo) {
            await MainActor.run { openInboxItem(inbox) }
            return
        }
        let payload = AgentReplyNotificationPayload(userInfo: userInfo)
        let resolved = await resolvedPayloadForPush(payload)
        let actionIdentifier = response.actionIdentifier
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        await handleResponse(payload: resolved ?? payload, actionIdentifier: actionIdentifier, replyText: replyText)
    }

    /// Resolve a push payload to a full payload, fetching the thread id from the
    /// durable agent_notification_events document when the push omits it for
    /// privacy (OPUS-F-006).
    private nonisolated func resolvedPayloadForPush(_ payload: AgentReplyNotificationPayload?) async -> AgentReplyNotificationPayload? {
        guard let payload, payload.threadID.isEmpty, !payload.eventID.isEmpty else { return payload }
        guard let uid = Auth.auth().currentUser?.uid else { return payload }
        do {
            let snapshot = try await Firestore.firestore()
                .collection("users").document(uid)
                .collection("agent_notification_events").document(payload.eventID)
                .getDocument(source: .server)
            guard let data = snapshot.data(),
                  let threadID = string(data["threadId"])?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !threadID.isEmpty else { return payload }
            return payload.withResolvedThreadID(threadID)
        } catch {
            // Best-effort: fall back to the un-resolved push payload, but log —
            // the tap will land without a thread id and open the generic surface.
            agentReplyNotificationLogger.warning("resolvedPayloadForPush failed event=\(payload.eventID, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return payload
        }
    }
}

extension AgentReplyNotificationService: MessagingDelegate {
    nonisolated func messaging(_ messaging: Messaging, didReceiveRegistrationToken fcmToken: String?) {
        guard let fcmToken else { return }
        Task { @MainActor in
            AgentReplyNotificationService.shared.persistToken(fcmToken)
        }
    }
}

struct AgentReplyNotificationBannerView: View {
    let banner: AgentReplyNotificationBanner
    let onOpen: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack {
            HStack(spacing: 12) {
                Button(action: onOpen) {
                    HStack(spacing: 12) {
                        ZStack {
                            Circle()
                                .fill(Color.accentColor.opacity(0.14))
                                .frame(width: 36, height: 36)
                            if let runtimeProvider = banner.runtimeProvider {
                                HarnessModelBadge(
                                    harness: runtimeProvider,
                                    model: banner.provider,
                                    size: 30,
                                    modelScale: 0.36
                                )
                            } else if let provider = banner.provider {
                                UnifiedProviderLogoView(provider: provider, size: 24, useFallbackColor: true)
                            } else {
                                Image(systemName: "bubble.left.and.bubble.right.fill")
                                    .font(.system(size: 20, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }

                        VStack(alignment: .leading, spacing: 3) {
                            Text(banner.title)
                                .font(.headline)
                                .lineLimit(1)
                            Text(banner.preview)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(banner.title). \(banner.preview)")
                .accessibilityHint("Opens the reply thread.")

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss reply notification")
            }
            .padding(14)
            .liquidGlassInteractive(
                in: RoundedRectangle(cornerRadius: 8, style: .continuous),
                fallback: .regularMaterial
            )
            .shadow(color: .black.opacity(0.16), radius: 24, x: 0, y: 12)
            .padding(.horizontal, 16)
            .padding(.top, 12)

            Spacer()
        }
        .transition(.move(edge: .top).combined(with: .opacity))
    }
}

private extension AgentReplyNotificationBanner {
    var runtimeProvider: AgentProvider? {
        AssistantRuntimeID(rawValue: runtime)?.agentProvider
    }
}

private enum FirebaseAppAvailable {
    static var isConfigured: Bool {
        FirebaseApp.app() != nil
    }
}

private func string(_ raw: Any?) -> String? {
    if let value = raw as? String, !value.isEmpty { return value }
    return nil
}
