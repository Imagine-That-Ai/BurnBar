// SPDX-License-Identifier: AGPL-3.0-only
//
// Tests for the shared, fail-closed secret/PII gate promoted in PR-C1. Covers
// the five must-fixes: finding id+label carriage, mandatory Luhn for credit
// cards, bounded IPv4 octets, bounded fail-closed redaction, and availability.

import Foundation
import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarKernel

final class MemorySecretPIIGateTests: XCTestCase {
    // MARK: - Availability (must-fix #2: Bundle.module flat loader resolves)

    func testGateIsAvailableFromBundleModule() {
        // The corpus must load via Bundle.module (flat filename, no subdirectory)
        // or the filesystem fallback. A fail-closed gate would silently reject
        // everything, so this is the canary for resource wiring in Core.
        XCTAssertTrue(MemorySecretPIIGate.isAvailable, "Gate corpus failed to load — gate is fail-closed.")
        XCTAssertFalse(MemorySecretPIIGate.corpusVersion.isEmpty)
    }

    // MARK: - Positive secret detection

    func testDetectsNamedSecretsWithStableIDsAndLabels() {
        let anthropicKey = ["sk", "ant", String(repeating: "a", count: 26)].joined(separator: "-")
        let verdict = MemorySecretPIIGate.evaluate("User pasted \(anthropicKey) here.", policy: .reject)
        guard case .reject(let findings) = verdict else {
            XCTFail("Expected reject for a secret-bearing body, got \(verdict)")
            return
        }
        XCTAssertEqual(findings.map(\.id), ["anthropic-api-key"])
        XCTAssertEqual(findings.first?.label, "Anthropic API key detected")
        XCTAssertEqual(findings.first?.kind, .secret)
    }

    func testOpenAIKeyDetectedEvenWhenEmbeddedAfterUnderscore() {
        // The chat migration contract requires `apiKey_sk-...` to still reject as
        // an OpenAI key (the corpus openai regex drops the leading \b for this).
        let body = "Embedded key apiKey_sk-abcdefghijklmnopqrstuvwxyz1234567890 must reject."
        XCTAssertEqual(MemorySecretPIIGate.findingIDs(in: body), ["openai-api-key"])
    }

    func testAnthropicKeyDoesNotAlsoTripOpenAIPattern() {
        // Negative-lookahead in the openai regex keeps a single named finding for
        // an anthropic key (chat asserts a single-element array).
        let anthropicKey = "sk-ant-1234567890abcdef1234567890"
        XCTAssertEqual(MemorySecretPIIGate.findingIDs(in: "key \(anthropicKey)"), ["anthropic-api-key"])
    }

    // MARK: - Positive PII detection

    func testDetectsEmailAndSSNAsPII() {
        let emailFindings = MemorySecretPIIGate.findings(in: "reach me at person@example.com")
        XCTAssertEqual(emailFindings.map(\.id), ["email-address"])
        XCTAssertEqual(emailFindings.first?.kind, .pii)

        let ssnFindings = MemorySecretPIIGate.findings(in: "ssn 123-45-6789")
        XCTAssertEqual(ssnFindings.map(\.id), ["us-ssn"])
        XCTAssertEqual(ssnFindings.first?.kind, .pii)
    }

    // MARK: - Negative (clean text allowed)

    func testCleanTextIsAllowed() {
        XCTAssertEqual(MemorySecretPIIGate.evaluate("I prefer dark mode and tabs over spaces."), .allow)
        XCTAssertTrue(MemorySecretPIIGate.findings(in: "Nothing sensitive here at all.").isEmpty)
    }

    func testEmptyTextIsAllowed() {
        XCTAssertEqual(MemorySecretPIIGate.evaluate(""), .allow)
    }

    // MARK: - Luhn (must-fix #3): true-positive accepts, false-positive preserved

    func testLuhnValidCreditCardIsDetected() {
        // 4111 1111 1111 1111 is the canonical Luhn-valid Visa test number.
        let findings = MemorySecretPIIGate.findings(in: "card 4111 1111 1111 1111 on file")
        XCTAssertEqual(findings.map(\.id), ["credit-card-number"])
        XCTAssertEqual(findings.first?.kind, .pii)
    }

