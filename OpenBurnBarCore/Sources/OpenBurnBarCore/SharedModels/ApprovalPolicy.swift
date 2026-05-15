import Foundation

// MARK: - Approval Policy (Hermes Square §6.9)
//
// Class-based "Yes always for X" learning. When the user picks "Always for
// tests in this project" once, the host writes a policy record
// (`users/{uid}/approval_policies/{class}`) that auto-resolves matching
// future asks until the user revokes.
//
// A policy class is a tuple `(missionKind, toolName?, fileGlob?, runtimeID?)`.
// The classifier hashes the tuple to a stable string ID.

public struct ApprovalPolicy: Codable, Sendable, Hashable, Identifiable {
    /// Stable class hash — `id` for Firestore document name.
    public let id: String

    /// User-friendly display: "All shell commands for Codex on Project X".
    public let displayLabel: String

    /// Decision: approve or deny matching future asks.
    public let decision: Decision

    public enum Decision: String, Codable, Sendable, Hashable {
        case approve
        case deny
    }

    /// Discriminators that compose the policy class.
    public let missionKind: String?
    public let toolName: String?
    public let fileGlob: String?
    public let runtimeID: String?
    public let targetProject: String?

    /// ISO-8601 timestamp the policy was created.
    public let createdAt: Date

    /// Optional expiry (ISO-8601). `nil` = forever.
    public let expiresAt: Date?

    /// Counter for how many asks this policy has auto-resolved. Lets the
    /// UI surface "this policy has approved 23 asks" so the user can audit.
    public var matchCount: Int

    public init(
        missionKind: String? = nil,
        toolName: String? = nil,
        fileGlob: String? = nil,
        runtimeID: String? = nil,
        targetProject: String? = nil,
        decision: Decision = .approve,
        displayLabel: String,
        createdAt: Date = Date(),
        expiresAt: Date? = nil,
        matchCount: Int = 0
    ) {
        let id = ApprovalPolicy.classHash(
            missionKind: missionKind,
            toolName: toolName,
            fileGlob: fileGlob,
            runtimeID: runtimeID,
            targetProject: targetProject,
            decision: decision
        )
        self.id = id
        self.missionKind = missionKind
        self.toolName = toolName
        self.fileGlob = fileGlob
        self.runtimeID = runtimeID
        self.targetProject = targetProject
        self.decision = decision
        self.displayLabel = displayLabel
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.matchCount = matchCount
    }

    /// Stable hash for the class tuple. Format keeps it grep-able.
    public static func classHash(
        missionKind: String?,
        toolName: String?,
        fileGlob: String?,
        runtimeID: String?,
        targetProject: String?,
        decision: Decision
    ) -> String {
        let parts: [String] = [
            "decision=\(decision.rawValue)",
            "mk=\(missionKind ?? "*")",
            "tool=\(toolName ?? "*")",
            "glob=\(fileGlob ?? "*")",
            "runtime=\(runtimeID ?? "*")",
            "project=\(targetProject ?? "*")"
        ]
        return parts.joined(separator: "|")
    }

    // MARK: - Matching

    /// Returns true if this policy applies to the given ask. A wildcard
    /// field (`nil`) matches anything; a concrete field must match exactly
    /// (or glob-style for `fileGlob`).
    public func matches(
        missionKind: String?,
        toolName: String?,
        filePath: String?,
        runtimeID: String?,
        targetProject: String?
    ) -> Bool {
        if let expiresAt, expiresAt < Date() { return false }
        if let mk = self.missionKind, mk != missionKind { return false }
        if let tn = self.toolName, tn != toolName { return false }
        if let glob = self.fileGlob {
            if let path = filePath {
                if !Self.matchGlob(glob, path: path) { return false }
            } else {
                return false
            }
        }
        if let r = self.runtimeID, r != runtimeID { return false }
        if let p = self.targetProject, p != targetProject { return false }
        return true
    }

    /// Minimal glob: `*` matches any non-slash segment; `**` matches
    /// anything including slashes. Anchored at both ends.
    public static func matchGlob(_ pattern: String, path: String) -> Bool {
        let regex = pattern
            .replacingOccurrences(of: ".", with: "\\.")
            .replacingOccurrences(of: "**", with: "::DOUBLESTAR::")
            .replacingOccurrences(of: "*", with: "[^/]*")
            .replacingOccurrences(of: "::DOUBLESTAR::", with: ".*")
        let anchored = "^" + regex + "$"
        return path.range(of: anchored, options: .regularExpression) != nil
    }
}

// MARK: - Ask shape

/// Lightweight DTO carrying the fields a policy might match against.
public struct ApprovalAskClassifier: Sendable, Equatable, Hashable {
    public let missionKind: String?
    public let toolName: String?
    public let filePath: String?
    public let runtimeID: String?
    public let targetProject: String?

    public init(
        missionKind: String? = nil,
        toolName: String? = nil,
        filePath: String? = nil,
        runtimeID: String? = nil,
        targetProject: String? = nil
    ) {
        self.missionKind = missionKind
        self.toolName = toolName
        self.filePath = filePath
        self.runtimeID = runtimeID
        self.targetProject = targetProject
    }

    /// Find the first policy in `policies` that matches this ask.
    /// Returns the policy decision or `nil` if no policy applies (the host
    /// must surface the ask to the user manually).
    public func resolve(against policies: [ApprovalPolicy]) -> ApprovalPolicy? {
        policies.first { policy in
            policy.matches(
                missionKind: missionKind,
                toolName: toolName,
                filePath: filePath,
                runtimeID: runtimeID,
                targetProject: targetProject
            )
        }
    }
}
