import Foundation
import XCTest
@testable import OpenBurnBarKernelCrypto

/// Phase 2.5 G6 — cross-language byte-parity gate for the v4 Signal-envelope
/// binding -> AAD canonicalizer in TRANSPORT mode (scope=gateway, clientId/slotId).
///
/// The fixture `Fixtures/SignalTransportBindingAADVectors.json` is a byte-identical
/// copy of the canonical
/// `packages/signal-envelope-contracts/fixtures/transport-binding-aad-vectors.json`
/// consumed by the Node harness (`scripts/ci/crypto-proof-harness.mjs` section A2)
/// and the Android `CloudVaultTransportBindingParityTest`. The canonicalizer is
/// mode-agnostic, so this freezes the transport-mode seam (clientId/slotId
/// positions, NFC parity, fail-closed) as a first-class, separately-named KAT — the
/// at-rest seam is frozen by `SignalEnvelopeAADTests`.
final class SignalEnvelopeTransportAADParityTests: XCTestCase {
    // MARK: Fixture loading (mirrors SignalEnvelopeAADTests).

    private static let fixtureURL: URL = {
        URL(fileURLWithPath: #file)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent("SignalTransportBindingAADVectors.json")
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

    func test_prefixMatchesTheSharedContract() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(fixture.prefix, SignalEnvelopeAAD.prefix)
        XCTAssertEqual(SignalEnvelopeAAD.prefix, "OpenBurnBar-Signal-AAD-v1|")
    }

    /// The byte-parity proof: every transport vector's binding canonicalizes to the
    /// EXACT `expectedAAD` the TypeScript contract emits for the same input.
    func test_everyTransportVectorMatchesExpectedAADByteForByte() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.vectors.count, 4, "fixture must cover the documented transport vectors")
        for vector in fixture.vectors {
            let aad = try signalEnvelopeBindingToAAD(vector.binding.toBinding())
            XCTAssertEqual(aad, vector.expectedAAD, "\(vector.name): Swift AAD must equal the vendored expectedAAD")
        }
    }

    /// Every vector in this fixture is a transport/gateway binding, and a transport
    /// AAD carries the same pipe-field count as an at-rest AAD (the mode segment, not
    /// the field count, distinguishes them — no mode confusion).
    func test_everyVectorIsTransportGatewayAndShareFieldCount() throws {
        let fixture = try loadFixture()
        for vector in fixture.vectors {
            XCTAssertEqual(vector.binding.mode, "transport", "\(vector.name) must be a transport binding")
            XCTAssertEqual(vector.binding.scope, "gateway", "\(vector.name) must be a gateway binding")
        }
        let transportAAD = try signalEnvelopeBindingToAAD(fixture.vectors[0].binding.toBinding())
        let atRestAAD = try signalEnvelopeBindingToAAD(
            SignalEnvelopeAAD.Binding(
                uid: "u",
                scope: .cloudvault,
                collection: "col",
                docId: "d",
                field: "f",
                mode: .atRest,
                formatVersion: 1
            )
        )
        let pipeCount: (String) -> Int = { $0.filter { $0 == "|" }.count }
        XCTAssertEqual(pipeCount(transportAAD), pipeCount(atRestAAD), "transport and at-rest AAD must share the pipe-field count")
    }

    /// Cross-platform Unicode parity: a clientId supplied DECOMPOSED (NFD: `e` +
    /// U+0301) must fail closed instead of canonicalizing to the same AAD as the
    /// PRECOMPOSED form (NFC: U+00E9). This keeps the transport binding injective
    /// over raw identifier bytes.
    func test_rejectsNonNFCClientIdInsteadOfCollapsingItToTheNFCAAD() throws {
        let fixture = try loadFixture()
        let nfcVector = try XCTUnwrap(
            fixture.vectors.first { $0.name == "transport-non-ascii-nfc-clientId" },
            "fixture must include the transport-non-ascii-nfc-clientId vector"
        )
        let nfcClientId = try XCTUnwrap(nfcVector.binding.clientId, "non-ascii vector must carry a clientId")
        XCTAssertEqual(nfcClientId.precomposedStringWithCanonicalMapping, nfcClientId, "fixture clientId must be stored in NFC")

        let nfdClientId = nfcClientId.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(
            Array(nfdClientId.utf8),
            Array(nfcClientId.utf8),
            "NFD and NFC of the fixture clientId must differ at the UTF-8 byte level"
        )

        let json = nfcVector.binding
        let nfdBinding = SignalEnvelopeAAD.Binding(
            uid: json.uid,
            scope: .gateway,
            clientId: nfdClientId,
            slotId: json.slotId,
            mode: .transport,
            formatVersion: json.formatVersion
        )
        XCTAssertEqual(try signalEnvelopeBindingToAAD(nfcVector.binding.toBinding()), nfcVector.expectedAAD, "NFC clientId must remain accepted")
        XCTAssertThrowsError(try signalEnvelopeBindingToAAD(nfdBinding)) { error in
            XCTAssertEqual(
                error as? SignalEnvelopeAAD.SignalEnvelopeAADError,
                .nonCanonicalUnicodeSegment
            )
        }
    }

    /// Fail-closed: a transport segment carrying `|`, CR, or LF throws rather than
    /// emitting an ambiguous AAD — in the transport-only clientId AND slotId positions.
    func test_throwsFailClosedOnReservedCharacterInTransportSegment() {
        let injections: [SignalEnvelopeAAD.Binding] = [
            SignalEnvelopeAAD.Binding(uid: "uid-1", scope: .gateway, clientId: "client|evil", slotId: "event-1", mode: .transport, formatVersion: 1),
            SignalEnvelopeAAD.Binding(uid: "uid-1", scope: .gateway, clientId: "client-1", slotId: "slot\nevil", mode: .transport, formatVersion: 1),
            SignalEnvelopeAAD.Binding(uid: "uid-1", scope: .gateway, clientId: "client\revil", slotId: "event-1", mode: .transport, formatVersion: 1)
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
