import Foundation
import OpenBurnBarCore

/// Storage-agnostic surface for the iroh pairing record. The production
/// implementation is Firestore-backed (Mac + iOS), but keeping the contract
/// abstract lets us:
///
///   * Unit-test publish/verify flows without booting Firebase.
///   * Swap to a Pi-agent gateway store if the relay topology ever changes.
///   * Run audit-only tooling against on-disk snapshots.
public protocol IrohPairingDirectory: Sendable {
    /// Persists the signed pairing record. Idempotent — overwrites the
    /// existing document at `/users/{uid}/iroh_pairing/{connectionId}`.
    func publish(_ record: IrohPairingRecord, for uid: String) async throws

    /// Fetches the pairing record advertised by the Mac for this user +
    /// connection. Returns `nil` if no record has been published yet.
    func fetch(uid: String, connectionId: String) async throws -> IrohPairingRecord?

    /// Removes the pairing record. Used by the Mac on `stop()` so iOS does
    /// not dial a NodeId that is no longer accepting streams.
    func revoke(uid: String, connectionId: String) async throws
}

/// In-memory directory for tests + dev fixtures. Threadsafe by construction.
public actor InMemoryIrohPairingDirectory: IrohPairingDirectory {
    private var store: [String: IrohPairingRecord] = [:]

    public init() {}

    public func publish(_ record: IrohPairingRecord, for uid: String) async throws {
        store[Self.key(uid: uid, connectionId: record.connectionId)] = record
    }

    public func fetch(uid: String, connectionId: String) async throws -> IrohPairingRecord? {
        store[Self.key(uid: uid, connectionId: connectionId)]
    }

    public func revoke(uid: String, connectionId: String) async throws {
        store.removeValue(forKey: Self.key(uid: uid, connectionId: connectionId))
    }

    public func allRecords() async -> [IrohPairingRecord] {
        Array(store.values)
    }

    private static func key(uid: String, connectionId: String) -> String {
        "\(uid)::\(connectionId)"
    }
}

/// High-level pairing publisher. The Mac calls `publish(...)` once it has
/// bootstrapped an iroh endpoint; iOS calls `fetchAndVerify(...)` before
/// dialing. The publisher signs canonical AAD locally — directories never
/// see the signing key.
public struct IrohPairingPublisher: Sendable {
    private let directory: any IrohPairingDirectory

    public init(directory: any IrohPairingDirectory) {
        self.directory = directory
    }

    /// Mac-side publish. Signs the record with the supplied pairing keypair
    /// and persists it to the directory.
    public func publish(
        uid: String,
        connectionId: String,
        nodeId: String,
        publishedAt: Date = Date(),
        with keypair: IrohPairingKeypair
    ) async throws -> IrohPairingRecord {
        let record = try IrohPairingSignature.sign(
            uid: uid,
            connectionId: connectionId,
            nodeId: nodeId,
            publishedAtMillis: Int64(publishedAt.timeIntervalSince1970 * 1000),
            with: keypair.signingKey
        )
        try await directory.publish(record, for: uid)
        return record
    }

    /// iOS-side fetch + verify. Returns the verified NodeId, or throws.
    /// Missing records surface as `IrohPairingDirectoryError.recordNotFound`
    /// so callers can distinguish "Mac never published" from "Mac published
    /// but the signature didn't verify" — both surface to the user with
    /// distinct copy in the connection sheet.
    public func fetchAndVerify(
        uid: String,
        connectionId: String,
        publicKey: Data,
        now: Date = Date()
    ) async throws -> String {
        guard let record = try await directory.fetch(uid: uid, connectionId: connectionId) else {
            throw IrohPairingDirectoryError.recordNotFound
        }
        try IrohPairingSignature.verify(record, publicKey: publicKey, now: now)
        return record.nodeId
    }
}

public enum IrohPairingDirectoryError: Error, Equatable, Sendable {
    case recordNotFound
    /// Surface raised when a read-only directory implementation (such as
    /// the iOS mobile reader) is asked to publish or revoke a record. The
    /// previous design no-oped these calls silently, which would mask a
    /// future coding error that wired a mobile caller into the publisher.
    case unsupportedOnReader
}