    func testLuhnInvalidSixteenDigitRunIsNotACard() {
        // 1234 5678 9012 3456 has 16 digits but fails Luhn — must NOT be deleted as
        // a card (this is the data-integrity regression the must-fix prevents).
        let verdict = MemorySecretPIIGate.evaluate("order 1234 5678 9012 3456 shipped", policy: .reject)
        XCTAssertEqual(verdict, .allow)
    }

    func testLuhnHelperDirectly() {
        XCTAssertTrue(MemorySecretPIIGate.passesLuhn("4111111111111111"))
        XCTAssertTrue(MemorySecretPIIGate.passesLuhn("4111 1111 1111 1111"))
        XCTAssertFalse(MemorySecretPIIGate.passesLuhn("1234567890123456"))
        XCTAssertFalse(MemorySecretPIIGate.passesLuhn("4111"))            // too short
        XCTAssertFalse(MemorySecretPIIGate.passesLuhn(String(repeating: "1", count: 20))) // too long
    }

    func testTenDigitPhoneIsNotMisclassifiedAsCreditCard() {
        // A US phone has 10 digits; the card regex needs 13-19, and Luhn guards the
        // rest. The phone must surface as PII phone, never as a card.
        let findings = MemorySecretPIIGate.findings(in: "call 312-555-0199 after noon")
        XCTAssertTrue(findings.map(\.id).contains("us-phone-number"))
        XCTAssertFalse(findings.map(\.id).contains("credit-card-number"))
    }

    // MARK: - IPv4 octet bounds (must-fix #3)

    func testValidIPv4IsDetected() {
        XCTAssertEqual(MemorySecretPIIGate.findings(in: "host 192.168.20.15").map(\.id), ["ipv4-address"])
    }

    func testOutOfRangeIPv4IsPreservedNotDeleted() {
        // 999.888.777.666 is not a real address; deleting it as PII would corrupt a
        // legitimate version-like string.
        XCTAssertEqual(MemorySecretPIIGate.evaluate("ver 999.888.777.666 ok", policy: .reject), .allow)
    }

    func testIPv4OctetHelperDirectly() {
        XCTAssertTrue(MemorySecretPIIGate.hasBoundedIPv4Octets("0.0.0.0"))
        XCTAssertTrue(MemorySecretPIIGate.hasBoundedIPv4Octets("255.255.255.255"))
        XCTAssertFalse(MemorySecretPIIGate.hasBoundedIPv4Octets("256.1.1.1"))
        XCTAssertFalse(MemorySecretPIIGate.hasBoundedIPv4Octets("1.2.3"))      // too few octets
        XCTAssertFalse(MemorySecretPIIGate.hasBoundedIPv4Octets("1.2.3.4.5"))  // too many octets
    }

    // MARK: - Entropy + decode rescan

    func testHighEntropyTokenIsDetected() {
        let token = ["Az9qLm8Pr2Vx7", "Ns4Tu6Wy1Za3", "Qb5Cd7Ef9Gh2", "Jk4Mn6"].joined()
        let findings = MemorySecretPIIGate.findings(in: "blob \(token)")
        XCTAssertEqual(findings.map(\.id), [MemorySecretPIIGate.highEntropyFindingID])
        XCTAssertEqual(findings.first?.kind, .secret)
    }

    func testBase64EncodedSecretIsDetectedViaDecodeRescan() {
        let encoded = Data(("ghp_" + "A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R8").utf8).base64EncodedString()
        let findings = MemorySecretPIIGate.findings(in: "payload \(encoded)")
        XCTAssertTrue(
            findings.map(\.id).contains("github-token"),
            "Expected the decoded github token to surface; got \(findings.map(\.id))"
        )
    }

    func testPrivateKeyMarkerFragmentIsRejected() {
        let marker = ["-----BEGIN", "OPENSSH", "PRIVATE", "KEY-----"].joined(separator: " ")
        let body = """
        setup note
        \(marker)
        """
        let verdict = MemorySecretPIIGate.evaluate(body, policy: .reject)
        guard case .reject(let findings) = verdict else {
            XCTFail("Expected reject for private-key marker fragment, got \(verdict)")
            return
        }
        XCTAssertEqual(findings.map(\.id), ["private-key-marker"])
        XCTAssertEqual(findings.first?.kind, .secret)
    }

