import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Three-way parity between the Swift contract, the Kotlin mirror, and
/// `firestore.rules`.
///
/// The AI Inbox document shape is declared in three languages that no compiler
/// checks against each other:
///
///   • Swift   — `BurnBarAIInboxContracts.swift` / `AIInboxMirrorRecord.swift`
///   • Kotlin  — `android/…/data/inbox/AIInboxItem.kt`
///   • Rules   — `firestore.rules`, `validAIInboxMirror()`
///
/// Every drift between them fails SILENTLY and in a different direction:
///
///   • a field the encoder writes but the rules allowlist omits → Firestore
///     rejects EVERY write, and the phone shows an empty inbox
///   • a kind the rules accept but Kotlin does not know → Android renders it as
///     a generic notice (survivable, by design — see the forward-compat tests)
///   • a kind Swift emits that the rules reject → that detector's items never
///     leave the Mac, and only that detector goes quiet
///
/// None of those produce a crash, a log line, or a red build. This suite is the
/// only thing standing between a one-word typo and a feature that looks like it
/// is working while showing nothing.
///
/// The files are read from source rather than imported because two of them are
/// not Swift.
final class AIInboxCrossPlatformContractTests: XCTestCase {
    // MARK: - Expected vocabulary
    //
    // Declared literally rather than derived, so widening the vocabulary is a
    // deliberate edit here plus three implementations — never an accident in one.

    private static let expectedKinds: Set<String> = [
        "ci_waste",
        "promised_not_landed",
        "uncommitted_work",
        "cost_anomaly",
        "stuck_pr",
        "index_health",
        "brief",
        "budget",
        "system"
    ]

    private static let expectedStates: Set<String> = ["new", "updated", "resolved", "expired"]

    // MARK: - Source access

