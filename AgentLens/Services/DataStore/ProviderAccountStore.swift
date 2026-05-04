import Foundation
import GRDB
import OpenBurnBarCore

/// Local CRUD for provider accounts.
///
/// The table intentionally stores account metadata only. Raw credentials stay in
/// Keychain, daemon credential slots, or server-private secret storage.
public final class ProviderAccountStore: Sendable {
    private let dbQueue: any DatabaseWriter

    public init(dbQueue: any DatabaseWriter) {
        self.dbQueue = dbQueue
    }

    public func upsert(_ account: ProviderAccountDoc) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO provider_accounts (
                    id, providerID, label, identityHint, status, credentialKind,
                    storageScope, redactedLabel, sourceDeviceID, linkedSwitcherProfileID,
                    isDefault, sortKey, lastValidatedAt, lastRefreshAt, lastErrorCode,
                    schemaVersion, createdAt, updatedAt
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                    providerID = excluded.providerID,
                    label = excluded.label,
                    identityHint = excluded.identityHint,
                    status = excluded.status,
                    credentialKind = excluded.credentialKind,
                    storageScope = excluded.storageScope,
                    redactedLabel = excluded.redactedLabel,
                    sourceDeviceID = excluded.sourceDeviceID,
                    linkedSwitcherProfileID = excluded.linkedSwitcherProfileID,
                    isDefault = excluded.isDefault,
                    sortKey = excluded.sortKey,
                    lastValidatedAt = excluded.lastValidatedAt,
                    lastRefreshAt = excluded.lastRefreshAt,
                    lastErrorCode = excluded.lastErrorCode,
                    schemaVersion = excluded.schemaVersion,
                    createdAt = excluded.createdAt,
                    updatedAt = excluded.updatedAt
                """,
                arguments: Self.arguments(for: account)
            )
        }
    }

    public func fetch(id: String) throws -> ProviderAccountDoc? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM provider_accounts WHERE id = ?",
                arguments: [id]
            )
            return row.flatMap(Self.account(from:))
        }
    }

    public func fetchAll(providerID: ProviderID? = nil) throws -> [ProviderAccountDoc] {
        try dbQueue.read { db in
            let rows: [Row]
            if let providerID {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM provider_accounts
                    WHERE providerID = ?
                    ORDER BY sortKey ASC, createdAt ASC, label ASC
                    """,
                    arguments: [providerID.rawValue]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM provider_accounts
                    ORDER BY providerID ASC, sortKey ASC, createdAt ASC, label ASC
                    """
                )
            }
            return rows.compactMap(Self.account(from:))
        }
    }

    public func fetchDefault(providerID: ProviderID) throws -> ProviderAccountDoc? {
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM provider_accounts
                WHERE providerID = ? AND isDefault = 1
                ORDER BY sortKey ASC, createdAt ASC
                LIMIT 1
                """,
                arguments: [providerID.rawValue]
            )
            return row.flatMap(Self.account(from:))
        }
    }

    public func setDefault(accountID: String, providerID: ProviderID) throws {
        try dbQueue.write { db in
            let existingProviderID = try String.fetchOne(
                db,
                sql: "SELECT providerID FROM provider_accounts WHERE id = ?",
                arguments: [accountID]
            )
            guard existingProviderID == providerID.rawValue else {
                throw ProviderAccountStoreError.accountNotFound(accountID)
            }

            let now = Date()
            try db.execute(
                sql: """
                UPDATE provider_accounts
                SET isDefault = 0, updatedAt = ?
                WHERE providerID = ?
                """,
                arguments: [now, providerID.rawValue]
            )
            try db.execute(
                sql: """
                UPDATE provider_accounts
                SET isDefault = 1, updatedAt = ?
                WHERE id = ?
                """,
                arguments: [now, accountID]
            )
        }
    }

    public func delete(id: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM provider_accounts WHERE id = ?",
                arguments: [id]
            )
        }
    }

    private static func arguments(for account: ProviderAccountDoc) -> StatementArguments {
        let values: [(any DatabaseValueConvertible)?] = [
            account.id,
            account.providerID.rawValue,
            account.label,
            account.identityHint,
            account.status.rawValue,
            account.credentialKind.rawValue,
            account.storageScope.rawValue,
            account.redactedLabel,
            account.sourceDeviceID,
            account.linkedSwitcherProfileID,
            account.isDefault,
            account.sortKey,
            account.lastValidatedAt,
            account.lastRefreshAt,
            account.lastErrorCode,
            account.schemaVersion,
            account.createdAt,
            account.updatedAt
        ]
        return StatementArguments(values)
    }

    private static func account(from row: Row) -> ProviderAccountDoc? {
        guard
            let id: String = row["id"],
            let providerIDRaw: String = row["providerID"],
            let label: String = row["label"],
            let statusRaw: String = row["status"],
            let status = ProviderAccountStatus(rawValue: statusRaw),
            let credentialKindRaw: String = row["credentialKind"],
            let credentialKind = CredentialKind(rawValue: credentialKindRaw),
            let storageScopeRaw: String = row["storageScope"],
            let storageScope = ProviderAccountStorageScope(rawValue: storageScopeRaw),
            let redactedLabel: String = row["redactedLabel"]
        else {
            return nil
        }

        return ProviderAccountDoc(
            id: id,
            providerID: ProviderID(rawValue: providerIDRaw),
            label: label,
            identityHint: row["identityHint"],
            status: status,
            credentialKind: credentialKind,
            storageScope: storageScope,
            redactedLabel: redactedLabel,
            sourceDeviceID: row["sourceDeviceID"],
            linkedSwitcherProfileID: row["linkedSwitcherProfileID"],
            isDefault: row["isDefault"] ?? false,
            sortKey: row["sortKey"] ?? 0,
            lastValidatedAt: OpenBurnBarDatabase.parseDateValue(row["lastValidatedAt"]),
            lastRefreshAt: OpenBurnBarDatabase.parseDateValue(row["lastRefreshAt"]),
            lastErrorCode: row["lastErrorCode"],
            schemaVersion: row["schemaVersion"] ?? 1,
            createdAt: OpenBurnBarDatabase.parseDateValue(row["createdAt"]) ?? Date(),
            updatedAt: OpenBurnBarDatabase.parseDateValue(row["updatedAt"]) ?? Date()
        )
    }
}

public enum ProviderAccountStoreError: Error, LocalizedError {
    case accountNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .accountNotFound(let id):
            return "Provider account not found: \(id)"
        }
    }
}