    func testDecodedOpenSSHPrivateKeyPayloadIsRejected() {
        let magic = "openssh-key-v1"
        let payload = Data(Array(magic.utf8) + [0x00, 0xFF, 0xFE, 0x80] + Array(repeating: 0x41, count: 32))
        let encoded = payload.base64EncodedString()
        let verdict = MemorySecretPIIGate.evaluate("payload \(encoded)", policy: .reject)
        guard case .reject(let findings) = verdict else {
            XCTFail("Expected reject for decoded private-key payload marker, got \(verdict)")
            return
        }
        XCTAssertEqual(findings.map(\.id), ["openssh-private-key-payload"])
        XCTAssertEqual(findings.first?.kind, .secret)
    }

    func testOpenSSHFormatStringWithoutDecodedNulIsAllowed() {
        let formatMarker = ["openssh", "key", "v1"].joined(separator: "-")
        XCTAssertEqual(
            MemorySecretPIIGate.evaluate("parser handles \(formatMarker) payloads", policy: .reject),
            .allow
        )
    }

    func testPublicKeyMarkerIsAllowed() {
        let marker = ["-----BEGIN", "PUBLIC", "KEY-----"].joined(separator: " ")
        XCTAssertEqual(
            MemorySecretPIIGate.evaluate(marker, policy: .reject),
            .allow
        )
    }

    // MARK: - Redaction (must-fix #4): bounded, fail-closed downgrade

    func testRedactRemovesLocatableSecretSpan() {
        let ssn = "123-45-6789"
        let verdict = MemorySecretPIIGate.evaluate("My ssn is \(ssn) keep the rest.", policy: .redact)
        guard case .redact(let text, let findings) = verdict else {
            XCTFail("Expected redact for a locatable PII span, got \(verdict)")
            return
        }
        XCTAssertFalse(text.contains(ssn), "Redacted text still contains the SSN.")
        XCTAssertTrue(text.contains("[REDACTED-PII]"))
        XCTAssertTrue(text.contains("keep the rest."))
        XCTAssertEqual(findings.map(\.id), ["us-ssn"])
    }

    func testRedactDowngradesToRejectForNonLocatableDecodedSecret() {
        // The secret only exists in a base64-decoded view — there is no span to
        // excise on the original body, so redact MUST fail closed to reject.
        let encoded = Data(("ghp_" + "A1B2C3D4E5F6G7H8I9J0K1L2M3N4O5P6Q7R8").utf8).base64EncodedString()
        let verdict = MemorySecretPIIGate.evaluate("payload \(encoded)", policy: .redact)
        guard case .reject(let findings) = verdict else {
            XCTFail("Expected reject (downgrade) for non-locatable decoded secret, got \(verdict)")
            return
        }
        XCTAssertTrue(findings.map(\.id).contains("github-token"))
    }

    func testRedactRemovesMultipleLocatableSpans() {
        // Exercises the right-to-left, offset-recomputed multi-span path.
        let ssn = "123-45-6789"
        let ip = "192.168.20.15"
        let verdict = MemorySecretPIIGate.evaluate(
            "ssn \(ssn) and host \(ip) remain readable around them.",
            policy: .redact
        )
        guard case .redact(let text, let findings) = verdict else {
            XCTFail("Expected redact for two locatable PII spans, got \(verdict)")
            return
        }
        XCTAssertFalse(text.contains(ssn))
        XCTAssertFalse(text.contains(ip))
        XCTAssertTrue(text.contains("[REDACTED-PII]"))
        XCTAssertTrue(text.contains("remain readable around them."))
        XCTAssertEqual(Set(findings.map(\.id)), ["us-ssn", "ipv4-address"])
    }

    func testRedactCleanTextIsAllow() {
        XCTAssertEqual(MemorySecretPIIGate.evaluate("totally fine note", policy: .redact), .allow)
    }

    // MARK: - Finding-id / label contract carriage (must-fix #1)

    func testFindingCarriesBothIDAndLabel() {
        let body = "key " + ["sk", "ant", String(repeating: "z", count: 20)].joined(separator: "-")
        XCTAssertEqual(MemorySecretPIIGate.findingIDs(in: body), ["anthropic-api-key"])
        XCTAssertEqual(MemorySecretPIIGate.labels(in: body), ["Anthropic API key detected"])
    }

