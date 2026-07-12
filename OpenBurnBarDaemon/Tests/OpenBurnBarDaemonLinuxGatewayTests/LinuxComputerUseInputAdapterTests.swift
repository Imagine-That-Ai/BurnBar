#if os(Linux)
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

final class LinuxComputerUseInputAdapterTests: XCTestCase {
    func testAtspiClickPlanUsesPythonWhenSessionBusIsAvailable() throws {
        let adapter = LinuxComputerUseInputAdapter(
            environment: { name in
                ["DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"][name]
            },
            resolveExecutable: { name in
                name == "python3" ? "/usr/bin/python3" : nil
            },
            runCommand: { _, _ in LinuxComputerUseInputAdapter.CommandResult(exitCode: 0) }
        )

        let plan = try adapter.plan(
            for: MacInputAction(kind: .click, displayX: 220, displayY: 160)
        )

        XCTAssertEqual(plan.adapter, .atspi2)
        XCTAssertEqual(plan.executableName, "python3")
        XCTAssertEqual(Array(plan.arguments.suffix(2)), ["220", "160"])
    }

    func testX11FallbackDispatchDoesNotEchoTypedSecretInResult() async throws {
        let recorder = CommandRecorder()
        let adapter = LinuxComputerUseInputAdapter(
            environment: { name in
                ["DISPLAY": ":99"][name]
            },
            resolveExecutable: { name in
                name == "xdotool" ? "/usr/bin/xdotool" : nil
            },
            runCommand: { executable, arguments in
                recorder.record(executable: executable, arguments: arguments)
                return LinuxComputerUseInputAdapter.CommandResult(exitCode: 0, stdout: "typed\n")
            }
        )

        let result = try await adapter.dispatch(
            MacInputAction(kind: .type, text: "super-secret")
        )

        XCTAssertEqual(recorder.lastExecutable, "/usr/bin/xdotool")
        XCTAssertEqual(recorder.lastArguments, ["type", "--clearmodifiers", "--delay", "0", "super-secret"])
        guard case .object(let object) = result else {
            XCTFail("expected object result")
            return
        }
        XCTAssertEqual(object.stringValue(forKey: "adapter"), "x11-xtest")
        XCTAssertEqual(object.intValue(forKey: "textLength"), 12)
        XCTAssertNil(object.stringValue(forKey: "text"))
    }

    func testUnavailableInputAdapterFailsClosed() {
        let adapter = LinuxComputerUseInputAdapter(
            environment: { _ in nil },
            resolveExecutable: { _ in nil },
            runCommand: { _, _ in LinuxComputerUseInputAdapter.CommandResult(exitCode: 0) }
        )

        XCTAssertThrowsError(
            try adapter.plan(for: MacInputAction(kind: .click, displayX: 1, displayY: 2))
        ) { error in
            XCTAssertEqual(
                error as? LinuxComputerUseInputAdapter.AdapterError,
                .adapterUnavailable("no approved Linux input adapter is available")
            )
        }
    }

    func testDenyRegionInspectorMapsPasswordRoleAtPoint() {
        let recorder = CommandRecorder()
        let adapter = LinuxComputerUseInputAdapter(
            environment: { name in
                ["DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"][name]
            },
            resolveExecutable: { name in
                name == "python3" ? "/usr/bin/python3" : nil
            },
            runCommand: { executable, arguments in
                recorder.record(executable: executable, arguments: arguments)
                return LinuxComputerUseInputAdapter.CommandResult(
                    exitCode: 0,
                    stdout: #"{"inspectable":true,"denyReason":"secure_text_field","detail":null}"#
                )
            }
        )

        let reason = adapter.accessibilityDenyReason(
            for: MacInputAction(kind: .click, displayX: 220, displayY: 160)
        )

        XCTAssertEqual(reason, .secureTextField)
        XCTAssertEqual(recorder.lastExecutable, "/usr/bin/python3")
        XCTAssertEqual(Array(recorder.lastArguments?.suffix(3) ?? []), ["point", "220", "160"])
    }

