import XCTest
@testable import OpenBurnBar
@testable import OpenBurnBarCore

/// Wave 3.6 compat pins for the TypeSpec-first RPC catalog.
///
/// The catalog source is `RpcMethod` in
/// tools/schema-sync/typespec/domains/daemon-rpc.tsp; the Swift enum under
/// test is generated from it (BurnBarRPCMethod.generated.swift), and the N-1
/// wire-id snapshot lives at
/// tools/schema-sync/fixtures/daemon-rpc-methods.snapshot.json. These tests
/// pin the Swift projection: catalog size, wire-id shape, agreement with the
/// IPC canon the daemon dispatches from, and raw-value/Codable round-trips.
/// Adding a method updates the count here AND regenerates the snapshot.
final class BurnBarRPCMethodCompatTests: XCTestCase {

    func testMethodCountMatchesSnapshot() {
        XCTAssertEqual(
            BurnBarRPCMethod.allCases.count,
            196,
            "RPC catalog size changed: update this count and regenerate the N-1 snapshot "
                + "(node tools/schema-sync/check-rpc-snapshot.mjs --update)"
        )
    }

    func testRawValuesAreUniqueAndWellFormed() {
        let rawValues = BurnBarRPCMethod.allCases.map(\.rawValue)
        XCTAssertEqual(
            Set(rawValues).count,
            rawValues.count,
            "Duplicate RPC wire ids: \(rawValues.count - Set(rawValues).count) collision(s)"
        )
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._"))
        for raw in rawValues {
            XCTAssertFalse(raw.isEmpty, "Empty RPC wire id")
            XCTAssertTrue(
                raw.unicodeScalars.allSatisfy(allowed.contains),
                "Malformed RPC wire id: \(raw)"
            )
        }
    }

    func testIPCCanonAgreesWithMethodEnum() {
        let enumIDs = Set(BurnBarRPCMethod.allCases.map(\.rawValue))
        let canonIDs = Set(BurnBarRPCIPCCanon.methods.map(\.id))
        XCTAssertEqual(
            canonIDs,
            enumIDs,
            "IPC canon drifted from the method enum "
                + "(missing: \(enumIDs.subtracting(canonIDs).sorted()), "
                + "extra: \(canonIDs.subtracting(enumIDs).sorted())); "
                + "regenerate via tools/ipc/generate-burnbarrpc-canon.mjs"
        )
    }

    func testSpotCheckRawValues() {
        XCTAssertEqual(BurnBarRPCMethod(rawValue: "daemon.health"), .health)
        XCTAssertEqual(BurnBarRPCMethod(rawValue: "auth.bootstrap"), .authBootstrap)
        XCTAssertEqual(BurnBarRPCMethod(rawValue: "workspace.executeTool"), .workspaceExecuteTool)
        XCTAssertNil(BurnBarRPCMethod(rawValue: "daemon.no.such.method"))
    }

    func testCodableRoundTrip() throws {
        let encoded = try JSONEncoder().encode(BurnBarRPCMethod.health)
        XCTAssertEqual(String(data: encoded, encoding: .utf8), "\"daemon.health\"")
        XCTAssertEqual(try JSONDecoder().decode(BurnBarRPCMethod.self, from: encoded), .health)
    }
}
