import Foundation
import XCTest
@testable import OpenBurnBarCore

/// Cross-language byte-parity gate for the v4 Signal-envelope binding -> AAD
/// canonicalizer. The fixture
/// `Fixtures/SignalBindingAADVectors.json` is a byte-identical copy of the
/// canonical `packages/signal-envelope-contracts/fixtures/binding-aad-vectors.json`
/// consumed by the TypeScript suite (`packages/signal-envelope-contracts`). If
/// Swift's `signalEnvelopeBindingToAAD(_:)` and the TypeScript `bindingToAAD`
/// diverge by a single byte, one of these vectors fails here.
///
/// This is inert/new code (nothing in the app calls it yet); the test exists to
/// freeze the contract before any consumer is wired up.
final class SignalEnvelopeAADTests: XCTestCase {
    // MARK: Fixture loading (mirrors BurnBarHpkeV3CrossPlatformVectorTests).

    private static let fixtureURL: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("SignalBindingAADVectors.json")
    }()

    private struct Fixture: Decodable {
        let prefix: String
        let vectors: [Vector]
    }

    private struct Vector: Decodable {
        let name: String
        let binding: BindingJSON
        let expectedAAD: String
    }

    /// JSON shape of a binding exactly as the shared fixture stores it (optionals
    /// omitted, not null), decoded then mapped onto `SignalEnvelopeAAD.Binding`.
    private struct BindingJSON: Decodable {
        let uid: String
        let scope: String
        let clientId: String?
        let collection: String?
        let docId: String?
        let field: String?
        let slotId: String?
        let mode: String
        let formatVersion: Int

        func toBinding() throws -> SignalEnvelopeAAD.Binding {
            let scope = try XCTUnwrap(
                SignalEnvelopeAAD.Scope(rawValue: scope),
                "unknown scope \(scope)"
            )
            let mode = try XCTUnwrap(
                SignalEnvelopeAAD.Mode(rawValue: mode),
                "unknown mode \(mode)"
            )
            return SignalEnvelopeAAD.Binding(
                uid: uid,
                scope: scope,
                clientId: clientId,
                collection: collection,
                docId: docId,
                field: field,
                slotId: slotId,
                mode: mode,
                formatVersion: formatVersion
            )
        }
    }

    private func loadFixture() throws -> Fixture {
        try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: Self.fixtureURL))
    }

    // MARK: Tests

    func test_prefixMatchesTheSharedContract() {
        XCTAssertEqual(SignalEnvelopeAAD.prefix, "OpenBurnBar-Signal-AAD-v1|")
    }

    /// The byte-parity proof: every vector's binding canonicalizes to the EXACT
    /// `expectedAAD` the TypeScript contract emits for the same input.
    func test_everyVectorMatchesExpectedAADByteForByte() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.prefix, SignalEnvelopeAAD.prefix)
        XCTAssertGreaterThanOrEqual(fixture.vectors.count, 4, "fixture must cover the documented vectors")
        for vector in fixture.vectors {
            let aad = try signalEnvelopeBindingToAAD(vector.binding.toBinding())
            XCTAssertEqual(aad, vector.expectedAAD, "\(vector.name): Swift AAD must equal the vendored expectedAAD")
        }
    }

    /// Absent optionals serialize as empty segments in stable positions, so the
    /// pipe count is identical whether or not optionals are present.
    func test_absentOptionalsAreStableEmptySegments() throws {
        let minimal = SignalEnvelopeAAD.Binding(
            uid: "u",
            scope: .gateway,
            mode: .transport,
            formatVersion: 1
        )
        XCTAssertEqual(
            try signalEnvelopeBindingToAAD(minimal),
            "OpenBurnBar-Signal-AAD-v1|transport|gateway|u||||||1"
        )

        let full = SignalEnvelopeAAD.Binding(
            uid: "u",
            scope: .cloudvault,
            clientId: "c",
            collection: "col",
            docId: "d",
            field: "f",
            slotId: "s",
            mode: .atRest,
            formatVersion: 1
        )
        XCTAssertEqual(
            try signalEnvelopeBindingToAAD(full),
            "OpenBurnBar-Signal-AAD-v1|at-rest|cloudvault|u|c|col|d|f|s|1"
        )

        let pipeCount: (String) -> Int = { $0.filter { $0 == "|" }.count }
        XCTAssertEqual(
            try pipeCount(signalEnvelopeBindingToAAD(minimal)),
            try pipeCount(signalEnvelopeBindingToAAD(full))
        )
    }

    /// Cross-platform Unicode parity: a uid supplied DECOMPOSED (NFD: `e` +
    /// U+0301) canonicalizes to the byte-identical AAD as the PRECOMPOSED form
    /// (NFC: U+00E9) the shared fixture stores, byte-for-byte matching the
    /// TypeScript `.normalize("NFC")`. Without this a Swift-sealed and a
    /// Node-sealed ciphertext for the same logical uid would carry divergent
    /// UTF-8 AAD and fail to open. ASCII vectors are NFC-stable (verified).
    func test_nfdNormalizesToTheSameAADAsNFC() throws {
        let fixture = try loadFixture()
        let nfcVector = try XCTUnwrap(
            fixture.vectors.first { $0.name == "non-ascii-nfc-uid" },
            "fixture must include the non-ascii-nfc-uid vector"
        )

        let nfcUid = nfcVector.binding.uid
        XCTAssertEqual(nfcUid.precomposedStringWithCanonicalMapping, nfcUid, "fixture uid must be stored in NFC")
        let nfdUid = nfcUid.decomposedStringWithCanonicalMapping
        // NFD and NFC are the same Swift String value (canonical equivalence) but
        // a different byte sequence; compare the raw UTF-8 to prove they differ.
        XCTAssertNotEqual(
            Array(nfdUid.utf8),
            Array(nfcUid.utf8),
            "NFD and NFC of the fixture uid must differ at the UTF-8 byte level"
        )

        var nfdBinding = try nfcVector.binding.toBinding()
        nfdBinding.uid = nfdUid
        let nfcBinding = try nfcVector.binding.toBinding()

        let nfdAAD = try signalEnvelopeBindingToAAD(nfdBinding)
        XCTAssertEqual(nfdAAD, nfcVector.expectedAAD, "NFD uid must canonicalize to the NFC expectedAAD")
        XCTAssertEqual(
            Array(nfdAAD.utf8),
            Array(try signalEnvelopeBindingToAAD(nfcBinding).utf8),
            "NFD and NFC bindings must produce byte-identical AAD"
        )

        // ASCII vectors are NFC-stable, so normalization is a no-op for them.
        for vector in fixture.vectors where vector.name != "non-ascii-nfc-uid" {
            XCTAssertEqual(
                vector.expectedAAD.precomposedStringWithCanonicalMapping,
                vector.expectedAAD,
                "\(vector.name) expectedAAD must be NFC-stable"
            )
        }
    }

    /// Fail-closed: a segment carrying `|`, CR, or LF throws rather than emitting
    /// an ambiguous AAD — in required AND optional positions.
    func test_throwsFailClosedOnReservedCharacterInSegment() {
        let injections: [SignalEnvelopeAAD.Binding] = [
            SignalEnvelopeAAD.Binding(uid: "a|b", scope: .gateway, mode: .transport, formatVersion: 1),
            SignalEnvelopeAAD.Binding(uid: "a|\u{0301}b", scope: .gateway, mode: .transport, formatVersion: 1),
            SignalEnvelopeAAD.Binding(uid: "line\r", scope: .gateway, mode: .transport, formatVersion: 1),
            SignalEnvelopeAAD.Binding(uid: "line\n", scope: .gateway, mode: .transport, formatVersion: 1),
            SignalEnvelopeAAD.Binding(
                uid: "u",
                scope: .cloudvault,
                collection: "col|evil",
                docId: "d",
                field: "f",
                mode: .atRest,
                formatVersion: 1
            ),
        ]
        for binding in injections {
            XCTAssertThrowsError(try signalEnvelopeBindingToAAD(binding)) { error in
                XCTAssertEqual(
                    error as? SignalEnvelopeAAD.SignalEnvelopeAADError,
                    .reservedCharacterInSegment
                )
            }
        }
    }
}