    func testDenyRegionInspectorFailsClosedWhenTargetIsUninspectable() {
        let adapter = LinuxComputerUseInputAdapter(
            environment: { name in
                ["DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"][name]
            },
            resolveExecutable: { name in
                name == "python3" ? "/usr/bin/python3" : nil
            },
            runCommand: { _, _ in
                LinuxComputerUseInputAdapter.CommandResult(
                    exitCode: 0,
                    stdout: #"{"inspectable":false,"denyReason":null,"detail":"no accessible target"}"#
                )
            }
        )

        let reason = adapter.accessibilityDenyReason(
            for: MacInputAction(kind: .click, displayX: 10, displayY: 20)
        )

        XCTAssertEqual(reason, .unknown)
    }

    func testDenyRegionInspectorUsesFocusedAccessibleForKeyboardInput() {
        let recorder = CommandRecorder()
        let adapter = LinuxComputerUseInputAdapter(
            environment: { name in
                ["DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"][name]
            },
            resolveExecutable: { name in
                name == "python3" ? "/usr/bin/python3" : nil
            },
            runCommand: { executable, arguments in
                recorder.record(executable: executable, arguments: arguments)
                return LinuxComputerUseInputAdapter.CommandResult(
                    exitCode: 0,
                    stdout: #"{"inspectable":true,"denyReason":null,"detail":null}"#
                )
            }
        )

        let reason = adapter.accessibilityDenyReason(
            for: MacInputAction(kind: .type, text: "redacted-in-test")
        )

        XCTAssertNil(reason)
        XCTAssertEqual(recorder.lastExecutable, "/usr/bin/python3")
        XCTAssertEqual(recorder.lastArguments?.last, "focus")
    }

    func testDenyRegionInspectorChecksAbsolutePointerMoveTarget() {
        let recorder = CommandRecorder()
        let adapter = LinuxComputerUseInputAdapter(
            environment: { name in
                ["DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"][name]
            },
            resolveExecutable: { name in
                name == "python3" ? "/usr/bin/python3" : nil
            },
            runCommand: { executable, arguments in
                recorder.record(executable: executable, arguments: arguments)
                return LinuxComputerUseInputAdapter.CommandResult(
                    exitCode: 0,
                    stdout: #"{"inspectable":false,"denyReason":null,"detail":"no accessible target"}"#
                )
            }
        )

        let reason = adapter.accessibilityDenyReason(
            for: MacInputAction(kind: .pointerMove, displayX: 400, displayY: 300)
        )

        XCTAssertEqual(reason, .unknown)
        XCTAssertEqual(Array(recorder.lastArguments?.suffix(3) ?? []), ["point", "400", "300"])
    }

    func testKillSwitchFlagBlocksDispatchBeforeCommandRuns() async throws {
        let flagPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-cu-kill-\(UUID().uuidString)")
            .path
        try "hotkey".write(toFile: flagPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: flagPath) }

        let recorder = CommandRecorder()
        let adapter = LinuxComputerUseInputAdapter(
            environment: { name in
                [
                    "DISPLAY": ":99",
                    "OPENBURNBAR_PRIVILEGED_INPUT_KILL_FLAG_PATH": flagPath
                ][name]
            },
            resolveExecutable: { name in
                name == "xdotool" ? "/usr/bin/xdotool" : nil
            },
            runCommand: { executable, arguments in
                recorder.record(executable: executable, arguments: arguments)
                return LinuxComputerUseInputAdapter.CommandResult(exitCode: 0)
            }
        )

