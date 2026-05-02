import Foundation

// MARK: - Run create metadata (typed keys, wire-compatible JSON object)

/// Keys for `BurnBarRunCreateRequest.metadata` used by the daemon planner and
/// run-execution path. Use these instead of ad hoc string constants so renames
/// and typos surface at compile time.
public enum BurnBarRunCreateMetadataKey: String, Sendable, CaseIterable, Hashable {
    case requiresApproval
    case failUntilAttempt
    case inputTokens
    case outputTokens
    case cacheCreationTokens
    case cacheReadTokens
    case approvalTitle
    case approvalMessage
    case controllerReview
    case missionExecution
    case autoTakeover
    /// Inline `BurnBarAgentIntent` JSON when the client sends a pre-baked intent.
    case agentIntent
    case workspaceWorkflow
    case workflow
    case toolKind
    case toolArguments
    case filePath
    case path
    case activeFilePath
    case activeSelectionText
}

/// JSON object carried on `BurnBarRunCreateRequest` (same on-wire shape as
/// before: a single JSON object of string keys to `BurnBarJSONValue`).
public struct BurnBarRunCreateMetadata: Hashable, Sendable {
    public var storage: [String: BurnBarJSONValue]

    public init(_ storage: [String: BurnBarJSONValue] = [:]) {
        self.storage = storage
    }

    public subscript(_ key: BurnBarRunCreateMetadataKey) -> BurnBarJSONValue? {
        get { storage[key.rawValue] }
        set {
            if let newValue {
                storage[key.rawValue] = newValue
            } else {
                storage.removeValue(forKey: key.rawValue)
            }
        }
    }

    public subscript(_ key: String) -> BurnBarJSONValue? {
        get { storage[key] }
        set {
            if let newValue {
                storage[key] = newValue
            } else {
                storage.removeValue(forKey: key)
            }
        }
    }
}

// MARK: - Codable (single JSON object)

extension BurnBarRunCreateMetadata: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        self.storage = try c.decode([String: BurnBarJSONValue].self)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(storage)
    }
}

// MARK: - Dictionary literal (ergonomics in tests and call sites)

extension BurnBarRunCreateMetadata: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, BurnBarJSONValue)...) {
        self.storage = Dictionary(uniqueKeysWithValues: elements)
    }
}

// MARK: - Value extraction (replaces string-keyed dictionary-only helpers for runs)

extension BurnBarRunCreateMetadata {
    public func boolValue(forKey key: String) -> Bool? {
        guard case .bool(let value)? = storage[key] else { return nil }
        return value
    }

    public func stringValue(forKey key: String) -> String? {
        guard case .string(let value)? = storage[key] else { return nil }
        return value
    }

    public func intValue(forKey key: String) -> Int? {
        guard case .number(let value)? = storage[key] else { return nil }
        return Int(value)
    }

    public func boolValue(forKey key: BurnBarRunCreateMetadataKey) -> Bool? {
        boolValue(forKey: key.rawValue)
    }

    public func stringValue(forKey key: BurnBarRunCreateMetadataKey) -> String? {
        stringValue(forKey: key.rawValue)
    }

    public func intValue(forKey key: BurnBarRunCreateMetadataKey) -> Int? {
        intValue(forKey: key.rawValue)
    }

    public func toolKindValue(forKey key: String) -> BurnBarToolKind? {
        guard let rawValue = stringValue(forKey: key) else { return nil }
        return BurnBarToolKind(rawValue: rawValue)
    }

    public func toolKindValue(forKey key: BurnBarRunCreateMetadataKey) -> BurnBarToolKind? {
        toolKindValue(forKey: key.rawValue)
    }
}
