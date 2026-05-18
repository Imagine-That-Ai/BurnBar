import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

final class ComputerUseRunCoordinatorPlaywrightScenarioTests: XCTestCase {
    func testLocalBrowserScenarioInStepModeUsesExplicitApprovalsAndWritesAuditChain() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_COMPUTER_USE_PLAYWRIGHT_SCENARIOS"] == "1",
            "Set RUN_COMPUTER_USE_PLAYWRIGHT_SCENARIOS=1 to run real Playwright coordinator scenarios."
        )

        let proof = try await runLocalBrowserScenario(trustMode: .step, scopeOutcome: .notMatched)

        XCTAssertEqual(proof.responseCount, 7)
        XCTAssertEqual(proof.approvalRequests.count, 7)
        XCTAssertEqual(Set(proof.approvalRequests.compactMap(\.trustMode)), [ComputerUseTrustMode.step.rawValue])
        XCTAssertEqual(proof.auditEntries.count, 7)
        XCTAssertEqual(proof.auditEntries.map(\.entryIndex), Array(0..<7))
        XCTAssertEqual(Set(proof.auditEntries.map(\.approvedBy)), [.mac])
        XCTAssertEqual(
            proof.auditEntries.compactMap(\.approvalId),
            proof.approvalRequests.map(\.approvalId)
        )
        XCTAssertTrue(proof.auditEntries.allSatisfy { $0.denyReason == nil })
        XCTAssertEqual(proof.finalExtractedText, "hello Hermes")
        XCTAssertGreaterThan(proof.screenshotBytes, 1_000)
    }

    func testLocalBrowserScenarioInTrustedModeSkipsApprovalsAndWritesTrustedScopeAuditChain() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_COMPUTER_USE_PLAYWRIGHT_SCENARIOS"] == "1",
            "Set RUN_COMPUTER_USE_PLAYWRIGHT_SCENARIOS=1 to run real Playwright coordinator scenarios."
        )

        let allowRule = ComputerUseScopeRuleID(rawValue: "allow-local-playwright")
        let proof = try await runLocalBrowserScenario(
            trustMode: .trusted,
            scopeOutcome: .allowed(rule: allowRule)
        )

        XCTAssertEqual(proof.responseCount, 7)
        XCTAssertTrue(proof.approvalRequests.isEmpty)
        XCTAssertEqual(proof.auditEntries.count, 7)
        XCTAssertEqual(proof.auditEntries.map(\.entryIndex), Array(0..<7))
        XCTAssertEqual(Set(proof.auditEntries.map(\.approvedBy)), [.trustedScope])
        XCTAssertTrue(proof.auditEntries.allSatisfy { $0.approvalId == nil })
        XCTAssertTrue(proof.auditEntries.allSatisfy { $0.scopeRuleId == allowRule.rawValue })
        XCTAssertTrue(proof.auditEntries.allSatisfy { $0.denyReason == nil })
        XCTAssertEqual(proof.finalExtractedText, "hello Hermes")
        XCTAssertGreaterThan(proof.screenshotBytes, 1_000)
    }

    func testFiftyLocalBrowserScenariosValidateAuditChainEveryRun() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["RUN_COMPUTER_USE_PLAYWRIGHT_50_RUN_GATE"] == "1",
            "Set RUN_COMPUTER_USE_PLAYWRIGHT_50_RUN_GATE=1 to run the Phase 9 50-run audit-chain gate."
        )

        let started = Date()
        var totalResponses = 0
        var totalAuditEntries = 0
        for run in 1...50 {
            let trustMode: ComputerUseTrustMode = run.isMultiple(of: 2) ? .trusted : .step
            let scopeOutcome: ComputerUseScopeOutcome
            if trustMode == .trusted {
                scopeOutcome = .allowed(rule: ComputerUseScopeRuleID(rawValue: "allow-local-playwright-\(run)"))
            } else {
                scopeOutcome = .notMatched
            }
            let proof = try await runLocalBrowserScenario(
                trustMode: trustMode,
                scopeOutcome: scopeOutcome
            )
            XCTAssertEqual(proof.responseCount, 7, "run \(run)")
            XCTAssertEqual(proof.auditValidation.entryCount, 7, "run \(run)")
            XCTAssertTrue(proof.auditValidation.isValid, "run \(run): \(String(describing: proof.auditValidation.firstInvalidReason))")
            totalResponses += proof.responseCount
            totalAuditEntries += proof.auditEntries.count
        }

        let elapsedMillis = Int(Date().timeIntervalSince(started) * 1_000)
        print("phase9_50_run_gate runs=50 responses=\(totalResponses) auditEntries=\(totalAuditEntries) elapsedMs=\(elapsedMillis)")
        XCTAssertEqual(totalResponses, 350)
        XCTAssertEqual(totalAuditEntries, 350)
    }

    private func runLocalBrowserScenario(
        trustMode: ComputerUseTrustMode,
        scopeOutcome: ComputerUseScopeOutcome
    ) async throws -> BrowserScenarioProof {
        let sessionId = ComputerUseSessionID.newRandom()
        let auditBaseDirectory = testAuditBaseDirectory()
        let approvals = ApprovalRecorder(decision: .approve)
        let coordinator = makeCoordinator(
            approvalIssuer: { request in
                try await approvals.issue(request)
            },
            auditBaseDirectory: auditBaseDirectory
        )
        let manifest = manifest(sessionId: sessionId, trustMode: trustMode)
        let driver = try await makeRealPlaywrightDriver(sessionId: sessionId)
        _ = try await coordinator.startSession(manifest: manifest, playwrightDriver: driver)
        defer { Task { await driver.stop() } }

        let context = ComputerUseScopeContext(url: "https://openburnbar.test/computer-use/local-scenario")
        let capabilityContext = capability(for: ComputerUseSessionState(
            sessionId: sessionId,
            manifest: manifest,
            liveTrustMode: trustMode
        ))

        let page = dataURL(
            title: "Coordinator Browser Scenario",
            body: """
            <input id="name" />
            <button id="submit" onclick="document.querySelector('#out').textContent='hello ' + document.querySelector('#name').value">Submit</button>
            <select id="choice" onchange="document.querySelector('#out').textContent=this.value">
              <option value="alpha">Alpha</option>
              <option value="beta">Beta</option>
            </select>
            <script>
              window.addEventListener('keydown', (event) => {
                if (event.key === 'Enter') document.querySelector('#out').textContent = 'entered';
              });
            </script>
            <div id="out">unset</div>
            """
        )

        var responses: [ComputerUseInvokeResponse] = []
        responses.append(await invoke(
            coordinator,
            sessionId: sessionId,
            tool: .browserGoto,
            arguments: .object(["url": .string(page), "timeoutMillis": .number(10_000)]),
            scopeContext: context,
            scopeOutcome: scopeOutcome,
            capability: capabilityContext
        ))
        responses.append(await invoke(
            coordinator,
            sessionId: sessionId,
            tool: .browserFill,
            arguments: .object(["selector": .string("#name"), "text": .string("Hermes")]),
            scopeContext: context,
            scopeOutcome: scopeOutcome,
            capability: capabilityContext
        ))
        responses.append(await invoke(
            coordinator,
            sessionId: sessionId,
            tool: .browserClick,
            arguments: .object(["selector": .string("#submit")]),
            scopeContext: context,
            scopeOutcome: scopeOutcome,
            capability: capabilityContext
        ))
        responses.append(await invoke(
            coordinator,
            sessionId: sessionId,
            tool: .browserSelect,
            arguments: .object(["selector": .string("#choice"), "value": .string("beta")]),
            scopeContext: context,
            scopeOutcome: scopeOutcome,
            capability: capabilityContext
        ))
        responses.append(await invoke(
            coordinator,
            sessionId: sessionId,
            tool: .browserKey,
            arguments: .object(["key": .string("Enter")]),
            scopeContext: context,
            scopeOutcome: scopeOutcome,
            capability: capabilityContext
        ))
        let extract = await invoke(
            coordinator,
            sessionId: sessionId,
            tool: .browserExtract,
            arguments: .object(["selector": .string("#out")]),
            scopeContext: context,
            scopeOutcome: scopeOutcome,
            capability: capabilityContext
        )
        responses.append(extract)
        let screenshot = await invoke(
            coordinator,
            sessionId: sessionId,
            tool: .browserScreenshot,
            arguments: .object([:]),
            scopeContext: context,
            scopeOutcome: scopeOutcome,
            capability: capabilityContext
        )
        responses.append(screenshot)

        for response in responses {
            XCTAssertEqual(response.status, .executed, response.denyReason ?? "unexpected non-executed status")
            XCTAssertEqual(response.result?.succeeded, true, String(describing: response.result?.output))
        }
        let finalAuditHeadHashHex = try XCTUnwrap(responses.last?.auditHeadHashHex)
        let auditValidation = try validateAuditChain(
            baseDirectory: auditBaseDirectory,
            sessionId: sessionId,
            manifest: manifest,
            expectedHeadHashHex: finalAuditHeadHashHex
        )

        return BrowserScenarioProof(
            responseCount: responses.count,
            approvalRequests: approvals.requests,
            auditEntries: try auditEntries(baseDirectory: auditBaseDirectory, sessionId: sessionId),
            auditValidation: auditValidation,
            finalExtractedText: textOutput(from: extract),
            screenshotBytes: screenshotSize(from: screenshot)
        )
    }

    private func invoke(
        _ coordinator: ComputerUseRunCoordinator,
        sessionId: ComputerUseSessionID,
        tool: BurnBarToolKind,
        arguments: BurnBarJSONValue,
        scopeContext: ComputerUseScopeContext,
        scopeOutcome: ComputerUseScopeOutcome,
        capability: ComputerUseCapabilityContext
    ) async -> ComputerUseInvokeResponse {
        await coordinator.invoke(
            sessionId: sessionId,
            invocation: BurnBarToolInvocation(
                callID: UUID().uuidString,
                runID: BurnBarRunID(rawValue: "run-\(UUID().uuidString)"),
                tool: tool,
                arguments: arguments,
                requestedBy: BurnBarClientID(rawValue: "client"),
                requestedAt: Date()
            ),
            scopeContext: scopeContext,
            scopeOutcome: scopeOutcome,
            accessibilityDeny: nil,
            capability: capability
        )
    }

    private func makeCoordinator(
        approvalIssuer: @escaping ComputerUseRunCoordinator.ApprovalIssuer,
        auditBaseDirectory: URL
    ) -> ComputerUseRunCoordinator {
        ComputerUseRunCoordinator(
            approvalIssuer: approvalIssuer,
            macAppVersion: "test",
            auditBaseDirectory: auditBaseDirectory,
            logger: BurnBarDaemonLogger(category: "cu-playwright-scenario-tests")
        )
    }

    private func manifest(
        sessionId: ComputerUseSessionID,
        trustMode: ComputerUseTrustMode
    ) -> ComputerUseSessionManifest {
        ComputerUseSessionManifest(
            sessionId: sessionId,
            mode: .browser,
            trustMode: trustMode,
            startedAt: Date(),
            userId: "test-user",
            entitlementProductId: "com.openburnbar.hostedComputerUseSync.monthly",
            actionCap: 50,
            sessionTimeoutSeconds: 1_800
        )
    }

    private func capability(for state: ComputerUseSessionState) -> ComputerUseCapabilityContext {
        ComputerUseCapabilityContext(
            entitlement: ComputerUseEntitlementSnapshot(
                isActive: true,
                productId: "com.openburnbar.hostedComputerUseSync.monthly",
                allowsBrowser: true,
                allowsSystem: true,
                allowsPhoneControl: true,
                allowsTrustedScopes: true,
                allowsAuditExport: true
            ),
            envelope: .initialNormal,
            usage: ComputerUseQuotaUsage(dayKey: "2026-05-17"),
            session: state,
            concurrentSessionActive: false,
            killSwitch: false,
            accessibilityTrusted: false
        )
    }

    private func makeRealPlaywrightDriver(sessionId: ComputerUseSessionID) async throws -> OpenBurnBarPlaywrightDriver {
        let node = try XCTUnwrap(nodeExecutablePath())
        let driver = OpenBurnBarPlaywrightDriver(
            configuration: OpenBurnBarPlaywrightDriver.Configuration(
                nodeExecutablePath: node,
                bridgeScriptPath: bridgeScriptPath(),
                headless: true,
                perActionTimeoutMillis: 15_000
            ),
            sessionId: sessionId,
            logger: BurnBarDaemonLogger(category: "cu-playwright-scenario-driver")
        )
        try await driver.start()
        return driver
    }

    private func dataURL(title: String, body: String) -> String {
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <title>\(title)</title>
          <style>
            body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 32px; }
            button, input, select { font: inherit; margin: 8px 0; padding: 8px 10px; }
          </style>
        </head>
        <body>\(body)</body>
        </html>
        """
        return "data:text/html;charset=utf-8,\(html.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")"
    }

    private func textOutput(from response: ComputerUseInvokeResponse) -> String? {
        guard case let .object(output)? = response.result?.output,
              case let .string(text)? = output["text"] else { return nil }
        return text
    }

    private func screenshotSize(from response: ComputerUseInvokeResponse) -> Int {
        guard case let .object(output)? = response.result?.output,
              case let .number(size)? = output["sizeBytes"] else { return 0 }
        return Int(size)
    }

    private func auditEntries(
        baseDirectory: URL,
        sessionId: ComputerUseSessionID
    ) throws -> [ComputerUseAuditEntry] {
        let chainURL = baseDirectory
            .appendingPathComponent(sessionId.rawValue, isDirectory: true)
            .appendingPathComponent("chain.jsonl")
        let data = try Data(contentsOf: chainURL)
        let lines = try XCTUnwrap(String(data: data, encoding: .utf8)?
            .split(separator: "\n"))
        return try lines.map { line in
            try ComputerUseAuditHasher.canonicalJSONDecoder.decode(
                ComputerUseAuditEntry.self,
                from: Data(line.utf8)
            )
        }
    }

    private func validateAuditChain(
        baseDirectory: URL,
        sessionId: ComputerUseSessionID,
        manifest: ComputerUseSessionManifest,
        expectedHeadHashHex: String
    ) throws -> ComputerUseAuditChain.ValidationResult {
        let chainURL = baseDirectory
            .appendingPathComponent(sessionId.rawValue, isDirectory: true)
            .appendingPathComponent("chain.jsonl")
        let chain = ComputerUseAuditChain()
        let manifestHashHex = try chain.hashSessionManifest(manifest)
        return try chain.validate(
            at: chainURL,
            sessionManifestHashHex: manifestHashHex,
            expectedHeadHashHex: expectedHeadHashHex
        )
    }

    private func testAuditBaseDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-cu-playwright-scenarios-\(UUID().uuidString)", isDirectory: true)
    }

    private func bridgeScriptPath() -> URL {
        repoRoot()
            .appendingPathComponent("OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js")
    }

    private func repoRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func nodeExecutablePath() -> String? {
        let candidates = [
            ProcessInfo.processInfo.environment["NODE_EXECUTABLE"],
            ProcessInfo.processInfo.environment["NODE_BINARY"],
            "/Users/albertonunez/.local/bin/node",
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node"
        ].compactMap { $0 }

        if let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) {
            return path
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["which", "node"]
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path, FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }
}

private struct BrowserScenarioProof {
    let responseCount: Int
    let approvalRequests: [HermesRealtimeRelayApprovalRequest]
    let auditEntries: [ComputerUseAuditEntry]
    let auditValidation: ComputerUseAuditChain.ValidationResult
    let finalExtractedText: String?
    let screenshotBytes: Int
}

private final class ApprovalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var requests: [HermesRealtimeRelayApprovalRequest] = []
    private let decision: HermesRealtimeRelayApprovalResponse.Decision

    init(decision: HermesRealtimeRelayApprovalResponse.Decision) {
        self.decision = decision
    }

    func issue(_ request: HermesRealtimeRelayApprovalRequest) async throws -> HermesRealtimeRelayApprovalResponse {
        lock.withLock { requests.append(request) }
        return HermesRealtimeRelayApprovalResponse(
            approvalId: request.approvalId,
            decision: decision,
            respondedBy: "mac",
            respondedAt: Date()
        )
    }
}
