import Foundation
import GRDB
import OpenBurnBarEngine

/// Daemon-owned Linux cloud replication. The renderer supplies neither vault
/// keys nor cloud credentials; it can only select consent policy and ask the
/// daemon to run a cycle through an authenticated gateway.
public actor LinuxCloudReplicaEngine {
    private static let maximumPlaintextBytes = 512 * 1_024
    private static let maximumSealedEnvelopeBytes = 768 * 1_024
    private static let maximumPullPageCount = 500

    public struct Domain: RawRepresentable, Codable, Hashable, Sendable {
        public let rawValue: String

        private init(uncheckedRawValue: String) {
            self.rawValue = uncheckedRawValue
        }

        public init?(rawValue: String) {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty,
                  value.count <= 64,
                  value.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "-" }) else {
                return nil
            }
            self.rawValue = value
        }

        public static let usage = Domain(uncheckedRawValue: "usage")
        public static let conversations = Domain(uncheckedRawValue: "conversations")
        public static let sessionLogs = Domain(uncheckedRawValue: "session_logs")
        public static let textExpansion = Domain(uncheckedRawValue: "text_expansion")
        public static let roamingProfile = Domain(uncheckedRawValue: "roaming_profile")
        public static let supported: Set<Domain> = [
            .usage, .conversations, .sessionLogs, .textExpansion, .roamingProfile
        ]
    }

    public struct ConsentPolicy: Codable, Equatable, Sendable {
        public var enabledDomains: Set<Domain>
        public var remoteAccessEnabled: Bool

        public init(enabledDomains: Set<Domain> = [], remoteAccessEnabled: Bool = false) {
            self.enabledDomains = enabledDomains
            self.remoteAccessEnabled = remoteAccessEnabled
        }
    }

    public struct RemoteReplica: Codable, Equatable, Sendable {
        public let domain: Domain
        public let recordID: String
        public let revision: Int64
        public let modifiedAtMillis: Int64
        public let sourceDeviceID: String
        public let tombstone: Bool
        public let sealedPayload: CloudVaultSealedText?

        public init(
            domain: Domain,
            recordID: String,
            revision: Int64,
            modifiedAtMillis: Int64,
            sourceDeviceID: String,
            tombstone: Bool,
            sealedPayload: CloudVaultSealedText?
        ) {
            self.domain = domain
            self.recordID = recordID
            self.revision = revision
            self.modifiedAtMillis = modifiedAtMillis
            self.sourceDeviceID = sourceDeviceID
            self.tombstone = tombstone
            self.sealedPayload = sealedPayload
        }
    }

    public struct OutboundMutation: Codable, Equatable, Sendable {
        public let sequence: Int64
        /// Stable across retries and daemon restarts. Gateways must use this as
        /// their create/write idempotency key before acknowledging the batch.
        public let mutationID: String
        public let replica: RemoteReplica

        public init(sequence: Int64, mutationID: String, replica: RemoteReplica) {
            self.sequence = sequence
            self.mutationID = mutationID
            self.replica = replica
        }
    }

    public struct PullPage: Codable, Equatable, Sendable {
        public let replicas: [RemoteReplica]
        public let nextCursor: String?

        public init(replicas: [RemoteReplica], nextCursor: String?) {
            self.replicas = replicas
            self.nextCursor = nextCursor
        }
    }

    /// Result of an atomic compare-and-merge push. The gateway must process
    /// every mutation idempotently, choose the authoritative winner using the
    /// replica total order, and return the final winner for every record key in
    /// the batch. This prevents a stale client from treating a blind overwrite
    /// as a successful sync.
    public struct PushResult: Codable, Equatable, Sendable {
        public let acknowledgedMutationIDs: [String]
        public let authoritativeReplicas: [RemoteReplica]

        public init(
            acknowledgedMutationIDs: [String],
            authoritativeReplicas: [RemoteReplica]
        ) {
            self.acknowledgedMutationIDs = acknowledgedMutationIDs
            self.authoritativeReplicas = authoritativeReplicas
        }
    }

    public protocol Gateway: Sendable {
        /// Must atomically compare-and-merge the full ordered batch or throw.
        /// A conforming gateway never blindly overwrites a newer replica and
        /// returns the final authoritative winner for every record in the
        /// batch. The engine validates the complete result before removing any
        /// durable outbox rows.
        func push(uid: String, mutations: [OutboundMutation]) async throws -> PushResult
        func pull(uid: String, domains: Set<Domain>, after cursor: String?) async throws -> PullPage
    }

    public enum Phase: String, Codable, Sendable {
        case disabled
        case ready
        case syncing
        case backoff
    }

    public struct Status: Codable, Equatable, Sendable {
        public let phase: Phase
        public let pendingMutationCount: Int
        public let consecutiveFailures: Int
        public let retryAtMillis: Int64?
        public let lastSuccessfulSyncAtMillis: Int64?
        public let pullCursor: String?
        public let enabledDomains: Set<Domain>
        public let remoteAccessEnabled: Bool
    }

    public struct CycleResult: Equatable, Sendable {
        public let pushedCount: Int
        public let appliedRemoteCount: Int
        public let retainedLocalConflictCount: Int
        public let cursor: String?
    }

    public enum EngineError: LocalizedError, Equatable, Sendable {
        case invalidIdentifier
        case backupDisabled(Domain)
        case remoteAccessDisabled
        case invalidVaultKey
        case invalidRemoteEnvelope
        case retryNotDue(Int64)

        public var errorDescription: String? {
            switch self {
            case .invalidIdentifier: return "The cloud replica identifier is invalid."
            case .backupDisabled(let domain): return "Cloud backup is disabled for \(domain.rawValue)."
            case .remoteAccessDisabled: return "Remote access is disabled."
            case .invalidVaultKey: return "The cloud vault key is unavailable or invalid."
            case .invalidRemoteEnvelope: return "A remote replica failed encrypted-envelope validation."
            case .retryNotDue(let retryAt): return "Cloud sync is backing off until \(retryAt)."
            }
        }
    }

    public struct BackoffPolicy: Equatable, Sendable {
        public let baseDelayMillis: Int64
        public let maximumDelayMillis: Int64

        public init(baseDelayMillis: Int64 = 2_000, maximumDelayMillis: Int64 = 300_000) {
            precondition(baseDelayMillis > 0 && maximumDelayMillis >= baseDelayMillis)
            self.baseDelayMillis = baseDelayMillis
            self.maximumDelayMillis = maximumDelayMillis
        }

        public func delayMillis(after failures: Int) -> Int64 {
            guard failures > 1 else { return baseDelayMillis }
            var delay = baseDelayMillis
            for _ in 1..<failures {
                if delay >= maximumDelayMillis / 2 { return maximumDelayMillis }
                delay *= 2
            }
            return min(delay, maximumDelayMillis)
        }
    }

    private struct StoredReplica {
        let revision: Int64
        let modifiedAtMillis: Int64
        let sourceDeviceID: String
        let tombstone: Bool
        let sealedPayloadData: Data?
        let pending: Bool
    }

    private let database: any DatabaseWriter
    private let gateway: any Gateway
    private let deviceID: String
    private let nowMillis: @Sendable () -> Int64
    private let backoff: BackoffPolicy
    private let batchLimit: Int
    private let encoder: JSONEncoder
    private let decoder = JSONDecoder()

    public init(
        database: any DatabaseWriter,
        gateway: any Gateway,
        deviceID: String,
        backoff: BackoffPolicy = BackoffPolicy(),
        batchLimit: Int = 200,
        nowMillis: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1_000) }
    ) throws {
        guard Self.validIdentifier(deviceID), batchLimit > 0 && batchLimit <= 500 else {
            throw EngineError.invalidIdentifier
        }
        self.database = database
        self.gateway = gateway
        self.deviceID = deviceID
        self.backoff = backoff
        self.batchLimit = batchLimit
        self.nowMillis = nowMillis
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        try Self.migrate(database)
    }

    public func setConsentPolicy(_ policy: ConsentPolicy, uid: String) throws {
        try Self.validate(uid: uid)
        guard policy.enabledDomains.isSubset(of: Domain.supported) else {
            throw EngineError.invalidIdentifier
        }
        let domains = try encoder.encode(policy.enabledDomains.sorted { $0.rawValue < $1.rawValue })
        try database.write { db in
            let previousDomains = try Data.fetchOne(
                db,
                sql: "SELECT enabled_domains FROM linux_cloud_sync_policy WHERE uid = ?",
                arguments: [uid]
            )
            try db.execute(
                sql: """
                    INSERT INTO linux_cloud_sync_policy (uid, enabled_domains, remote_access_enabled)
                    VALUES (?, ?, ?)
                    ON CONFLICT(uid) DO UPDATE SET
                        enabled_domains = excluded.enabled_domains,
                        remote_access_enabled = excluded.remote_access_enabled
                    """,
                arguments: [uid, domains, policy.remoteAccessEnabled]
            )
            // A cursor describes the exact domain set used to obtain it. When
            // backup consent adds or removes a domain, restart the pull from a
            // full snapshot so newly enabled records cannot be skipped.
            if let previousDomains, previousDomains != domains {
                try db.execute(
                    sql: """
                        UPDATE linux_cloud_sync_state
                        SET cursor = NULL, failures = 0, retry_at = NULL
                        WHERE uid = ?
                        """,
                    arguments: [uid]
                )
            }
        }
    }

    public func consentPolicy(uid: String) throws -> ConsentPolicy {
        try Self.validate(uid: uid)
        return try database.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT enabled_domains, remote_access_enabled FROM linux_cloud_sync_policy WHERE uid = ?",
                arguments: [uid]
            ) else { return ConsentPolicy() }
            let data: Data = row["enabled_domains"]
            let domains = Set(try decoder.decode([Domain].self, from: data))
            guard domains.isSubset(of: Domain.supported) else {
                throw EngineError.invalidIdentifier
            }
            return ConsentPolicy(enabledDomains: domains, remoteAccessEnabled: row["remote_access_enabled"])
        }
    }

    /// Encrypt and durably queue a local update in one transaction. No plaintext
    /// payload is written to SQLite or passed to the gateway.
    public func stageUpdate(
        uid: String,
        domain: Domain,
        recordID: String,
        plaintext: Data,
        vaultKey: Data
    ) throws -> RemoteReplica {
        try validateWrite(uid: uid, domain: domain, recordID: recordID, vaultKey: vaultKey)
        guard plaintext.count <= Self.maximumPlaintextBytes else {
            throw EngineError.invalidRemoteEnvelope
        }
        let current = try storedReplica(uid: uid, domain: domain, recordID: recordID)
        let revision = max(current?.revision ?? 0, 0) + 1
        let aad = try Self.aad(uid: uid, domain: domain, recordID: recordID)
        guard let text = String(data: plaintext, encoding: .utf8) else {
            throw EngineError.invalidRemoteEnvelope
        }
        let sealed = try CloudVaultCrypto.sealText(text, keyData: vaultKey, aadContext: aad)
        let replica = RemoteReplica(
            domain: domain,
            recordID: recordID,
            revision: revision,
            modifiedAtMillis: nowMillis(),
            sourceDeviceID: deviceID,
            tombstone: false,
            sealedPayload: sealed
        )
        try persistLocal(replica, uid: uid)
        return replica
    }

    public func stageDeletion(uid: String, domain: Domain, recordID: String, vaultKey: Data) throws -> RemoteReplica {
        try validateWrite(uid: uid, domain: domain, recordID: recordID, vaultKey: vaultKey)
        let current = try storedReplica(uid: uid, domain: domain, recordID: recordID)
        let replica = RemoteReplica(
            domain: domain,
            recordID: recordID,
            revision: max(current?.revision ?? 0, 0) + 1,
            modifiedAtMillis: nowMillis(),
            sourceDeviceID: deviceID,
            tombstone: true,
            sealedPayload: nil
        )
        try persistLocal(replica, uid: uid)
        return replica
    }

    /// Remote reads are a separate, off-by-default consent surface. AAD binding
    /// makes ciphertext substitution across users, domains, or records fail.
    public func readForRemoteAccess(uid: String, domain: Domain, recordID: String, vaultKey: Data) throws -> Data? {
        let policy = try consentPolicy(uid: uid)
        guard policy.remoteAccessEnabled, policy.enabledDomains.contains(domain) else {
            throw EngineError.remoteAccessDisabled
        }
        try Self.validateKey(vaultKey)
        guard let stored = try storedReplica(uid: uid, domain: domain, recordID: recordID), !stored.tombstone else {
            return nil
        }
        guard let sealedData = stored.sealedPayloadData,
              let sealed = try? decoder.decode(CloudVaultSealedText.self, from: sealedData) else {
            throw EngineError.invalidRemoteEnvelope
        }
        let plaintext = try CloudVaultCrypto.openText(
            sealed,
            keyData: vaultKey,
            aadContext: Self.aad(uid: uid, domain: domain, recordID: recordID)
        )
        return Data(plaintext.utf8)
    }

    public func status(uid: String) throws -> Status {
        let policy = try consentPolicy(uid: uid)
        return try database.read { db in
            let pending = try Self.pendingMutationCount(
                uid: uid,
                enabledDomains: policy.enabledDomains,
                db: db
            )
            let row = try Row.fetchOne(
                db,
                sql: "SELECT cursor, failures, retry_at, last_success_at FROM linux_cloud_sync_state WHERE uid = ?",
                arguments: [uid]
            )
            let failures: Int = row?["failures"] ?? 0
            let retryAt: Int64? = row?["retry_at"]
            let phase: Phase
            if policy.enabledDomains.isEmpty { phase = .disabled } else if let retryAt, failures > 0, retryAt > nowMillis() {
                phase = .backoff
            } else {
                phase = .ready
            }
            return Status(
                phase: phase,
                pendingMutationCount: pending,
                consecutiveFailures: failures,
                retryAtMillis: retryAt,
                lastSuccessfulSyncAtMillis: row?["last_success_at"],
                pullCursor: row?["cursor"],
                enabledDomains: policy.enabledDomains,
                remoteAccessEnabled: policy.remoteAccessEnabled
            )
        }
    }

    /// One deterministic push-then-pull cycle. A failed push retains every
    /// mutation. A failed pull leaves the prior cursor and local snapshot intact.
    @discardableResult
    public func syncOnce(uid: String, vaultKey: Data, force: Bool = false) async throws -> CycleResult {
        try Self.validate(uid: uid)
        try Self.validateKey(vaultKey)
        let policy = try consentPolicy(uid: uid)
        guard !policy.enabledDomains.isEmpty else {
            return CycleResult(pushedCount: 0, appliedRemoteCount: 0, retainedLocalConflictCount: 0, cursor: nil)
        }
        let initialStatus = try status(uid: uid)
        if !force, let retryAt = initialStatus.retryAtMillis, retryAt > nowMillis() {
            throw EngineError.retryNotDue(retryAt)
        }

        do {
            let mutations = try pendingMutations(uid: uid, domains: policy.enabledDomains)
            if !mutations.isEmpty {
                let pushResult = try await gateway.push(uid: uid, mutations: mutations)
                try reconcilePush(
                    pushResult,
                    mutations: mutations,
                    uid: uid,
                    enabledDomains: policy.enabledDomains,
                    vaultKey: vaultKey
                )
            }

            let cursor = try currentCursor(uid: uid)
            let page = try await gateway.pull(uid: uid, domains: policy.enabledDomains, after: cursor)
            let outcome = try apply(page: page, uid: uid, enabledDomains: policy.enabledDomains, vaultKey: vaultKey)
            let completedAt = nowMillis()
            try await database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO linux_cloud_sync_state (uid, cursor, failures, retry_at, last_success_at)
                        VALUES (?, ?, 0, NULL, ?)
                        ON CONFLICT(uid) DO UPDATE SET
                            cursor = excluded.cursor,
                            failures = 0,
                            retry_at = NULL,
                            last_success_at = excluded.last_success_at
                        """,
                    arguments: [uid, page.nextCursor ?? cursor, completedAt]
                )
            }
            return CycleResult(
                pushedCount: mutations.count,
                appliedRemoteCount: outcome.applied,
                retainedLocalConflictCount: outcome.conflicts,
                cursor: page.nextCursor ?? cursor
            )
        } catch {
            if error is EngineError { throw error }
            try recordFailure(uid: uid)
            throw error
        }
    }

    private func validateWrite(uid: String, domain: Domain, recordID: String, vaultKey: Data) throws {
        try Self.validate(uid: uid)
        try Self.validate(recordID: recordID)
        try Self.validateKey(vaultKey)
        guard try consentPolicy(uid: uid).enabledDomains.contains(domain) else {
            throw EngineError.backupDisabled(domain)
        }
    }

    private func persistLocal(_ replica: RemoteReplica, uid: String) throws {
        let sealedData = try replica.sealedPayload.map { try encoder.encode($0) }
        let replicaData = try encoder.encode(replica)
        try database.write { db in
            try upsert(replica, sealedData: sealedData, pending: true, uid: uid, db: db)
            try db.execute(
                sql: "INSERT INTO linux_cloud_outbox (uid, domain, record_id, replica) VALUES (?, ?, ?, ?)",
                arguments: [uid, replica.domain.rawValue, replica.recordID, replicaData]
            )
        }
    }

    private func pendingMutations(uid: String, domains: Set<Domain>) throws -> [OutboundMutation] {
        guard !domains.isEmpty else { return [] }
        let orderedDomains = domains.map(\.rawValue).sorted()
        let placeholders = Array(repeating: "?", count: orderedDomains.count).joined(separator: ", ")
        var arguments = StatementArguments()
        arguments += [uid]
        for domain in orderedDomains { arguments += [domain] }
        arguments += [batchLimit]
        return try database.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT sequence, replica FROM linux_cloud_outbox
                    WHERE uid = ? AND domain IN (\(placeholders))
                    ORDER BY sequence LIMIT ?
                    """,
                arguments: arguments
            )
            return try rows.compactMap { row in
                let replicaData: Data = row["replica"]
                guard replicaData.count <= Self.maximumSealedEnvelopeBytes,
                      let replica = try? decoder.decode(RemoteReplica.self, from: replicaData) else {
                    throw EngineError.invalidRemoteEnvelope
                }
                let sequence: Int64 = row["sequence"]
                return OutboundMutation(
                    sequence: sequence,
                    mutationID: "\(replica.sourceDeviceID):\(sequence)",
                    replica: replica
                )
            }
        }
    }

    private func reconcilePush(
        _ result: PushResult,
        mutations: [OutboundMutation],
        uid: String,
        enabledDomains: Set<Domain>,
        vaultKey: Data
    ) throws {
        let expectedMutationIDs = Set(mutations.map(\.mutationID))
        guard result.acknowledgedMutationIDs.count == expectedMutationIDs.count,
              Set(result.acknowledgedMutationIDs) == expectedMutationIDs else {
            throw EngineError.invalidRemoteEnvelope
        }

        let mutationsByKey = Dictionary(grouping: mutations) {
            Self.replicaKey(domain: $0.replica.domain, recordID: $0.replica.recordID)
        }
        var authoritativeByKey: [String: (RemoteReplica, Data?)] = [:]
        for authoritative in result.authoritativeReplicas {
            let key = Self.replicaKey(domain: authoritative.domain, recordID: authoritative.recordID)
            guard authoritativeByKey[key] == nil,
                  let localMutations = mutationsByKey[key],
                  enabledDomains.contains(authoritative.domain),
                  Self.validIdentifier(authoritative.recordID),
                  Self.validIdentifier(authoritative.sourceDeviceID),
                  authoritative.revision > 0,
                  authoritative.modifiedAtMillis >= 0,
                  authoritative.tombstone == (authoritative.sealedPayload == nil) else {
                throw EngineError.invalidRemoteEnvelope
            }

            guard let newestLocal = localMutations.map(\.replica).max(by: { lhs, rhs in
                Self.precedes(Self.order(of: lhs), Self.order(of: rhs))
            }) else {
                throw EngineError.invalidRemoteEnvelope
            }
            let authoritativeOrder = Self.order(of: authoritative)
            let newestLocalOrder = Self.order(of: newestLocal)
            guard !Self.precedes(authoritativeOrder, newestLocalOrder),
                  authoritativeOrder != newestLocalOrder || authoritative == newestLocal else {
                throw EngineError.invalidRemoteEnvelope
            }

            let sealedData: Data?
            if let sealed = authoritative.sealedPayload {
                let aad = try Self.aad(uid: uid, domain: authoritative.domain, recordID: authoritative.recordID)
                guard (try? CloudVaultCrypto.openText(sealed, keyData: vaultKey, aadContext: aad)) != nil else {
                    throw EngineError.invalidRemoteEnvelope
                }
                let encoded = try encoder.encode(sealed)
                guard encoded.count <= Self.maximumSealedEnvelopeBytes else {
                    throw EngineError.invalidRemoteEnvelope
                }
                sealedData = encoded
            } else {
                sealedData = nil
            }
            authoritativeByKey[key] = (authoritative, sealedData)
        }
        guard authoritativeByKey.count == mutationsByKey.count else {
            throw EngineError.invalidRemoteEnvelope
        }

        try database.write { db in
            for mutation in mutations {
                try db.execute(
                    sql: "DELETE FROM linux_cloud_outbox WHERE uid = ? AND sequence = ?",
                    arguments: [uid, mutation.sequence]
                )
            }
            for (key, (authoritative, sealedData)) in authoritativeByKey {
                guard mutationsByKey[key] != nil else { throw EngineError.invalidRemoteEnvelope }
                let stillPending = try Bool.fetchOne(
                    db,
                    sql: """
                        SELECT EXISTS (
                            SELECT 1 FROM linux_cloud_outbox
                            WHERE uid = ? AND domain = ? AND record_id = ?
                        )
                        """,
                    arguments: [uid, authoritative.domain.rawValue, authoritative.recordID]
                ) ?? false
                if !stillPending {
                    try upsert(authoritative, sealedData: sealedData, pending: false, uid: uid, db: db)
                }
            }
            for mutation in mutations {
                try db.execute(
                    sql: """
                        UPDATE linux_cloud_replica SET pending =
                            CASE WHEN EXISTS (
                                SELECT 1 FROM linux_cloud_outbox
                                WHERE uid = ? AND domain = ? AND record_id = ?
                            ) THEN 1 ELSE 0 END
                        WHERE uid = ? AND domain = ? AND record_id = ?
                        """,
                    arguments: [
                        uid, mutation.replica.domain.rawValue, mutation.replica.recordID,
                        uid, mutation.replica.domain.rawValue, mutation.replica.recordID
                    ]
                )
            }
        }
    }

    private static func pendingMutationCount(
        uid: String,
        enabledDomains: Set<Domain>,
        db: Database
    ) throws -> Int {
        guard !enabledDomains.isEmpty else { return 0 }
        let domains = enabledDomains.map(\.rawValue).sorted()
        let placeholders = Array(repeating: "?", count: domains.count).joined(separator: ", ")
        var arguments = StatementArguments()
        arguments += [uid]
        for domain in domains { arguments += [domain] }
        return try Int.fetchOne(
            db,
            sql: "SELECT COUNT(*) FROM linux_cloud_outbox WHERE uid = ? AND domain IN (\(placeholders))",
            arguments: arguments
        ) ?? 0
    }

    private static func replicaKey(domain: Domain, recordID: String) -> String {
        "\(domain.rawValue)\u{0}\(recordID)"
    }

    private static func order(of replica: RemoteReplica) -> (Int64, Int64, String) {
        (replica.revision, replica.modifiedAtMillis, replica.sourceDeviceID)
    }

    private func apply(
        page: PullPage,
        uid: String,
        enabledDomains: Set<Domain>,
        vaultKey: Data
    ) throws -> (applied: Int, conflicts: Int) {
        guard page.replicas.count <= Self.maximumPullPageCount else {
            throw EngineError.invalidRemoteEnvelope
        }
        var prepared: [(RemoteReplica, Data?)] = []
        var pageKeys = Set<String>()
        for replica in page.replicas {
            let pageKey = "\(replica.domain.rawValue)\u{0}\(replica.recordID)"
            guard enabledDomains.contains(replica.domain),
                  pageKeys.insert(pageKey).inserted,
                  Self.validIdentifier(replica.recordID),
                  Self.validIdentifier(replica.sourceDeviceID),
                  replica.revision > 0,
                  replica.modifiedAtMillis >= 0,
                  replica.tombstone == (replica.sealedPayload == nil) else {
                throw EngineError.invalidRemoteEnvelope
            }
            let sealedData: Data?
            if let sealed = replica.sealedPayload {
                let aad = try Self.aad(uid: uid, domain: replica.domain, recordID: replica.recordID)
                guard (try? CloudVaultCrypto.openText(sealed, keyData: vaultKey, aadContext: aad)) != nil else {
                    throw EngineError.invalidRemoteEnvelope
                }
                let encoded = try encoder.encode(sealed)
                guard encoded.count <= Self.maximumSealedEnvelopeBytes else {
                    throw EngineError.invalidRemoteEnvelope
                }
                sealedData = encoded
            } else {
                sealedData = nil
            }
            prepared.append((replica, sealedData))
        }

        return try database.write { db in
            var applied = 0
            var conflicts = 0
            for (remote, sealedData) in prepared {
                let local = try Self.storedReplica(
                    uid: uid,
                    domain: remote.domain,
                    recordID: remote.recordID,
                    db: db
                )
                // Pending local intent explicitly wins until acknowledged. Once
                // both sides are settled, a total ordering makes concurrent
                // equal-revision edits converge on every device: revision,
                // modified time, then source device ID.
                if let local {
                    if local.pending {
                        conflicts += 1
                        continue
                    }
                    let localOrder = (local.revision, local.modifiedAtMillis, local.sourceDeviceID)
                    let remoteOrder = (remote.revision, remote.modifiedAtMillis, remote.sourceDeviceID)
                    if !Self.precedes(localOrder, remoteOrder) {
                        conflicts += 1
                        continue
                    }
                }
                try upsert(remote, sealedData: sealedData, pending: false, uid: uid, db: db)
                applied += 1
            }
            return (applied, conflicts)
        }
    }

    private func storedReplica(uid: String, domain: Domain, recordID: String) throws -> StoredReplica? {
        try database.read { db in
            try Self.storedReplica(uid: uid, domain: domain, recordID: recordID, db: db)
        }
    }

    private static func storedReplica(uid: String, domain: Domain, recordID: String, db: Database) throws -> StoredReplica? {
        guard let row = try Row.fetchOne(
            db,
            sql: """
                SELECT revision, modified_at, source_device_id, tombstone, sealed_payload, pending
                FROM linux_cloud_replica WHERE uid = ? AND domain = ? AND record_id = ?
                """,
            arguments: [uid, domain.rawValue, recordID]
        ) else { return nil }
        return StoredReplica(
            revision: row["revision"],
            modifiedAtMillis: row["modified_at"],
            sourceDeviceID: row["source_device_id"],
            tombstone: row["tombstone"],
            sealedPayloadData: row["sealed_payload"],
            pending: row["pending"]
        )
    }

    private func upsert(
        _ replica: RemoteReplica,
        sealedData: Data?,
        pending: Bool,
        uid: String,
        db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO linux_cloud_replica
                    (uid, domain, record_id, revision, modified_at, source_device_id, tombstone, sealed_payload, pending)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(uid, domain, record_id) DO UPDATE SET
                    revision = excluded.revision,
                    modified_at = excluded.modified_at,
                    source_device_id = excluded.source_device_id,
                    tombstone = excluded.tombstone,
                    sealed_payload = excluded.sealed_payload,
                    pending = excluded.pending
                """,
            arguments: [
                uid, replica.domain.rawValue, replica.recordID, replica.revision,
                replica.modifiedAtMillis, replica.sourceDeviceID, replica.tombstone,
                sealedData, pending
            ]
        )
    }

    private func currentCursor(uid: String) throws -> String? {
        try database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT cursor FROM linux_cloud_sync_state WHERE uid = ?",
                arguments: [uid]
            )
        }
    }

    private func recordFailure(uid: String) throws {
        let currentFailures = try database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT failures FROM linux_cloud_sync_state WHERE uid = ?",
                arguments: [uid]
            ) ?? 0
        }
        let failures = currentFailures + 1
        let retryAt = nowMillis() + backoff.delayMillis(after: failures)
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO linux_cloud_sync_state (uid, failures, retry_at)
                    VALUES (?, ?, ?)
                    ON CONFLICT(uid) DO UPDATE SET failures = excluded.failures, retry_at = excluded.retry_at
                    """,
                arguments: [uid, failures, retryAt]
            )
        }
    }

    private static func aad(uid: String, domain: Domain, recordID: String) throws -> CloudVaultAADContext {
        try CloudVaultAADContext(
            uid: uid,
            collection: domain.rawValue,
            docID: recordID,
            field: "sealedPayload",
            purpose: "linux-cloud-replica"
        )
    }

    private static func validate(uid: String) throws {
        guard validIdentifier(uid) else { throw EngineError.invalidIdentifier }
    }

    private static func validate(recordID: String) throws {
        guard validIdentifier(recordID) else { throw EngineError.invalidIdentifier }
    }

    private static func validateKey(_ vaultKey: Data) throws {
        guard vaultKey.count == 32 else { throw EngineError.invalidVaultKey }
    }

    private static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 512 && value.unicodeScalars.allSatisfy {
            $0.value >= 0x20 && $0.value != 0x7f && $0 != "|"
        }
    }

    private static func precedes(
        _ lhs: (Int64, Int64, String),
        _ rhs: (Int64, Int64, String)
    ) -> Bool {
        if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
        if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
        return lhs.2 < rhs.2
    }

    private static func migrate(_ database: any DatabaseWriter) throws {
        try database.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS linux_cloud_sync_policy (
                    uid TEXT PRIMARY KEY NOT NULL,
                    enabled_domains BLOB NOT NULL,
                    remote_access_enabled INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS linux_cloud_replica (
                    uid TEXT NOT NULL,
                    domain TEXT NOT NULL,
                    record_id TEXT NOT NULL,
                    revision INTEGER NOT NULL,
                    modified_at INTEGER NOT NULL,
                    source_device_id TEXT NOT NULL,
                    tombstone INTEGER NOT NULL,
                    sealed_payload BLOB,
                    pending INTEGER NOT NULL,
                    PRIMARY KEY (uid, domain, record_id),
                    CHECK ((tombstone = 1 AND sealed_payload IS NULL) OR (tombstone = 0 AND sealed_payload IS NOT NULL))
                );
                CREATE TABLE IF NOT EXISTS linux_cloud_outbox (
                    sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                    uid TEXT NOT NULL,
                    domain TEXT NOT NULL,
                    record_id TEXT NOT NULL,
                    replica BLOB NOT NULL
                );
                CREATE INDEX IF NOT EXISTS linux_cloud_outbox_account_sequence
                    ON linux_cloud_outbox(uid, sequence);
                CREATE TABLE IF NOT EXISTS linux_cloud_sync_state (
                    uid TEXT PRIMARY KEY NOT NULL,
                    cursor TEXT,
                    failures INTEGER NOT NULL DEFAULT 0,
                    retry_at INTEGER,
                    last_success_at INTEGER
                );
                """)
        }
    }
}