    func testFindingsAreDedupedByID() {
        let key = ["sk", "ant", String(repeating: "a", count: 20)].joined(separator: "-")
        // Two occurrences of the same secret => one finding.
        let ids = MemorySecretPIIGate.findingIDs(in: "\(key) and again \(key)")
        XCTAssertEqual(ids, ["anthropic-api-key"])
    }

    // MARK: - Corpus unavailable: fail-closed (G7 gate audit finding)
    //
    // The gate design contract states: when the secret-pattern corpus is missing
    // or fails to load, `evaluate` MUST return `.reject` with a synthetic
    // `corpus-unavailable` finding — it must NEVER fall through to `.allow`.
    // These tests exercise that branch via the `_evaluate(_:policy:overrideCorpus:)`
    // testing seam, which injects `LoadedCorpus.unavailable` so the test runs
    // without depending on filesystem state.

    func testCorpusUnavailableRejectsEverything_benignText() {
        // Even completely benign text must be rejected when the corpus is missing.
        let verdict = MemorySecretPIIGate._evaluate(
            "I prefer dark mode and tabs over spaces.",
            policy: .reject,
            overrideCorpus: .unavailable
        )
        guard case .reject(let findings) = verdict else {
            XCTFail("Expected .reject when corpus is unavailable, got \(verdict)")
            return
        }
        XCTAssertEqual(
            findings.map(\.id),
            [MemorySecretPIIGate.corpusUnavailableFindingID],
            "Fail-closed finding must carry the stable corpus-unavailable id."
        )
        XCTAssertEqual(
            findings.first?.label,
            MemorySecretPIIGate.corpusUnavailableLabel,
            "Fail-closed finding must carry the daemon-contract label verbatim."
        )
        XCTAssertEqual(
            findings.first?.kind,
            .secret,
            "Corpus-unavailable finding kind must be .secret (existing audit contract)."
        )
    }

    func testCorpusUnavailableRejectsEverything_emptyText() {
        // Even the empty string must be rejected — the gate cannot verify
        // anything without a corpus.
        let verdict = MemorySecretPIIGate._evaluate(
            "",
            policy: .reject,
            overrideCorpus: .unavailable
        )
        guard case .reject(let findings) = verdict else {
            XCTFail("Expected .reject for empty text when corpus is unavailable, got \(verdict)")
            return
        }
        XCTAssertEqual(findings.map(\.id), [MemorySecretPIIGate.corpusUnavailableFindingID])
    }

    func testCorpusUnavailableRejectsUnderRedactPolicy() {
        // The `.redact` policy must ALSO fail closed when the corpus is unavailable;
        // the policy default of `.reject` must not be the only guarded branch.
        let verdict = MemorySecretPIIGate._evaluate(
            "totally fine note",
            policy: .redact,
            overrideCorpus: .unavailable
        )
        guard case .reject(let findings) = verdict else {
            XCTFail("Expected .reject under .redact policy when corpus is unavailable, got \(verdict)")
            return
        }
        XCTAssertEqual(findings.map(\.id), [MemorySecretPIIGate.corpusUnavailableFindingID])
    }

    func testAvailableCorpusStillAllowsBenignText() {
        // Sanity-check: when we do NOT override the corpus (real production path),
        // benign text is still allowed. This pair-test distinguishes "test
        // exercises the unavailable path" from "the gate is just broken globally".
        XCTAssertTrue(
            MemorySecretPIIGate.isAvailable,
            "Production corpus must be available; if not, ALL tests in this class are vacuous."
        )
        let verdict = MemorySecretPIIGate._evaluate(
            "I prefer dark mode and tabs over spaces.",
            policy: .reject,
            overrideCorpus: corpus  // real loaded corpus
        )
        XCTAssertEqual(verdict, .allow, "Benign text must be .allow when corpus is available.")
    }
}

// MARK: - Test-only corpus accessor

// Constructs a minimal available-sentinel `LoadedCorpus` for use in
// `testAvailableCorpusStillAllowsBenignText`. The corpus payload is empty
// (zero patterns) because `_evaluate` delegates to `MemorySecretPIIGate.evaluate`
// (the real production scanner) whenever `overrideCorpus.available == true`, so
// only the `available` flag matters here.
private var corpus: MemorySecretPIIGate.LoadedCorpus {
    MemorySecretPIIGate.LoadedCorpus(
        version: "test-sentinel",
        patterns: [],
        entropy: nil,
        hexEntropy: nil,
        decoding: nil,
        available: true
    )
}
