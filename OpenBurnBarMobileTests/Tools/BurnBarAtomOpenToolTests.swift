import XCTest
import Foundation
import OpenBurnBarCore
@testable import OpenBurnBarMobile

@MainActor
final class BurnBarAtomOpenToolTests: XCTestCase {

    func test_descriptor_advertisesAtomURLArgument() throws {
        let tool = BurnBarAtomOpenTool()
        let descriptor = tool.descriptor
        XCTAssertEqual(descriptor["type"] as? String, "function")
        let function = try XCTUnwrap(descriptor["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "burnbar_atom_open")
        let params = try XCTUnwrap(function["parameters"] as? [String: Any])
        let properties = try XCTUnwrap(params["properties"] as? [String: Any])
        XCTAssertNotNil(properties["atom_url"])
        let required = try XCTUnwrap(params["required"] as? [String])
        XCTAssertEqual(required, ["atom_url"])
    }

    func test_execute_callsNavigatorAndReturnsStructuredConfirmation() async throws {
        let tool = BurnBarAtomOpenTool()
        let nav = RecordingNavigator()
        let context = StubToolContext()
        context.capturedAtomNavigator = { nav }

        let result = try await tool.execute(
            arguments: #"{"atom_url":"burnbar://window?value=7d"}"#,
            context: context
        )

        XCTAssertEqual(nav.openCalls.count, 1)
        XCTAssertEqual(nav.openCalls.first, .window(.sevenDays))

        let payload = try XCTUnwrap(parseJSON(result))
        XCTAssertEqual(payload["opened"] as? Bool, true)
        XCTAssertEqual(payload["atom_kind"] as? String, HermesAtomKind.window.rawValue)
        XCTAssertEqual(payload["atom_url"] as? String, "burnbar://window?value=7d")
    }

    func test_execute_rejectsMissingArgument() async {
        let tool = BurnBarAtomOpenTool()
        let context = StubToolContext()
        do {
            _ = try await tool.execute(arguments: "{}", context: context)
            XCTFail("expected invalidArguments")
        } catch let error as MobileToolError {
            switch error {
            case .invalidArguments(let message):
                XCTAssertTrue(message.contains("atom_url"))
            default:
                XCTFail("expected invalidArguments, got \(error)")
            }
        } catch {
            XCTFail("expected MobileToolError, got \(error)")
        }
    }

    func test_execute_rejectsUnparseableURL() async {
        let tool = BurnBarAtomOpenTool()
        let context = StubToolContext()
        do {
            _ = try await tool.execute(
                arguments: #"{"atom_url":"https://example.com"}"#,
                context: context
            )
            XCTFail("expected invalidArguments")
        } catch let error as MobileToolError {
            switch error {
            case .invalidArguments(let message):
                XCTAssertTrue(message.contains("decode"))
            default:
                XCTFail("expected invalidArguments, got \(error)")
            }
        } catch {
            XCTFail("expected MobileToolError, got \(error)")
        }
    }

    func test_execute_failsWhenNoNavigatorInstalled() async {
        let tool = BurnBarAtomOpenTool()
        let context = StubToolContext()
        context.capturedAtomNavigator = { nil }
        do {
            _ = try await tool.execute(
                arguments: #"{"atom_url":"burnbar://window?value=today"}"#,
                context: context
            )
            XCTFail("expected toolDisabled")
        } catch let error as MobileToolError {
            switch error {
            case .toolDisabled:
                break
            default:
                XCTFail("expected toolDisabled, got \(error)")
            }
        } catch {
            XCTFail("expected MobileToolError, got \(error)")
        }
    }

    // MARK: - Helpers

    private func parseJSON(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data, options: [])) as? [String: Any]
    }
}

// MARK: - Recording Navigator

@MainActor
private final class RecordingNavigator: HermesAtomNavigator {
    var openCalls: [HermesAtom] = []
    func open(_ atom: HermesAtom) {
        openCalls.append(atom)
    }
}
