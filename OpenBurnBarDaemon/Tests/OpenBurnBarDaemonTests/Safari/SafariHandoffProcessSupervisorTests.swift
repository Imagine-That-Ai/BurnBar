import Dispatch
import Foundation
import OpenBurnBarEngine
import XCTest

@testable import OpenBurnBarDaemon

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#endif

final class SafariHandoffProcessSupervisorTests: XCTestCase {
    func testImmediateSuccessfulExitTerminalizesExactlyOnce() async throws {
        let workspace = try SafariHandoffTestWorkspace()
        let runID = BurnBarRunID(rawValue: "immediate-success")
        let package = try workspace.makePackage(runID: runID)
        let factory = SafariHandoffTestSessionFactory(
            configuration: .init(
                startTerminals: [
                    .init(waitStatus: waitStatus(exitCode: 0), failure: nil),
                    .init(waitStatus: waitStatus(exitCode: 42), failure: nil),
                ]
            )
        )
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory
        )

        let running = try await supervisor.launch(
            specification(
                runID: runID,
                package: package,
                identity: try filesystemIdentity(of: package)
            )
        )
        let terminal = try await terminalObservation(
            from: supervisor,
            runID: runID
        )

        XCTAssertEqual(running.state, .running)
        XCTAssertEqual(terminal.state, .completed)
        XCTAssertEqual(terminal.terminationReason, .exit)
        XCTAssertEqual(terminal.exitStatus, 0)
        XCTAssertNil(terminal.failure)

        let session = try XCTUnwrap(factory.sessionsSnapshot().first)
        XCTAssertEqual(session.finishDrainingCount, 1)
        XCTAssertEqual(session.closeLivenessCount, 1)
        XCTAssertEqual(
            session.lifecycleEventsSnapshot(),
            ["start", "ready", "finish-draining", "close-liveness"]
        )

