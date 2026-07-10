import Foundation
import OpenBurnBarCore
import XCTest
@testable import OpenBurnBarDaemon

final class BurnBarProviderExternalAuthServiceTests: XCTestCase {
    private final class StateBox<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func read() -> Value {
            lock.lock()
            defer { lock.unlock() }
            return value
        }

        func write(_ newValue: Value) {
            lock.lock()
            value = newValue
            lock.unlock()
        }
    }

    private struct Fixture {
        let root: URL
        let executable: URL
        let now: StateBox<Date>
        let auth: StateBox<CLIAuthInfo>
        let launches: StateBox<[URL]>
        let service: BurnBarProviderExternalAuthService
    }

    func testStartAndVerifiedStatusUseDefaultCLIStateWithoutSensitivePersistence() async throws {
        let fixture = try makeFixture(cliType: .codex)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let started = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        ))

        XCTAssertEqual(started.flow.state, .awaitingUser)
        XCTAssertEqual(started.flow.flowID, "11111111-1111-1111-1111-111111111111")
        XCTAssertEqual(fixture.launches.read().count, 1)
        let scriptURL = try XCTUnwrap(fixture.launches.read().first)
        XCTAssertEqual(permissions(at: fixture.root), 0o700)
        XCTAssertEqual(permissions(at: scriptURL.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(permissions(at: scriptURL), 0o700)
        let startedURL = scriptURL.deletingLastPathComponent().appendingPathComponent("started.ready")
        XCTAssertEqual(permissions(at: startedURL), 0o600)
        XCTAssertEqual(try String(contentsOf: startedURL, encoding: .utf8), "started\n")

        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertTrue(script.contains("STARTED_DEFAULT="))
        XCTAssertTrue(script.contains("STARTED=\"${1:-$STARTED_DEFAULT}\""))
        XCTAssertTrue(script.contains("ACCEPTED=\"${2:-}\""))
        XCTAssertTrue(script.contains("launch.accepted.*"))
        XCTAssertTrue(script.contains("while [ ! -f \"$ACCEPTED\" ]"))
        XCTAssertTrue(script.contains("printf 'started\\n' > \"$started_tmp\" || exit 125"))
        XCTAssertLessThan(
            try XCTUnwrap(script.range(of: "printf 'started\\n'")?.lowerBound),
            try XCTUnwrap(script.range(of: "set +e")?.lowerBound)
        )
        XCTAssertTrue(script.contains("unset CODEX_HOME CODEX_CONFIG_PATH"))
        XCTAssertTrue(script.contains("'login'"))
        XCTAssertTrue(script.contains("'auth' 'login'"))
        XCTAssertTrue(script.contains("cancel.requested"))
        XCTAssertTrue(script.contains("timeout.expired"))
        XCTAssertEqual(script.components(separatedBy: "deadline_epoch=").count - 1, 1)
        XCTAssertTrue(script.contains("deadline_epoch=$((started_epoch + 300))"))
        XCTAssertTrue(script.contains("[ \"$now_epoch\" -ge \"$deadline_epoch\" ]"))
        XCTAssertFalse(script.contains("elapsed=0"))
        XCTAssertTrue(script.contains("return 124"))
        XCTAssertTrue(script.contains("/bin/mv -f"))
        XCTAssertTrue(script.contains("trap 'handle_signal 129' HUP"))
        XCTAssertTrue(script.contains("trap 'cleanup_processes' EXIT"))
        XCTAssertTrue(script.contains("/usr/bin/setsid \"$@\""))
        XCTAssertFalse(script.contains("else\n    \"$@\""))
        XCTAssertFalse(script.contains("OPENBURNBAR_DAEMON_SOCKET_AUTH_TOKEN"))
        XCTAssertFalse(script.contains("secret-value"))

        let stateData = try Data(contentsOf: fixture.root.appendingPathComponent("current-flow.json"))
        let stateText = try XCTUnwrap(String(data: stateData, encoding: .utf8))
        XCTAssertEqual(permissions(at: fixture.root.appendingPathComponent("current-flow.json")), 0o600)
        XCTAssertFalse(stateText.contains("executablePath"))
        XCTAssertFalse(stateText.contains("configDirectory"))
        XCTAssertFalse(stateText.contains("accountDescription"))
        XCTAssertFalse(stateText.contains("secret-value"))

        fixture.auth.write(authInfo(
            cliType: .codex,
            state: .authenticated(lastRefresh: nil),
            accountDescription: "Desktop account"
        ))
        try Data("0\n".utf8).write(
            to: scriptURL.deletingLastPathComponent().appendingPathComponent("exit.status"),
            options: .atomic
        )
        let verified = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "openai",
            flowID: started.flow.flowID
        ))

        XCTAssertEqual(verified.flow.state, .succeeded)
        XCTAssertTrue(verified.flow.connected)
        XCTAssertEqual(verified.flow.accountDescription, "Desktop account")
        XCTAssertEqual(verified.flow.authMethodID, "openai-codex-oauth")
    }

    func testTerminalHistoryIsScopedWhileUnscopedStatusUsesLiveAuth() async throws {
        let uuids = StateBox([
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        ])
        let fixture = try makeFixture(cliType: .codex, makeUUID: {
            var remaining = uuids.read()
            let next = remaining.removeFirst()
            uuids.write(remaining)
            return next
        })
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let started = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        ))
        let scriptURL = try XCTUnwrap(fixture.launches.read().first)
        fixture.auth.write(authInfo(cliType: .codex, state: .authenticated(lastRefresh: nil)))
        try Data("0\n".utf8).write(
            to: scriptURL.deletingLastPathComponent().appendingPathComponent("exit.status"),
            options: .atomic
        )

        let completed = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "openai",
            flowID: started.flow.flowID
        ))
        XCTAssertEqual(completed.flow.state, .succeeded)
        XCTAssertTrue(completed.flow.connected)

        fixture.auth.write(authInfo(cliType: .codex, state: .notAuthenticated))
        let currentAuth = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "openai"
        ))
        XCTAssertNil(currentAuth.flow.flowID)
        XCTAssertEqual(currentAuth.flow.state, .idle)
        XCTAssertFalse(currentAuth.flow.connected)

        let historical = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "openai",
            flowID: started.flow.flowID
        ))
        XCTAssertEqual(historical.flow.flowID, started.flow.flowID)
        XCTAssertEqual(historical.flow.state, .succeeded)
        XCTAssertTrue(historical.flow.connected)

        let replacement = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        ))
        XCTAssertEqual(replacement.flow.flowID, "22222222-2222-2222-2222-222222222222")
        XCTAssertEqual(replacement.flow.state, .awaitingUser)

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
                providerID: "openai",
                flowID: started.flow.flowID
            ))
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
                providerID: "anthropic",
                authMethodID: "anthropic-claude-code-login",
                flowID: replacement.flow.flowID
            ))
        }
    }

    func testStartReportsMissingCLIAndMissingTerminalWithoutRawErrors() async throws {
        let missingCLIRoot = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: missingCLIRoot) }
        let missingCLI = BurnBarProviderExternalAuthService(
            rootDirectoryURL: missingCLIRoot,
            dependencies: .init(
                resolveExecutable: { _ in nil },
                discoverAuth: { cliType, _ in self.authInfo(cliType: cliType, state: .notInstalled) },
                launchTerminal: { _ in XCTFail("Terminal must not launch without a CLI") }
            )
        )
        let unavailable = await missingCLI.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "anthropic",
            authMethodID: "anthropic-claude-code-login"
        ))
        XCTAssertEqual(unavailable.flow.state, .failed)
        XCTAssertEqual(unavailable.flow.problem?.code, .executableNotFound)
        XCTAssertEqual(unavailable.flow.problem?.message, "Install Claude Code before starting sign-in.")
        XCTAssertNil(unavailable.flow.flowID)

        let fixture = try makeFixture(
            cliType: .claude,
            launchTerminal: { _ in throw BurnBarProviderExternalAuthTerminalLaunchError.unavailable }
        )
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let noTerminal = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "anthropic",
            authMethodID: "anthropic-claude-code-login"
        ))
        XCTAssertEqual(noTerminal.flow.state, .failed)
        XCTAssertEqual(noTerminal.flow.problem?.code, .terminalUnavailable)
        XCTAssertEqual(noTerminal.flow.problem?.message, "Install a supported terminal emulator before starting sign-in.")
        XCTAssertFalse(noTerminal.flow.problem?.message.contains(fixture.root.path) == true)
    }

    func testUnsupportedPairsAreRegistryBackedAndNeverLaunch() async throws {
        let fixture = try makeFixture(cliType: .codex)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let wrongMethod = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "anthropic",
            authMethodID: "openai-codex-oauth"
        ))
        XCTAssertEqual(wrongMethod.flow.providerID, "anthropic")
        XCTAssertEqual(wrongMethod.flow.problem?.code, .unsupportedAuthMethod)

        let wrongProvider = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "ollama",
            authMethodID: "openai-codex-oauth"
        ))
        XCTAssertEqual(wrongProvider.flow.problem?.code, .unsupportedProvider)
        XCTAssertTrue(fixture.launches.read().isEmpty)
    }

    func testRepeatedStartIsIdempotentAndDifferentProviderIsBlocked() async throws {
        let fixture = try makeFixture(cliType: .codex)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let request = BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        )

        let first = await fixture.service.start(request)
        let repeated = await fixture.service.start(request)
        XCTAssertEqual(repeated.flow.flowID, first.flow.flowID)
        XCTAssertEqual(fixture.launches.read().count, 1)

        let blocked = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "anthropic",
            authMethodID: "anthropic-claude-code-login"
        ))
        XCTAssertEqual(blocked.flow.problem?.code, .anotherFlowActive)
        XCTAssertNil(blocked.flow.flowID)
        XCTAssertEqual(fixture.launches.read().count, 1)
    }

    func testCancelWritesSentinelAndRejectsWrongFlow() async throws {
        let fixture = try makeFixture(cliType: .codex)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let started = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        ))
        let flowID = try XCTUnwrap(started.flow.flowID)

        let cancelled = try await fixture.service.cancel(BurnBarProviderExternalAuthFlowRequest(flowID: flowID))
        XCTAssertEqual(cancelled.flow.state, .cancelled)
        XCTAssertEqual(cancelled.flow.problem?.code, .cancelled)
        let scriptURL = try XCTUnwrap(fixture.launches.read().first)
        let sentinel = scriptURL.deletingLastPathComponent().appendingPathComponent("cancel.requested")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
        XCTAssertEqual(permissions(at: sentinel), 0o600)

        let repeated = try await fixture.service.cancel(BurnBarProviderExternalAuthFlowRequest(flowID: flowID))
        XCTAssertEqual(repeated.flow.state, .cancelled)
        let restartBeforeCleanup = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        ))
        XCTAssertEqual(restartBeforeCleanup.flow.problem?.code, .anotherFlowActive)
        XCTAssertNil(restartBeforeCleanup.flow.flowID)
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.service.cancel(BurnBarProviderExternalAuthFlowRequest(flowID: "WRONG"))
        }
    }

    func testStatusTimesOutAndRequestsSafeScriptCancellation() async throws {
        let fixture = try makeFixture(cliType: .claude)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let started = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "anthropic",
            authMethodID: "anthropic-claude-code-login"
        ))
        fixture.now.write(fixture.now.read().addingTimeInterval(301))

        let timedOut = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "anthropic",
            flowID: started.flow.flowID
        ))
        XCTAssertEqual(timedOut.flow.state, .timedOut)
        XCTAssertEqual(timedOut.flow.problem?.code, .timeout)
        let scriptURL = try XCTUnwrap(fixture.launches.read().first)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: scriptURL.deletingLastPathComponent().appendingPathComponent("cancel.requested").path
        ))
        let repeated = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "anthropic",
            flowID: started.flow.flowID
        ))
        XCTAssertEqual(repeated.flow.state, .timedOut)
        XCTAssertEqual(repeated.flow.problem?.code, .timeout)
    }

    func testScriptLocalTimeoutMarkerIsTerminalWithoutStatusPolling() async throws {
        let fixture = try makeFixture(cliType: .codex)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let started = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        ))
        let scriptURL = try XCTUnwrap(fixture.launches.read().first)
        let script = try String(contentsOf: scriptURL, encoding: .utf8)
        XCTAssertEqual(script.components(separatedBy: "deadline_epoch=").count - 1, 1)
        XCTAssertTrue(script.contains("deadline_epoch=$((started_epoch + 300))"))
        XCTAssertTrue(script.contains("[ \"$now_epoch\" -ge \"$deadline_epoch\" ]"))
        XCTAssertFalse(script.contains("elapsed=0"))
        XCTAssertTrue(script.contains(": > \"$TIMEOUT\""))
        XCTAssertTrue(script.contains("/bin/kill -TERM -- \"$login_group\""))

        try Data("124\n".utf8).write(
            to: scriptURL.deletingLastPathComponent().appendingPathComponent("exit.status"),
            options: .atomic
        )
        let timedOut = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "openai",
            flowID: started.flow.flowID
        ))
        XCTAssertEqual(timedOut.flow.state, .timedOut)
        XCTAssertEqual(timedOut.flow.problem?.code, .timeout)
        let repeated = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "openai",
            flowID: started.flow.flowID
        ))
        XCTAssertEqual(repeated.flow.state, .timedOut)
        XCTAssertEqual(repeated.flow.problem?.code, .timeout)
    }

    func testPreauthenticatedReconnectWaitsForOwnedSuccessfulExitMarker() async throws {
        let fixture = try makeFixture(cliType: .codex)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.auth.write(authInfo(cliType: .codex, state: .authenticated(lastRefresh: nil)))

        let started = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        ))
        XCTAssertEqual(started.flow.state, .awaitingUser)

        let stillRunning = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "openai",
            flowID: started.flow.flowID
        ))
        XCTAssertEqual(stillRunning.flow.state, .awaitingUser)

        let scriptURL = try XCTUnwrap(fixture.launches.read().first)
        try Data("0\n".utf8).write(
            to: scriptURL.deletingLastPathComponent().appendingPathComponent("exit.status"),
            options: .atomic
        )
        let completed = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "openai",
            flowID: started.flow.flowID
        ))
        XCTAssertEqual(completed.flow.state, .succeeded)
        XCTAssertTrue(completed.flow.connected)
    }

    func testAlternatingDiscoveryCannotEmitSucceededWithDisconnectedSnapshot() async throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let executable = root.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let calls = StateBox(0)
        let launched = StateBox<URL?>(nil)
        let service = BurnBarProviderExternalAuthService(
            rootDirectoryURL: root,
            dependencies: .init(
                makeUUID: { UUID(uuidString: "33333333-3333-3333-3333-333333333333")! },
                resolveExecutable: { _ in executable },
                discoverAuth: { cliType, _ in
                    let next = calls.read() + 1
                    calls.write(next)
                    return self.authInfo(
                        cliType: cliType,
                        state: next.isMultiple(of: 2) ? .authenticated(lastRefresh: nil) : .notAuthenticated
                    )
                },
                launchTerminal: {
                    launched.write($0)
                    try Self.writeStartedSentinel(for: $0)
                }
            )
        )

        let started = await service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        ))
        let scriptURL = try XCTUnwrap(launched.read())
        try Data("0\n".utf8).write(
            to: scriptURL.deletingLastPathComponent().appendingPathComponent("exit.status"),
            options: .atomic
        )
        let completed = try await service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "openai",
            flowID: started.flow.flowID
        ))

        XCTAssertEqual(calls.read(), 2)
        XCTAssertEqual(completed.flow.state, .succeeded)
        XCTAssertTrue(completed.flow.connected)
    }

    func testVerificationGraceSurvivesRestartAndAllowsDelayedAuth() async throws {
        let fixture = try makeFixture(cliType: .codex)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let started = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        ))
        let scriptURL = try XCTUnwrap(fixture.launches.read().first)
        try Data("0\n".utf8).write(
            to: scriptURL.deletingLastPathComponent().appendingPathComponent("exit.status"),
            options: .atomic
        )

        let verifying = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "openai",
            flowID: started.flow.flowID
        ))
        XCTAssertEqual(verifying.flow.state, .verifying)
        XCTAssertNil(verifying.flow.completedAt)
        let persisted = try String(
            contentsOf: fixture.root.appendingPathComponent("current-flow.json"),
            encoding: .utf8
        )
        XCTAssertTrue(persisted.contains("verificationStartedAt"))
        XCTAssertTrue(persisted.contains("verificationDeadline"))

        let recovered = BurnBarProviderExternalAuthService(
            rootDirectoryURL: fixture.root,
            dependencies: dependencies(
                executable: fixture.executable,
                now: fixture.now,
                auth: fixture.auth,
                launches: fixture.launches
            )
        )
        fixture.now.write(fixture.now.read().addingTimeInterval(5))
        fixture.auth.write(authInfo(cliType: .codex, state: .authenticated(lastRefresh: nil)))
        let completed = try await recovered.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "openai",
            flowID: started.flow.flowID
        ))
        XCTAssertEqual(completed.flow.state, .succeeded)
        XCTAssertTrue(completed.flow.connected)
    }

    func testExitMarkerBeatsFlowExpiryAndVerificationGraceExpires() async throws {
        let fixture = try makeFixture(cliType: .codex)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let started = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        ))
        let scriptURL = try XCTUnwrap(fixture.launches.read().first)
        try Data("0\n".utf8).write(
            to: scriptURL.deletingLastPathComponent().appendingPathComponent("exit.status"),
            options: .atomic
        )
        fixture.now.write(fixture.now.read().addingTimeInterval(301))

        let verifying = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "openai",
            flowID: started.flow.flowID
        ))
        XCTAssertEqual(verifying.flow.state, .verifying)
        XCTAssertNil(verifying.flow.problem)

        fixture.now.write(fixture.now.read().addingTimeInterval(16))
        let expired = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "openai",
            flowID: started.flow.flowID
        ))
        XCTAssertEqual(expired.flow.state, .failed)
        XCTAssertEqual(expired.flow.problem?.code, .verificationFailed)
    }

    func testAwaitingStateIsDurableBeforeTerminalLaunch() async throws {
        let observedState = StateBox<String?>(nil)
        let fixture = try makeFixture(cliType: .claude) { scriptURL in
            let root = scriptURL.deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            observedState.write(try String(
                contentsOf: root.appendingPathComponent("current-flow.json"),
                encoding: .utf8
            ))
            try Self.writeStartedSentinel(for: scriptURL)
        }
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let response = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "anthropic",
            authMethodID: "anthropic-claude-code-login"
        ))

        XCTAssertEqual(response.flow.state, .awaitingUser)
        XCTAssertTrue(observedState.read()?.contains("\"state\":\"awaiting_user\"") == true)
    }

    func testBlankAndOversizedSelectorsNeverLaunch() async throws {
        let fixture = try makeFixture(cliType: .codex)
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let blank = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "   "
        ))
        XCTAssertEqual(blank.flow.problem?.code, .unsupportedAuthMethod)
        let oversized = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: String(repeating: "x", count: 129)
        ))
        XCTAssertEqual(oversized.flow.problem?.code, .unsupportedAuthMethod)
        XCTAssertTrue(fixture.launches.read().isEmpty)

        let blankMethod = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "openai",
            authMethodID: " "
        ))
        XCTAssertEqual(blankMethod.flow.problem?.code, .unsupportedAuthMethod)
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
                providerID: "openai",
                flowID: " "
            ))
        }
        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.service.cancel(BurnBarProviderExternalAuthFlowRequest(
                flowID: String(repeating: "A", count: 65)
            ))
        }
    }

    func testCorruptedAndSymlinkedPersistedStateIsRejected() async throws {
        let corrupted = try makeFixture(cliType: .codex)
        defer { try? FileManager.default.removeItem(at: corrupted.root) }
        let started = await corrupted.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        ))
        let stateURL = corrupted.root.appendingPathComponent("current-flow.json")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any]
        )
        object["flowID"] = "../escape"
        try JSONSerialization.data(withJSONObject: object).write(to: stateURL, options: .atomic)
        let rejectedCorruption = BurnBarProviderExternalAuthService(
            rootDirectoryURL: corrupted.root,
            dependencies: dependencies(
                executable: corrupted.executable,
                now: corrupted.now,
                auth: corrupted.auth,
                launches: StateBox([])
            )
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await rejectedCorruption.status(BurnBarProviderExternalAuthStatusRequest(
                providerID: "openai",
                flowID: started.flow.flowID
            ))
        }

        let symlinked = try makeFixture(cliType: .claude)
        defer { try? FileManager.default.removeItem(at: symlinked.root) }
        let symlinkedStart = await symlinked.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "anthropic",
            authMethodID: "anthropic-claude-code-login"
        ))
        let symlinkedState = symlinked.root.appendingPathComponent("current-flow.json")
        let stateTarget = symlinked.root.appendingPathComponent("state-target.json")
        try FileManager.default.moveItem(at: symlinkedState, to: stateTarget)
        try FileManager.default.createSymbolicLink(at: symlinkedState, withDestinationURL: stateTarget)
        let rejectedSymlink = BurnBarProviderExternalAuthService(
            rootDirectoryURL: symlinked.root,
            dependencies: dependencies(
                executable: symlinked.executable,
                now: symlinked.now,
                auth: symlinked.auth,
                launches: StateBox([])
            )
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await rejectedSymlink.status(BurnBarProviderExternalAuthStatusRequest(
                providerID: "anthropic",
                flowID: symlinkedStart.flow.flowID
            ))
        }

        let sessionSymlinked = try makeFixture(cliType: .codex)
        defer { try? FileManager.default.removeItem(at: sessionSymlinked.root) }
        let sessionStart = await sessionSymlinked.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        ))
        let flowID = try XCTUnwrap(sessionStart.flow.flowID)
        let sessionURL = sessionSymlinked.root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent(flowID, isDirectory: true)
        let sessionTarget = sessionSymlinked.root.appendingPathComponent("session-target", isDirectory: true)
        try FileManager.default.moveItem(at: sessionURL, to: sessionTarget)
        try FileManager.default.createSymbolicLink(at: sessionURL, withDestinationURL: sessionTarget)
        let rejectedSessionSymlink = BurnBarProviderExternalAuthService(
            rootDirectoryURL: sessionSymlinked.root,
            dependencies: dependencies(
                executable: sessionSymlinked.executable,
                now: sessionSymlinked.now,
                auth: sessionSymlinked.auth,
                launches: StateBox([])
            )
        )
        await XCTAssertThrowsErrorAsync {
            _ = try await rejectedSessionSymlink.status(BurnBarProviderExternalAuthStatusRequest(
                providerID: "openai",
                flowID: sessionStart.flow.flowID
            ))
        }
    }

    func testRestartRecoversPersistedFlowAndMarkerWithoutPersistedPID() async throws {
        let fixture = try makeFixture(cliType: .codex)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let started = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        ))

        let recovered = BurnBarProviderExternalAuthService(
            rootDirectoryURL: fixture.root,
            dependencies: dependencies(
                executable: fixture.executable,
                now: fixture.now,
                auth: fixture.auth,
                launches: StateBox([])
            )
        )
        let pending = try await recovered.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "openai",
            flowID: started.flow.flowID
        ))
        XCTAssertEqual(pending.flow.flowID, started.flow.flowID)
        XCTAssertEqual(pending.flow.state, .awaitingUser)
        XCTAssertEqual(pending.flow.problem?.code, .daemonRestarted)

        let scriptURL = try XCTUnwrap(fixture.launches.read().first)
        try Data("0\n".utf8).write(
            to: scriptURL.deletingLastPathComponent().appendingPathComponent("exit.status"),
            options: .atomic
        )
        let unverified = try await recovered.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "openai",
            flowID: started.flow.flowID
        ))
        XCTAssertEqual(unverified.flow.state, .verifying)
        XCTAssertNil(unverified.flow.problem)

        let persisted = try String(
            contentsOf: fixture.root.appendingPathComponent("current-flow.json"),
            encoding: .utf8
        )
        XCTAssertFalse(persisted.lowercased().contains("pid"))
    }

    func testStatusRejectsStaleFlowIDAndResolvesDefaultMethod() async throws {
        let fixture = try makeFixture(cliType: .claude)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let idle = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
            providerID: "claude"
        ))
        XCTAssertEqual(idle.flow.providerID, "anthropic")
        XCTAssertEqual(idle.flow.authMethodID, "anthropic-claude-code-login")
        XCTAssertEqual(idle.flow.state, .idle)

        await XCTAssertThrowsErrorAsync {
            _ = try await fixture.service.status(BurnBarProviderExternalAuthStatusRequest(
                providerID: "anthropic",
                flowID: "STALE"
            ))
        }
    }

    func testLinuxTerminalCandidateOrderAndArgumentsAreDeterministic() {
        let script = URL(fileURLWithPath: "/tmp/openburnbar login/login.sh")
        let candidates = BurnBarProviderExternalAuthLinuxTerminalLauncher.candidates(scriptURL: script)
        XCTAssertEqual(candidates.map(\.executableURL.path), [
            "/usr/bin/x-terminal-emulator",
            "/usr/bin/gnome-terminal",
            "/usr/bin/konsole",
            "/usr/bin/xfce4-terminal",
            "/usr/bin/xterm"
        ])
        XCTAssertEqual(candidates[0].arguments, ["-e", script.path])
        XCTAssertEqual(candidates[1].arguments, ["--wait", "--", script.path])
        XCTAssertEqual(candidates[2].arguments, ["--separate", "-e", script.path])
    }

    func testLinuxTerminalLauncherFallsBackAfterSpawnWithoutHandshake() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let scriptURL = root.appendingPathComponent("login.sh")
        try "#!/bin/sh\nexit 0\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        let startedURL = root.appendingPathComponent("started.ready")
        let exitMarkerURL = root.appendingPathComponent("exit.status")

        try BurnBarProviderExternalAuthLinuxTerminalLauncher.launchCandidates(
            scriptURL: scriptURL,
            candidates: [
                BurnBarProviderExternalAuthTerminalCandidate(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "umask 077; trap 'printf 143 > \"$1\"; exit 143' TERM; while :; do :; done",
                        "openburnbar-terminal-test",
                        exitMarkerURL.path
                    ]
                ),
                BurnBarProviderExternalAuthTerminalCandidate(
                    executableURL: URL(fileURLWithPath: "/bin/sh"),
                    arguments: [
                        "-c",
                        "umask 077; printf 'started\\n' > \"$2\"; /bin/chmod 600 \"$2\"",
                        "openburnbar-terminal-test",
                        startedURL.path
                    ]
                )
            ],
            candidateTimeout: 0.05,
            totalTimeout: 0.5,
            pollInterval: 0.005
        )

        XCTAssertTrue(BurnBarProviderExternalAuthLinuxTerminalLauncher.isStartedSentinelReady(
            scriptURL: scriptURL
        ))
        XCTAssertEqual(permissions(at: startedURL), 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exitMarkerURL.path))
    }

    func testLinuxTerminalLauncherRejectsAllSpawnedCandidatesWithoutHandshake() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let scriptURL = root.appendingPathComponent("login.sh")
        try "#!/bin/sh\nexit 0\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        let candidates = (0..<2).map { _ in
            BurnBarProviderExternalAuthTerminalCandidate(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "exit 0"]
            )
        }

        XCTAssertThrowsError(try BurnBarProviderExternalAuthLinuxTerminalLauncher.launchCandidates(
            scriptURL: scriptURL,
            candidates: candidates,
            candidateTimeout: 0.05,
            totalTimeout: 0.2,
            pollInterval: 0.005
        )) { error in
            XCTAssertEqual(error as? BurnBarProviderExternalAuthTerminalLaunchError, .failed)
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("started.ready").path
        ))
    }

    func testLinuxTerminalLauncherRejectsUnsafeAcceptanceBeforeLoginStarts() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let scriptURL = root.appendingPathComponent("login.sh")
        try "#!/bin/sh\nexit 0\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        let targetURL = root.appendingPathComponent("accepted-target")
        let loginStartedURL = root.appendingPathComponent("login-started")
        try "blocked\n".write(to: targetURL, atomically: true, encoding: .utf8)
        let candidate = BurnBarProviderExternalAuthTerminalCandidate(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "/bin/ln -s \"$1\" \"$4\"; umask 077; printf 'started\\n' > \"$3\"; "
                    + "/bin/chmod 600 \"$3\"; while [ \"$(/bin/cat \"$4\")\" != accepted ]; do :; done; "
                    + "printf launched > \"$2\"",
                "openburnbar-terminal-test",
                targetURL.path,
                loginStartedURL.path
            ]
        )

        XCTAssertThrowsError(try BurnBarProviderExternalAuthLinuxTerminalLauncher.launchCandidates(
            scriptURL: scriptURL,
            candidates: [candidate],
            candidateTimeout: 0.2,
            totalTimeout: 0.3,
            pollInterval: 0.005
        )) { error in
            XCTAssertEqual(error as? BurnBarProviderExternalAuthTerminalLaunchError, .failed)
        }
        XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "blocked\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: loginStartedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("started.ready").path
        ))
    }

    func testLinuxTerminalLauncherPrecommitFailureCannotStartLogin() throws {
        let root = temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        let scriptURL = root.appendingPathComponent("login.sh")
        try "#!/bin/sh\nexit 0\n".write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: scriptURL.path)
        let loginStartedURL = root.appendingPathComponent("login-started")
        let candidate = BurnBarProviderExternalAuthTerminalCandidate(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: [
                "-c",
                "umask 077; printf 'started\\n' > \"$2\"; /bin/chmod 600 \"$2\"; "
                    + "while [ ! -f \"$3\" ] || [ \"$(/bin/cat \"$3\")\" != accepted ]; do :; done; "
                    + "printf launched > \"$1\"",
                "openburnbar-terminal-test",
                loginStartedURL.path
            ]
        )

        XCTAssertThrowsError(try BurnBarProviderExternalAuthLinuxTerminalLauncher.launchCandidates(
            scriptURL: scriptURL,
            candidates: [candidate],
            candidateTimeout: 0.2,
            totalTimeout: 0.3,
            pollInterval: 0.005,
            acceptancePrecommit: { acceptedURL in
                try FileManager.default.createDirectory(at: acceptedURL, withIntermediateDirectories: false)
            }
        )) { error in
            XCTAssertEqual(error as? BurnBarProviderExternalAuthTerminalLaunchError, .failed)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: loginStartedURL.path))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("started.ready").path
        ))
    }

    func testStartedSentinelRejectsSymlinkWithoutTouchingTarget() async throws {
        let fixture = try makeFixture(cliType: .codex)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let sessionURL = fixture.root
            .appendingPathComponent("sessions", isDirectory: true)
            .appendingPathComponent("11111111-1111-1111-1111-111111111111", isDirectory: true)
        try FileManager.default.createDirectory(
            at: sessionURL,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fixture.root.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: sessionURL.deletingLastPathComponent().path
        )
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessionURL.path)
        let targetURL = fixture.root.appendingPathComponent("sentinel-target")
        try "untouched".write(to: targetURL, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: sessionURL.appendingPathComponent("started.ready"),
            withDestinationURL: targetURL
        )

        let response = await fixture.service.start(BurnBarProviderExternalAuthStartRequest(
            providerID: "openai",
            authMethodID: "openai-codex-oauth"
        ))

        XCTAssertEqual(response.flow.state, .failed)
        XCTAssertEqual(response.flow.problem?.code, .launchFailed)
        XCTAssertTrue(fixture.launches.read().isEmpty)
        XCTAssertEqual(try String(contentsOf: targetURL, encoding: .utf8), "untouched")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: sessionURL.appendingPathComponent("started.ready").path
        )
        XCTAssertEqual(attributes[.type] as? FileAttributeType, .typeSymbolicLink)
    }

    private func makeFixture(
        cliType: SwitcherCLIProfileType,
        launchTerminal: (@Sendable (URL) throws -> Void)? = nil,
        makeUUID: @escaping @Sendable () -> UUID = {
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        }
    ) throws -> Fixture {
        let root = temporaryRoot()
        let executable = root.appendingPathComponent(cliType.executableName)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
        let now = StateBox(Date(timeIntervalSince1970: 1_750_000_000))
        let auth = StateBox(authInfo(cliType: cliType, state: .notAuthenticated))
        let launches = StateBox<[URL]>([])
        var dependencies = dependencies(
            executable: executable,
            now: now,
            auth: auth,
            launches: launches,
            makeUUID: makeUUID
        )
        if let launchTerminal {
            dependencies.launchTerminal = launchTerminal
        }
        return Fixture(
            root: root,
            executable: executable,
            now: now,
            auth: auth,
            launches: launches,
            service: BurnBarProviderExternalAuthService(
                rootDirectoryURL: root,
                dependencies: dependencies
            )
        )
    }

    private func dependencies(
        executable: URL,
        now: StateBox<Date>,
        auth: StateBox<CLIAuthInfo>,
        launches: StateBox<[URL]>,
        makeUUID: @escaping @Sendable () -> UUID = {
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        }
    ) -> BurnBarProviderExternalAuthService.Dependencies {
        BurnBarProviderExternalAuthService.Dependencies(
            now: { now.read() },
            makeUUID: makeUUID,
            resolveExecutable: { _ in executable },
            discoverAuth: { _, _ in auth.read() },
            launchTerminal: { url in
                var values = launches.read()
                values.append(url)
                launches.write(values)
                try Self.writeStartedSentinel(for: url)
            }
        )
    }

    private static func writeStartedSentinel(for scriptURL: URL) throws {
        let startedURL = scriptURL.deletingLastPathComponent().appendingPathComponent("started.ready")
        try Data("started\n".utf8).write(to: startedURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: startedURL.path)
    }

    private func authInfo(
        cliType: SwitcherCLIProfileType,
        state: CLIAuthState,
        accountDescription: String? = nil
    ) -> CLIAuthInfo {
        CLIAuthInfo(
            cliType: cliType,
            isInstalled: state != .notInstalled,
            executablePath: state == .notInstalled ? nil : "/trusted/\(cliType.executableName)",
            authState: state,
            configDirectory: nil,
            accountDescription: accountDescription
        )
    }

    private func temporaryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-provider-auth-tests-\(UUID().uuidString)", isDirectory: true)
    }

    private func permissions(at url: URL) -> Int {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    private func XCTAssertThrowsErrorAsync(
        _ operation: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await operation()
            XCTFail("Expected operation to throw", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? BurnBarProviderExternalAuthServiceError, .invalidFlow, file: file, line: line)
        }
    }
}
