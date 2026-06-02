import OpenBurnBarCore
import Foundation

enum BurnBarRPCValidationError: Error, LocalizedError {
    case invalidParams(String)

    var errorDescription: String? {
        switch self {
        case .invalidParams(let message):
            return message
        }
    }
}

extension BurnBarDaemonServer {
    private static let maxClientNameBytes = 200
    private static let maxIdentifierBytes = 128
    private static let maxPromptBytes = 48 * 1024
    private static let maxModelIDBytes = 200
    private static let maxNoteBytes = 4_096
    private static let maxToolErrorBytes = 4_096
    private static let maxRunListLimit = 200
    private static let maxRunOffset = 10_000
    private static let maxSupportedProtocolVersions = 16
    private static let maxToolOutputDepth = 16
    private static let maxToolOutputCollectionSize = 200
    private static let maxToolOutputStringBytes = 32 * 1024
    private static let maxTimestampSkew: TimeInterval = 300
    private static let maxTimestampAge: TimeInterval = 7 * 24 * 60 * 60

    func validateClientAttachRequest(_ request: BurnBarClientAttachRequest) throws {
        try validateIdentifier(request.clientID.rawValue, label: "clientID")
        try validateIdentifier(request.sessionID.rawValue, label: "sessionID")
        try validateBoundedString(request.clientName, label: "clientName", maxBytes: Self.maxClientNameBytes, allowEmpty: false)
        guard !request.supportedProtocolVersions.isEmpty,
              request.supportedProtocolVersions.count <= Self.maxSupportedProtocolVersions,
              request.supportedProtocolVersions.allSatisfy({ $0 > 0 }) else {
            throw BurnBarRPCValidationError.invalidParams(
                "supportedProtocolVersions must contain 1...\(Self.maxSupportedProtocolVersions) positive entries."
            )
        }
    }

    func validateClientSessionRequest(clientID: BurnBarClientID, sessionID: BurnBarSessionID) throws {
        try validateIdentifier(clientID.rawValue, label: "clientID")
        try validateIdentifier(sessionID.rawValue, label: "sessionID")
    }

    func validateRunCreateRequest(_ request: BurnBarRunCreateRequest) throws {
        try validateClientSessionRequest(clientID: request.clientID, sessionID: request.sessionID)
        try validateBoundedString(request.prompt, label: "prompt", maxBytes: Self.maxPromptBytes, allowEmpty: false)
        try validateBoundedString(request.modelID, label: "modelID", maxBytes: Self.maxModelIDBytes, allowEmpty: false)
        try validateJSONValue(.object(request.metadata.storage), label: "metadata", maxDepth: 8)
    }

    func validateRunListRequest(_ request: BurnBarRunListRequest) throws {
        try validateIdentifier(request.clientID.rawValue, label: "clientID")
        try validateRange(request.offset, label: "offset", min: 0, max: Self.maxRunOffset)
        try validateRange(request.limit, label: "limit", min: 1, max: Self.maxRunListLimit)
    }

    func validateRunGetRequest(_ request: BurnBarRunGetRequest) throws {
        try validateIdentifier(request.runID.rawValue, label: "runID")
        try validateIdentifier(request.clientID.rawValue, label: "clientID")
    }

    func validateRunPollRequest(_ request: BurnBarRunPollRequest) throws {
        try validateClientSessionRequest(clientID: request.clientID, sessionID: request.sessionID)
        if let runID = request.runID {
            try validateIdentifier(runID.rawValue, label: "runID")
        }
        try validateRange(request.limit, label: "limit", min: 1, max: Self.maxRunListLimit)
    }

    func validateRunCancelRequest(_ request: BurnBarRunCancelRequest) throws {
        try validateIdentifier(request.runID.rawValue, label: "runID")
        try validateIdentifier(request.clientID.rawValue, label: "clientID")
        if let reason = request.reason {
            try validateBoundedString(reason, label: "reason", maxBytes: Self.maxNoteBytes, allowEmpty: true)
        }
    }

    func validateRunRetryRequest(_ request: BurnBarRunRetryRequest) throws {
        try validateIdentifier(request.runID.rawValue, label: "runID")
        try validateIdentifier(request.clientID.rawValue, label: "clientID")
    }

    func validateToolExecutionRequest(_ request: BurnBarToolExecutionRequest) throws {
        try validateClientSessionRequest(clientID: request.clientID, sessionID: request.sessionID)
        if let runID = request.runID {
            try validateIdentifier(runID.rawValue, label: "runID")
        }
    }

