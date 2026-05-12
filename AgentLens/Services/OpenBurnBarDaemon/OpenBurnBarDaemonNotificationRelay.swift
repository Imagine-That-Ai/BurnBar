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

enum AgentCompletionNotificationParser {
    struct Completion {
        var providerID: String
        var providerName: String
        var modelName: String?
    }

    static func parse(title: String, body: String) -> Completion? {
        let text = "\(title) \(body)".lowercased()
        let hasCompletionSignal = ["complete", "completed", "finished", "done"].contains { text.contains($0) }
        guard hasCompletionSignal else {
            return nil
        }
        let modelName = extractModelName(title: title, body: body)
        if let provider = PixelClockCompletionSoundResolver.provider(forModelName: modelName)
            ?? provider(fromText: text) {
            return Completion(
                providerID: provider.persistedToken,
                providerName: providerName(for: provider),
                modelName: modelName
            )
        }
        return Completion(providerID: "openburnbar", providerName: "OpenBurnBar", modelName: modelName)
    }

    private static func extractModelName(title: String, body: String) -> String? {
        let combined = "\(title)\n\(body)"
        let patterns = [
            #"(?i)\bcompleted\s+on\s+([A-Za-z0-9][A-Za-z0-9._:/+-]*)"#,
            #"(?i)\bfinished\s+on\s+([A-Za-z0-9][A-Za-z0-9._:/+-]*)"#,
            #"(?i)\bdone\s+on\s+([A-Za-z0-9][A-Za-z0-9._:/+-]*)"#,
            #"(?i)\bmodel(?:_id| id|:)?\s+([A-Za-z0-9][A-Za-z0-9._:/+-]*)"#,
            #"(?i)\busing\s+([A-Za-z0-9][A-Za-z0-9._:/+-]*)"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(combined.startIndex..<combined.endIndex, in: combined)
            guard let match = regex.firstMatch(in: combined, range: range),
                  let captureRange = Range(match.range(at: 1), in: combined) else {
                continue
            }
            let candidate = String(combined[captureRange]).trimmingCharacters(in: CharacterSet(charactersIn: " .,\n\t"))
            if !candidate.isEmpty {
                return candidate
            }
        }
        return nil
    }

    private static func provider(fromText text: String) -> AgentProvider? {
        if text.contains("droid") || text.contains("factory") { return .factory }
        if text.contains("codex") || text.contains("openai") { return .codex }
        if text.contains("claude") { return .claudeCode }
        if text.contains("cursor") { return .cursor }
        if text.contains("minimax") { return .minimax }
        if text.contains("z.ai") || text.contains("zai") || text.contains("z-ai") { return .zai }
        if text.contains("kimi") || text.contains("moonshot") { return .kimi }
        if text.contains("ollama") { return .ollama }
        return nil
    }

    private static func providerName(for provider: AgentProvider) -> String {
        switch provider {
        case .factory:
            return "Factory / Droid"
        case .zai:
            return "Z.ai"
        default:
            return provider.displayName
        }
    }
}