        do {
            _ = try await adapter.dispatch(MacInputAction(kind: .click, displayX: 10, displayY: 20))
            XCTFail("dispatch should fail while the privileged input kill flag is active")
        } catch {
            XCTAssertEqual(error as? LinuxComputerUseInputAdapter.AdapterError, .killSwitchActive(flagPath))
            XCTAssertNil(recorder.lastExecutable)
        }
    }

    func testRuntimeDirectoryKillSwitchFlagBlocksDispatchByDefault() async throws {
        let runtimeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-cu-runtime-\(UUID().uuidString)", isDirectory: true)
        let flagPath = runtimeDirectory
            .appendingPathComponent("openburnbar", isDirectory: true)
            .appendingPathComponent("privileged-input-kill")
            .path
        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: flagPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "hotkey".write(toFile: flagPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: runtimeDirectory) }

        let recorder = CommandRecorder()
        let adapter = LinuxComputerUseInputAdapter(
            environment: { name in
                [
                    "DISPLAY": ":99",
                    "XDG_RUNTIME_DIR": runtimeDirectory.path
                ][name]
            },
            resolveExecutable: { name in
                name == "xdotool" ? "/usr/bin/xdotool" : nil
            },
            runCommand: { executable, arguments in
                recorder.record(executable: executable, arguments: arguments)
                return LinuxComputerUseInputAdapter.CommandResult(exitCode: 0)
            }
        )

        do {
            _ = try await adapter.dispatch(MacInputAction(kind: .click, displayX: 10, displayY: 20))
            XCTFail("dispatch should fail while the XDG runtime kill flag is active")
        } catch {
            XCTAssertEqual(error as? LinuxComputerUseInputAdapter.AdapterError, .killSwitchActive(flagPath))
            XCTAssertNil(recorder.lastExecutable)
        }
    }
}

