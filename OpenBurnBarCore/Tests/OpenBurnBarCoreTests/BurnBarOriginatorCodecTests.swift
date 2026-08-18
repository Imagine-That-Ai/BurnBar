import XCTest
@testable import OpenBurnBarKernel

/// Pins the `BurnBarOriginator` wire contract: the flat two-field codec
/// (SQLite columns, mission docs) and the full-map codec (Firestore
/// `OriginatorRef` wire mirror) must round-trip losslessly. A drift here
/// fails silently — the Command Board's STARTED BY column renders "unknown"
/// with no error, so this suite is the only thing that catches it.
final class BurnBarOriginatorCodecTests: XCTestCase {

    // MARK: - Flat codec round-trip

    func test_flatRoundTrip_flame() {
        let origin = BurnBarOriginator(kind: .flame, decisionID: "d-a3f2c901", confidence: .exact)
        let flat = origin.flatFields
        XCTAssertEqual(flat.kind, "flame")
        XCTAssertEqual(flat.ref, "d-a3f2c901")
        let restored = BurnBarOriginator(flatKind: flat.kind, flatRef: flat.ref)
        XCTAssertEqual(restored?.kind, .flame)
        XCTAssertEqual(restored?.decisionID, "d-a3f2c901")
        XCTAssertEqual(restored?.confidence, .exact)
    }

    func test_flatRoundTrip_wand() {
        let origin = BurnBarOriginator(kind: .wand, missionGroupID: "9c41ee70", confidence: .exact)
        let flat = origin.flatFields
        XCTAssertEqual(flat.kind, "wand")
        XCTAssertEqual(flat.ref, "9c41ee70")
        let restored = BurnBarOriginator(flatKind: flat.kind, flatRef: flat.ref)
        XCTAssertEqual(restored?.kind, .wand)
        XCTAssertEqual(restored?.missionGroupID, "9c41ee70")
    }

    func test_flatRoundTrip_mission() {
        let origin = BurnBarOriginator(kind: .mission, missionID: "m-12345", confidence: .exact)
        let flat = origin.flatFields
        let restored = BurnBarOriginator(flatKind: flat.kind, flatRef: flat.ref)
        XCTAssertEqual(restored?.kind, .mission)
        XCTAssertEqual(restored?.missionID, "m-12345")
    }

    func test_flatRoundTrip_hermesBot() {
        let origin = BurnBarOriginator(kind: .hermesBot, botName: "claude-opus", confidence: .inferred)
        let flat = origin.flatFields
        XCTAssertEqual(flat.ref, "claude-opus")
        let restored = BurnBarOriginator(flatKind: flat.kind, flatRef: flat.ref)
        XCTAssertEqual(restored?.kind, .hermesBot)
        XCTAssertEqual(restored?.botName, "claude-opus")
        XCTAssertEqual(restored?.confidence, .inferred)
    }

    func test_flatRoundTrip_userLocal() {
        let origin = BurnBarOriginator(kind: .userLocal, bodyID: "relay-host-abc", confidence: .exact)
        let flat = origin.flatFields
        let restored = BurnBarOriginator(flatKind: flat.kind, flatRef: flat.ref)
        XCTAssertEqual(restored?.kind, .userLocal)
        XCTAssertEqual(restored?.bodyID, "relay-host-abc")
    }

    func test_flatRoundTrip_unknown() {
        let origin = BurnBarOriginator.unknown
        let flat = origin.flatFields
        XCTAssertEqual(flat.kind, "unknown")
        XCTAssertNil(flat.ref)
        let restored = BurnBarOriginator(flatKind: flat.kind, flatRef: flat.ref)
        XCTAssertEqual(restored?.kind, .unknown)
        XCTAssertEqual(restored?.confidence, .unknown)
    }

    func test_flatRoundTrip_emptyRef() {
        let origin = BurnBarOriginator(kind: .flame, decisionID: "d-abc", confidence: .exact)
        let flat = (origin.flatFields.kind, origin.flatFields.ref)
        let restored = BurnBarOriginator(flatKind: flat.0, flatRef: "")
        XCTAssertEqual(restored?.kind, .flame)
        XCTAssertNil(restored?.decisionID)
    }

    func test_flatInit_nilKindReturnsNil() {
        XCTAssertNil(BurnBarOriginator(flatKind: nil, flatRef: "x"))
        XCTAssertNil(BurnBarOriginator(flatKind: "garbage", flatRef: "x"))
    }

    // MARK: - Wire dictionary round-trip

