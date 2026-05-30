import XCTest
@testable import OpenBurnBarRemoteAccessAgentCore

final class VirtualHIDBridgeInputPolicyTests: XCTestCase {
    private func assertValidation(
        _ request: VirtualHIDBridgeInputPolicy.Request,
        equals expected: Result<Void, VirtualHIDBridgeInputPolicy.RejectionReason>,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let actual = VirtualHIDBridgeInputPolicy.validate(request)
        switch (actual, expected) {
        case (.success, .success):
            return
        case (.failure(let actualReason), .failure(let expectedReason)):
            XCTAssertEqual(actualReason, expectedReason, file: file, line: line)
        default:
            XCTFail("Expected \(expected), got \(actual)", file: file, line: line)
        }
    }

    func test_rejectsArbitraryTypeInput() {
        let request = VirtualHIDBridgeInputPolicy.Request(
            kind: "type",
            text: "malware",
            key: nil,
            modifiers: nil
        )
        assertValidation(request, equals: .failure(.disallowedTypeOperation))
    }

    func test_rejectsArbitraryKey() {
        let request = VirtualHIDBridgeInputPolicy.Request(
            kind: "key",
            text: nil,
            key: "a",
            modifiers: nil
        )
        assertValidation(request, equals: .failure(.disallowedKey))
    }

    func test_allowsCertifiedEscapeKey() {
        let request = VirtualHIDBridgeInputPolicy.Request(
            kind: "key",
            text: nil,
            key: "escape",
            modifiers: nil
        )
        assertValidation(request, equals: .success(()))
    }

    func test_allowsPointerMoveAndClick() {
        for kind in ["click", "pointer_move"] {
            let request = VirtualHIDBridgeInputPolicy.Request(kind: kind, text: nil, key: nil, modifiers: nil)
            assertValidation(request, equals: .success(()))
        }
    }

    func test_rejectsShortcutWithModifiers() {
        let request = VirtualHIDBridgeInputPolicy.Request(
            kind: "shortcut",
            text: nil,
            key: "escape",
            modifiers: ["command"]
        )
        assertValidation(request, equals: .failure(.disallowedShortcut))
    }
}
