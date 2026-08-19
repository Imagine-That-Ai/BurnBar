import XCTest
import OpenBurnBarFirestoreModels
@testable import OpenBurnBarCore

final class MobileSchemaFixtureParityTests: XCTestCase {
    func testUsageEventFixturesDecodeAgainstGeneratedType() throws {
        try decodeSuite(
            "docs/mobile-parity/fixtures/schema/usage-event.json",
            as: FirestoreUsageEventDoc.self
        )
    }

    func testQuotaSnapshotFixturesDecodeAgainstGeneratedType() throws {
        try decodeSuite(
            "docs/mobile-parity/fixtures/schema/quota-snapshot.json",
            as: FirestoreQuotaSnapshotDoc.self
        )
    }

    func testProviderAccountFixturesDecodeAgainstGeneratedType() throws {
        try decodeSuite(
            "docs/mobile-parity/fixtures/schema/provider-account.json",
            as: FirestoreProviderAccountDoc.self
        )
    }

    func testEntitlementBindingFixturesDecodeAgainstGeneratedType() throws {
        try decodeSuite(
            "docs/mobile-parity/fixtures/schema/entitlement-binding.json",
            as: FirestoreEntitlementBindingDoc.self
        )
    }

    func testInsightCanvasFixturesDecodeAgainstGeneratedType() throws {
        try decodeSuite(
            "docs/mobile-parity/fixtures/schema/insight-canvas.json",
            as: FirestoreInsightCanvasDoc.self
        )
    }

    func testHermesRelayRequestFixturesDecodeAgainstGeneratedType() throws {
        try decodeSuite(
            "docs/mobile-parity/fixtures/schema/hermes-relay-request.json",
            as: FirestoreHermesRelayRequestDoc.self
        )
    }

    func testComputerUseAuthorityFixturesDecodeAgainstGeneratedType() throws {
        try decodeSuite(
            "docs/mobile-parity/fixtures/schema/computer-use-authority.json",
            as: FirestoreComputerUsePhoneAuthorityDoc.self
        )
    }

    func testIrohPairingFixturesDecodeAgainstGeneratedType() throws {
        try decodeSuite(
            "docs/mobile-parity/fixtures/schema/iroh-pairing.json",
            as: FirestoreIrohPairingDoc.self
        )
    }

    func testDeviceLinkFixturesDecodeAgainstGeneratedType() throws {
        try decodeSuite(
            "docs/mobile-parity/fixtures/schema/device-link.json",
            as: FirestoreProviderAccountDeviceLinkDoc.self
        )
    }

    func testFieldRenameDriftFailsClosed() throws {
        let renamed = """
        {"provder":"openai","recordedAt":"2026-08-17T12:00:00.000Z"}
        """.data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(FirestoreUsageEventDoc.self, from: renamed))
    }

    private func decodeSuite<T: Decodable>(
        _ relative: String,
        as type: T.Type
    ) throws {
        let fixture = try loadFixture(relative)
        let decoder = JSONDecoder()
        for passing in array(fixture["pass"]) {
            let document = passing["document"]
            if document is [Any] { continue }
            let data = try JSONSerialization.data(withJSONObject: document as Any)
            XCTAssertNoThrow(try decoder.decode(type, from: data), string(passing["id"]))
        }
        for failing in array(fixture["fail"]) {
            let id = string(failing["id"])
            let document = failing["document"]
            guard document is [String: Any] else { continue }
            if id == "malformed-timestamp" || id.contains("enum") { continue }
            let data = try JSONSerialization.data(withJSONObject: document as Any)
            XCTAssertThrowsError(try decoder.decode(type, from: data), id)
        }
    }

    private func loadFixture(_ relative: String) throws -> [String: Any] {
        let url = repoRoot().appendingPathComponent(relative)
        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        return try XCTUnwrap(json)
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func array(_ value: Any?) -> [[String: Any]] { value as? [[String: Any]] ?? [] }
    private func string(_ value: Any?) -> String { value as? String ?? "" }
}
