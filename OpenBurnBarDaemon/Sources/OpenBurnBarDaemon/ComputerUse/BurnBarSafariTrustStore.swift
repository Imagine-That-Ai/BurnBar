import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarKernel

/// Persistent, daemon-owned trust policy for the Safari WebExtension.
///
/// The popup may propose future-session policy changes, but it never supplies
/// live scope rules to the Computer Use coordinator. This actor normalizes one
/// exact HTTPS origin (or exact HTTP loopback origin), bounds its
/// lifetime/action budget, persists it with
/// owner-only permissions, and materializes immutable rules only when a new
/// Computer Use session is admitted.
public actor BurnBarSafariTrustStore {
    public struct SessionPolicy: Sendable, Equatable {
        public let origin: String
        public let trustMode: ComputerUseTrustMode
        public let actionCap: Int
        public let scopeRules: [ComputerUseScopeRule]
        public let killSwitchEnabled: Bool

        public init(
            origin: String,
            trustMode: ComputerUseTrustMode,
            actionCap: Int,
            scopeRules: [ComputerUseScopeRule],
            killSwitchEnabled: Bool
        ) {
            self.origin = origin
            self.trustMode = trustMode
            self.actionCap = actionCap
            self.scopeRules = scopeRules
            self.killSwitchEnabled = killSwitchEnabled
        }
    }

    public enum StoreError: Error, LocalizedError, Sendable, Equatable {
        case invalidOrigin
        case invalidTrustMode
        case invalidActionBudget
        case invalidExpiry
        case malformedStore
        case killSwitchEnabled
        case deniedOrigin

        public var errorDescription: String? {
            switch self {
            case .invalidOrigin:
                return "Safari trust policy requires one exact HTTPS origin or exact HTTP loopback origin."
            case .invalidTrustMode:
                return "Safari trust mode is invalid."
            case .invalidActionBudget:
                return "Safari trust action budget is outside the supported range."
            case .invalidExpiry:
                return "Safari trust expiry is invalid or too far in the future."
            case .malformedStore:
                return "The persisted Safari trust policy is malformed."
            case .killSwitchEnabled:
                return "Safari Computer Use is disabled by the global kill switch."
            case .deniedOrigin:
                return "Safari Computer Use is denied for this origin."
            }
        }
    }

    private struct RuleRecord: Codable, Hashable, Sendable {
        let ruleID: String
        let origin: String
        let decision: BurnBarSafariTrustDecision
        let trustMode: String
        let actionBudget: Int
        let expiresAt: Date
        let createdAt: Date
        let updatedAt: Date
    }

    private struct StoreEnvelope: Codable, Sendable {
        let schemaVersion: Int
        var killSwitchEnabled: Bool
        var rules: [String: RuleRecord]
        var updatedAt: Date
    }

    private static let schemaVersion = 1
    private static let defaultActionBudget = 50
    private static let maximumActionBudget = 10_000
    private static let maximumTrustedActionBudget = 50
    private static let maximumRuleLifetime: TimeInterval = 24 * 60 * 60
    private static let maximumRuleCount = 2_048

    private let fileURL: URL
    private let fileManager: FileManager
    private let now: @Sendable () -> Date
    private var loaded = false
    private var envelope = StoreEnvelope(
        schemaVersion: schemaVersion,
        killSwitchEnabled: false,
        rules: [:],
        updatedAt: .distantPast
    )

    public init(
        fileURL: URL = BurnBarDaemonPaths.supportDirectoryURL
            .appendingPathComponent("safari", isDirectory: true)
            .appendingPathComponent("trust-v1.json", isDirectory: false),
        fileManager: FileManager = .default,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.fileURL = fileURL.standardizedFileURL
        self.fileManager = fileManager
        self.now = now
    }

    public func update(
        _ request: BurnBarSafariTrustUpdateRequest
    ) throws -> BurnBarSafariTrustUpdateResponse {
        try loadIfNeeded()
        let current = now()

        if let killSwitchEnabled = request.killSwitchEnabled {
            envelope.killSwitchEnabled = killSwitchEnabled
        }

        var responseOrigin = request.origin
        var responseRuleID: String?
        if request.origin != "*" {
            let origin = try Self.normalizedTrustOrigin(request.origin)
            responseOrigin = origin
            switch request.decision {
            case .remove:
                responseRuleID = envelope.rules.removeValue(forKey: origin)?.ruleID
            case .allow, .deny:
                guard let requestedTrustMode = ComputerUseTrustMode(rawValue: request.trustMode) else {
                    throw StoreError.invalidTrustMode
                }
                let requestedBudget = request.actionBudget ?? Self.defaultActionBudget
                guard (1...Self.maximumActionBudget).contains(requestedBudget) else {
                    throw StoreError.invalidActionBudget
                }
                let expiresAt = request.expiresAt
                    ?? current.addingTimeInterval(Self.maximumRuleLifetime)
                guard expiresAt > current,
                      expiresAt <= current.addingTimeInterval(Self.maximumRuleLifetime) else {
                    throw StoreError.invalidExpiry
                }
                let effectiveBudget = requestedTrustMode == .trusted
                    ? min(requestedBudget, Self.maximumTrustedActionBudget)
                    : requestedBudget
                let existing = envelope.rules[origin]
                let ruleID = existing?.ruleID ?? "safari-origin:\(origin)"
                let record = RuleRecord(
                    ruleID: ruleID,
                    origin: origin,
                    decision: request.decision,
                    trustMode: requestedTrustMode.rawValue,
                    actionBudget: effectiveBudget,
                    expiresAt: expiresAt,
                    createdAt: existing?.createdAt ?? current,
                    updatedAt: current
                )
                envelope.rules[origin] = record
                responseRuleID = ruleID
            }
        } else if request.decision != .remove {
            throw StoreError.invalidOrigin
        }

        pruneExpired(at: current)
        guard envelope.rules.count <= Self.maximumRuleCount else {
            throw StoreError.malformedStore
        }
        envelope.updatedAt = current
        try persist()
        return BurnBarSafariTrustUpdateResponse(
            accepted: true,
            ruleId: responseRuleID,
            origin: responseOrigin,
            decision: request.decision,
            killSwitchEnabled: envelope.killSwitchEnabled
        )
    }

    public func policy(
        for pageURL: String,
        requestedTrustMode: ComputerUseTrustMode = .manual,
        requestedActionCap: Int = 50
    ) throws -> SessionPolicy {
        try loadIfNeeded()
        let current = now()
        pruneExpired(at: current)
        guard envelope.killSwitchEnabled == false else {
            throw StoreError.killSwitchEnabled
        }
        let origin = try Self.normalizedTrustOrigin(fromPageURL: pageURL)
        guard let record = envelope.rules[origin] else {
            return SessionPolicy(
                origin: origin,
                trustMode: .manual,
                actionCap: min(max(requestedActionCap, 1), Self.defaultActionBudget),
                scopeRules: [],
                killSwitchEnabled: false
            )
        }
        guard record.decision != .deny else {
            throw StoreError.deniedOrigin
        }
        guard let storedTrustMode = ComputerUseTrustMode(rawValue: record.trustMode) else {
            throw StoreError.malformedStore
        }
        let effectiveTrustMode = Self.moreRestrictive(requestedTrustMode, storedTrustMode)
        let effectiveCap = min(max(requestedActionCap, 1), record.actionBudget)
        let escapedOrigin = NSRegularExpression.escapedPattern(for: origin)
        let rule = ComputerUseScopeRule(
            id: ComputerUseScopeRuleID(record.ruleID),
            effect: .allow,
            origin: .user,
            label: "Safari site trust: \(origin)",
            urlRegex: "^\(escapedOrigin)(?:[/?#]|$)",
            bundleId: "com.apple.Safari",
            actionBudget: effectiveCap,
            expiresAt: record.expiresAt,
            createdAt: record.updatedAt
        )
        return SessionPolicy(
            origin: origin,
            trustMode: effectiveTrustMode,
            actionCap: effectiveCap,
            scopeRules: [rule],
            killSwitchEnabled: false
        )
    }

    public func killSwitchEnabled() throws -> Bool {
        try loadIfNeeded()
        return envelope.killSwitchEnabled
    }

    private func loadIfNeeded() throws {
        guard loaded == false else { return }
        loaded = true
        guard fileManager.fileExists(atPath: fileURL.path) else {
            envelope.updatedAt = now()
            return
        }
        let values = try fileURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        )
        guard values.isRegularFile == true,
              values.isSymbolicLink != true,
              let size = values.fileSize,
              size > 0,
              size <= 4 * 1024 * 1024 else {
            throw StoreError.malformedStore
        }
        let decoded = try JSONDecoder().decode(
            StoreEnvelope.self,
            from: Data(contentsOf: fileURL)
        )
        guard decoded.schemaVersion == Self.schemaVersion,
              decoded.rules.count <= Self.maximumRuleCount else {
            throw StoreError.malformedStore
        }
        for (origin, record) in decoded.rules {
            guard origin == record.origin,
                  (try? Self.normalizedTrustOrigin(origin)) == origin,
                  record.decision != .remove,
                  ComputerUseTrustMode(rawValue: record.trustMode) != nil,
                  (1...Self.maximumActionBudget).contains(record.actionBudget),
                  record.expiresAt > record.createdAt else {
                throw StoreError.malformedStore
            }
        }
        envelope = decoded
        pruneExpired(at: now())
    }

    private func pruneExpired(at date: Date) {
        envelope.rules = envelope.rules.filter { _, record in
            record.expiresAt > date
        }
    }

    private func persist() throws {
        let directory = fileURL.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: [.atomic])
        try fileManager.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: fileURL.path
        )
    }

    static func normalizedTrustOrigin(_ raw: String) throws -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              trimmed.utf8.count <= 2_048,
              var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.path.isEmpty || components.path == "/" else {
            throw StoreError.invalidOrigin
        }
        guard scheme == "https"
                || (scheme == "http" && Self.loopbackHosts.contains(host)) else {
            throw StoreError.invalidOrigin
        }
        components.scheme = scheme
        components.host = host
        components.path = ""
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        guard let normalized = components.string,
              let url = URL(string: normalized),
              url.scheme == scheme,
              url.host != nil else {
            throw StoreError.invalidOrigin
        }
        return normalized
    }

    static func normalizedTrustOrigin(fromPageURL raw: String) throws -> String {
        guard let page = URLComponents(string: raw),
              let scheme = page.scheme?.lowercased(),
              let host = page.host?.lowercased(),
              !host.isEmpty,
              page.user == nil,
              page.password == nil else {
            throw StoreError.invalidOrigin
        }
        guard scheme == "https"
                || (scheme == "http" && Self.loopbackHosts.contains(host)) else {
            throw StoreError.invalidOrigin
        }
        var origin = URLComponents()
        origin.scheme = scheme
        origin.host = host
        origin.port = (scheme == "https" && page.port == 443)
            || (scheme == "http" && page.port == 80)
            ? nil
            : page.port
        guard let value = origin.string else {
            throw StoreError.invalidOrigin
        }
        return value
    }

    private static let loopbackHosts: Set<String> = [
        "127.0.0.1",
        "localhost",
        "::1"
    ]

    private static func moreRestrictive(
        _ lhs: ComputerUseTrustMode,
        _ rhs: ComputerUseTrustMode
    ) -> ComputerUseTrustMode {
        func rank(_ mode: ComputerUseTrustMode) -> Int {
            switch mode {
            case .manual: 0
            case .step: 1
            case .trusted: 2
            }
        }
        return rank(lhs) <= rank(rhs) ? lhs : rhs
    }
}