        try await Task.sleep(nanoseconds: 150_000_000)
        let stable = await supervisor.observation(for: runID)
        XCTAssertEqual(stable, terminal)
        XCTAssertEqual(session.finishDrainingCount, 1)
        XCTAssertEqual(session.closeLivenessCount, 1)
    }

    func testNonzeroExitAndSignalAreReportedFaithfully() async throws {
        let workspace = try SafariHandoffTestWorkspace()
        let factory = SafariHandoffTestSessionFactory()
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory
        )

        let nonzeroRun = BurnBarRunID(rawValue: "nonzero-exit")
        let nonzeroPackage = try workspace.makePackage(runID: nonzeroRun)
        _ = try await supervisor.launch(
            specification(
                runID: nonzeroRun,
                package: nonzeroPackage,
                identity: try filesystemIdentity(of: nonzeroPackage)
            )
        )
        factory.sessionsSnapshot()[0].emitTerminal(
            .init(waitStatus: waitStatus(exitCode: 17), failure: nil)
        )
        let nonzero = try await terminalObservation(
            from: supervisor,
            runID: nonzeroRun
        )

        XCTAssertEqual(nonzero.state, .failed)
        XCTAssertEqual(nonzero.terminationReason, .exit)
        XCTAssertEqual(nonzero.exitStatus, 17)
        XCTAssertEqual(nonzero.failure, .nonzeroExit)

        let signalRun = BurnBarRunID(rawValue: "uncaught-signal")
        let signalPackage = try workspace.makePackage(runID: signalRun)
        _ = try await supervisor.launch(
            specification(
                runID: signalRun,
                package: signalPackage,
                identity: try filesystemIdentity(of: signalPackage)
            )
        )
        factory.sessionsSnapshot()[1].emitTerminal(
            .init(waitStatus: Int32(SIGTERM), failure: nil)
        )
        let signalled = try await terminalObservation(
            from: supervisor,
            runID: signalRun
        )

        XCTAssertEqual(signalled.state, .failed)
        XCTAssertEqual(signalled.terminationReason, .uncaughtSignal)
        XCTAssertEqual(signalled.exitStatus, Int32(SIGTERM))
        XCTAssertEqual(signalled.failure, .signal)
    }

    func testTimeoutRequestsTerminationAndWaitsForTerminalization() async throws {
        let workspace = try SafariHandoffTestWorkspace()
        let runID = BurnBarRunID(rawValue: "timeout")
        let package = try workspace.makePackage(runID: runID)
        let factory = SafariHandoffTestSessionFactory(
            configuration: .init(
                terminationTerminal: .init(
                    waitStatus: Int32(SIGTERM),
                    failure: nil
                )
            )
        )
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory
        )

        _ = try await supervisor.launch(
            specification(
                runID: runID,
                package: package,
                identity: try filesystemIdentity(of: package),
                timeout: 0.01
            )
        )
        let terminal = try await terminalObservation(
            from: supervisor,
            runID: runID
        )

        XCTAssertEqual(terminal.state, .failed)
        XCTAssertEqual(terminal.terminationReason, .timeout)
        XCTAssertEqual(terminal.failure, .timeout)
        XCTAssertEqual(
            factory.sessionsSnapshot().first?.requestTerminationCount,
            1
        )
    }

    func testTimeoutUsesInjectedClockAndRemainsDeterministic() async throws {
        let workspace = try SafariHandoffTestWorkspace()
        let runID = BurnBarRunID(rawValue: "injected-timeout")
        let package = try workspace.makePackage(runID: runID)
        let factory = SafariHandoffTestSessionFactory(
            configuration: .init(
                terminationTerminal: .init(
                    waitStatus: Int32(SIGTERM),
                    failure: nil
                )
            )
        )
        let sleep = SafariHandoffSleepGate()
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory,
            sleep: sleep.sleep
        )

        _ = try await supervisor.launch(
            specification(
                runID: runID,
                package: package,
                identity: try filesystemIdentity(of: package),
                timeout: 60
            )
        )
        try await sleep.waitUntilRequested()
        XCTAssertEqual(sleep.requestedNanoseconds, 60_000_000_000)
        XCTAssertEqual(
            factory.sessionsSnapshot().first?.requestTerminationCount,
            0
        )

        sleep.resume()
        let terminal = try await terminalObservation(
            from: supervisor,
            runID: runID
        )

        XCTAssertEqual(terminal.state, .failed)
        XCTAssertEqual(terminal.terminationReason, .timeout)
        XCTAssertEqual(terminal.failure, .timeout)
        XCTAssertEqual(
            factory.sessionsSnapshot().first?.requestTerminationCount,
            1
        )
    }

    func testWatchdogFailureForcesContainmentAndFailsInterrupted()
        async throws
    {
        let workspace = try SafariHandoffTestWorkspace()
        let runID = BurnBarRunID(rawValue: "watchdog-failure")
        let package = try workspace.makePackage(runID: runID)
        let factory = SafariHandoffTestSessionFactory()
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory
        )

        _ = try await supervisor.launch(
            specification(
                runID: runID,
                package: package,
                identity: try filesystemIdentity(of: package)
            )
        )
        factory.sessionsSnapshot()[0].emitFailure("status-channel-closed")
        let terminal = try await terminalObservation(
            from: supervisor,
            runID: runID
        )

        XCTAssertEqual(terminal.state, .interrupted)
        XCTAssertEqual(terminal.terminationReason, .interrupted)
        XCTAssertEqual(terminal.failure, .interrupted)
        XCTAssertEqual(
            factory.sessionsSnapshot().first?.forceContainmentCount,
            1
        )
        XCTAssertEqual(
            factory.sessionsSnapshot().first?.lifecycleEventsSnapshot(),
            [
                "start",
                "ready",
                "force-containment",
                "finish-draining",
                "close-liveness",
            ]
        )
    }

    func testWatchdogMonitorFailureNeverFabricatesSuccessfulExit()
        async throws
    {
        let workspace = try SafariHandoffTestWorkspace()
        let runID = BurnBarRunID(rawValue: "watchdog-monitor-failure")
        let package = try workspace.makePackage(runID: runID)
        let factory = SafariHandoffTestSessionFactory()
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory
        )

        _ = try await supervisor.launch(
            specification(
                runID: runID,
                package: package,
                identity: try filesystemIdentity(of: package)
            )
        )
        factory.sessionsSnapshot()[0].emitTerminal(
            .init(
                waitStatus: nil,
                failure: "watchdog_waitpid_failed"
            )
        )
        let terminal = try await terminalObservation(
            from: supervisor,
            runID: runID
        )

        XCTAssertEqual(terminal.state, .interrupted)
        XCTAssertEqual(terminal.terminationReason, .interrupted)
        XCTAssertNil(terminal.exitStatus)
        XCTAssertEqual(terminal.failure, .interrupted)
    }

    func testCancellationReasonSurvivesOutputPersistenceFailure() async throws {
        let workspace = try SafariHandoffTestWorkspace()
        let runID = BurnBarRunID(rawValue: "cancel-persistence-failure")
        let package = try workspace.makePackage(runID: runID)
        let factory = SafariHandoffTestSessionFactory(
            configuration: .init(
                terminationTerminal: .init(
                    waitStatus: Int32(SIGTERM),
                    failure: nil
                )
            )
        )
        let synchronization = SafariHandoffSynchronizationGate(
            fail: .outputFile,
            occurrence: 1
        )
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory,
            synchronization: synchronization
        )

        _ = try await supervisor.launch(
            specification(
                runID: runID,
                package: package,
                identity: try filesystemIdentity(of: package)
            )
        )
        let cancellation = await supervisor.cancel(runID: runID)
        let cancelled = try XCTUnwrap(cancellation)

        XCTAssertEqual(cancelled.state, .failed)
        XCTAssertEqual(cancelled.terminationReason, .cancelled)
        XCTAssertEqual(cancelled.failure, .outputPersistence)
        XCTAssertEqual(
            factory.sessionsSnapshot().first?.requestTerminationCount,
            1
        )
    }

    func testOutputIsPersistedAtTheOneMiBBoundWithTruncationEvidence() async throws {
        let workspace = try SafariHandoffTestWorkspace()
        let runID = BurnBarRunID(rawValue: "bounded-output")
        let package = try workspace.makePackage(runID: runID)
        let stdout = Data(repeating: 0x41, count: 1 * 1024 * 1024)
        let stderr = Data("bounded stderr".utf8)
        let factory = SafariHandoffTestSessionFactory(
            configuration: .init(
                stdout: .init(
                    data: stdout,
                    observedBytes: stdout.count * 2,
                    truncated: true
                ),
                stderr: .init(
                    data: stderr,
                    observedBytes: stderr.count,
                    truncated: false
                )
            )
        )
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory
        )

        _ = try await supervisor.launch(
            specification(
                runID: runID,
                package: package,
                identity: try filesystemIdentity(of: package)
            )
        )
        factory.sessionsSnapshot()[0].emitTerminal(
            .init(waitStatus: waitStatus(exitCode: 0), failure: nil)
        )
        let terminal = try await terminalObservation(
            from: supervisor,
            runID: runID
        )

        XCTAssertEqual(terminal.state, .completed)
        XCTAssertEqual(terminal.stdoutBytes, stdout.count)
        XCTAssertEqual(terminal.stderrBytes, stderr.count)
        XCTAssertEqual(terminal.stdoutObservedBytes, stdout.count * 2)
        XCTAssertEqual(terminal.stderrObservedBytes, stderr.count)
        XCTAssertTrue(terminal.stdoutTruncated)
        XCTAssertFalse(terminal.stderrTruncated)
        XCTAssertEqual(
            try Data(
                contentsOf: package.appendingPathComponent("stdout.log")
            ),
            stdout
        )
        XCTAssertEqual(
            try Data(
                contentsOf: package.appendingPathComponent("stderr.log")
            ),
            stderr
        )
        XCTAssertEqual(
            try permissions(
                of: package.appendingPathComponent("stdout.log")
            ),
            0o600
        )
        XCTAssertEqual(
            try permissions(
                of: package.appendingPathComponent("completion.json")
            ),
            0o600
        )

        let receipt = try JSONDecoder().decode(
            SafariHandoffTestReceipt.self,
            from: Data(
                contentsOf: package.appendingPathComponent("completion.json")
            )
        )
        XCTAssertEqual(receipt.schemaVersion, 4)
        XCTAssertEqual(
            receipt.stdoutSHA256,
            PlatformCrypto.sha256Hex(stdout)
        )
        XCTAssertEqual(
            receipt.stderrSHA256,
            PlatformCrypto.sha256Hex(stderr)
        )
        XCTAssertEqual(receipt.authenticationCode.count, 64)
        XCTAssertEqual(receipt.stdoutBytes, stdout.count)
        XCTAssertEqual(receipt.stderrBytes, stderr.count)
        XCTAssertEqual(receipt.stdoutObservedBytes, stdout.count * 2)
        XCTAssertEqual(receipt.stderrObservedBytes, stderr.count)
        XCTAssertTrue(receipt.stdoutTruncated)
        XCTAssertFalse(receipt.stderrTruncated)
    }

    func testTerminalizationDrainsOutputBeforeTakingDurableSnapshots()
        async throws
    {
        let workspace = try SafariHandoffTestWorkspace()
        let runID = BurnBarRunID(rawValue: "drain-before-snapshot")
        let package = try workspace.makePackage(runID: runID)
        let stdout = Data("stdout available only after EOF".utf8)
        let stderr = Data("stderr available only after EOF".utf8)
        let factory = SafariHandoffTestSessionFactory(
            configuration: .init(
                stdoutAfterFinishDraining: .init(
                    data: stdout,
                    observedBytes: stdout.count,
                    truncated: false
                ),
                stderrAfterFinishDraining: .init(
                    data: stderr,
                    observedBytes: stderr.count,
                    truncated: false
                )
            )
        )
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory
        )

        _ = try await supervisor.launch(
            specification(
                runID: runID,
                package: package,
                identity: try filesystemIdentity(of: package)
            )
        )
        factory.sessionsSnapshot()[0].emitTerminal(
            .init(waitStatus: waitStatus(exitCode: 0), failure: nil)
        )
        let terminal = try await terminalObservation(
            from: supervisor,
            runID: runID
        )

        XCTAssertEqual(terminal.state, .completed)
        XCTAssertEqual(terminal.stdoutBytes, stdout.count)
        XCTAssertEqual(terminal.stderrBytes, stderr.count)
        XCTAssertEqual(terminal.stdoutObservedBytes, stdout.count)
        XCTAssertEqual(terminal.stderrObservedBytes, stderr.count)
        XCTAssertEqual(
            try Data(
                contentsOf: package.appendingPathComponent("stdout.log")
            ),
            stdout
        )
        XCTAssertEqual(
            try Data(
                contentsOf: package.appendingPathComponent("stderr.log")
            ),
            stderr
        )
        XCTAssertEqual(
            factory.sessionsSnapshot()[0].finishDrainingCount,
            1
        )
    }

    func testTerminalObservationAndReceiptWaitForDeterministicSessionReap()
        async throws
    {
        let workspace = try SafariHandoffTestWorkspace()
        let runID = BurnBarRunID(rawValue: "terminal-after-reap")
        let package = try workspace.makePackage(runID: runID)
        let drainGate = SafariHandoffFinishDrainGate()
        let factory = SafariHandoffTestSessionFactory(
            configuration: .init(finishDrainingGate: drainGate)
        )
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory
        )

        _ = try await supervisor.launch(
            specification(
                runID: runID,
                package: package,
                identity: try filesystemIdentity(of: package)
            )
        )
        let session = factory.sessionsSnapshot()[0]
        let completion = SafariHandoffCompletionProbe()
        let terminalTask = Task {
            let observation = await supervisor.cancel(runID: runID)
            completion.markCompleted()
            return observation
        }
        try await waitUntil {
            session.requestTerminationCount == 1
        }
        session.emitTerminal(
            .init(waitStatus: waitStatus(exitCode: 0), failure: nil)
        )
        defer { drainGate.resume() }
        try await drainGate.waitUntilEntered()

        XCTAssertFalse(
            completion.isCompleted,
            "Terminal waiters must not resume while watchdog and sentinel reaping is blocked."
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    package
                    .appendingPathComponent("completion.json")
                    .path
            )
        )

        drainGate.resume()
        let terminalValue = await terminalTask.value
        let terminal = try XCTUnwrap(terminalValue)

        XCTAssertEqual(terminal.state, .cancelled)
        XCTAssertEqual(terminal.terminationReason, .cancelled)
        XCTAssertTrue(completion.isCompleted)
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath:
                    package
                    .appendingPathComponent("completion.json")
                    .path
            )
        )
        XCTAssertEqual(
            factory.sessionsSnapshot()[0].lifecycleEventsSnapshot(),
            ["start", "ready", "finish-draining", "close-liveness"]
        )
    }

    func testChildEnvironmentIsAllowlistedSanitizedAndNoninteractive()
        async throws
    {
        let workspace = try SafariHandoffTestWorkspace()
        let runID = BurnBarRunID(rawValue: "environment")
        let package = try workspace.makePackage(runID: runID)
        let factory = SafariHandoffTestSessionFactory()
        let ambient = [
            "HOME": NSHomeDirectory(),
            "USER": "burnbar-test",
            "SHELL": "/bin/zsh",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "C",
            "PATH": "/attacker/bin",
            "PWD": "/attacker/workspace",
            "TMPDIR": "/attacker/tmp",
            "TERM": "xterm-256color",
            "PAGER": "less",
            "EDITOR": "vim",
            "VISUAL": "code",
            "BROWSER": "open",
            "SSH_AUTH_SOCK": "/private/agent.sock",
            "OPENAI_API_KEY": "openai-secret",
            "ANTHROPIC_API_KEY": "anthropic-secret",
            "BURNBAR_DAEMON_TOKEN": "daemon-secret",
            "APPLE_ID_PASSWORD": "apple-secret",
            "NOTARYTOOL_PASSWORD": "notary-secret",
            "DYLD_INSERT_LIBRARIES": "/tmp/injected.dylib",
            "GITHUB_TOKEN": "github-secret",
            "AWS_SECRET_ACCESS_KEY": "aws-secret",
            "CLAUDE_CONFIG_DIR": "/attacker/claude",
            "CLAUDE_CONFIG_PATH": "/attacker/claude.json",
            "CODEX_HOME": "/attacker/codex",
            "CODEX_CONFIG_PATH": "/attacker/codex.json",
            "OPENCODE_CONFIG_PATH": "/attacker/opencode.json",
            "AGY_CONFIG_HOME": "/attacker/agy",
            "ANTIGRAVITY_HOME": "/attacker/antigravity",
            "GEMINI_HOME": "/attacker/gemini",
            "CURSOR_AGENT_HOME": "/attacker/cursor",
            "CURSOR_AGENT_CONFIG_PATH": "/attacker/cursor.json",
        ]
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory,
            environment: ambient
        )

        _ = try await supervisor.launch(
            specification(
                runID: runID,
                package: package,
                identity: try filesystemIdentity(of: package)
            )
        )
        let environment = try XCTUnwrap(
            factory.contextsSnapshot().first?.environment
        )

        XCTAssertEqual(environment["HOME"], ambient["HOME"])
        XCTAssertEqual(environment["USER"], "burnbar-test")
        XCTAssertEqual(environment["LANG"], "en_US.UTF-8")
        XCTAssertEqual(environment["LC_ALL"], "C")
        XCTAssertEqual(environment["PWD"], package.path)
        XCTAssertEqual(environment["TMPDIR"], "/tmp")
        XCTAssertEqual(environment["TERM"], "dumb")
        XCTAssertEqual(environment["NO_COLOR"], "1")
        XCTAssertEqual(environment["CI"], "1")
        XCTAssertEqual(environment["PAGER"], "/usr/bin/false")
        XCTAssertEqual(environment["GIT_PAGER"], "/usr/bin/false")
        XCTAssertEqual(environment["GIT_EDITOR"], "/usr/bin/false")
        XCTAssertEqual(environment["HG_EDITOR"], "/usr/bin/false")
        XCTAssertEqual(environment["GIT_TERMINAL_PROMPT"], "0")
        XCTAssertEqual(environment["GIT_ASKPASS"], "/usr/bin/false")
        XCTAssertEqual(environment["SSH_ASKPASS"], "/usr/bin/false")
        XCTAssertFalse(environment["PATH", default: ""].contains("/attacker"))

        for secretKey in [
            "SSH_AUTH_SOCK",
            "OPENAI_API_KEY",
            "ANTHROPIC_API_KEY",
            "BURNBAR_DAEMON_TOKEN",
            "APPLE_ID_PASSWORD",
            "NOTARYTOOL_PASSWORD",
            "DYLD_INSERT_LIBRARIES",
            "GITHUB_TOKEN",
            "AWS_SECRET_ACCESS_KEY",
            "EDITOR",
            "VISUAL",
            "BROWSER",
            "CLAUDE_CONFIG_DIR",
            "CLAUDE_CONFIG_PATH",
            "CODEX_HOME",
            "CODEX_CONFIG_PATH",
            "OPENCODE_CONFIG_PATH",
            "AGY_CONFIG_HOME",
            "ANTIGRAVITY_HOME",
            "GEMINI_HOME",
            "CURSOR_AGENT_HOME",
            "CURSOR_AGENT_CONFIG_PATH",
        ] {
            XCTAssertNil(
                environment[secretKey],
                "\(secretKey) crossed the installed-CLI authority boundary"
            )
        }
    }

    func testWrongRootNestedPackageAndIdentityMismatchFailClosed()
        async throws
    {
        let workspace = try SafariHandoffTestWorkspace()
        let factory = SafariHandoffTestSessionFactory()
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory
        )

        let wrongRun = BurnBarRunID(rawValue: "wrong-root")
        let wrongPackage = try workspace.makePackage(runID: wrongRun)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(wrongRun.rawValue, isDirectory: true)
        await assertLaunchFailure(
            supervisor,
            specification(
                runID: wrongRun,
                package: wrongPackage,
                identity: .init(device: 1, inode: 1)
            ),
            is: .invalidSpecification
        )

        let nestedRun = BurnBarRunID(rawValue: "nested/package")
        let nestedPackage = workspace.rootURL
            .appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("package", isDirectory: true)
        await assertLaunchFailure(
            supervisor,
            specification(
                runID: nestedRun,
                package: nestedPackage,
                identity: .init(device: 1, inode: 1)
            ),
            is: .invalidSpecification
        )

        let mismatchedRun = BurnBarRunID(rawValue: "identity-mismatch")
        let mismatchedPackage = try workspace.makePackage(runID: mismatchedRun)
        let actual = try filesystemIdentity(of: mismatchedPackage)
        await assertLaunchFailure(
            supervisor,
            specification(
                runID: mismatchedRun,
                package: mismatchedPackage,
                identity: .init(
                    device: actual.device,
                    inode: actual.inode &+ 1
                )
            ),
            is: .unsafePackage
        )
        XCTAssertTrue(factory.sessionsSnapshot().isEmpty)
    }

    func testHarnessIdentifierAndFileURLAuthorityFailClosed()
        async throws
    {
        let workspace = try SafariHandoffTestWorkspace()
        let factory = SafariHandoffTestSessionFactory()
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory
        )
        let runID = BurnBarRunID(rawValue: "invalid-authority")
        let package = try workspace.makePackage(runID: runID)
        let identity = try filesystemIdentity(of: package)
        let base = specification(
            runID: runID,
            package: package,
            identity: identity
        )

        for targetHarness in [
            "",
            "Codex",
            "codex\nforged",
            String(repeating: "a", count: 129),
        ] {
            await assertLaunchFailure(
                supervisor,
                .init(
                    runID: base.runID,
                    targetHarness: targetHarness,
                    packageDirectory: base.packageDirectory,
                    expectedPackageIdentity: base.expectedPackageIdentity,
                    executableURL: base.executableURL,
                    arguments: base.arguments,
                    timeout: base.timeout
                ),
                is: .invalidSpecification
            )
        }

        await assertLaunchFailure(
            supervisor,
            .init(
                runID: base.runID,
                targetHarness: base.targetHarness,
                packageDirectory: base.packageDirectory,
                expectedPackageIdentity: base.expectedPackageIdentity,
                executableURL: URL(
                    string: "file://remote-host/usr/bin/true"
                )!,
                arguments: base.arguments,
                timeout: base.timeout
            ),
            is: .invalidSpecification
        )
        XCTAssertTrue(factory.sessionsSnapshot().isEmpty)
    }

    func testRootAndPackageSymlinksFailClosed() async throws {
        let workspace = try SafariHandoffTestWorkspace()

        let symlinkRoot = workspace.containerURL
            .appendingPathComponent("linked-root", isDirectory: true)
        try FileManager.default.createSymbolicLink(
            at: symlinkRoot,
            withDestinationURL: workspace.rootURL
        )
        let rootRun = BurnBarRunID(rawValue: "symlink-root-package")
        let rootPackage = try workspace.makePackage(runID: rootRun)
        let rootSupervisor = makeSupervisor(
            rootURL: symlinkRoot,
            factory: SafariHandoffTestSessionFactory()
        )
        await assertLaunchFailure(
            rootSupervisor,
            specification(
                runID: rootRun,
                package: symlinkRoot.appendingPathComponent(
                    rootRun.rawValue,
                    isDirectory: true
                ),
                identity: try filesystemIdentity(of: rootPackage)
            ),
            is: .unsafePackage
        )

        let targetRun = BurnBarRunID(rawValue: "package-target")
        let target = try workspace.makePackage(runID: targetRun)
        let linkRun = BurnBarRunID(rawValue: "package-link")
        let link = workspace.rootURL.appendingPathComponent(
            linkRun.rawValue,
            isDirectory: true
        )
        try FileManager.default.createSymbolicLink(
            at: link,
            withDestinationURL: target
        )
        let packageSupervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: SafariHandoffTestSessionFactory()
        )
        await assertLaunchFailure(
            packageSupervisor,
            specification(
                runID: linkRun,
                package: link,
                identity: try filesystemIdentity(of: link)
            ),
            is: .unsafePackage
        )
    }

    func testBroadRootAndPackagePermissionsFailClosed() async throws {
        let broadRootWorkspace = try SafariHandoffTestWorkspace()
        try setPermissions(0o755, on: broadRootWorkspace.rootURL)
        let rootRun = BurnBarRunID(rawValue: "broad-root")
        let rootPackage = try broadRootWorkspace.makePackage(runID: rootRun)
        let rootSupervisor = makeSupervisor(
            rootURL: broadRootWorkspace.rootURL,
            factory: SafariHandoffTestSessionFactory()
        )
        await assertLaunchFailure(
            rootSupervisor,
            specification(
                runID: rootRun,
                package: rootPackage,
                identity: try filesystemIdentity(of: rootPackage)
            ),
            is: .unsafePackage
        )

        let broadPackageWorkspace = try SafariHandoffTestWorkspace()
        let packageRun = BurnBarRunID(rawValue: "broad-package")
        let broadPackage = try broadPackageWorkspace.makePackage(
            runID: packageRun
        )
        try setPermissions(0o755, on: broadPackage)
        let packageSupervisor = makeSupervisor(
            rootURL: broadPackageWorkspace.rootURL,
            factory: SafariHandoffTestSessionFactory()
        )
        await assertLaunchFailure(
            packageSupervisor,
            specification(
                runID: packageRun,
                package: broadPackage,
                identity: try filesystemIdentity(of: broadPackage)
            ),
            is: .unsafePackage
        )
    }

    func testPreexistingOutputFileFailsBeforeStartingTheWatchdog()
        async throws
    {
        let workspace = try SafariHandoffTestWorkspace()
        let runID = BurnBarRunID(rawValue: "preexisting-output")
        let package = try workspace.makePackage(runID: runID)
        try workspace.writeOwnerOnly(
            Data("untrusted-output".utf8),
            to: package.appendingPathComponent("stdout.log")
        )
        let factory = SafariHandoffTestSessionFactory()
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory
        )

        await assertLaunchFailure(
            supervisor,
            specification(
                runID: runID,
                package: package,
                identity: try filesystemIdentity(of: package)
            ),
            is: .outputPreparationFailed
        )

        XCTAssertTrue(factory.sessionsSnapshot().isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
    }

    func testPackageSwapAndRootIdentitySwapAreRejected() async throws {
        let workspace = try SafariHandoffTestWorkspace()
        let factory = SafariHandoffTestSessionFactory()
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory
        )

        let swappedRun = BurnBarRunID(rawValue: "swapped-package")
        let original = try workspace.makePackage(runID: swappedRun)
        let expectedIdentity = try filesystemIdentity(of: original)
        let retainedOriginal = workspace.rootURL.appendingPathComponent(
            "retained-original",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: original,
            to: retainedOriginal
        )
        let replacement = try workspace.makePackage(runID: swappedRun)
        await assertLaunchFailure(
            supervisor,
            specification(
                runID: swappedRun,
                package: replacement,
                identity: expectedIdentity
            ),
            is: .unsafePackage
        )

        let firstRun = BurnBarRunID(rawValue: "root-generation-one")
        let firstPackage = try workspace.makePackage(runID: firstRun)
        _ = try await supervisor.launch(
            specification(
                runID: firstRun,
                package: firstPackage,
                identity: try filesystemIdentity(of: firstPackage)
            )
        )
        factory.sessionsSnapshot().last?.emitTerminal(
            .init(waitStatus: waitStatus(exitCode: 0), failure: nil)
        )
        _ = try await terminalObservation(
            from: supervisor,
            runID: firstRun
        )

        let retiredRoot = workspace.containerURL.appendingPathComponent(
            "retired-root",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: workspace.rootURL,
            to: retiredRoot
        )
        try FileManager.default.createDirectory(
            at: workspace.rootURL,
            withIntermediateDirectories: false
        )
        try setPermissions(0o700, on: workspace.rootURL)
        let secondRun = BurnBarRunID(rawValue: "root-generation-two")
        let secondPackage = try workspace.makePackage(runID: secondRun)
        await assertLaunchFailure(
            supervisor,
            specification(
                runID: secondRun,
                package: secondPackage,
                identity: try filesystemIdentity(of: secondPackage)
            ),
            is: .unsafePackage
        )
    }

    func testExecutableValidatorRejectsSymlinkDirectoryNonExecutableAndWritable()
        throws
    {
        let workspace = try SafariHandoffTestWorkspace(
            requiresTrustedParentDirectories: true
        )
        let executable = try workspace.makeExecutable(named: "trusted-agent")
        let environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin",
        ]

        _ = try SafariHandoffProcessSupervisor.ExecutableValidator.validate(
            url: executable,
            environment: environment
        )

        let symlink = workspace.containerURL.appendingPathComponent(
            "linked-agent"
        )
        try FileManager.default.createSymbolicLink(
            at: symlink,
            withDestinationURL: executable
        )
        XCTAssertThrowsError(
            try SafariHandoffProcessSupervisor.ExecutableValidator.validate(
                url: symlink,
                environment: environment
            )
        )

        let directory = workspace.containerURL.appendingPathComponent(
            "agent-directory",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        try setPermissions(0o700, on: directory)
        XCTAssertThrowsError(
            try SafariHandoffProcessSupervisor.ExecutableValidator.validate(
                url: directory,
                environment: environment
            )
        )

        let nonExecutable = try workspace.makeExecutable(
            named: "non-executable"
        )
        try setPermissions(0o600, on: nonExecutable)
        XCTAssertThrowsError(
            try SafariHandoffProcessSupervisor.ExecutableValidator.validate(
                url: nonExecutable,
                environment: environment
            )
        )

        let writable = try workspace.makeExecutable(named: "writable-agent")
        try setPermissions(0o777, on: writable)
        XCTAssertThrowsError(
            try SafariHandoffProcessSupervisor.ExecutableValidator.validate(
                url: writable,
                environment: environment
            )
        )
    }

    func testExecutableIdentityChangesWhenTheValidatedFileIsReplaced()
        throws
    {
        let workspace = try SafariHandoffTestWorkspace(
            requiresTrustedParentDirectories: true
        )
        let executable = try workspace.makeExecutable(named: "replaceable")
        let environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin",
        ]
        let original =
            try SafariHandoffProcessSupervisor.ExecutableValidator.validate(
                url: executable,
                environment: environment
            )
        let retained = workspace.containerURL.appendingPathComponent(
            "retained-executable"
        )
        try FileManager.default.moveItem(at: executable, to: retained)
        _ = try workspace.makeExecutable(named: "replaceable")
        let replacement =
            try SafariHandoffProcessSupervisor.ExecutableValidator.validate(
                url: executable,
                environment: environment
            )

        XCTAssertNotEqual(original.identity, replacement.identity)
        XCTAssertEqual(original.path, replacement.path)
    }

    func testExecutableValidatorPinsEnvInterpreterIdentityAndLaunchVector()
        throws
    {
        let workspace = try SafariHandoffTestWorkspace(
            requiresTrustedParentDirectories: true
        )
        let executable = try workspace.makeExecutable(
            named: "env-script",
            contents: "#!/usr/bin/env true\n"
        )
        let environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin",
        ]

        let validated =
            try SafariHandoffProcessSupervisor.ExecutableValidator.validate(
                url: executable,
                environment: environment
            )

        XCTAssertEqual(validated.path, executable.path)
        XCTAssertEqual(validated.launchPath, "/usr/bin/true")
        XCTAssertEqual(validated.launchArguments, [executable.path])
        XCTAssertEqual(
            validated.components.map(\.path),
            [
                executable.path,
                "/usr/bin/env",
                "/usr/bin/true",
            ]
        )
        XCTAssertNotEqual(
            validated.components[0].identity,
            validated.components[1].identity
        )
        XCTAssertNotEqual(
            validated.components[1].identity,
            validated.components[2].identity
        )
    }

    func testExecutableLaunchAssessmentReportsTrustedInterpreterChainAndHardLinkRejection()
        throws
    {
        let fixtureRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                ".openburnbar-safari-executable-trust-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: fixtureRoot,
            withIntermediateDirectories: false
        )
        try setPermissions(0o700, on: fixtureRoot)
        defer { try? FileManager.default.removeItem(at: fixtureRoot) }
        let trusted = fixtureRoot.appendingPathComponent("trusted-env-script")
        try Data("#!/usr/bin/env true\n".utf8).write(
            to: trusted,
            options: .withoutOverwriting
        )
        try setPermissions(0o755, on: trusted)
        let environment = [
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin",
        ]

        XCTAssertEqual(
            SafariHandoffProcessSupervisor.ExecutableValidator.assessForLaunch(
                url: trusted,
                ambientEnvironment: environment
            ),
            .trusted
        )

        let hardLinked = fixtureRoot.appendingPathComponent(
            "hard-linked-agent"
        )
        try FileManager.default.linkItem(at: trusted, to: hardLinked)

        XCTAssertEqual(
            SafariHandoffProcessSupervisor.ExecutableValidator.assessForLaunch(
                url: hardLinked,
                ambientEnvironment: environment
            ),
            .rejected(.multipleHardLinks)
        )
    }

    func testMissingMalformedInvalidAndValidReceiptsRestoreFailClosed()
        async throws
    {
        let workspace = try SafariHandoffTestWorkspace()
        let clock = SafariHandoffTestClock(
            Date(timeIntervalSinceReferenceDate: 20_000)
        )
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: SafariHandoffTestSessionFactory(),
            now: clock.now
        )
        let launchedAt = Date(timeIntervalSinceReferenceDate: 19_000)

        let missingRun = BurnBarRunID(rawValue: "missing-receipt")
        let missingPackage = try workspace.makePackage(runID: missingRun)
        try workspace.makePersistedOutputFiles(in: missingPackage)
        let missing = await supervisor.registerInterruptedRun(
            runID: missingRun,
            targetHarness: "codex",
            packageDirectory: missingPackage,
            expectedPackageIdentity: try filesystemIdentity(
                of: missingPackage
            ),
            launchedAt: launchedAt
        )
        XCTAssertEqual(missing.state, .interrupted)
        XCTAssertEqual(missing.failure, .missingReceipt)

        let malformedRun = BurnBarRunID(rawValue: "malformed-receipt")
        let malformedPackage = try workspace.makePackage(runID: malformedRun)
        try workspace.makePersistedOutputFiles(in: malformedPackage)
        try workspace.writeOwnerOnly(
            Data("{not-json".utf8),
            to: malformedPackage.appendingPathComponent("completion.json")
        )
        let malformed = await supervisor.registerInterruptedRun(
            runID: malformedRun,
            targetHarness: "codex",
            packageDirectory: malformedPackage,
            expectedPackageIdentity: try filesystemIdentity(
                of: malformedPackage
            ),
            launchedAt: launchedAt
        )
        XCTAssertEqual(malformed.state, .interrupted)
        XCTAssertEqual(malformed.failure, .malformedReceipt)

        let invalidRun = BurnBarRunID(rawValue: "invalid-receipt")
        let invalidPackage = try workspace.makePackage(runID: invalidRun)
        try workspace.makePersistedOutputFiles(in: invalidPackage)
        try workspace.writeReceipt(
            in: invalidPackage,
            runID: BurnBarRunID(rawValue: "other-run"),
            targetHarness: "codex",
            identity: try filesystemIdentity(of: invalidPackage),
            launchedAt: launchedAt,
            completedAt: launchedAt.addingTimeInterval(10)
        )
        let invalid = await supervisor.registerInterruptedRun(
            runID: invalidRun,
            targetHarness: "codex",
            packageDirectory: invalidPackage,
            expectedPackageIdentity: try filesystemIdentity(
                of: invalidPackage
            ),
            launchedAt: launchedAt
        )
        XCTAssertEqual(invalid.state, .interrupted)
        XCTAssertEqual(invalid.failure, .invalidReceipt)

        let validRun = BurnBarRunID(rawValue: "valid-receipt")
        let validPackage = try workspace.makePackage(runID: validRun)
        let validStdout = Data("captured".utf8)
        try workspace.makePersistedOutputFiles(
            in: validPackage,
            stdout: validStdout
        )
        let validIdentity = try filesystemIdentity(of: validPackage)
        try workspace.writeReceipt(
            in: validPackage,
            runID: validRun,
            targetHarness: "codex",
            identity: validIdentity,
            launchedAt: launchedAt,
            completedAt: launchedAt.addingTimeInterval(10),
            stdoutBytes: validStdout.count,
            stdoutObservedBytes: validStdout.count * 2,
            stdoutTruncated: true
        )
        let valid = await supervisor.registerInterruptedRun(
            runID: validRun,
            targetHarness: "codex",
            packageDirectory: validPackage,
            expectedPackageIdentity: validIdentity,
            launchedAt: launchedAt
        )
        XCTAssertEqual(valid.state, .completed)
        XCTAssertEqual(valid.terminationReason, .exit)
        XCTAssertEqual(valid.exitStatus, 0)
        XCTAssertEqual(valid.stdoutBytes, validStdout.count)
        XCTAssertEqual(valid.stdoutObservedBytes, validStdout.count * 2)
        XCTAssertEqual(valid.stderrObservedBytes, 0)
        XCTAssertTrue(valid.stdoutTruncated)
        XCTAssertNil(valid.failure)
    }

    func testReceiptRejectsLegacySchemaAndIncoherentOutputEvidence()
        async throws
    {
        let workspace = try SafariHandoffTestWorkspace()
        let observedAt = Date(timeIntervalSinceReferenceDate: 25_000)
        let launchedAt = Date(timeIntervalSinceReferenceDate: 24_000)
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: SafariHandoffTestSessionFactory(),
            now: { observedAt }
        )

        struct ReceiptCase: Sendable {
            let name: String
            let schemaVersion: Int
            let retained: Int
            let observed: Int
            let truncated: Bool
        }

        let cases = [
            ReceiptCase(
                name: "legacy-schema",
                schemaVersion: 3,
                retained: 0,
                observed: 0,
                truncated: false
            ),
            ReceiptCase(
                name: "observed-smaller-than-retained",
                schemaVersion: 4,
                retained: 4,
                observed: 3,
                truncated: false
            ),
            ReceiptCase(
                name: "unreported-truncation",
                schemaVersion: 4,
                retained: 4,
                observed: 5,
                truncated: false
            ),
            ReceiptCase(
                name: "false-truncation",
                schemaVersion: 4,
                retained: 4,
                observed: 4,
                truncated: true
            ),
            ReceiptCase(
                name: "retained-over-limit",
                schemaVersion: 4,
                retained: 1 * 1024 * 1024 + 1,
                observed: 1 * 1024 * 1024 + 1,
                truncated: false
            ),
        ]

        for receiptCase in cases {
            let runID = BurnBarRunID(rawValue: receiptCase.name)
            let package = try workspace.makePackage(runID: runID)
            try workspace.makePersistedOutputFiles(
                in: package,
                stdout: Data(repeating: 0x41, count: receiptCase.retained)
            )
            let identity = try filesystemIdentity(of: package)
            try workspace.writeReceipt(
                in: package,
                runID: runID,
                targetHarness: "codex",
                identity: identity,
                launchedAt: launchedAt,
                completedAt: launchedAt.addingTimeInterval(1),
                schemaVersion: receiptCase.schemaVersion,
                stdoutBytes: receiptCase.retained,
                stdoutObservedBytes: receiptCase.observed,
                stdoutTruncated: receiptCase.truncated
            )

            let restored = await supervisor.registerInterruptedRun(
                runID: runID,
                targetHarness: "codex",
                packageDirectory: package,
                expectedPackageIdentity: identity,
                launchedAt: launchedAt
            )

            XCTAssertEqual(
                restored.failure,
                .invalidReceipt,
                "Receipt case \(receiptCase.name) must fail closed"
            )
        }
    }

    func testAuthenticatedReceiptRejectsFieldOutputAndKeyForgery()
        async throws
    {
        let observedAt = Date(timeIntervalSinceReferenceDate: 40_000)
        let launchedAt = observedAt.addingTimeInterval(-60)
        let signingKey = Data(repeating: 0xA5, count: 32)
        let signingAuthenticator =
            SafariHandoffProcessSupervisor.ReceiptAuthenticator.hmacSHA256(
                key: signingKey
            )

        for mutation in ["receipt", "stdout", "stderr", "wrong-key"] {
            let workspace = try SafariHandoffTestWorkspace()
            let runID = BurnBarRunID(rawValue: "forged-\(mutation)")
            let package = try workspace.makePackage(runID: runID)
            let stdout = Data("same-size-output".utf8)
            let stderr = Data("same-size-errors".utf8)
            try workspace.makePersistedOutputFiles(
                in: package,
                stdout: stdout,
                stderr: stderr
            )
            let identity = try filesystemIdentity(of: package)
            try workspace.writeReceipt(
                in: package,
                runID: runID,
                targetHarness: "codex",
                identity: identity,
                launchedAt: launchedAt,
                completedAt: observedAt.addingTimeInterval(-1),
                stdoutBytes: stdout.count,
                stderrBytes: stderr.count,
                stdoutObservedBytes: stdout.count,
                stderrObservedBytes: stderr.count,
                authenticator: signingAuthenticator
            )

            switch mutation {
            case "receipt":
                var object = try XCTUnwrap(
                    JSONSerialization.jsonObject(
                        with: Data(
                            contentsOf:
                                package.appendingPathComponent(
                                    "completion.json"
                                )
                        )
                    ) as? [String: Any]
                )
                object["exitStatus"] = 42
                try FileManager.default.removeItem(
                    at: package.appendingPathComponent("completion.json")
                )
                try workspace.writeOwnerOnly(
                    try JSONSerialization.data(withJSONObject: object),
                    to: package.appendingPathComponent("completion.json")
                )
            case "stdout":
                try Data("forged-output!!!".utf8).write(
                    to: package.appendingPathComponent("stdout.log")
                )
            case "stderr":
                try Data("forged-errors!!!".utf8).write(
                    to: package.appendingPathComponent("stderr.log")
                )
            default:
                break
            }

            let verifier = mutation == "wrong-key"
                ? SafariHandoffProcessSupervisor.ReceiptAuthenticator
                    .hmacSHA256(key: Data(repeating: 0x5A, count: 32))
                : signingAuthenticator
            let supervisor = makeSupervisor(
                rootURL: workspace.rootURL,
                factory: SafariHandoffTestSessionFactory(),
                now: { observedAt },
                receiptAuthenticator: verifier
            )
            let restored = await supervisor.registerInterruptedRun(
                runID: runID,
                targetHarness: "codex",
                packageDirectory: package,
                expectedPackageIdentity: identity,
                launchedAt: launchedAt
            )
            XCTAssertEqual(restored.state, .interrupted)
            XCTAssertEqual(restored.failure, .invalidReceipt)
        }
    }

    func testUnavailableReceiptAuthenticatorNeverRestoresCompletion()
        async throws
    {
        let workspace = try SafariHandoffTestWorkspace()
        let observedAt = Date(timeIntervalSinceReferenceDate: 42_000)
        let launchedAt = observedAt.addingTimeInterval(-30)
        let runID = BurnBarRunID(rawValue: "unavailable-authenticator")
        let package = try workspace.makePackage(runID: runID)
        try workspace.makePersistedOutputFiles(in: package)
        let identity = try filesystemIdentity(of: package)
        try workspace.writeReceipt(
            in: package,
            runID: runID,
            targetHarness: "codex",
            identity: identity,
            launchedAt: launchedAt,
            completedAt: observedAt.addingTimeInterval(-1)
        )
        let unavailable =
            SafariHandoffProcessSupervisor.ReceiptAuthenticator(
                authenticate: { _ in
                    throw SafariHandoffProcessSupervisor.ReceiptAuthenticator
                        .AuthenticationError.unavailable
                },
                validate: { _, _ in
                    throw SafariHandoffProcessSupervisor.ReceiptAuthenticator
                        .AuthenticationError.unavailable
                }
            )
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: SafariHandoffTestSessionFactory(),
            now: { observedAt },
            receiptAuthenticator: unavailable
        )

        let restored = await supervisor.registerInterruptedRun(
            runID: runID,
            targetHarness: "codex",
            packageDirectory: package,
            expectedPackageIdentity: identity,
            launchedAt: launchedAt
        )

        XCTAssertEqual(restored.state, .interrupted)
        XCTAssertEqual(restored.failure, .invalidReceipt)
    }

    func testReceiptRejectsHardLinkedOutputAndMissingExpectedIdentity()
        async throws
    {
        let workspace = try SafariHandoffTestWorkspace()
        let clock = SafariHandoffTestClock(
            Date(timeIntervalSinceReferenceDate: 30_000)
        )
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: SafariHandoffTestSessionFactory(),
            now: clock.now
        )
        let launchedAt = Date(timeIntervalSinceReferenceDate: 29_000)

        let hardLinkRun = BurnBarRunID(rawValue: "hard-linked-output")
        let hardLinkPackage = try workspace.makePackage(runID: hardLinkRun)
        try workspace.makePersistedOutputFiles(in: hardLinkPackage)
        let stdout = hardLinkPackage.appendingPathComponent("stdout.log")
        try FileManager.default.linkItem(
            at: stdout,
            to: hardLinkPackage.appendingPathComponent("stdout-alias.log")
        )
        let identity = try filesystemIdentity(of: hardLinkPackage)
        try workspace.writeReceipt(
            in: hardLinkPackage,
            runID: hardLinkRun,
            targetHarness: "codex",
            identity: identity,
            launchedAt: launchedAt,
            completedAt: launchedAt.addingTimeInterval(1)
        )
        let hardLinked = await supervisor.registerInterruptedRun(
            runID: hardLinkRun,
            targetHarness: "codex",
            packageDirectory: hardLinkPackage,
            expectedPackageIdentity: identity,
            launchedAt: launchedAt
        )
        XCTAssertEqual(hardLinked.failure, .invalidReceipt)

        let missingIdentityRun = BurnBarRunID(rawValue: "missing-identity")
        let missingIdentityPackage = try workspace.makePackage(
            runID: missingIdentityRun
        )
        let missingIdentity = await supervisor.registerInterruptedRun(
            runID: missingIdentityRun,
            targetHarness: "codex",
            packageDirectory: missingIdentityPackage,
            expectedPackageIdentity: nil,
            launchedAt: launchedAt
        )
        XCTAssertEqual(missingIdentity.state, .interrupted)
        XCTAssertEqual(missingIdentity.failure, .invalidReceipt)
    }

    func testSynchronizationFailuresFailClosedAtPreparationOutputAndReceipt()
        async throws
    {
        let preparationWorkspace = try SafariHandoffTestWorkspace()
        let preparationRun = BurnBarRunID(rawValue: "prepare-fsync-failure")
        let preparationPackage = try preparationWorkspace.makePackage(
            runID: preparationRun
        )
        let preparationFactory = SafariHandoffTestSessionFactory()
        let preparationSupervisor = makeSupervisor(
            rootURL: preparationWorkspace.rootURL,
            factory: preparationFactory,
            synchronization: SafariHandoffSynchronizationGate(
                fail: .packageDirectory,
                occurrence: 1
            )
        )
        await assertLaunchFailure(
            preparationSupervisor,
            specification(
                runID: preparationRun,
                package: preparationPackage,
                identity: try filesystemIdentity(of: preparationPackage)
            ),
            is: .outputPreparationFailed
        )
        XCTAssertTrue(preparationFactory.sessionsSnapshot().isEmpty)

        let outputWorkspace = try SafariHandoffTestWorkspace()
        let outputRun = BurnBarRunID(rawValue: "output-fsync-failure")
        let outputPackage = try outputWorkspace.makePackage(runID: outputRun)
        let outputFactory = SafariHandoffTestSessionFactory()
        let outputSupervisor = makeSupervisor(
            rootURL: outputWorkspace.rootURL,
            factory: outputFactory,
            synchronization: SafariHandoffSynchronizationGate(
                fail: .outputFile,
                occurrence: 1
            )
        )
        _ = try await outputSupervisor.launch(
            specification(
                runID: outputRun,
                package: outputPackage,
                identity: try filesystemIdentity(of: outputPackage)
            )
        )
        outputFactory.sessionsSnapshot()[0].emitTerminal(
            .init(waitStatus: waitStatus(exitCode: 0), failure: nil)
        )
        let outputFailure = try await terminalObservation(
            from: outputSupervisor,
            runID: outputRun
        )
        XCTAssertEqual(outputFailure.state, .failed)
        XCTAssertEqual(outputFailure.failure, .outputPersistence)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    outputPackage
                    .appendingPathComponent("completion.json").path
            ),
            "Incomplete output must never gain an authenticated completion receipt"
        )
        let outputRestoreSupervisor = makeSupervisor(
            rootURL: outputWorkspace.rootURL,
            factory: SafariHandoffTestSessionFactory()
        )
        let outputRestored =
            await outputRestoreSupervisor.registerInterruptedRun(
                runID: outputRun,
                targetHarness: "codex",
                packageDirectory: outputPackage,
                expectedPackageIdentity: try filesystemIdentity(
                    of: outputPackage
                ),
                launchedAt: outputFailure.launchedAt
            )
        XCTAssertEqual(outputRestored.state, .interrupted)
        XCTAssertEqual(outputRestored.failure, .missingReceipt)

        let receiptWorkspace = try SafariHandoffTestWorkspace()
        let receiptRun = BurnBarRunID(rawValue: "receipt-fsync-failure")
        let receiptPackage = try receiptWorkspace.makePackage(
            runID: receiptRun
        )
        let receiptFactory = SafariHandoffTestSessionFactory()
        let receiptSupervisor = makeSupervisor(
            rootURL: receiptWorkspace.rootURL,
            factory: receiptFactory,
            synchronization: SafariHandoffSynchronizationGate(
                fail: .receiptFile,
                occurrence: 1
            )
        )
        _ = try await receiptSupervisor.launch(
            specification(
                runID: receiptRun,
                package: receiptPackage,
                identity: try filesystemIdentity(of: receiptPackage)
            )
        )
        receiptFactory.sessionsSnapshot()[0].emitTerminal(
            .init(waitStatus: waitStatus(exitCode: 0), failure: nil)
        )
        let receiptFailure = try await terminalObservation(
            from: receiptSupervisor,
            runID: receiptRun
        )
        XCTAssertEqual(receiptFailure.state, .failed)
        XCTAssertEqual(receiptFailure.failure, .invalidReceipt)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    receiptPackage
                    .appendingPathComponent("completion.json").path
            )
        )

        let publicationWorkspace = try SafariHandoffTestWorkspace()
        let publicationRun = BurnBarRunID(
            rawValue: "receipt-publication-fsync-failure"
        )
        let publicationPackage = try publicationWorkspace.makePackage(
            runID: publicationRun
        )
        let publicationFactory = SafariHandoffTestSessionFactory()
        let publicationSupervisor = makeSupervisor(
            rootURL: publicationWorkspace.rootURL,
            factory: publicationFactory,
            synchronization: SafariHandoffSynchronizationGate(
                fail: .packageDirectory,
                occurrence: 4
            )
        )
        _ = try await publicationSupervisor.launch(
            specification(
                runID: publicationRun,
                package: publicationPackage,
                identity: try filesystemIdentity(of: publicationPackage)
            )
        )
        publicationFactory.sessionsSnapshot()[0].emitTerminal(
            .init(waitStatus: waitStatus(exitCode: 0), failure: nil)
        )
        let publicationFailure = try await terminalObservation(
            from: publicationSupervisor,
            runID: publicationRun
        )
        XCTAssertEqual(publicationFailure.state, .failed)
        XCTAssertEqual(publicationFailure.failure, .invalidReceipt)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath:
                    publicationPackage
                    .appendingPathComponent("completion.json").path
            ),
            "A receipt that failed final directory durability must be removed"
        )
        let publicationRestoreSupervisor = makeSupervisor(
            rootURL: publicationWorkspace.rootURL,
            factory: SafariHandoffTestSessionFactory()
        )
        let publicationRestored =
            await publicationRestoreSupervisor.registerInterruptedRun(
                runID: publicationRun,
                targetHarness: "codex",
                packageDirectory: publicationPackage,
                expectedPackageIdentity: try filesystemIdentity(
                    of: publicationPackage
                ),
                launchedAt: publicationFailure.launchedAt
            )
        XCTAssertEqual(publicationRestored.state, .interrupted)
        XCTAssertEqual(publicationRestored.failure, .missingReceipt)
    }

    func testSilentCancellationAndTimeoutContainExactGenerationAfterTwoSeconds()
        async throws
    {
        for reason in ["cancel", "timeout"] {
            let workspace = try SafariHandoffTestWorkspace()
            let runID = BurnBarRunID(
                rawValue: "silent-\(reason)-containment"
            )
            let package = try workspace.makePackage(runID: runID)
            let factory = SafariHandoffTestSessionFactory()
            let sleep = SafariHandoffSleepSequence()
            let supervisor = makeSupervisor(
                rootURL: workspace.rootURL,
                factory: factory,
                sleep: sleep.sleep
            )

            _ = try await supervisor.launch(
                specification(
                    runID: runID,
                    package: package,
                    identity: try filesystemIdentity(of: package),
                    timeout: reason == "timeout" ? 60 : 0
                )
            )
            let session = try XCTUnwrap(factory.sessionsSnapshot().first)
            let firstWaiter: Task<
                SafariHandoffProcessSupervisor.Observation?,
                Never
            >
            if reason == "timeout" {
                try await sleep.waitForRequest(count: 1)
                XCTAssertEqual(
                    sleep.requestedNanoseconds,
                    [60_000_000_000]
                )
                XCTAssertEqual(session.requestTerminationCount, 0)
                sleep.resumeNext()
                try await sleep.waitForRequest(count: 2)
                XCTAssertEqual(
                    sleep.requestedNanoseconds,
                    [60_000_000_000, 2_000_000_000]
                )
                firstWaiter = Task {
                    await supervisor.cancel(runID: runID)
                }
            } else {
                firstWaiter = Task {
                    await supervisor.cancel(runID: runID)
                }
                try await sleep.waitForRequest(count: 1)
                XCTAssertEqual(
                    sleep.requestedNanoseconds,
                    [2_000_000_000]
                )
            }

            XCTAssertEqual(session.requestTerminationCount, 1)
            let secondWaiter = Task {
                await supervisor.cancel(runID: runID)
            }
            sleep.resumeNext()
            let firstTerminalValue = await firstWaiter.value
            let terminal = try XCTUnwrap(firstTerminalValue)
            let secondTerminalValue = await secondWaiter.value
            XCTAssertEqual(
                try XCTUnwrap(secondTerminalValue),
                terminal,
                "Every waiter must resume with the same generation-bound terminal observation"
            )

            XCTAssertEqual(session.forceContainmentCount, 1)
            XCTAssertEqual(session.finishDrainingCount, 1)
            XCTAssertEqual(session.closeLivenessCount, 1)
            XCTAssertEqual(
                terminal.terminationReason,
                reason == "timeout" ? .timeout : .cancelled
            )
            XCTAssertEqual(
                terminal.state,
                reason == "timeout" ? .failed : .cancelled
            )
            XCTAssertEqual(
                terminal.failure,
                reason == "timeout" ? .timeout : nil
            )
        }
    }

    func testCommandWriteFailureClosesLivenessThenEscalatesContainment()
        async throws
    {
        let workspace = try SafariHandoffTestWorkspace()
        let runID = BurnBarRunID(rawValue: "command-write-failure")
        let package = try workspace.makePackage(runID: runID)
        let factory = SafariHandoffTestSessionFactory(
            configuration: .init(
                terminationRequestSucceeds: false
            )
        )
        let clock = SafariHandoffShutdownClock()
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory,
            sleep: { nanoseconds in
                clock.advance(by: nanoseconds)
                await Task.yield()
            },
            uptimeNanoseconds: { clock.now }
        )

        _ = try await supervisor.launch(
            specification(
                runID: runID,
                package: package,
                identity: try filesystemIdentity(of: package)
            )
        )
        let session = try XCTUnwrap(factory.sessionsSnapshot().first)
        let terminalValue = await supervisor.cancel(runID: runID)
        let terminal = try XCTUnwrap(terminalValue)

        XCTAssertEqual(clock.now, 2_000_000_000)
        XCTAssertEqual(session.requestTerminationCount, 1)
        XCTAssertEqual(
            session.closeLivenessCount,
            2,
            "Failed command delivery must close liveness immediately, then terminalization closes its local descriptor"
        )
        XCTAssertEqual(session.forceContainmentCount, 1)
        XCTAssertEqual(terminal.state, .cancelled)
        XCTAssertEqual(terminal.terminationReason, .cancelled)
        XCTAssertNil(terminal.failure)
    }

    func testExistingReceiptIsNeverReplaced() async throws {
        let workspace = try SafariHandoffTestWorkspace()
        let runID = BurnBarRunID(rawValue: "existing-receipt")
        let package = try workspace.makePackage(runID: runID)
        let receiptURL = package.appendingPathComponent("completion.json")
        let sentinel = Data("preexisting-receipt".utf8)
        try workspace.writeOwnerOnly(sentinel, to: receiptURL)
        let factory = SafariHandoffTestSessionFactory()
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory
        )

        _ = try await supervisor.launch(
            specification(
                runID: runID,
                package: package,
                identity: try filesystemIdentity(of: package)
            )
        )
        factory.sessionsSnapshot()[0].emitTerminal(
            .init(waitStatus: waitStatus(exitCode: 0), failure: nil)
        )
        let terminal = try await terminalObservation(
            from: supervisor,
            runID: runID
        )

        XCTAssertEqual(terminal.state, .failed)
        XCTAssertEqual(terminal.failure, .invalidReceipt)
        XCTAssertEqual(try Data(contentsOf: receiptURL), sentinel)
    }

    func testCleanupHonorsRetentionBoundaryAndKeepsReplacementDirectory()
        async throws
    {
        let workspace = try SafariHandoffTestWorkspace()
        let completedAt = Date(timeIntervalSinceReferenceDate: 40_000)
        let clock = SafariHandoffTestClock(completedAt)
        let factory = SafariHandoffTestSessionFactory()
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory,
            now: clock.now
        )
        let retainedRun = BurnBarRunID(rawValue: "retention-boundary")
        let retainedPackage = try workspace.makePackage(runID: retainedRun)
        _ = try await supervisor.launch(
            specification(
                runID: retainedRun,
                package: retainedPackage,
                identity: try filesystemIdentity(of: retainedPackage)
            )
        )
        factory.sessionsSnapshot()[0].emitTerminal(
            .init(waitStatus: waitStatus(exitCode: 0), failure: nil)
        )
        _ = try await terminalObservation(
            from: supervisor,
            runID: retainedRun
        )

        await supervisor.cleanupEligiblePackages(
            now: completedAt.addingTimeInterval(24 * 60 * 60 - 0.001)
        )
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: retainedPackage.path)
        )
        let retainedObservation = await supervisor.observation(
            for: retainedRun
        )
        XCTAssertNotNil(retainedObservation)

        await supervisor.cleanupEligiblePackages(
            now: completedAt.addingTimeInterval(24 * 60 * 60)
        )
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: retainedPackage.path)
        )
        let removedObservation = await supervisor.observation(
            for: retainedRun
        )
        XCTAssertNil(removedObservation)

        let replacementRun = BurnBarRunID(rawValue: "cleanup-replacement")
        let originalPackage = try workspace.makePackage(runID: replacementRun)
        _ = try await supervisor.launch(
            specification(
                runID: replacementRun,
                package: originalPackage,
                identity: try filesystemIdentity(of: originalPackage)
            )
        )
        factory.sessionsSnapshot()[1].emitTerminal(
            .init(waitStatus: waitStatus(exitCode: 0), failure: nil)
        )
        _ = try await terminalObservation(
            from: supervisor,
            runID: replacementRun
        )
        let quarantined = workspace.rootURL.appendingPathComponent(
            "cleanup-original",
            isDirectory: true
        )
        try FileManager.default.moveItem(
            at: originalPackage,
            to: quarantined
        )
        let replacement = try workspace.makePackage(runID: replacementRun)
        let marker = replacement.appendingPathComponent("replacement-marker")
        try Data("do-not-delete".utf8).write(to: marker)

        await supervisor.cleanupEligiblePackages(
            now: completedAt.addingTimeInterval(48 * 60 * 60)
        )

        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        let replacementObservation = await supervisor.observation(
            for: replacementRun
        )
        XCTAssertNotNil(replacementObservation)
    }

    func testRootDirectorySynchronizationFailureRetainsTerminalBookkeeping()
        async throws
    {
        let workspace = try SafariHandoffTestWorkspace()
        let completedAt = Date(timeIntervalSinceReferenceDate: 50_000)
        let runID = BurnBarRunID(rawValue: "root-fsync-failure")
        let package = try workspace.makePackage(runID: runID)
        let factory = SafariHandoffTestSessionFactory()
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory,
            now: { completedAt },
            synchronization: SafariHandoffSynchronizationGate(
                fail: .rootDirectory,
                occurrence: 1
            )
        )
        _ = try await supervisor.launch(
            specification(
                runID: runID,
                package: package,
                identity: try filesystemIdentity(of: package)
            )
        )
        factory.sessionsSnapshot()[0].emitTerminal(
            .init(waitStatus: waitStatus(exitCode: 0), failure: nil)
        )
        _ = try await terminalObservation(
            from: supervisor,
            runID: runID
        )

        await supervisor.cleanupEligiblePackages(
            now: completedAt.addingTimeInterval(24 * 60 * 60)
        )

        let observation = await supervisor.observation(for: runID)
        XCTAssertNotNil(
            observation,
            "A failed root fsync must not be represented as durable cleanup"
        )
    }

    func testShutdownAllTerminatesEveryRunAndIsIdempotent() async throws {
        let workspace = try SafariHandoffTestWorkspace()
        let factory = SafariHandoffTestSessionFactory(
            configuration: .init(
                terminationTerminal: .init(
                    waitStatus: Int32(SIGTERM),
                    failure: nil
                )
            )
        )
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory
        )
        let firstRun = BurnBarRunID(rawValue: "shutdown-one")
        let secondRun = BurnBarRunID(rawValue: "shutdown-two")
        let firstPackage = try workspace.makePackage(runID: firstRun)
        let secondPackage = try workspace.makePackage(runID: secondRun)

        _ = try await supervisor.launch(
            specification(
                runID: firstRun,
                package: firstPackage,
                identity: try filesystemIdentity(of: firstPackage)
            )
        )
        _ = try await supervisor.launch(
            specification(
                runID: secondRun,
                package: secondPackage,
                identity: try filesystemIdentity(of: secondPackage)
            )
        )

        await supervisor.shutdownAll()

        let firstObservation = await supervisor.observation(for: firstRun)
        let secondObservation = await supervisor.observation(for: secondRun)
        let first = try XCTUnwrap(firstObservation)
        let second = try XCTUnwrap(secondObservation)
        XCTAssertEqual(first.state, .interrupted)
        XCTAssertEqual(first.terminationReason, .interrupted)
        XCTAssertEqual(first.failure, .interrupted)
        XCTAssertEqual(second.state, .interrupted)
        XCTAssertEqual(second.terminationReason, .interrupted)
        XCTAssertEqual(second.failure, .interrupted)
        XCTAssertEqual(
            factory.sessionsSnapshot().map(\.requestTerminationCount),
            [1, 1]
        )

        await supervisor.shutdownAll()
        XCTAssertEqual(
            factory.sessionsSnapshot().map(\.requestTerminationCount),
            [1, 1]
        )

        let rejectedRun = BurnBarRunID(rawValue: "shutdown-rejects-launch")
        let rejectedPackage = try workspace.makePackage(runID: rejectedRun)
        await assertLaunchFailure(
            supervisor,
            specification(
                runID: rejectedRun,
                package: rejectedPackage,
                identity: try filesystemIdentity(of: rejectedPackage)
            ),
            is: .shuttingDown
        )
    }

    func testShutdownDeadlineForceContainsOnlyTheLiveGenerationAndResumesWaiters()
        async throws
    {
        let workspace = try SafariHandoffTestWorkspace()
        let factory = SafariHandoffTestSessionFactory()
        let clock = SafariHandoffShutdownClock()
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory,
            sleep: { nanoseconds in
                clock.advance(by: nanoseconds)
                await Task.yield()
            },
            uptimeNanoseconds: {
                clock.now
            }
        )
        let runID = BurnBarRunID(rawValue: "shutdown-deadline")
        let package = try workspace.makePackage(runID: runID)

        _ = try await supervisor.launch(
            specification(
                runID: runID,
                package: package,
                identity: try filesystemIdentity(of: package)
            )
        )
        let session = try XCTUnwrap(factory.sessionsSnapshot().first)
        let cancellation = Task {
            await supervisor.cancel(runID: runID)
        }
        try await waitUntil {
            session.requestTerminationCount == 1
        }

        await supervisor.shutdownAll()

        let awaitedCancellation = await cancellation.value
        let cancellationObservation = try XCTUnwrap(awaitedCancellation)
        let currentObservation = await supervisor.observation(for: runID)
        let observation = try XCTUnwrap(currentObservation)
        XCTAssertEqual(cancellationObservation, observation)
        XCTAssertEqual(observation.state, .interrupted)
        XCTAssertEqual(observation.terminationReason, .interrupted)
        XCTAssertEqual(observation.failure, .interrupted)
        XCTAssertNil(observation.exitStatus)
        XCTAssertEqual(session.requestTerminationCount, 1)
        XCTAssertEqual(session.forceContainmentCount, 1)
        XCTAssertEqual(session.finishDrainingCount, 1)
        XCTAssertEqual(session.closeLivenessCount, 2)
        XCTAssertEqual(clock.now, 2_000_000_000)
        XCTAssertGreaterThan(clock.sleepCount, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath:
                    package
                    .appendingPathComponent("completion.json")
                    .path
            )
        )

        await supervisor.shutdownAll()
        XCTAssertEqual(session.requestTerminationCount, 1)
        XCTAssertEqual(session.forceContainmentCount, 1)
        XCTAssertEqual(session.closeLivenessCount, 2)
        XCTAssertEqual(clock.now, 2_000_000_000)
    }

    func testLaunchFailureRemovesOnlyTheExactPreparedPackage() async throws {
        let workspace = try SafariHandoffTestWorkspace()
        let runID = BurnBarRunID(rawValue: "watchdog-launch-failure")
        let package = try workspace.makePackage(runID: runID)
        let sibling = workspace.rootURL.appendingPathComponent(
            "sibling-package",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: sibling,
            withIntermediateDirectories: false
        )
        try setPermissions(0o700, on: sibling)
        let siblingMarker = sibling.appendingPathComponent("marker")
        try Data("preserve".utf8).write(to: siblingMarker)
        let factory = SafariHandoffTestSessionFactory(
            configuration: .init(startThrows: true)
        )
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory
        )

        await assertLaunchFailure(
            supervisor,
            specification(
                runID: runID,
                package: package,
                identity: try filesystemIdentity(of: package)
            ),
            is: .watchdogLaunchFailed
        )

        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: siblingMarker.path))
        let failedSession = try XCTUnwrap(factory.sessionsSnapshot().first)
        XCTAssertEqual(failedSession.forceContainmentCount, 1)
        XCTAssertEqual(failedSession.closeLivenessCount, 1)
        XCTAssertEqual(failedSession.finishDrainingCount, 1)
        XCTAssertEqual(
            failedSession.lifecycleEventsSnapshot(),
            [
                "start",
                "force-containment",
                "close-liveness",
                "finish-draining",
            ]
        )
    }

    func testDuplicateRunIsRejectedWithoutReplacingTheLiveGeneration()
        async throws
    {
        let workspace = try SafariHandoffTestWorkspace()
        let runID = BurnBarRunID(rawValue: "duplicate-run")
        let package = try workspace.makePackage(runID: runID)
        let factory = SafariHandoffTestSessionFactory()
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory
        )
        let launch = specification(
            runID: runID,
            package: package,
            identity: try filesystemIdentity(of: package)
        )

        _ = try await supervisor.launch(launch)
        await assertLaunchFailure(
            supervisor,
            launch,
            is: .duplicateRun
        )

        XCTAssertEqual(factory.sessionsSnapshot().count, 1)
        let stillRunning = await supervisor.observation(for: runID)
        XCTAssertEqual(stillRunning?.state, .running)
    }

    func testStaleTerminalCallbackCannotCompleteAReplacementGeneration()
        async throws
    {
        let workspace = try SafariHandoffTestWorkspace()
        let runID = BurnBarRunID(rawValue: "replacement-generation")
        let firstPackage = try workspace.makePackage(runID: runID)
        let factory = SafariHandoffTestSessionFactory()
        let supervisor = makeSupervisor(
            rootURL: workspace.rootURL,
            factory: factory
        )

        _ = try await supervisor.launch(
            specification(
                runID: runID,
                package: firstPackage,
                identity: try filesystemIdentity(of: firstPackage)
            )
        )
        let firstSession = factory.sessionsSnapshot()[0]
        firstSession.emitTerminal(
            .init(waitStatus: waitStatus(exitCode: 0), failure: nil)
        )
        _ = try await terminalObservation(
            from: supervisor,
            runID: runID
        )
        await supervisor.discard(runID: runID)

        let secondPackage = try workspace.makePackage(runID: runID)
        _ = try await supervisor.launch(
            specification(
                runID: runID,
                package: secondPackage,
                identity: try filesystemIdentity(of: secondPackage)
            )
        )
        let secondSession = factory.sessionsSnapshot()[1]

        firstSession.emitTerminal(
            .init(waitStatus: waitStatus(exitCode: 42), failure: nil)
        )
        try await Task.sleep(nanoseconds: 150_000_000)
        let afterStaleCallback = await supervisor.observation(for: runID)
        XCTAssertEqual(afterStaleCallback?.state, .running)

        secondSession.emitTerminal(
            .init(waitStatus: waitStatus(exitCode: 0), failure: nil)
        )
        let completed = try await terminalObservation(
            from: supervisor,
            runID: runID
        )
        XCTAssertEqual(completed.state, .completed)
        XCTAssertEqual(completed.exitStatus, 0)
    }
}

