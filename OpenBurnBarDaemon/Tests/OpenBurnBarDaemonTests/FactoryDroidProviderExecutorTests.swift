import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import Foundation
import XCTest

final class FactoryDroidProviderExecutorTests: XCTestCase {
    func testFactoryExecutorBuildsReadOnlyDroidCommandAndReturnsChatCompletion() async throws {
        let runner = RecordingFactoryDroidRunner(
            result: FactoryDroidProcessResult(
                exitCode: 0,
                stdout: #"{"result":"Factory answer"}"#,
                stderr: ""
            )
        )
        let executor = FactoryDroidProviderExecutor(runner: runner, timeout: 1)
        let route = factoryRoute(modelID: "gpt-5.5", apiKey: "fk-secret")

        let response = try await executor.proxyChatCompletions(
            body: Data(#"{"model":"gpt-5.5","messages":[{"role":"user","content":"hello"}]}"#.utf8),
            route: route
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.contentType, "application/json")
        let body = String(decoding: response.body, as: UTF8.self)
        XCTAssertTrue(body.contains("Factory answer"))
        XCTAssertEqual(runner.lastEnvironment?["FACTORY_API_KEY"], "fk-secret")
        XCTAssertEqual(runner.lastArguments?.prefix(2), ["exec", "--model"])
        XCTAssertTrue(runner.lastArguments?.contains("--disabled-tools") == true)
        XCTAssertFalse(runner.lastArguments?.contains("--auto") == true)
        XCTAssertFalse(runner.lastArguments?.contains("--skip-permissions-unsafe") == true)
    }

    func testFactoryExecutorMapsStandardToDroidCoreDowngradeAsExhausted() async throws {
        let runner = RecordingFactoryDroidRunner(
            result: FactoryDroidProcessResult(
                exitCode: 0,
                stdout: #"{"result":"Using Droid Core after Standard Usage is exhausted"}"#,
                stderr: ""
            )
        )
        let executor = FactoryDroidProviderExecutor(runner: runner, timeout: 1)

        do {
            _ = try await executor.proxyChatCompletions(
                body: Data(#"{"model":"gpt-5.5","messages":[{"role":"user","content":"hello"}]}"#.utf8),
                route: factoryRoute(modelID: "gpt-5.5", apiKey: "fk-secret")
            )
            XCTFail("Expected Factory Standard downgrade to be rejected")
        } catch let error as BurnBarProviderExecutorError {
            guard case .upstreamError(let status, let body) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 402)
            XCTAssertTrue(body.contains("Droid Core fallback is disabled"))
        }
    }

    func testFactoryExecutorAllowsDroidCoreSignalsForDroidCoreModels() async throws {
        let runner = RecordingFactoryDroidRunner(
            result: FactoryDroidProcessResult(
                exitCode: 0,
                stdout: #"{"result":"Droid Core answer"}"#,
                stderr: "Droid Core"
            )
        )
        let executor = FactoryDroidProviderExecutor(runner: runner, timeout: 1)

        let response = try await executor.proxyChatCompletions(
            body: Data(#"{"model":"glm-5.1","messages":[{"role":"user","content":"hello"}]}"#.utf8),
            route: factoryRoute(modelID: "glm-5.1", apiKey: "fk-secret")
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(String(decoding: response.body, as: UTF8.self).contains("Droid Core answer"))
    }

    func testFactoryExecutorClassifiesAskMeStandardLimitAsExhaustedAndRedactsKey() async throws {
        let runner = RecordingFactoryDroidRunner(
            result: FactoryDroidProcessResult(
                exitCode: 1,
                stdout: "",
                stderr: "Ask me when I run out: Standard Usage exhausted for fk-secret"
            )
        )
        let executor = FactoryDroidProviderExecutor(runner: runner, timeout: 1)

        do {
            _ = try await executor.proxyChatCompletions(
                body: Data(#"{"model":"gpt-5.5","messages":[{"role":"user","content":"hello"}]}"#.utf8),
                route: factoryRoute(modelID: "gpt-5.5", apiKey: "fk-secret")
            )
            XCTFail("Expected Factory limit to be rejected")
        } catch let error as BurnBarProviderExecutorError {
            guard case .upstreamError(let status, let body) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(status, 402)
            XCTAssertFalse(body.contains("fk-secret"))
            XCTAssertTrue(body.contains("<redacted>"))
        }
    }

    func testFactoryReasoningEffortMapsUnsupportedMaxForGPTToXHigh() {
        let variant = BurnBarModelVariant(
            variantID: "gpt-5.5-max",
            label: "Max",
            baseModelID: "gpt-5.5",
            thinkingLevel: .max
        )
        XCTAssertEqual(
            FactoryDroidProviderExecutor.droidReasoningEffort(for: "gpt-5.5", variant: variant),
            "xhigh"
        )
    }

    private func factoryRoute(modelID: String, apiKey: String) -> BurnBarProviderRoute {
        BurnBarProviderRoute(
            providerID: "factory",
            providerDisplayName: "Factory Droid",
            credentialSlotID: "max-a",
            credentialSlotLabel: "Factory Max A",
            baseURL: "factory-droid://local",
            requestedModel: modelID,
            resolvedModelID: modelID,
            apiKey: apiKey,
            pricing: .defaultFallback,
            modelCapabilityClassID: modelID == "glm-5.1" ? "factory-droid-core:glm-5.1" : "openai:gpt-5.5",
            formatFamily: .openaiCompat
        )
    }
}

final class RecordingFactoryDroidRunner: FactoryDroidProcessRunning, @unchecked Sendable {
    private let result: FactoryDroidProcessResult
    nonisolated(unsafe) private(set) var lastArguments: [String]?
    nonisolated(unsafe) private(set) var lastEnvironment: [String: String]?

    init(result: FactoryDroidProcessResult) {
        self.result = result
    }

    func runDroid(arguments: [String], environment: [String: String], timeout: TimeInterval) async throws -> FactoryDroidProcessResult {
        lastArguments = arguments
        lastEnvironment = environment
        return result
    }
}