    func test_wireDictionaryRoundTrip_full() {
        let origin = BurnBarOriginator(
            kind: .flame,
            label: "Flame · d-a3f2",
            bodyID: "relay-host-abc",
            decisionID: "d-a3f2c901",
            missionID: nil,
            missionGroupID: nil,
            botName: nil,
            confidence: .exact
        )
        let dict = origin.wireDictionary
        XCTAssertEqual(dict["kind"], "flame")
        XCTAssertEqual(dict["label"], "Flame · d-a3f2")
        XCTAssertEqual(dict["confidence"], "exact")
        XCTAssertEqual(dict["bodyID"], "relay-host-abc")
        XCTAssertEqual(dict["decisionID"], "d-a3f2c901")
        XCTAssertNil(dict["missionID"])
        XCTAssertNil(dict["missionGroupID"])
        XCTAssertNil(dict["botName"])

        let restored = BurnBarOriginator(wireDictionary: dict)
        XCTAssertEqual(restored?.kind, .flame)
        XCTAssertEqual(restored?.label, "Flame · d-a3f2")
        XCTAssertEqual(restored?.confidence, .exact)
        XCTAssertEqual(restored?.decisionID, "d-a3f2c901")
        XCTAssertEqual(restored?.bodyID, "relay-host-abc")
    }

    func test_wireDictionaryRoundTrip_wand() {
        let origin = BurnBarOriginator(kind: .wand, missionGroupID: "grp-1", confidence: .exact)
        let dict = origin.wireDictionary
        XCTAssertEqual(dict["kind"], "wand")
        XCTAssertEqual(dict["missionGroupID"], "grp-1")
        let restored = BurnBarOriginator(wireDictionary: dict)
        XCTAssertEqual(restored?.kind, .wand)
        XCTAssertEqual(restored?.missionGroupID, "grp-1")
    }

    func test_wireInit_nilKindReturnsNil() {
        XCTAssertNil(BurnBarOriginator(wireDictionary: ["label": "x"]))
        XCTAssertNil(BurnBarOriginator(wireDictionary: ["kind": "garbage"]))
    }

    func test_wireInit_missingConfidenceDefaultsUnknown() {
        let dict = ["kind": "flame", "label": "Flame"]
        let restored = BurnBarOriginator(wireDictionary: dict)
        XCTAssertEqual(restored?.kind, .flame)
        XCTAssertEqual(restored?.confidence, .unknown)
    }

    // MARK: - Default label

    func test_defaultLabel_flameWithDecision() {
        let label = BurnBarOriginator.defaultLabel(kind: .flame, decisionID: "d-a3f2c901ee")
        XCTAssertEqual(label, "Flame · d-a3f2c9")
    }

    func test_defaultLabel_flameNoDecision() {
        let label = BurnBarOriginator.defaultLabel(kind: .flame)
        XCTAssertEqual(label, "Flame")
    }

    func test_defaultLabel_wandWithGroup() {
        let label = BurnBarOriginator.defaultLabel(kind: .wand, missionGroupID: "9c41ee70")
        XCTAssertEqual(label, "Wand · group 9c41ee70")
    }

    func test_defaultLabel_wandNoGroup() {
        let label = BurnBarOriginator.defaultLabel(kind: .wand)
        XCTAssertEqual(label, "Wand")
    }

    func test_defaultLabel_hermesBotWithBotName() {
        let label = BurnBarOriginator.defaultLabel(kind: .hermesBot, botName: "claude-opus")
        XCTAssertEqual(label, "Hermes claude-opus")
    }

    func test_defaultLabel_hermesCronWithBotName() {
        let label = BurnBarOriginator.defaultLabel(kind: .hermesCron, botName: "nightly")
        XCTAssertEqual(label, "Hermes nightly · cron")
    }

    func test_defaultLabel_userLocal() {
        let label = BurnBarOriginator.defaultLabel(kind: .userLocal)
        XCTAssertEqual(label, "you (this Mac)")
    }

    func test_defaultLabel_external() {
        let label = BurnBarOriginator.defaultLabel(kind: .external)
        XCTAssertEqual(label, "external")
    }

    // MARK: - primaryRef

    func test_primaryRef_decisionIDWins() {
        let origin = BurnBarOriginator(
            kind: .flame,
            decisionID: "d-1",
            missionGroupID: "g-1",
            confidence: .exact
        )
        XCTAssertEqual(origin.primaryRef, "d-1")
    }

    func test_primaryRef_fallsToMissionGroupID() {
        let origin = BurnBarOriginator(kind: .wand, missionGroupID: "g-1", confidence: .exact)
        XCTAssertEqual(origin.primaryRef, "g-1")
    }

    func test_primaryRef_fallsToBotName() {
        let origin = BurnBarOriginator(kind: .hermesBot, botName: "opus", confidence: .inferred)
        XCTAssertEqual(origin.primaryRef, "opus")
    }

    func test_primaryRef_nilWhenNothingSet() {
        let origin = BurnBarOriginator.unknown
        XCTAssertNil(origin.primaryRef)
    }

    // MARK: - Statics

    func test_externalInferred() {
        let ext = BurnBarOriginator.externalInferred
        XCTAssertEqual(ext.kind, .external)
        XCTAssertEqual(ext.confidence, .inferred)
    }

    func test_unknown() {
        let unknown = BurnBarOriginator.unknown
        XCTAssertEqual(unknown.kind, .unknown)
        XCTAssertEqual(unknown.confidence, .unknown)
    }
}