final class LinuxComputerUseServiceSystemInputTests: XCTestCase {
    func testSystemSessionApprovesAndDispatchesThroughInjectedLinuxInput() async throws {
        let auditDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-cu-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: auditDirectory) }

        let recorder = MacInputActionRecorder()
        let service = try await makeService(
            auditBaseDirectory: auditDirectory,
            systemInputDispatcher: { _, action in
                recorder.record(action)
                return .object(["posted": .bool(true), "adapter": .string("test-linux")])
            }
        )
        let start = try await service.startSession(
            ComputerUseSessionStartRequest(
                mode: ComputerUseMode.system.rawValue,
                trustMode: ComputerUseTrustMode.manual.rawValue,
                clientID: BurnBarClientID(rawValue: "linux-test-client")
            )
        )

        let invokeTask = Task.detached(priority: .userInitiated) {
            try await service.invoke(
                ComputerUseInvokeRequest(
                    sessionId: start.sessionId,
                    invocation: BurnBarToolInvocation(
                        callID: "call-linux-click",
                        runID: BurnBarRunID(rawValue: "run-linux-click"),
                        tool: .macInputClick,
                        arguments: .object([
                            "displayX": .number(220),
                            "displayY": .number(160)
                        ]),
                        requestedBy: BurnBarClientID(rawValue: "linux-test-client"),
                        requestedAt: Date()
                    )
                )
            )
        }
        defer { invokeTask.cancel() }

        let approval = try await waitForApproval(service: service, sessionId: start.sessionId)
        let accepted = await service.respondToApproval(
            ComputerUseApprovalRespondRequest(
                sessionId: start.sessionId,
                response: HermesRealtimeRelayApprovalResponse(
                    approvalId: approval.approvalId,
                    decision: .approve,
                    respondedBy: "mac",
                    respondedAt: Date()
                )
            )
        )
        XCTAssertTrue(accepted.accepted)

        let response = try await invokeTask.value
        XCTAssertEqual(response.status, .executed)
        XCTAssertEqual(response.result?.succeeded, true)
        XCTAssertEqual(recorder.last?.kind, .click)
        XCTAssertEqual(recorder.last?.displayX, 220)
        XCTAssertEqual(recorder.last?.displayY, 160)
    }

    func testWildcardPanicHaltActivatesLinuxKillFlag() async throws {
        let auditDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-cu-\(UUID().uuidString)", isDirectory: true)
        let flagDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-cu-kill-\(UUID().uuidString)", isDirectory: true)
        let flagPath = flagDirectory
            .appendingPathComponent("privileged-input-kill")
            .path
        defer {
            try? FileManager.default.removeItem(at: auditDirectory)
            try? FileManager.default.removeItem(at: flagDirectory)
        }

        let service = try await makeService(
            auditBaseDirectory: auditDirectory,
            systemInputDispatcher: { _, _ in .object(["posted": .bool(true)]) },
            privilegedInputKillSwitchActivator: { reason in
                let flagURL = URL(fileURLWithPath: flagPath)
                try? FileManager.default.createDirectory(
                    at: flagURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try? reason.write(toFile: flagPath, atomically: true, encoding: .utf8)
            }
        )
        _ = try await service.startSession(
            ComputerUseSessionStartRequest(
                mode: ComputerUseMode.system.rawValue,
                trustMode: ComputerUseTrustMode.manual.rawValue,
                clientID: BurnBarClientID(rawValue: "linux-test-client")
            )
        )

        let response = try await service.panicHalt(
            ComputerUsePanicHaltRequest(sessionId: "*", source: ComputerUsePanicSource.hotkey.rawValue)
        )

        XCTAssertEqual(response.sessionId, "*")
        XCTAssertEqual(try String(contentsOfFile: flagPath, encoding: .utf8), "hotkey")
    }

    func testPasswordFieldDenyRegionRejectsBeforeLinuxDispatchAndAudits() async throws {
        let auditDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-cu-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: auditDirectory) }

        let recorder = MacInputActionRecorder()
        let service = try await makeService(
            auditBaseDirectory: auditDirectory,
            systemInputDispatcher: { _, action in
                recorder.record(action)
                return .object(["posted": .bool(true)])
            },
            systemInputAccessibilityDeny: { _ in .secureTextField }
        )
        let start = try await service.startSession(
            ComputerUseSessionStartRequest(
                mode: ComputerUseMode.system.rawValue,
                trustMode: ComputerUseTrustMode.manual.rawValue,
                clientID: BurnBarClientID(rawValue: "linux-test-client")
            )
        )

        let response = try await service.invoke(
            ComputerUseInvokeRequest(
                sessionId: start.sessionId,
                invocation: BurnBarToolInvocation(
                    callID: "call-linux-password-field",
                    runID: BurnBarRunID(rawValue: "run-linux-password-field"),
                    tool: .macInputClick,
                    arguments: .object([
                        "displayX": .number(220),
                        "displayY": .number(160)
                    ]),
                    requestedBy: BurnBarClientID(rawValue: "linux-test-client"),
                    requestedAt: Date()
                )
            )
        )

        XCTAssertEqual(response.status, .denied)
        XCTAssertEqual(response.denyReason, ComputerUseDenyReason.denyRegion.rawValue)
        XCTAssertNil(recorder.last)
        let entries = try auditEntries(
            baseDirectory: auditDirectory,
            sessionId: ComputerUseSessionID(start.sessionId)
        )
        let entry = try XCTUnwrap(entries.last)
        XCTAssertEqual(entry.approvedBy, .denied)
        XCTAssertEqual(entry.denyReason, ComputerUseDenyReason.denyRegion.rawValue)
        XCTAssertEqual(entry.actionKind, "mac.input.click")
    }

    func testUninspectableLinuxRegionFailsClosedBeforeDispatch() async throws {
        let auditDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-cu-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: auditDirectory) }

        let recorder = MacInputActionRecorder()
        let service = try await makeService(
            auditBaseDirectory: auditDirectory,
            systemInputDispatcher: { _, action in
                recorder.record(action)
                return .object(["posted": .bool(true)])
            },
            systemInputAccessibilityDeny: { _ in .unknown }
        )
        let start = try await service.startSession(
            ComputerUseSessionStartRequest(
                mode: ComputerUseMode.system.rawValue,
                trustMode: ComputerUseTrustMode.manual.rawValue,
                clientID: BurnBarClientID(rawValue: "linux-test-client")
            )
        )

        let response = try await service.invoke(
            ComputerUseInvokeRequest(
                sessionId: start.sessionId,
                invocation: BurnBarToolInvocation(
                    callID: "call-linux-uninspectable-type",
                    runID: BurnBarRunID(rawValue: "run-linux-uninspectable-type"),
                    tool: .macInputType,
                    arguments: .object([
                        "text": .string("password-field-fixture")
                    ]),
                    requestedBy: BurnBarClientID(rawValue: "linux-test-client"),
                    requestedAt: Date()
                )
            )
        )

        XCTAssertEqual(response.status, .denied)
        XCTAssertEqual(response.denyReason, ComputerUseDenyReason.denyRegion.rawValue)
        XCTAssertNil(recorder.last)
    }

    func testLinuxKillSwitchProviderDeniesBeforeDispatch() async throws {
        let auditDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-cu-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: auditDirectory) }

        let recorder = MacInputActionRecorder()
        let service = try await makeService(
            auditBaseDirectory: auditDirectory,
            systemInputDispatcher: { _, action in
                recorder.record(action)
                return .object(["posted": .bool(true)])
            },
            computerUseKillSwitchEnabled: { true }
        )
        do {
            _ = try await service.startSession(
                ComputerUseSessionStartRequest(
                    mode: ComputerUseMode.system.rawValue,
                    trustMode: ComputerUseTrustMode.manual.rawValue,
                    clientID: BurnBarClientID(rawValue: "linux-test-client")
                )
            )
            XCTFail("an active kill switch must deny the session before dispatch")
        } catch {
            XCTAssertEqual(
                error as? ComputerUseService.ServiceError,
                .capabilityDenied(ComputerUseDenyReason.killSwitch.rawValue)
            )
        }
        XCTAssertNil(recorder.last)
    }

    func testConcurrentLinuxSystemSessionDeniesBeforeDispatch() async throws {
        let auditDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-linux-cu-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: auditDirectory) }

        let recorder = MacInputActionRecorder()
        let service = try await makeService(
            auditBaseDirectory: auditDirectory,
            systemInputDispatcher: { _, action in
                recorder.record(action)
                return .object(["posted": .bool(true)])
            }
        )
        _ = try await service.startSession(
            ComputerUseSessionStartRequest(
                mode: ComputerUseMode.system.rawValue,
                trustMode: ComputerUseTrustMode.manual.rawValue,
                clientID: BurnBarClientID(rawValue: "linux-test-client")
            )
        )
        do {
            _ = try await service.startSession(
                ComputerUseSessionStartRequest(
                    mode: ComputerUseMode.system.rawValue,
                    trustMode: ComputerUseTrustMode.manual.rawValue,
                    clientID: BurnBarClientID(rawValue: "linux-test-client")
                )
            )
            XCTFail("a concurrent system session must be denied before dispatch")
        } catch {
            XCTAssertEqual(
                error as? ComputerUseService.ServiceError,
                .capabilityDenied(ComputerUseDenyReason.concurrentSession.rawValue)
            )
        }
        XCTAssertNil(recorder.last)
    }

    private func waitForApproval(
        service: ComputerUseService,
        sessionId: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> HermesRealtimeRelayApprovalRequest {
        for _ in 0..<40 {
            let pending = await service.pendingApprovals(
                ComputerUseApprovalPendingRequest(sessionId: sessionId)
            )
            if let approval = pending.requests.first {
                return approval
            }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
        XCTFail("timed out waiting for Computer Use approval", file: file, line: line)
        throw NSError(domain: "LinuxComputerUseServiceSystemInputTests", code: 1)
    }

    private func makeService(
        auditBaseDirectory: URL,
        systemInputDispatcher: @escaping ComputerUseRunCoordinator.MacInputDispatcher,
        systemInputAccessibilityDeny: @escaping @Sendable (MacInputAction) async -> ComputerUseAccessibilityDenyReason? = { _ in nil },
        computerUseKillSwitchEnabled: @escaping @Sendable () -> Bool = { false },
        privilegedInputKillSwitchActivator: (@Sendable (String) -> Void)? = nil
    ) async throws -> ComputerUseService {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let capabilityStateStore = ComputerUseCapabilityStateStore(
            fileURL: auditBaseDirectory.appendingPathComponent("capability-state.json"),
            now: { now }
        )
        _ = try await capabilityStateStore.update(capabilityState(generatedAt: now))
        return ComputerUseService(
            auditBaseDirectory: auditBaseDirectory,
            bridgeScriptURL: URL(fileURLWithPath: "/tmp/missing-playwright-bridge.js"),
            capabilityStateStore: capabilityStateStore,
            leafKillSwitch: { false },
            playwrightDriverFactory: nil,
            systemInputDispatcher: systemInputDispatcher,
            systemInputAccessibilityTrusted: { mode in mode == .system },
            systemInputAccessibilityDeny: systemInputAccessibilityDeny,
            computerUseKillSwitchEnabled: computerUseKillSwitchEnabled,
            privilegedInputKillSwitchActivator: privilegedInputKillSwitchActivator,
            logger: BurnBarDaemonLogger(category: "linux-cu-service-test")
        )
    }

    private func capabilityState(generatedAt: Date) -> ComputerUseCapabilityStateSnapshot {
        let provenance = ComputerUseAuthorityProvenance(
            source: .firestoreServer,
            observedAt: generatedAt,
            updatedAt: generatedAt
        )
        return ComputerUseCapabilityStateSnapshot(
            publisherInstanceID: "linux-system-input-tests",
            revision: 1,
            generatedAt: generatedAt,
            userID: "linux-test-user",
            entitlement: ComputerUseEntitlementSnapshot(
                isActive: true,
                productId: ComputerUseEntitlementSnapshot.hostedProductID,
                expireAt: generatedAt.addingTimeInterval(3_600),
                allowsBrowser: true,
                allowsSystem: true,
                allowsPhoneControl: true,
                allowsTrustedScopes: true,
                allowsAuditExport: true
            ),
            entitlementProvenance: provenance,
            budgetEnvelope: ComputerUseBudgetEnvelope(
                level: .normal,
                projectedMonthEndUSD: 0,
                monthToDateUSD: 0,
                activeActionsPerRun: 50,
                activeActionsPerDay: 200,
                activeSessionsPerDay: 4,
                perUserDailySpendCeilingUSD: 5,
                updatedAt: generatedAt
            ),
            budgetProvenance: provenance,
            quotaUsage: ComputerUseQuotaUsage(
                dayKey: "2027-01-15",
                updatedAt: generatedAt
            ),
            quotaProvenance: provenance,
            concurrentSessionActive: false,
            killSwitch: false,
            isComplete: true
        )
    }

    private func auditEntries(
        baseDirectory: URL,
        sessionId: ComputerUseSessionID
    ) throws -> [ComputerUseAuditEntry] {
        let chainURL = baseDirectory
            .appendingPathComponent(sessionId.rawValue, isDirectory: true)
            .appendingPathComponent("chain.jsonl")
        let data = try Data(contentsOf: chainURL)
        let lines = try XCTUnwrap(String(data: data, encoding: .utf8)?.split(separator: "\n"))
        return try lines.map { line in
            try ComputerUseAuditHasher.canonicalJSONDecoder.decode(
                ComputerUseAuditEntry.self,
                from: Data(line.utf8)
            )
        }
    }
}

private final class CommandRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var executable: String?
    private var arguments: [String]?

    func record(executable: String, arguments: [String]) {
        lock.lock()
        self.executable = executable
        self.arguments = arguments
        lock.unlock()
    }

    var lastExecutable: String? {
        lock.lock()
        defer { lock.unlock() }
        return executable
    }

    var lastArguments: [String]? {
        lock.lock()
        defer { lock.unlock() }
        return arguments
    }
}

private final class MacInputActionRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var action: MacInputAction?

    func record(_ action: MacInputAction) {
        lock.lock()
        self.action = action
        lock.unlock()
    }

    var last: MacInputAction? {
        lock.lock()
        defer { lock.unlock() }
        return action
    }
}
#endif