    func validateToolResultSubmissionRequest(_ request: BurnBarToolResultSubmissionRequest, now: Date = Date()) throws {
        try validateClientSessionRequest(clientID: request.clientID, sessionID: request.sessionID)
        try validateIdentifier(request.runID.rawValue, label: "runID")
        try validateIdentifier(request.callID, label: "callID")
        try validateTimestamp(request.completedAt, label: "completedAt", now: now)
        try validateJSONValue(request.output, label: "output", maxDepth: Self.maxToolOutputDepth)
        if let error = request.error {
            try validateBoundedString(
                error.message,
                label: "error.message",
                maxBytes: Self.maxToolErrorBytes,
                allowEmpty: false
            )
        }
    }

    func validateApprovalRespondRequest(_ request: BurnBarApprovalRespondRequest, now: Date = Date()) throws {
        try validateIdentifier(request.response.approvalID.rawValue, label: "approvalID")
        try validateIdentifier(request.response.clientID.rawValue, label: "clientID")
        try validateTimestamp(request.response.respondedAt, label: "respondedAt", now: now)
        if let note = request.response.note {
            try validateBoundedString(note, label: "note", maxBytes: Self.maxNoteBytes, allowEmpty: true)
        }
    }

    private func validateIdentifier(_ value: String, label: String) throws {
        try validateBoundedString(value, label: label, maxBytes: Self.maxIdentifierBytes, allowEmpty: false)
    }

    private func validateBoundedString(_ value: String, label: String, maxBytes: Int, allowEmpty: Bool) throws {
        if !allowEmpty && value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw BurnBarRPCValidationError.invalidParams("\(label) must not be empty.")
        }
        guard value.utf8.count <= maxBytes else {
            throw BurnBarRPCValidationError.invalidParams("\(label) is limited to \(maxBytes) UTF-8 bytes.")
        }
    }

    private func validateRange(_ value: Int, label: String, min: Int, max: Int) throws {
        guard value >= min && value <= max else {
            throw BurnBarRPCValidationError.invalidParams("\(label) must be between \(min) and \(max).")
        }
    }

    private func validateTimestamp(_ value: Date, label: String, now: Date) throws {
        guard value.timeIntervalSince(now) <= Self.maxTimestampSkew else {
            throw BurnBarRPCValidationError.invalidParams("\(label) is too far in the future.")
        }
        guard now.timeIntervalSince(value) <= Self.maxTimestampAge else {
            throw BurnBarRPCValidationError.invalidParams("\(label) is too old.")
        }
    }

    private func validateJSONValue(_ value: BurnBarJSONValue?, label: String, maxDepth: Int) throws {
        guard let value else { return }
        try validateJSONValue(value, label: label, depth: 0, maxDepth: maxDepth)
    }

    private func validateJSONValue(_ value: BurnBarJSONValue, label: String, depth: Int, maxDepth: Int) throws {
        guard depth <= maxDepth else {
            throw BurnBarRPCValidationError.invalidParams("\(label) exceeds maximum JSON depth \(maxDepth).")
        }

        switch value {
        case .string(let string):
            try validateBoundedString(
                string,
                label: label,
                maxBytes: Self.maxToolOutputStringBytes,
                allowEmpty: true
            )
        case .array(let values):
            guard values.count <= Self.maxToolOutputCollectionSize else {
                throw BurnBarRPCValidationError.invalidParams("\(label) array exceeds \(Self.maxToolOutputCollectionSize) entries.")
            }
            for (index, child) in values.enumerated() {
                try validateJSONValue(child, label: "\(label)[\(index)]", depth: depth + 1, maxDepth: maxDepth)
            }
        case .object(let object):
            guard object.count <= Self.maxToolOutputCollectionSize else {
                throw BurnBarRPCValidationError.invalidParams("\(label) object exceeds \(Self.maxToolOutputCollectionSize) keys.")
            }
            for (key, child) in object {
                try validateBoundedString(
                    key,
                    label: "\(label) key",
                    maxBytes: Self.maxIdentifierBytes,
                    allowEmpty: false
                )
                try validateJSONValue(child, label: "\(label).\(key)", depth: depth + 1, maxDepth: maxDepth)
            }
        case .number, .bool, .null:
            break
        }
    }
}
