import XCTest
@testable import OpenBurnBarRecap

/// Extraction of the first balanced JSON object from a model response.
///
/// The interesting property is that it is string-aware: a brace inside a quoted
/// string must not change nesting depth. A naive depth counter gets this wrong the
/// first time a recap headline contains a `{`, and the failure is silent — the
/// object is truncated at the wrong byte and simply fails to decode, which reads
/// downstream as "the model returned nothing useful".
final class RecapJSONTests: XCTestCase {

    // MARK: Plain extraction

    func test_extractsABareObject() {
        XCTAssertEqual(RecapJSON.extractFirstObject(from: #"{"a":1}"#), #"{"a":1}"#)
    }

    func test_ignoresChatterBeforeAndAfter() {
        let text = "Sure! Here is the recap:\n{\"a\":1}\nHope that helps."
        XCTAssertEqual(RecapJSON.extractFirstObject(from: text), #"{"a":1}"#)
    }

    func test_survivesAMarkdownFence() {
        let text = "```json\n{\"headline\":\"Big month\"}\n```"
        XCTAssertEqual(RecapJSON.extractFirstObject(from: text), #"{"headline":"Big month"}"#)
    }

    func test_takesTheFirstObjectWhenSeveralFollow() {
        XCTAssertEqual(RecapJSON.extractFirstObject(from: #"{"a":1} {"b":2}"#), #"{"a":1}"#)
    }

    // MARK: Nesting

    func test_balancesNestedObjects() {
        let json = #"{"outer":{"inner":{"deep":true}},"tail":1}"#
        XCTAssertEqual(RecapJSON.extractFirstObject(from: "noise " + json + " noise"), json)
    }

    func test_balancesObjectsInsideArrays() {
        let json = #"{"cards":[{"id":"a"},{"id":"b"}]}"#
        XCTAssertEqual(RecapJSON.extractFirstObject(from: json), json)
    }

    // MARK: String awareness — the whole reason this is not a depth counter

    /// A brace inside a quoted string must not open or close nesting. Without
    /// string awareness this returns at the `}` inside the headline and yields
    /// `{"headline":"Spend {`, which is not valid JSON.
    func test_bracesInsideStringsDoNotChangeDepth() {
        let json = #"{"headline":"Spend {up} 40%","total":12}"#
        XCTAssertEqual(RecapJSON.extractFirstObject(from: json), json)
    }

    func test_escapedQuotesDoNotEndTheString() {
        let json = #"{"headline":"They said \"more\" {again}","n":1}"#
        XCTAssertEqual(RecapJSON.extractFirstObject(from: json), json)
    }

    /// A trailing backslash inside a string is the nastiest case: the escape flag
    /// must be consumed by the next character, not leak out and swallow the quote.
    func test_escapedBackslashStillClosesTheString() {
        let json = #"{"path":"C:\\","n":1}"#
        XCTAssertEqual(RecapJSON.extractFirstObject(from: json), json)
    }

    // MARK: Nothing to extract

    func test_returnsNilWhenThereIsNoObject() {
        XCTAssertNil(RecapJSON.extractFirstObject(from: "no json at all"))
        XCTAssertNil(RecapJSON.extractFirstObject(from: ""))
    }

    /// Truncated output is the common real failure — a response cut off mid-object
    /// must yield nil rather than a partial string that fails to decode later.
    func test_returnsNilWhenTheObjectNeverCloses() {
        XCTAssertNil(RecapJSON.extractFirstObject(from: #"{"a":1"#))
        XCTAssertNil(RecapJSON.extractFirstObject(from: #"{"a":{"b":1}"#))
        XCTAssertNil(RecapJSON.extractFirstObject(from: #"{"a":"unterminated"#))
    }

    // MARK: decode

    private struct Payload: Decodable, Equatable {
        let headline: String
        let total: Int
    }

    func test_decodesThroughTheFence() {
        let text = "Here you go:\n```json\n{\"headline\":\"Big month\",\"total\":42}\n```"
        XCTAssertEqual(
            RecapJSON.decode(Payload.self, from: text),
            Payload(headline: "Big month", total: 42)
        )
    }

    func test_decodeReturnsNilOnAShapeMismatch() {
        XCTAssertNil(RecapJSON.decode(Payload.self, from: #"{"headline":"only"}"#))
    }

    func test_decodeReturnsNilWhenThereIsNoObject() {
        XCTAssertNil(RecapJSON.decode(Payload.self, from: "nothing here"))
    }
}
