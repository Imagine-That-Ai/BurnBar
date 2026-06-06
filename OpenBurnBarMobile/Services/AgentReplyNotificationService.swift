import Foundation
import FirebaseAuth
import FirebaseCore
import FirebaseFirestore
import FirebaseFunctions
import FirebaseMessaging
import OpenBurnBarCore
import SwiftUI
import UIKit
import UserNotifications

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

    init?(userInfo: [AnyHashable: Any]) {
        guard let type = Self.string(userInfo["type"]), type == "agent_reply" else { return nil }
        self.type = type
        eventID = Self.string(userInfo["event_id"]) ?? UUID().uuidString
        runtime = Self.string(userInfo["runtime"]) ?? "hermes"
        threadID = Self.string(userInfo["thread_id"]) ?? ""
        title = Self.string(userInfo["title"]) ?? "Agent replied"
        preview = Self.string(userInfo["preview"]) ?? ""
        provider = Self.string(userInfo["provider"]).flatMap(AgentProvider.init(rawValue:))
        deepLink = Self.string(userInfo["deep_link"])
    }

    var url: URL? {
        deepLink.flatMap(URL.init(string:)) ?? URL(string: "burnbar://assistants/\(runtime)?threadId=\(threadID)")
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

    static func sealedReplyMap(replyText: String, keyData: Data, vaultKeyID: String) throws -> [String: Any] {
        let payload = try encoder.encode(AgentNotificationReplyPrivatePayload(replyText: replyText))
        let sealed = try CloudVaultCrypto.sealPayload(payload, keyData: keyData, vaultKeyID: vaultKeyID)
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
        center.setNotificationCategories([Self.agentReplyCategory])
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

    private func persistDeviceState() async {
        guard FirebaseAppAvailable.isConfigured,
              let uid = Auth.auth().currentUser?.uid else { return }
        var payload: [String: Any] = [
            "deviceId": deviceID,
            "platform": "ios",
            "appLifecycle": appLifecycle,
            "agentNotificationsEnabled": true,
            "lastSeenAtMillis": Int64(Date().timeIntervalSince1970 * 1000),
            "updated_at_millis": Int64(Date().timeIntervalSince1970 * 1000),
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
            print("AgentReplyNotificationService device state write failed: \(error.localizedDescription)")
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
            _ = try await callable.call([
                "eventId": eventID,
                "sealedReplyPayload": try AgentNotificationReplySealer.sealedReplyMap(
                    replyText: replyText,
                    keyData: key.keyData,
                    vaultKeyID: key.vaultKeyID
                ),
                "vaultKeyID": key.vaultKeyID,
                "deviceId": deviceID,
                "clientReplyId": "\(eventID)_\(deviceID)",
            ])
        } catch {
            #if DEBUG
            print("submitAgentNotificationReply failed: \(error.localizedDescription)")
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
            HermesService.shared.loadMobileThread(id: threadID)
            HermesService.shared.selectedSessionID = threadID
            HermesService.shared.sendMessage(replyText)
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
        let payload = AgentReplyNotificationPayload(userInfo: notification.request.content.userInfo)
        return await MainActor.run {
            handleNotificationPayload(payload, foreground: true)
        }
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let payload = AgentReplyNotificationPayload(userInfo: response.notification.request.content.userInfo)
        let actionIdentifier = response.actionIdentifier
        let replyText = (response as? UNTextInputNotificationResponse)?.userText
        await handleResponse(payload: payload, actionIdentifier: actionIdentifier, replyText: replyText)
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
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
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
