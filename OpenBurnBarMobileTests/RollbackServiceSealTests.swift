import XCTest
import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarMobile

/// Verifies the privacy-leak remediation for `rollback_requests` and the
/// `cli_sessions/{id}/snapshots` index: scope JSON (which can embed an absolute
/// file path), the Mac resolution diagnostic, and the snapshot action label /
/// touched files / Mac path are SEALED with the vault key before they touch
/// Firestore. Every reader keeps a legacy plaintext fallback so in-flight /
/// pre-migration documents still decode.
@MainActor
final class RollbackServiceSealTests: XCTestCase {

    // MARK: - rollback_requests — scope

    func test_encodeRequest_sealsScope_writesNoPlaintextScopeJSON() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let request = RollbackRequest(
            sessionID: "sess-1",
            scope: .singleFile(path: "/Users/me/secret.swift"),
            requestedBy: "iphone"
        )

        let encoded = try RollbackService.encodeRequest(request, vaultKey: key)

        // The scope is sealed; no plaintext scopeJSON leaks.
        XCTAssertNotNil(encoded["sealedScope"])
        XCTAssertNil(encoded["scopeJSON"])
        XCTAssertNil(encoded["errorMessage"])
        XCTAssertNil(encoded["sealedErrorMessage"])
        XCTAssertEqual(encoded["status"] as? String, "pending")
        XCTAssertEqual(encoded["source"] as? String, "ios-hermes-square")

