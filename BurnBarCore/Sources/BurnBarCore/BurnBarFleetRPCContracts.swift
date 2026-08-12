import Foundation

// MARK: - RPC contract

/// Fleet RPC methods. These are colocated with the fleet DTOs (rather than
/// added to `BurnBarRPCMethod`) so the fleet contract layer stays in its own
/// file; the wire strings are the authoritative method names.
///
/// Wire strings (golden): `daemon.fleet.snapshot`,
/// `daemon.fleet.orchestrator.get`, `daemon.fleet.orchestrator.set`,
/// `daemon.fleet.directive.record`.
public enum BurnBarFleetRPCMethod: String, Codable, CaseIterable, Hashable, Sendable {
    case snapshot = "daemon.fleet.snapshot"
    case orchestratorGet = "daemon.fleet.orchestrator.get"
    case orchestratorSet = "daemon.fleet.orchestrator.set"
    case directiveRecord = "daemon.fleet.directive.record"
}

/// Fleet request envelope mirroring `BurnBarRPCRequestEnvelopeWithParams`
/// (`{id, method, params}`) with the fleet method enum.
public struct BurnBarFleetRPCRequestEnvelopeWithParams<Params: Codable & Sendable>: Codable, Sendable {
    public let id: String
    public let method: BurnBarFleetRPCMethod
    public let params: Params

    public init(id: String = UUID().uuidString, method: BurnBarFleetRPCMethod, params: Params) {
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct BurnBarFleetSnapshotRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarFleetSnapshotResponse: Codable, Hashable, Sendable {
    public let snapshot: BurnBarFleetSnapshot

    public init(snapshot: BurnBarFleetSnapshot) {
        self.snapshot = snapshot
    }
}

public struct BurnBarFleetOrchestratorGetRequest: Codable, Hashable, Sendable {
    public init() {}
}

public struct BurnBarFleetOrchestratorGetResponse: Codable, Hashable, Sendable {
    public let state: BurnBarOrchestratorState

    public init(state: BurnBarOrchestratorState) {
        self.state = state
    }
}

public struct BurnBarFleetOrchestratorSetRequest: Codable, Hashable, Sendable {
    public let state: BurnBarOrchestratorState

    public init(state: BurnBarOrchestratorState) {
        self.state = state
    }
}

public struct BurnBarFleetOrchestratorSetResponse: Codable, Hashable, Sendable {
    public let state: BurnBarOrchestratorState

    public init(state: BurnBarOrchestratorState) {
        self.state = state
    }
}

public struct BurnBarFleetDirectiveRecordRequest: Codable, Hashable, Sendable {
    public let directive: BurnBarFleetDirective

    public init(directive: BurnBarFleetDirective) {
        self.directive = directive
    }
}

public struct BurnBarFleetDirectiveRecordResponse: Codable, Hashable, Sendable {
    public let directive: BurnBarFleetDirective

    public init(directive: BurnBarFleetDirective) {
        self.directive = directive
    }
}

// MARK: - Internal helpers

/// ISO-8601 UTC date coding for all fleet date fields. Encoding always emits a
/// `Z`-suffixed timestamp with fractional seconds; decoding accepts both
/// fractional and non-fractional forms.
enum BurnBarFleetDateCoding {
    static func encode(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    static func decode(_ string: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: string) {
            return date
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}

extension KeyedDecodingContainer {
    func decodeFleetDate(forKey key: Key) throws -> Date {
        let raw = try decode(String.self, forKey: key)
        guard let date = BurnBarFleetDateCoding.decode(raw) else {
            throw BurnBarFleetContractError.invalidISODateString(raw)
        }
        return date
    }

    func decodeFleetDateIfPresent(forKey key: Key) throws -> Date? {
        guard contains(key) else { return nil }
        guard let raw = try decodeIfPresent(String.self, forKey: key) else { return nil }
        guard let date = BurnBarFleetDateCoding.decode(raw) else {
            throw BurnBarFleetContractError.invalidISODateString(raw)
        }
        return date
    }
}

extension KeyedEncodingContainer {
    mutating func encodeFleetDate(_ date: Date, forKey key: Key) throws {
        try encode(BurnBarFleetDateCoding.encode(date), forKey: key)
    }

    mutating func encodeFleetDateIfPresent(_ date: Date?, forKey key: Key) throws {
        if let date = date {
            try encode(BurnBarFleetDateCoding.encode(date), forKey: key)
        }
    }
}

extension BurnBarFleetContractError {
    static func validateNonEmptyReason(_ reason: String, field: String) throws {
        guard !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BurnBarFleetContractError.emptyReason(field: field)
        }
    }
}
