import XCTest
@testable import OpenBurnBar

/// The persona layer: the ten characters, the seat roster, and the one place a
/// persona reaches the model.
final class PlasmaPersonaTests: XCTestCase {

    // MARK: Roster

    func testAllTenPersonasShip() {
        XCTAssertEqual(PlasmaPersona.all.count, 10)
        XCTAssertEqual(Set(PlasmaPersona.all.map(\.id)).count, 10, "ids are unique")
        XCTAssertEqual(Set(PlasmaPersona.all.map(\.name)).count, 10, "names are unique")
    }

    func testEveryPersonaIsFullyDressed() {
        for persona in PlasmaPersona.all {
            XCTAssertFalse(persona.tagline.isEmpty, "\(persona.id) has no tagline")
            XCTAssertFalse(persona.voicePrompt.isEmpty, "\(persona.id) has no voice")
            XCTAssertFalse(persona.skills.isEmpty, "\(persona.id) has no skills")
            XCTAssertEqual(persona.gradient.stops.count, 3, "\(persona.id) gradient")
        }
    }

    func testEveryEyeStyleIsClaimedBySomePersona() {
        // The asset draws five of its ten eye styles and lets the rest fall back
        // to plain dots. All ten are drawn here, so all ten must be reachable —
        // otherwise the personas stop being distinguishable at 52pt.
        let used = Set(PlasmaPersona.all.map(\.eyeStyle))
        XCTAssertEqual(used.count, PlasmaEyeStyle.allCases.count)
    }

    func testUnknownPersonaIDResolvesToNilRatherThanASubstitute() {
        XCTAssertNil(PlasmaPersona.persona(id: "not-a-persona"))
        XCTAssertNotNil(PlasmaPersona.persona(id: PlasmaPersona.all[0].id))
    }

    func testBuiltInSeatsNameRealPersonas() {
        for seat in PlasmaSeat.builtIn {
            XCTAssertNotNil(
                PlasmaPersona.persona(id: seat.personaID),
                "built-in seat \(seat.id) names a persona that does not ship"
            )
            XCTAssertTrue(seat.isBuiltIn)
        }
    }

    // MARK: Prompt composition

    func testComposeWithoutAPersonaLeavesThePromptByteIdentical() {
        let base = "## Instructions\nBe accurate."
        XCTAssertEqual(PlasmaPersonaPrompt.compose(voice: nil, base: base), base)
    }

    func testComposePrependsTheVoiceAndKeepsTheBase() {
        let persona = PlasmaPersona.all[0]
        let base = "## Instructions\nBe accurate."
        let composed = PlasmaPersonaPrompt.compose(voice: persona, base: base)
        XCTAssertTrue(composed.contains(persona.voicePrompt))
        XCTAssertTrue(composed.hasSuffix(base), "the base prompt survives intact, at the end")
    }

    func testComposedVoiceIsNotWrappedAsUntrustedContent() {
        // The ten voices are app-authored constants, so they belong in the
        // trusted `.core` region. Wrapping them as untrusted would both be a
        // lie and make them droppable under token pressure.
        let composed = PlasmaPersonaPrompt.compose(voice: PlasmaPersona.all[1], base: "base")
        XCTAssertFalse(composed.contains("UNTRUSTED"))
        XCTAssertFalse(composed.contains("untrusted"))
    }

    func testNoPersonaVoiceCarriesInstructionOverrideLanguage() {
        // A persona sets register. It must never claim authority over safety,
        // tools, or the instruction hierarchy.
        let forbidden = ["ignore previous", "disregard", "override", "system prompt", "you must not refuse"]
        for persona in PlasmaPersona.all {
            let voice = persona.voicePrompt.lowercased()
            for phrase in forbidden {
                XCTAssertFalse(voice.contains(phrase), "\(persona.id) voice contains '\(phrase)'")
            }
        }
    }

    // MARK: Seat persistence

    func testSeatMapSurvivesAJSONRoundTrip() {
        let original = ["codex": "seat-a", "hermes": "seat-b"]
        let json = String(data: try! JSONEncoder().encode(original), encoding: .utf8)
        XCTAssertEqual(ChatSessionController.decodeSeatMap(json), original)
    }

    func testCorruptSeatStoreDecodesToEmptyRatherThanThrowing() {
        XCTAssertEqual(ChatSessionController.decodeSeatMap("{not json"), [:])
        XCTAssertEqual(ChatSessionController.decodeSeatMap(nil), [:])
    }

    func testRosterDropsSeatsNamingPersonasThisBuildNoLongerShips() {
        // A seat pointing at a removed persona would render as a blank orb.
        let seats = [
            PlasmaSeat(id: "seat-1", label: "Keep", personaID: PlasmaPersona.all[0].id, isBuiltIn: false),
            PlasmaSeat(id: "seat-2", label: "Drop", personaID: "retired-persona", isBuiltIn: false)
        ]
        let json = String(data: try! JSONEncoder().encode(seats), encoding: .utf8)
        let decoded = ChatSessionController.decodeRoster(json)
        XCTAssertEqual(decoded.map(\.id), ["seat-1"])
    }

    func testRosterDropsPersistedBuiltInsSoTheyCannotBeDuplicated() {
        // Built-ins come from code, not from the store; a stale persisted copy
        // would show the same seat twice.
        let seats = [PlasmaSeat(id: "b", label: "Built in", personaID: PlasmaPersona.all[0].id, isBuiltIn: true)]
        let json = String(data: try! JSONEncoder().encode(seats), encoding: .utf8)
        XCTAssertTrue(ChatSessionController.decodeRoster(json).isEmpty)
    }
}