        // The sealed envelope shape is the canonical CloudVaultSealedText.
        let sealed = try XCTUnwrap(encoded["sealedScope"] as? [String: Any])
        XCTAssertEqual(sealed["algorithm"] as? String, CloudVaultCrypto.aesGCMAlgorithm)
        XCTAssertNotNil(sealed["nonce"])
        XCTAssertNotNil(sealed["ciphertext"])
        XCTAssertNotNil(sealed["tag"])
    }

    func test_encodeRequest_thenDecodeRequest_roundTripsScope() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let request = RollbackRequest(
            sessionID: "sess-1",
            scope: .singleFile(path: "/Users/me/secret.swift"),
            requestedBy: "iphone"
        )
        var encoded = try RollbackService.encodeRequest(request, vaultKey: key)
        encoded["requestedAt"] = ISO8601DateFormatter().string(from: request.requestedAt)

        let decoded = try XCTUnwrap(
            RollbackService.decodeRequest(data: encoded, documentID: request.id, vaultKey: key)
        )
        XCTAssertEqual(decoded.sessionID, "sess-1")
        XCTAssertEqual(decoded.scope, .singleFile(path: "/Users/me/secret.swift"))
        XCTAssertEqual(decoded.status, .pending)
    }

    // MARK: - rollback_requests — status wire contract

    /// `inFlight` encodes as snake_case `"in_flight"` (matches firestore.rules,
    /// Android `IN_FLIGHT.token`, and every adjacent status enum) and round-trips
    /// back through `decodeRequest`.
    func test_encodeRequest_inFlightStatus_encodesSnakeCase_andRoundTrips() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let request = RollbackRequest(
            sessionID: "sess-1",
            scope: .fullSession,
            requestedBy: "mac",
            status: .inFlight
        )
        var encoded = try RollbackService.encodeRequest(request, vaultKey: key)
        // Wire value is snake_case, never camelCase `inFlight`.
        XCTAssertEqual(encoded["status"] as? String, "in_flight")
        encoded["requestedAt"] = ISO8601DateFormatter().string(from: request.requestedAt)

        let decoded = try XCTUnwrap(
            RollbackService.decodeRequest(data: encoded, documentID: request.id, vaultKey: key)
        )
        XCTAssertEqual(decoded.status, .inFlight)
    }

    /// A doc carrying the legacy camelCase `"inFlight"` status (written before
    /// the snake_case migration) still decodes via the `wireValue` alias.
    func test_decodeRequest_legacyCamelCaseInFlightStatus_decodes() throws {
        let scopeJSON = String(
            data: try JSONEncoder().encode(RollbackScope.fullSession),
            encoding: .utf8
        )!
        let legacy: [String: Any] = [
            "sessionID": "sess-legacy",
            "scopeJSON": scopeJSON,
            "status": "inFlight",        // legacy camelCase wire value
            "requestedAt": ISO8601DateFormatter().string(from: Date()),
            "requestedBy": "mac"
        ]
        let decoded = try XCTUnwrap(
            RollbackService.decodeRequest(data: legacy, documentID: "req-legacy", vaultKey: nil)
        )
        XCTAssertEqual(decoded.status, .inFlight)
    }

    /// A `cancelled` doc (Android- or Mac-written) now decodes; before the
    /// snake_case migration the missing case made `decodeRequest` nil-bail and
    /// the row silently disappeared from the iOS list.
    func test_decodeRequest_cancelledStatus_decodes() throws {
        let scopeJSON = String(
            data: try JSONEncoder().encode(RollbackScope.fullSession),
            encoding: .utf8
        )!
        let doc: [String: Any] = [
            "sessionID": "sess-cancelled",
            "scopeJSON": scopeJSON,
            "status": "cancelled",
            "requestedAt": ISO8601DateFormatter().string(from: Date()),
            "requestedBy": "android"
        ]
        let decoded = try XCTUnwrap(
            RollbackService.decodeRequest(data: doc, documentID: "req-cancelled", vaultKey: nil)
        )
        XCTAssertEqual(decoded.status, .cancelled)
    }

    /// A genuinely-unknown status string drops the row (no guessing).
    func test_decodeRequest_unknownStatus_dropsRow() throws {
        let scopeJSON = String(
            data: try JSONEncoder().encode(RollbackScope.fullSession),
            encoding: .utf8
        )!
        let doc: [String: Any] = [
            "sessionID": "sess-bogus",
            "scopeJSON": scopeJSON,
            "status": "bogus",
            "requestedAt": ISO8601DateFormatter().string(from: Date()),
            "requestedBy": "mac"
        ]
        XCTAssertNil(
            RollbackService.decodeRequest(data: doc, documentID: "req-bogus", vaultKey: nil)
        )
    }

    func test_decodeRequest_legacyPlaintextScope_stillDecodes() throws {
        let scopeJSON = String(
            data: try JSONEncoder().encode(RollbackScope.lastN(count: 3)),
            encoding: .utf8
        )!
        let legacy: [String: Any] = [
            "sessionID": "sess-legacy",
            "scopeJSON": scopeJSON,
            "status": "pending",
            "requestedAt": ISO8601DateFormatter().string(from: Date()),
            "requestedBy": "iphone"
        ]
        // No key (or a key) — legacy plaintext fallback must still resolve.
        let decoded = try XCTUnwrap(
            RollbackService.decodeRequest(data: legacy, documentID: "req-legacy", vaultKey: nil)
        )
        XCTAssertEqual(decoded.scope, .lastN(count: 3))
    }

    func test_decodeRequest_sealedScopeUnreadableWithoutKey() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let request = RollbackRequest(
            sessionID: "sess-1",
            scope: .singleFile(path: "/Users/me/secret.swift"),
            requestedBy: "iphone"
        )
        var encoded = try RollbackService.encodeRequest(request, vaultKey: key)
        encoded["requestedAt"] = ISO8601DateFormatter().string(from: Date())

        // Without the key and no legacy plaintext, the scope cannot be opened
        // and the row is dropped (no leak path).
        XCTAssertNil(RollbackService.decodeRequest(data: encoded, documentID: "req-1", vaultKey: nil))
    }

    // MARK: - rollback_requests — errorMessage (Mac-written, sealed on read)

    func test_decodeRequest_opensSealedErrorMessage_withLegacyFallback() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let scopeJSON = String(
            data: try JSONEncoder().encode(RollbackScope.fullSession), encoding: .utf8
        )!

        // Sealed errorMessage opens.
        let sealedErr = try sealedDictionary("disk full at /Users/me/proj", key: key)
        let sealedScope = try sealedDictionary(scopeJSON, key: key)
        let sealedDoc: [String: Any] = [
            "sessionID": "sess-1",
            "sealedScope": sealedScope,
            "sealedErrorMessage": sealedErr,
            "status": "failed",
            "requestedAt": ISO8601DateFormatter().string(from: Date()),
            "requestedBy": "mac"
        ]
        let decoded = try XCTUnwrap(
            RollbackService.decodeRequest(data: sealedDoc, documentID: "req-1", vaultKey: key)
        )
        XCTAssertEqual(decoded.errorMessage, "disk full at /Users/me/proj")

        // Legacy plaintext errorMessage still resolves.
        let legacyDoc: [String: Any] = [
            "sessionID": "sess-1",
            "scopeJSON": scopeJSON,
            "errorMessage": "legacy failure text",
            "status": "failed",
            "requestedAt": ISO8601DateFormatter().string(from: Date()),
            "requestedBy": "mac"
        ]
        let legacyDecoded = try XCTUnwrap(
            RollbackService.decodeRequest(data: legacyDoc, documentID: "req-2", vaultKey: key)
        )
        XCTAssertEqual(legacyDecoded.errorMessage, "legacy failure text")
    }

    // MARK: - cli_sessions snapshots

    func test_decodeSnapshot_opensSealedFields() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let touchedJSON = String(
            data: try JSONEncoder().encode(["src/a.swift", "src/b.swift"]), encoding: .utf8
        )!
        let doc: [String: Any] = [
            "sequence": 2,
            "takenAt": ISO8601DateFormatter().string(from: Date()),
            "sealedActionLabel": try sealedDictionary("Edit src/foo.swift", key: key),
            "sealedTouchedFiles": try sealedDictionary(touchedJSON, key: key),
            "sealedMacSnapshotPath": try sealedDictionary("/Users/me/.burnbar/snap/2", key: key)
        ]
        let snapshot = try XCTUnwrap(
            RollbackService.decodeSnapshot(data: doc, documentID: "snap-2", sessionID: "sess-1", vaultKey: key)
        )
        XCTAssertEqual(snapshot.actionLabel, "Edit src/foo.swift")
        XCTAssertEqual(snapshot.touchedFiles, ["src/a.swift", "src/b.swift"])
        XCTAssertEqual(snapshot.macSnapshotPath, "/Users/me/.burnbar/snap/2")
        XCTAssertEqual(snapshot.sequence, 2)
    }

    func test_decodeSnapshot_legacyPlaintext_stillDecodes() throws {
        let doc: [String: Any] = [
            "sequence": 0,
            "takenAt": ISO8601DateFormatter().string(from: Date()),
            "actionLabel": "Run npm test",
            "touchedFiles": ["pkg/x.ts"],
            "macSnapshotPath": "/tmp/snap/0"
        ]
        let snapshot = try XCTUnwrap(
            RollbackService.decodeSnapshot(data: doc, documentID: "snap-0", sessionID: "sess-1", vaultKey: nil)
        )
        XCTAssertEqual(snapshot.actionLabel, "Run npm test")
        XCTAssertEqual(snapshot.touchedFiles, ["pkg/x.ts"])
        XCTAssertEqual(snapshot.macSnapshotPath, "/tmp/snap/0")
    }

    func test_decodeSnapshot_sealedActionLabelUnreadableWithoutKey_dropsRow() throws {
        let key = CloudVaultCrypto.generateVaultKey()
        let doc: [String: Any] = [
            "sequence": 1,
            "takenAt": ISO8601DateFormatter().string(from: Date()),
            "sealedActionLabel": try sealedDictionary("Edit secret.swift", key: key)
        ]
        // No key, no legacy plaintext actionLabel => required field missing => nil.
        XCTAssertNil(
            RollbackService.decodeSnapshot(data: doc, documentID: "snap-1", sessionID: "sess-1", vaultKey: nil)
        )
    }

    // MARK: - Helpers

    private func sealedDictionary(_ text: String, key: Data) throws -> [String: Any] {
        let envelope = try CloudVaultCrypto.sealText(text, keyData: key)
        let data = try JSONEncoder().encode(envelope)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }
}
