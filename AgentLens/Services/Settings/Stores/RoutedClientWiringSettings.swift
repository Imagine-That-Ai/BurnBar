import Foundation

extension Notification.Name {
    /// Posted by `RoutedClientWiringSettings` whenever the enrolled-target set
    /// changes. The durability sentry listens for this so it can re-arm its
    /// `DispatchSource` watchers without polling.
    static let routedClientWiringEnrollmentDidChange = Notification.Name(
        "com.openburnbar.routedClientWiring.enrollmentDidChange"
    )
}

// MARK: - Routed Client Wiring Settings

/// Persisted intent for routed-client (Claude Code / Codex / Forge / OpenCode
/// / Droid) wiring durability. The sentry uses this store to know which CLI
/// configs the user expects to stay wired through the local BurnBar gateway,
/// even when an external tool (Claude Code's own settings rewrites, plugin
/// installs, dotfile syncs, etc.) strips the env block.
@Observable
@MainActor
final class RoutedClientWiringSettings {
    private let persistence: SettingsPersistenceCoordinator

    private static let enrolledTargetsKey = "routedClientWiringEnrolledTargets"
    private static let autoRepairEnabledKey = "routedClientWiringAutoRepairEnabled"
    private static let lastRepairAtPrefix = "routedClientWiringLastRepairAt."

    /// Master switch for the durability sentry. Default is `true` so users get
    /// self-healing the first time they connect a CLI, with no extra setup.
    var autoRepairEnabled: Bool = true {
        didSet { persistence.set(autoRepairEnabled, forKey: Self.autoRepairEnabledKey) }
    }

    /// Raw values of `RoutingClientWiringTarget` that the user has connected
    /// at least once and not explicitly disconnected. The sentry treats every
    /// entry as a standing request to keep wired.
    private(set) var enrolledTargets: Set<String> = [] {
        didSet { persistEnrolledTargets() }
    }

    init(persistence: SettingsPersistenceCoordinator) {
        self.persistence = persistence
        if persistence.objectExists(forKey: Self.autoRepairEnabledKey) {
            self.autoRepairEnabled = persistence.bool(forKey: Self.autoRepairEnabledKey)
        } else {
            self.autoRepairEnabled = true
        }
        if let raw = persistence.optionalString(forKey: Self.enrolledTargetsKey),
           let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            self.enrolledTargets = Set(decoded)
        } else {
            self.enrolledTargets = []
        }
    }

    /// Mark the target as wanted-wired. Called after a successful Connect.
    func enroll(targetRawValue: String) {
        let normalized = targetRawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        guard !enrolledTargets.contains(normalized) else { return }
        enrolledTargets.insert(normalized)
        postEnrollmentChange()
    }

    /// Drop the target from durability. Called after an explicit Disconnect.
    func unenroll(targetRawValue: String) {
        let normalized = targetRawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard enrolledTargets.contains(normalized) else { return }
        enrolledTargets.remove(normalized)
        persistence.removeObject(forKey: Self.lastRepairAtPrefix + normalized)
        postEnrollmentChange()
    }

    /// Record the most recent repair so the UI/audit log can show "self-healed
    /// 3 times today". Persisted as seconds-since-1970.
    func recordRepair(targetRawValue: String, at date: Date) {
        let normalized = targetRawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        persistence.set(date.timeIntervalSince1970, forKey: Self.lastRepairAtPrefix + normalized)
    }

    /// Read back the most recent repair timestamp.
    func lastRepairDate(targetRawValue: String) -> Date? {
        let normalized = targetRawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = persistence.optionalDouble(forKey: Self.lastRepairAtPrefix + normalized) else {
            return nil
        }
        return Date(timeIntervalSince1970: value)
    }

    private func persistEnrolledTargets() {
        let sorted = enrolledTargets.sorted()
        if let data = try? JSONEncoder().encode(sorted),
           let text = String(data: data, encoding: .utf8) {
            persistence.set(text, forKey: Self.enrolledTargetsKey)
        } else {
            persistence.removeObject(forKey: Self.enrolledTargetsKey)
        }
    }

    private func postEnrollmentChange() {
        NotificationCenter.default.post(
            name: .routedClientWiringEnrollmentDidChange,
            object: self
        )
    }
}