extension SafariHandoffProcessSupervisorTests {
    fileprivate enum ExpectedSupervisorError {
        case shuttingDown
        case duplicateRun
        case invalidSpecification
        case unsafePackage
        case outputPreparationFailed
        case watchdogLaunchFailed
    }

    fileprivate func makeSupervisor(
        rootURL: URL,
        factory: SafariHandoffTestSessionFactory,
        now: @escaping @Sendable () -> Date = Date.init,
        environment: [String: String] = [
            "HOME": NSHomeDirectory(),
            "USER": NSUserName(),
            "SHELL": "/bin/zsh",
            "LANG": "C",
        ],
        sleep: @escaping @Sendable (UInt64) async -> Void = {
            nanoseconds in
            try? await Task.sleep(nanoseconds: nanoseconds)
        },
        uptimeNanoseconds: @escaping @Sendable () -> UInt64 = {
            DispatchTime.now().uptimeNanoseconds
        },
        receiptAuthenticator:
            SafariHandoffProcessSupervisor.ReceiptAuthenticator =
                .hmacSHA256(key: Data(repeating: 0xA5, count: 32)),
        synchronization: SafariHandoffSynchronizationGate =
            SafariHandoffSynchronizationGate()
    ) -> SafariHandoffProcessSupervisor {
        SafariHandoffProcessSupervisor(
            rootURL: rootURL,
            now: now,
            dependencies: .init(
                environment: { environment },
                sleep: sleep,
                uptimeNanoseconds: uptimeNanoseconds,
                validateExecutable: { url, _ in
                    SafariHandoffProcessSupervisor.ValidatedExecutable(
                        path: url.path,
                        identity: .init(device: 1, inode: 1),
                        size: 1,
                        modificationSeconds: 1,
                        modificationNanoseconds: 0
                    )
                },
                makeSession: { context in
                    try factory.makeSession(context: context)
                },
                receiptAuthenticator: receiptAuthenticator,
                synchronize: { descriptor, point in
                    synchronization.synchronize(
                        descriptor: descriptor,
                        point: point
                    )
                }
            )
        )
    }

