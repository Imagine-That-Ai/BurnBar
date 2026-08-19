import Foundation
@preconcurrency import FirebaseAppCheck
@preconcurrency import FirebaseAuth
import FirebaseCore
@preconcurrency import FirebaseFirestore
@preconcurrency import FirebaseFunctions
import OpenBurnBarCore

// MARK: - Hermes Gateway approval records
//
// Split out of `HermesGatewayAPI.swift` (audit wave 4, item 14 structural
// decomposition). Pure move — no behavior change.

/// Owner-read view of a server-armed oversight gate at
/// `users/{uid}/hermes_gateway_approvals/{approvalId}`. The agent blocks on this
/// gate until a trusted native device approves or rejects via
/// `respondHermesGatewayApproval`.
struct HermesGatewayApprovalRecord: Decodable, Identifiable, Hashable, Sendable {
    let id: String
    let clientId: String
    let destinationId: String
    let actionId: String
    let toolName: String?
    let summary: String
    let status: String
    let requestedAt: String
    let expiresAt: String
    let respondedAt: String?
    let approvedByDeviceId: String?
    let schemaVersion: Int

    var isWaiting: Bool { status == "waiting_for_approval" }

    private enum CodingKeys: String, CodingKey {
        case id
        case clientId
        case destinationId
        case actionId
        case toolName
        case summary
        case status
        case requestedAt
        case expiresAt
        case respondedAt
        case approvedByDeviceId
        case schemaVersion
    }

    init(
        id: String,
        clientId: String,
        destinationId: String,
        actionId: String,
        toolName: String?,
        summary: String,
        status: String,
        requestedAt: String,
        expiresAt: String,
        respondedAt: String? = nil,
        approvedByDeviceId: String? = nil,
        schemaVersion: Int
    ) {
        self.id = id
        self.clientId = clientId
        self.destinationId = destinationId
        self.actionId = actionId
        self.toolName = toolName
        self.summary = summary
        self.status = status
        self.requestedAt = requestedAt
        self.expiresAt = expiresAt
        self.respondedAt = respondedAt
        self.approvedByDeviceId = approvedByDeviceId
        self.schemaVersion = schemaVersion
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decode(String.self, forKey: .id),
            clientId: try container.decode(String.self, forKey: .clientId),
            destinationId: try container.decode(String.self, forKey: .destinationId),
            actionId: try container.decode(String.self, forKey: .actionId),
            toolName: try container.decodeIfPresent(String.self, forKey: .toolName),
            summary: try container.decodeIfPresent(String.self, forKey: .summary) ?? "",
            status: try container.decode(String.self, forKey: .status),
            requestedAt: try container.decode(String.self, forKey: .requestedAt),
            expiresAt: try container.decode(String.self, forKey: .expiresAt),
            respondedAt: try container.decodeIfPresent(String.self, forKey: .respondedAt),
            approvedByDeviceId: try container.decodeIfPresent(String.self, forKey: .approvedByDeviceId),
            schemaVersion: try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        )
    }
}

extension HermesGatewayApprovalRecord {
    init?(documentID: String, data: [String: Any]) {
        guard
            let id = Self.string(data["id"]) ?? documentID.nilIfEmpty,
            let clientId = Self.string(data["clientId"]),
            let destinationId = Self.string(data["destinationId"]),
            let actionId = Self.string(data["actionId"]),
            let status = Self.string(data["status"]),
            let requestedAt = Self.string(data["requestedAt"]),
            let expiresAt = Self.string(data["expiresAt"])
        else { return nil }
        self.init(
            id: id,
            clientId: clientId,
            destinationId: destinationId,
            actionId: actionId,
            toolName: Self.string(data["toolName"]),
            summary: Self.string(data["summary"]) ?? "",
            status: status,
            requestedAt: requestedAt,
            expiresAt: expiresAt,
            respondedAt: Self.string(data["respondedAt"]),
            approvedByDeviceId: Self.string(data["approvedByDeviceId"]),
            schemaVersion: (data["schemaVersion"] as? NSNumber)?.intValue ?? (data["schemaVersion"] as? Int) ?? 1
        )
    }

    var expiresAtDate: Date? { Self.gatewayDate(from: expiresAt) }

    /// A gate is actionable only while it is still waiting and has not passed its
    /// server-stamped expiry.
    func isActionable(relativeTo now: Date = Date()) -> Bool {
        guard isWaiting else { return false }
        guard let expiresAtDate else { return true }
        return now < expiresAtDate
    }

    private static func gatewayDate(from raw: String) -> Date? {
        ParsePrimitives.gatewayDate(from: raw)
    }

    private static func string(_ raw: Any?) -> String? {
        ParsePrimitives.string(raw)
    }
}
