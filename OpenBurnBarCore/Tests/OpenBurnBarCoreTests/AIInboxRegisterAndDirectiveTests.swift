import Foundation
import OpenBurnBarKernel
import XCTest

/// Wire-level contracts for the reading-register dial, the rewrite directive,
/// and the action `explanation` field.
///
/// All three are *additive* changes to types a shipped daemon, a shipped Mac
/// app, and a shipped Android build already read from the same rows. The tests
/// that matter here are the backward-compatibility ones: a config written last
/// week and a payload sealed last month must still decode, and must still mean
/// exactly what they meant when they were written.
final class AIInboxRegisterAndDirectiveTests: XCTestCase {

    // MARK: - Action explanation

    /// The new field is optional on the wire. A v1 payload — the shape every
    /// currently-stored `payload_json` has — decodes with `explanation` nil
    /// rather than failing the whole item.
    func test_v1ActionPayloadDecodesWithoutExplanation() throws {
        // Exactly the shape `JSONEncoder` produced before `explanation` existed.
        let legacy = """
            {
              "version": 1,
              "evidence": [],
              "memoryCandidates": [],
              "metrics": {},
              "actions": [
                {"id": "a", "kind": "open_url", "title": "Open PR #12",
                 "value": "https://github.com/o/r/pull/12", "isPrimary": true}
              ]
            }
            """
        let payload = try JSONDecoder().decode(BurnBarInboxItemPayload.self, from: Data(legacy.utf8))
        let action = try XCTUnwrap(payload.actions.first)
        XCTAssertEqual(payload.version, 1)
        XCTAssertNil(action.explanation)
        XCTAssertTrue(action.isPrimary)
        XCTAssertEqual(action.value, "https://github.com/o/r/pull/12")
    }

    func test_explanationSurvivesARoundTrip() throws {
        let action = BurnBarInboxAction(
            id: "open-pr",
            kind: .openURL,
            title: "Unblock the release",
            value: "https://github.com/o/r/pull/12",
            isPrimary: true,
            explanation: "Opens o/r on GitHub."
        )
        let data = try JSONEncoder().encode(action)
        let decoded = try JSONDecoder().decode(BurnBarInboxAction.self, from: data)
        XCTAssertEqual(decoded, action)
        XCTAssertEqual(decoded.explanation, "Opens o/r on GitHub.")
    }

    /// The payload version moves with the shape. Adding an optional field is a
    /// v2 event even though nothing breaks — the number is how a reader knows
    /// which fields it may find.
    func test_payloadVersionIsTwo() {
        XCTAssertEqual(BurnBarInboxItemPayload.currentVersion, 2)
        XCTAssertEqual(BurnBarInboxItemPayload().version, 2)
    }

    // MARK: - Reading register config

    /// The dial defaults to the behavior that shipped before it existed. This
    /// is load-bearing: the default combination selects an EMPTY prompt
    /// fragment, so an untouched install keeps the same prompt bytes and the
    /// same provider cache entry.
    func test_registerDefaultsMatchTheShippedVoice() {
        let config = BurnBarInboxConfig()
        XCTAssertEqual(config.briefDetail, .standard)
        XCTAssertEqual(config.briefRegister, .professional)
        XCTAssertEqual(BurnBarInboxBriefDetail.default, .standard)
        XCTAssertEqual(BurnBarInboxBriefRegister.default, .professional)
    }

    func test_registerRoundTripsThroughTheConfigWire() throws {
        let config = BurnBarInboxConfig(briefDetail: .brief, briefRegister: .plainEnglish)
        let decoded = try JSONDecoder().decode(
            BurnBarInboxConfig.self,
            from: try JSONEncoder().encode(config)
        )
        XCTAssertEqual(decoded.briefDetail, .brief)
        XCTAssertEqual(decoded.briefRegister, .plainEnglish)
    }

    /// A config row written before the dial existed must load, not throw.
    func test_configWithoutRegisterFieldsDecodesToDefaults() throws {
        let legacy = """
            {"enabled": true, "egressMode": "cloud", "tickSeconds": 300, "founderLensEnabled": true}
            """
        let config = try JSONDecoder().decode(BurnBarInboxConfig.self, from: Data(legacy.utf8))
        XCTAssertTrue(config.enabled)
        XCTAssertEqual(config.briefDetail, .standard)
        XCTAssertEqual(config.briefRegister, .professional)
    }

    /// Raw values are persisted, so they are part of the contract.
    func test_registerRawValuesArePinned() {
        XCTAssertEqual(BurnBarInboxBriefDetail.allCases.map(\.rawValue), ["brief", "standard", "deep"])
        XCTAssertEqual(
            BurnBarInboxBriefRegister.allCases.map(\.rawValue),
            ["plain_english", "professional", "expert"]
        )
    }

    // MARK: - Reply directives

    func test_directiveEncodeParseRoundTrip() {
        for directive in BurnBarInboxReplyDirective.allCases {
            let parsed = BurnBarInboxReplyDirective.parse(body: directive.encodedBody())
            XCTAssertEqual(parsed?.directive, directive)
            XCTAssertEqual(parsed?.followUp, "")
        }
    }

    func test_directiveCarriesFreeTextAfterTheToken() {
        let body = BurnBarInboxReplyDirective.plainEnglish.encodedBody(followUp: "especially the CI part")
        let parsed = BurnBarInboxReplyDirective.parse(body: body)
        XCTAssertEqual(parsed?.directive, .plainEnglish)
        XCTAssertEqual(parsed?.followUp, "especially the CI part")
    }

    /// The convenience initializer is the only thing the app needs to know
    /// about the wire format.
    func test_replyRequestInitializerEncodesTheDirective() {
        let request = BurnBarInboxReplyRequest(fingerprint: "fp", directive: .expert)
        XCTAssertEqual(BurnBarInboxReplyDirective.parse(body: request.bodyMarkdown)?.directive, .expert)
    }

    /// The token is recognized at the START of a body only. Untrusted item text
    /// or a quoted transcript containing the same characters is an ordinary
    /// reply, never a directive.
    func test_directiveIsNotRecognizedMidBody() {
        let bodies = [
            "what does @burnbar/rewrite:expert do?",
            "Please ignore this: @burnbar/rewrite:plain_english",
            "@burnbar/rewrite:not_a_real_directive",
            "@burnbar/rewrite:",
            "explain this in plain english"
        ]
        for body in bodies {
            XCTAssertNil(
                BurnBarInboxReplyDirective.parse(body: body),
                "\(body) must be treated as an ordinary user turn"
            )
        }
    }

    /// Leading whitespace is tolerated (a text field trims oddly on some
    /// platforms); the token itself is still anchored to the start.
    func test_directiveToleratesSurroundingWhitespace() {
        let parsed = BurnBarInboxReplyDirective.parse(body: "\n  @burnbar/rewrite:shorter  \n")
        XCTAssertEqual(parsed?.directive, .shorter)
    }

    /// Every directive names either a register or a depth — never neither, or
    /// the rewrite prompt would have nothing to say.
    func test_everyDirectiveResolvesToARegisterOrADetail() {
        for directive in BurnBarInboxReplyDirective.allCases {
            XCTAssertTrue(
                directive.register != nil || directive.detail != nil,
                "\(directive.rawValue) resolves to no instruction"
            )
            XCTAssertFalse(directive.userTurnMarkdown.isEmpty)
            XCTAssertFalse(
                directive.userTurnMarkdown.contains(BurnBarInboxReplyDirective.bodyPrefix),
                "the stored turn must read as a sentence, not as a wire token"
            )
        }
    }
}