    fileprivate func specification(
        runID: BurnBarRunID,
        package: URL,
        identity: SafariHandoffProcessSupervisor.FilesystemIdentity,
        timeout: TimeInterval = 0
    ) -> SafariHandoffProcessSupervisor.LaunchSpecification {
        .init(
            runID: runID,
            targetHarness: "codex",
            packageDirectory: package,
            expectedPackageIdentity: identity,
            executableURL: URL(fileURLWithPath: "/usr/bin/true"),
            arguments: ["--version"],
            timeout: timeout
        )
    }

    fileprivate func assertLaunchFailure(
        _ supervisor: SafariHandoffProcessSupervisor,
        _ specification:
            SafariHandoffProcessSupervisor.LaunchSpecification,
        is expected: ExpectedSupervisorError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await supervisor.launch(specification)
            XCTFail(
                "Expected launch to fail with \(expected)",
                file: file,
                line: line
            )
        } catch let error as SafariHandoffProcessSupervisor.SupervisorError {
            let matches: Bool
            switch (error, expected) {
            case (.shuttingDown, .shuttingDown),
                (.duplicateRun, .duplicateRun),
                (.invalidSpecification, .invalidSpecification),
                (.unsafePackage, .unsafePackage),
                (.outputPreparationFailed, .outputPreparationFailed),
                (.watchdogLaunchFailed, .watchdogLaunchFailed):
                matches = true
            default:
                matches = false
            }
            XCTAssertTrue(
                matches,
                "Expected \(expected), got \(error)",
                file: file,
                line: line
            )
        } catch {
            XCTFail(
                "Expected supervisor error \(expected), got \(error)",
                file: file,
                line: line
            )
        }
    }

    fileprivate func terminalObservation(
        from supervisor: SafariHandoffProcessSupervisor,
        runID: BurnBarRunID,
        timeout: TimeInterval = 3,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> SafariHandoffProcessSupervisor.Observation {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let observation = await supervisor.observation(for: runID),
                observation.isTerminal
            {
                return observation
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail(
            "Run \(runID.rawValue) did not terminalize",
            file: file,
            line: line
        )
        throw SafariHandoffTestError.timedOut
    }

    fileprivate func waitUntil(
        timeout: TimeInterval = 1,
        condition: @escaping @Sendable () -> Bool
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while condition() == false, Date() < deadline {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        guard condition() else {
            throw SafariHandoffTestError.timedOut
        }
    }
}

private enum SafariHandoffTestError: Error {
    case invalidFilesystemState
    case sessionStart
    case timedOut
}

private final class SafariHandoffShutdownClock: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: UInt64 = 0
    private var _sleepCount = 0

    var now: UInt64 {
        locked { _now }
    }

    var sleepCount: Int {
        locked { _sleepCount }
    }

    func advance(by nanoseconds: UInt64) {
        locked {
            _sleepCount += 1
            _now &+= nanoseconds
        }
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class SafariHandoffSleepSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [UInt64] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private var waiters:
        [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var requestedNanoseconds: [UInt64] {
        locked { requests }
    }

    func sleep(_ nanoseconds: UInt64) async {
        await withCheckedContinuation { continuation in
            let readyWaiters = locked {
                requests.append(nanoseconds)
                continuations.append(continuation)
                let ready = waiters.filter { requests.count >= $0.count }
                waiters.removeAll { requests.count >= $0.count }
                return ready
            }
            readyWaiters.forEach { $0.continuation.resume() }
        }
    }

    func waitForRequest(count: Int) async throws {
        if requestedNanoseconds.count >= count {
            return
        }
        await withCheckedContinuation { continuation in
            let shouldResume = locked {
                if requests.count >= count {
                    return true
                }
                waiters.append((count, continuation))
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func resumeNext() {
        let continuation: CheckedContinuation<Void, Never>? = locked {
            guard continuations.isEmpty == false else { return nil }
            return continuations.removeFirst()
        }
        continuation?.resume()
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class SafariHandoffSleepGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var requestWaiters: [CheckedContinuation<Void, Never>] = []
    private var _requestedNanoseconds: UInt64?

    var requestedNanoseconds: UInt64? {
        locked { _requestedNanoseconds }
    }

    func sleep(_ nanoseconds: UInt64) async {
        await withCheckedContinuation { continuation in
            let waiters = locked {
                _requestedNanoseconds = nanoseconds
                self.continuation = continuation
                let waiters = requestWaiters
                requestWaiters.removeAll()
                return waiters
            }
            waiters.forEach { $0.resume() }
        }
    }

    func waitUntilRequested() async throws {
        if requestedNanoseconds != nil {
            return
        }
        await withCheckedContinuation { continuation in
            let shouldResume = locked {
                if _requestedNanoseconds != nil {
                    return true
                }
                requestWaiters.append(continuation)
                return false
            }
            if shouldResume {
                continuation.resume()
            }
        }
    }

    func resume() {
        let continuation = locked {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class SafariHandoffTestSessionFactory: @unchecked Sendable {
    struct Configuration: Sendable {
        var startThrows = false
        var startTerminals: [SafariHandoffProcessSupervisor.WatchdogTerminal] = []
        var terminationTerminal: SafariHandoffProcessSupervisor.WatchdogTerminal?
        var terminationRequestSucceeds = true
        var stdout = SafariHandoffProcessSupervisor.OutputSnapshot(
            data: Data(),
            observedBytes: 0,
            truncated: false
        )
        var stderr = SafariHandoffProcessSupervisor.OutputSnapshot(
            data: Data(),
            observedBytes: 0,
            truncated: false
        )
        var stdoutAfterFinishDraining: SafariHandoffProcessSupervisor.OutputSnapshot? = nil
        var stderrAfterFinishDraining: SafariHandoffProcessSupervisor.OutputSnapshot? = nil
        var finishDrainingGate: SafariHandoffFinishDrainGate? = nil
    }

    private let lock = NSLock()
    private let configuration: Configuration
    private var sessions: [SafariHandoffTestSession] = []
    private var contexts: [SafariHandoffProcessSupervisor.SessionLaunchContext] = []

    init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    func makeSession(
        context: SafariHandoffProcessSupervisor.SessionLaunchContext
    ) throws -> any SafariHandoffProcessSupervisor.WatchdogSession {
        let session = SafariHandoffTestSession(
            context: context,
            configuration: configuration
        )
        lock.lock()
        contexts.append(context)
        sessions.append(session)
        lock.unlock()
        return session
    }

    func sessionsSnapshot() -> [SafariHandoffTestSession] {
        lock.lock()
        defer { lock.unlock() }
        return sessions
    }

    func contextsSnapshot()
        -> [SafariHandoffProcessSupervisor.SessionLaunchContext]
    {
        lock.lock()
        defer { lock.unlock() }
        return contexts
    }
}

private final class SafariHandoffTestSession:
    SafariHandoffProcessSupervisor.WatchdogSession,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let context: SafariHandoffProcessSupervisor.SessionLaunchContext
    private let configuration: SafariHandoffTestSessionFactory.Configuration
    private var didDeliverTerminationTerminal = false
    private var _requestTerminationCount = 0
    private var _forceContainmentCount = 0
    private var _closeLivenessCount = 0
    private var _finishDrainingCount = 0
    private var lifecycleEvents: [String] = []

    init(
        context: SafariHandoffProcessSupervisor.SessionLaunchContext,
        configuration: SafariHandoffTestSessionFactory.Configuration
    ) {
        self.context = context
        self.configuration = configuration
    }

    var requestTerminationCount: Int {
        locked { _requestTerminationCount }
    }

    var forceContainmentCount: Int {
        locked { _forceContainmentCount }
    }

    var closeLivenessCount: Int {
        locked { _closeLivenessCount }
    }

    var finishDrainingCount: Int {
        locked { _finishDrainingCount }
    }

    func start() throws -> SafariHandoffProcessSupervisor.WatchdogReady {
        locked { lifecycleEvents.append("start") }
        if configuration.startThrows {
            throw SafariHandoffTestError.sessionStart
        }
        for terminal in configuration.startTerminals {
            context.onTerminal(terminal)
        }
        locked { lifecycleEvents.append("ready") }
        return .init(
            watchdogPID: 10_001,
            processGroupID: 10_002,
            containmentIdentity: .init(
                processID: 10_002,
                processGroupID: 10_002,
                startSeconds: 1,
                startMicroseconds: 2
            )
        )
    }

    @discardableResult
    func requestTermination() -> Bool {
        let terminal: SafariHandoffProcessSupervisor.WatchdogTerminal? =
            locked {
                _requestTerminationCount += 1
                guard configuration.terminationRequestSucceeds else {
                    return nil
                }
                guard didDeliverTerminationTerminal == false else {
                    return nil
                }
                didDeliverTerminationTerminal = true
                return configuration.terminationTerminal
            }
        if let terminal {
            context.onTerminal(terminal)
        }
        return configuration.terminationRequestSucceeds
    }

    func forceContainment() {
        locked {
            _forceContainmentCount += 1
            lifecycleEvents.append("force-containment")
        }
    }

    func closeLiveness() {
        locked {
            _closeLivenessCount += 1
            lifecycleEvents.append("close-liveness")
        }
    }

    func stdoutSnapshot()
        -> SafariHandoffProcessSupervisor.OutputSnapshot
    {
        locked {
            if _finishDrainingCount > 0,
                let drained = configuration.stdoutAfterFinishDraining
            {
                return drained
            }
            return configuration.stdout
        }
    }

    func stderrSnapshot()
        -> SafariHandoffProcessSupervisor.OutputSnapshot
    {
        locked {
            if _finishDrainingCount > 0,
                let drained = configuration.stderrAfterFinishDraining
            {
                return drained
            }
            return configuration.stderr
        }
    }

    func finishDraining() {
        locked {
            _finishDrainingCount += 1
            lifecycleEvents.append("finish-draining")
        }
        configuration.finishDrainingGate?.enterAndWait()
    }

    func lifecycleEventsSnapshot() -> [String] {
        locked { lifecycleEvents }
    }

    func emitTerminal(
        _ terminal: SafariHandoffProcessSupervisor.WatchdogTerminal
    ) {
        context.onTerminal(terminal)
    }

    func emitFailure(_ message: String) {
        context.onFailure(message)
    }

    @discardableResult
    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

private final class SafariHandoffCompletionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    var isCompleted: Bool {
        lock.lock()
        defer { lock.unlock() }
        return completed
    }

    func markCompleted() {
        lock.lock()
        completed = true
        lock.unlock()
    }
}

private final class SafariHandoffFinishDrainGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var entered = false

    func enterAndWait() {
        lock.lock()
        entered = true
        lock.unlock()
        semaphore.wait()
    }

    func waitUntilEntered() async throws {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            lock.lock()
            let hasEntered = entered
            lock.unlock()
            if hasEntered {
                return
            }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw SafariHandoffTestError.timedOut
    }

    func resume() {
        semaphore.signal()
    }
}

private final class SafariHandoffSynchronizationGate: @unchecked Sendable {
    enum Point: Hashable {
        case outputFile
        case receiptFile
        case packageDirectory
        case rootDirectory
    }

    private let lock = NSLock()
    private let failedPoint: Point?
    private let failedOccurrence: Int
    private var occurrences: [Point: Int] = [:]

    init(fail point: Point? = nil, occurrence: Int = 1) {
        failedPoint = point
        failedOccurrence = occurrence
    }

    func synchronize(
        descriptor: Int32,
        point: SafariHandoffProcessSupervisor.SynchronizationPoint
    ) -> Bool {
        _ = descriptor
        let mapped: Point
        switch point {
        case .outputFile:
            mapped = .outputFile
        case .receiptFile:
            mapped = .receiptFile
        case .packageDirectory:
            mapped = .packageDirectory
        case .rootDirectory:
            mapped = .rootDirectory
        }
        lock.lock()
        occurrences[mapped, default: 0] += 1
        let occurrence = occurrences[mapped]
        lock.unlock()
        return mapped != failedPoint || occurrence != failedOccurrence
    }
}

private final class SafariHandoffTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) {
        self.value = value
    }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class SafariHandoffTestWorkspace {
    let containerURL: URL
    let rootURL: URL

    init(requiresTrustedParentDirectories: Bool = false) throws {
        let parent = requiresTrustedParentDirectories
            ? FileManager.default.homeDirectoryForCurrentUser
            : FileManager.default.temporaryDirectory
                .resolvingSymlinksInPath()
        containerURL = parent.appendingPathComponent(
            requiresTrustedParentDirectories
                ? ".safari-handoff-supervisor-\(UUID().uuidString)"
                : "safari-handoff-supervisor-\(UUID().uuidString)",
            isDirectory: true
        )
        rootURL = containerURL.appendingPathComponent(
            "handoffs",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
        try setPermissions(0o700, on: containerURL)
        try setPermissions(0o700, on: rootURL)
    }

    deinit {
        try? FileManager.default.removeItem(at: containerURL)
    }

    func makePackage(runID: BurnBarRunID) throws -> URL {
        let package = rootURL.appendingPathComponent(
            runID.rawValue,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: false
        )
        try setPermissions(0o700, on: package)
        try writeOwnerOnly(
            Data("# Safari hand-off test briefing\n".utf8),
            to: package.appendingPathComponent("BRIEFING.md")
        )
        return package
    }

    func makeExecutable(
        named name: String,
        contents: String = "#!/bin/sh\nexit 0\n"
    ) throws -> URL {
        let executable = containerURL.appendingPathComponent(name)
        try Data(contents.utf8).write(
            to: executable,
            options: .withoutOverwriting
        )
        try setPermissions(0o755, on: executable)
        return executable
    }

    func makePersistedOutputFiles(
        in package: URL,
        stdout: Data = Data(),
        stderr: Data = Data()
    ) throws {
        try writeOwnerOnly(
            stdout,
            to: package.appendingPathComponent("stdout.log")
        )
        try writeOwnerOnly(
            stderr,
            to: package.appendingPathComponent("stderr.log")
        )
    }

    func writeOwnerOnly(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .withoutOverwriting)
        try setPermissions(0o600, on: url)
    }

    func writeReceipt(
        in package: URL,
        runID: BurnBarRunID,
        targetHarness: String,
        identity: SafariHandoffProcessSupervisor.FilesystemIdentity,
        launchedAt: Date,
        completedAt: Date,
        schemaVersion: Int = 4,
        stdoutBytes: Int = 0,
        stderrBytes: Int = 0,
        stdoutObservedBytes: Int = 0,
        stderrObservedBytes: Int = 0,
        stdoutTruncated: Bool = false,
        stderrTruncated: Bool = false,
        authenticator:
            SafariHandoffProcessSupervisor.ReceiptAuthenticator =
                .hmacSHA256(key: Data(repeating: 0xA5, count: 32))
    ) throws {
        let stdout = try Data(
            contentsOf: package.appendingPathComponent("stdout.log")
        )
        let stderr = try Data(
            contentsOf: package.appendingPathComponent("stderr.log")
        )
        let receipt = try SafariHandoffProcessSupervisor.CompletionReceipt(
            schemaVersion: schemaVersion,
            runID: runID.rawValue,
            targetHarness: targetHarness,
            packageIdentity: identity,
            launchedAt: launchedAt,
            completedAt: completedAt,
            terminationReason: .exit,
            exitStatus: 0,
            stdoutBytes: stdoutBytes,
            stderrBytes: stderrBytes,
            stdoutObservedBytes: stdoutObservedBytes,
            stderrObservedBytes: stderrObservedBytes,
            stdoutTruncated: stdoutTruncated,
            stderrTruncated: stderrTruncated,
            stdoutSHA256: PlatformCrypto.sha256Hex(stdout),
            stderrSHA256: PlatformCrypto.sha256Hex(stderr),
            authenticationCode: ""
        )
        .authenticated(using: authenticator)
        try writeOwnerOnly(
            try JSONEncoder().encode(receipt),
            to: package.appendingPathComponent("completion.json")
        )
    }
}

private struct SafariHandoffTestReceipt: Codable {
    let schemaVersion: Int
    let runID: String
    let targetHarness: String
    let packageIdentity: SafariHandoffProcessSupervisor.FilesystemIdentity
    let launchedAt: Date
    let completedAt: Date
    let terminationReason: SafariHandoffProcessSupervisor.TerminationReason
    let exitStatus: Int32?
    let stdoutBytes: Int
    let stderrBytes: Int
    let stdoutObservedBytes: Int
    let stderrObservedBytes: Int
    let stdoutTruncated: Bool
    let stderrTruncated: Bool
    let stdoutSHA256: String
    let stderrSHA256: String
    let authenticationCode: String
}

private func waitStatus(exitCode: Int32) -> Int32 {
    exitCode << 8
}

private func filesystemIdentity(
    of url: URL
) throws -> SafariHandoffProcessSupervisor.FilesystemIdentity {
    var information = stat()
    guard lstat(url.path, &information) == 0 else {
        throw SafariHandoffTestError.invalidFilesystemState
    }
    return .init(
        device: UInt64(information.st_dev),
        inode: UInt64(information.st_ino)
    )
}

private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(
        atPath: url.path
    )
    guard let permissions = attributes[.posixPermissions] as? NSNumber else {
        throw SafariHandoffTestError.invalidFilesystemState
    }
    return permissions.intValue
}

private func setPermissions(_ permissions: Int, on url: URL) throws {
    try FileManager.default.setAttributes(
        [.posixPermissions: NSNumber(value: permissions)],
        ofItemAtPath: url.path
    )
}
