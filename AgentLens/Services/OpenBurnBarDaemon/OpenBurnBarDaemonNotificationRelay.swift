import Foundation
import UserNotifications
import OpenBurnBarCore

/// Subscribes to `NSDistributedNotificationCenter` posts from the per-user daemon and mirrors them into
/// standard UserNotifications from the real app process (menu bar `.app`), avoiding helper-tool issues
/// and any `osascript` subprocess.
@MainActor
final class OpenBurnBarDaemonLocalNotificationRelay: NSObject {
    static let shared = OpenBurnBarDaemonLocalNotificationRelay()

    private var started = false

    func start() {
        guard !started else { return }
        started = true
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(handleDistributed(_:)),
            name: OpenBurnBarDistributedNotifications.daemonLocalNotificationName,
            object: nil,
            suspensionBehavior: .deliverImmediately
        )
    }

    @objc private func handleDistributed(_ notification: Notification) {
        guard
            let title = notification.userInfo?[OpenBurnBarDistributedNotifications.titleKey] as? String,
            let body = notification.userInfo?[OpenBurnBarDistributedNotifications.bodyKey] as? String
        else {
            return
        }
        Task { [title, body] in
            await Self.deliverUserNotification(title: title, body: body)
        }
    }

    private static func deliverUserNotification(title: String, body: String) async {
        let pixelClock = SettingsManager.shared.pixelClockConfig
        if pixelClock.completionClockSoundEnabled,
           let completion = AgentCompletionNotificationParser.parse(title: title, body: body) {
            let controller = PixelClockController(settingsManager: .shared, quotaService: nil)
            controller.start()
            await controller.notifyAgentCompletion(
                providerID: completion.providerID,
                providerName: completion.providerName,
                modelName: completion.modelName
            )
        }

        guard pixelClock.completionLocalNotificationsEnabled else { return }

        let center = UNUserNotificationCenter.current()
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        guard granted else { return }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

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
}

private enum AgentCompletionNotificationParser {
    struct Completion {
        var providerID: String
        var providerName: String
        var modelName: String?
    }

    static func parse(title: String, body: String) -> Completion? {
        let text = "\(title) \(body)".lowercased()
        guard text.contains("complete") || text.contains("completed") || text.contains("finished") || text.contains("done") else {
            return nil
        }
        if text.contains("droid") || text.contains("factory") {
            return Completion(providerID: AgentProvider.factory.persistedToken, providerName: "Factory / Droid", modelName: nil)
        }
        if text.contains("codex") || text.contains("openai") {
            return Completion(providerID: AgentProvider.codex.persistedToken, providerName: "Codex", modelName: nil)
        }
        if text.contains("claude") {
            return Completion(providerID: AgentProvider.claudeCode.persistedToken, providerName: "Claude Code", modelName: nil)
        }
        if text.contains("cursor") {
            return Completion(providerID: AgentProvider.cursor.persistedToken, providerName: "Cursor", modelName: nil)
        }
        if text.contains("minimax") {
            return Completion(providerID: AgentProvider.minimax.persistedToken, providerName: "MiniMax", modelName: nil)
        }
        if text.contains("z.ai") || text.contains("zai") {
            return Completion(providerID: AgentProvider.zai.persistedToken, providerName: "Z.ai", modelName: nil)
        }
        return Completion(providerID: "openburnbar", providerName: "OpenBurnBar", modelName: nil)
    }
}