    private static func repositoryRoot() -> URL? {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            url = url.deletingLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("AGENTS.md").path) {
                return url
            }
        }
        return nil
    }

    private static func source(_ relativePath: String) throws -> String? {
        guard let root = repositoryRoot() else { return nil }
        let url = root.appendingPathComponent(relativePath)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("Missing contract source: \(relativePath)")
            return nil
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// Isolates `validAIInboxMirror()` so a `kind in [...]` list elsewhere in the
    /// rules file (the Hermes relay chunk kinds, for one) cannot be mistaken for
    /// the inbox's.
    private static func inboxRulesBlock(_ rules: String) -> String? {
        guard let start = rules.range(of: "function validAIInboxMirror()") else { return nil }
        let remainder = rules[start.upperBound...]
        guard let end = remainder.range(of: "\n      }") else { return nil }
        return String(remainder[..<end.lowerBound])
    }

    /// Extracts the quoted strings from the bracketed list that follows `marker`.
    ///
    /// `marker` is expected to END with the opening bracket, so the scan starts
    /// inside the list. Values are read by walking quote pairs rather than by
    /// splitting on `"` and taking odd indices — the latter silently returns an
    /// empty set when the text preceding the first quote is itself empty, which
    /// is exactly what a marker ending in `[` produces.
    private static func quotedValues(in text: String, after marker: String) -> Set<String>? {
        guard let markerRange = text.range(of: marker) else { return nil }
        let remainder = text[markerRange.upperBound...]
        guard let close = remainder.firstIndex(of: "]") else { return nil }

        var values: Set<String> = []
        var cursor = remainder[..<close][...]
        while let open = cursor.firstIndex(of: "\"") {
            let afterOpen = cursor.index(after: open)
            guard afterOpen < cursor.endIndex,
                  let end = cursor[afterOpen...].firstIndex(of: "\"") else { break }
            values.insert(String(cursor[afterOpen..<end]))
            cursor = cursor[cursor.index(after: end)...]
        }
        return values
    }

    // MARK: - Swift is the source of truth

    func test_swiftDeclaresTheExpectedVocabulary() {
        XCTAssertEqual(Set(BurnBarInboxItemKind.allCases.map(\.rawValue)), Self.expectedKinds)
        XCTAssertEqual(Set(BurnBarInboxItemState.allCases.map(\.rawValue)), Self.expectedStates)
    }

    // MARK: - Rules agree with Swift

    func test_firestoreRulesAcceptExactlyTheSwiftVocabulary() throws {
        guard let rules = try Self.source("firestore.rules"),
              let block = Self.inboxRulesBlock(rules) else {
            throw XCTSkip("firestore.rules is not reachable from this environment.")
        }

        let kinds = try XCTUnwrap(
            Self.quotedValues(in: block, after: ".kind in ["),
            "Could not read the kind allowlist from validAIInboxMirror()"
        )
        XCTAssertEqual(
            kinds,
            Self.expectedKinds,
            """
            firestore.rules and Swift disagree on item kinds. A kind Swift emits \
            but the rules reject means that detector's items never leave the Mac — \
            silently, and only for that detector.
            """
        )

        let states = try XCTUnwrap(Self.quotedValues(in: block, after: ".state in ["))
        XCTAssertEqual(states, Self.expectedStates)
    }

    /// The encoder's output must be a SUBSET of the rules allowlist: `hasOnly`
    /// rejects the entire write for one unlisted key.
    func test_firestoreRulesAllowlistCoversEveryEncodedField() throws {
        guard let rules = try Self.source("firestore.rules"),
              let block = Self.inboxRulesBlock(rules) else {
            throw XCTSkip("firestore.rules is not reachable from this environment.")
        }

        let allowed = try XCTUnwrap(Self.quotedValues(in: block, after: "keys().hasOnly(["))
        XCTAssertEqual(
            allowed,
            Set(AIInboxMirrorCodec.documentKeys),
            "AIInboxMirrorCodec.documentKeys and the rules allowlist must match exactly"
        )
    }

    func test_itemStateRulesAllowlistMatchesTheCodec() throws {
        guard let rules = try Self.source("firestore.rules") else {
            throw XCTSkip("firestore.rules is not reachable from this environment.")
        }
        guard let start = rules.range(of: "function validAIInboxItemState()") else {
            XCTFail("Missing validAIInboxItemState() in firestore.rules")
            return
        }
        let block = String(rules[start.upperBound...].prefix(2_000))

        let allowed = try XCTUnwrap(Self.quotedValues(in: block, after: "keys().hasOnly(["))
        XCTAssertEqual(allowed, Set(AIInboxMirrorCodec.stateDocumentKeys))

        let feedback = try XCTUnwrap(Self.quotedValues(in: block, after: ".feedback in ["))
        XCTAssertEqual(
            feedback,
            Set(AIInboxMirrorCodec.allowedFeedbackValues),
            "Feedback is a closed vocabulary so it cannot become a free-text channel"
        )
    }

    // MARK: - Kotlin agrees with Swift

    func test_kotlinEnumsMirrorTheSwiftVocabulary() throws {
        guard let kotlin = try Self.source(
            "android/app/src/main/java/com/openburnbar/data/inbox/AIInboxItem.kt"
        ) else {
            throw XCTSkip("The Android contract is not reachable from this environment.")
        }

        for (enumName, expected) in [
            ("AIInboxItemKind", Self.expectedKinds),
            ("AIInboxItemState", Self.expectedStates)
        ] {
            guard let start = kotlin.range(of: "enum class \(enumName)") else {
                XCTFail("Missing Kotlin enum \(enumName)")
                continue
            }
            let remainder = kotlin[start.upperBound...]
            guard let end = remainder.range(of: "\n}") else {
                XCTFail("Could not delimit Kotlin enum \(enumName)")
                continue
            }
            let body = String(remainder[..<end.lowerBound])
            let tokens = Set(
                body
                    .split(separator: "\n")
                    .compactMap { line -> String? in
                        guard let open = line.firstIndex(of: "\""),
                              let close = line.lastIndex(of: "\""),
                              open < close else { return nil }
                        return String(line[line.index(after: open)..<close])
                    }
                    .filter { $0.isEmpty == false }
            )
            XCTAssertEqual(
                tokens,
                expected,
                """
                Kotlin \(enumName) has drifted from Swift. Android decodes by exact \
                token match, so a mismatch here drops or miscategorizes items with no error.
                """
            )
        }
    }

    /// The Kotlin AAD must bind the same four values as Swift, or nothing the Mac
    /// seals will open on Android.
    func test_kotlinBindsTheSameAAD() throws {
        guard let kotlin = try Self.source(
            "android/app/src/main/java/com/openburnbar/data/inbox/AIInboxRefreshParts.kt"
        ) else {
            throw XCTSkip("The Android contract is not reachable from this environment.")
        }

        XCTAssertTrue(
            kotlin.contains("collection = AIInboxMirrorCodec.COLLECTION"),
            "The Android AAD must bind the same collection Swift seals with"
        )
        XCTAssertTrue(
            kotlin.contains("field = AIInboxMirrorCodec.SEALED_PAYLOAD_FIELD"),
            "The Android AAD must bind the same field Swift seals with"
        )
        XCTAssertTrue(
            kotlin.contains("docID = documentID"),
            "The AAD must bind the document id so a relocated document cannot decrypt"
        )
    }

    func test_kotlinCollectionConstantsMatchSwift() throws {
        guard let kotlin = try Self.source(
            "android/app/src/main/java/com/openburnbar/data/inbox/AIInboxItem.kt"
        ) else {
            throw XCTSkip("The Android contract is not reachable from this environment.")
        }

        XCTAssertTrue(
            kotlin.contains("\"\(AIInboxMirrorCodec.collection)\""),
            "Kotlin must read from \(AIInboxMirrorCodec.collection)"
        )
        XCTAssertTrue(
            kotlin.contains("\"\(AIInboxMirrorCodec.stateCollection)\""),
            "Kotlin must write to \(AIInboxMirrorCodec.stateCollection)"
        )
        XCTAssertTrue(kotlin.contains("\"\(AIInboxMirrorCodec.sealedPayloadField)\""))
    }
}
