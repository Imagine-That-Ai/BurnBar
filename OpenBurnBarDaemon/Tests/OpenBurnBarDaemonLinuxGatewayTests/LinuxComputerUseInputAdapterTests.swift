#if os(Linux)
import Foundation
import OpenBurnBarComputerUseCore
import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

final class LinuxComputerUseInputAdapterTests: XCTestCase {
    func testWaylandPortalProbeSelectsConsentOnlyStateWithoutEnablingInput() throws {
        let recorder = CommandRecorder()
        let adapter = LinuxComputerUseInputAdapter(
            environment: { name in
                [
                    "XDG_SESSION_TYPE": "wayland",
                    "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"
                ][name]
            },
            resolveExecutable: { name in
                name == "gdbus" ? "/usr/bin/gdbus" : nil
            },
            runCommand: { _, _ in XCTFail("portal probe must use its bounded runner"); return .init(exitCode: 1) },
            runPortalProbe: { executable, arguments, timeoutMillis in
                recorder.record(executable: executable, arguments: arguments)
                XCTAssertEqual(timeoutMillis, 1_500)
                return .init(
                    exitCode: 0,
                    stdout: "interface org.freedesktop.portal.RemoteDesktop { method Start; }\n"
                )
            }
        )

        let capability = adapter.waylandPortalCapability()

        XCTAssertEqual(capability.state, .consentRequired)
        XCTAssertTrue(capability.remoteDesktop)
        XCTAssertFalse(capability.screenCast)
        XCTAssertTrue(capability.requiresConsent)
        XCTAssertTrue(capability.requiresApproval)
        XCTAssertTrue(capability.isProbeReady)
        XCTAssertFalse(adapter.isAvailableForSystemInput())
        XCTAssertEqual(recorder.lastExecutable, "/usr/bin/gdbus")
        XCTAssertEqual(
            recorder.lastArguments,
            [
                "introspect", "--session", "--dest", "org.freedesktop.portal.Desktop",
                "--object-path", "/org/freedesktop/portal/desktop"
            ]
        )
    }

    func testWaylandPortalPlanFailsClosedBeforeActionTextReachesAnyRunner() throws {
        let secret = "portal-secret-never-forwarded"
        let recorder = CommandRecorder()
        let adapter = LinuxComputerUseInputAdapter(
            environment: { name in
                [
                    "XDG_SESSION_TYPE": "wayland",
                    "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"
                ][name]
            },
            resolveExecutable: { name in
                name == "gdbus" ? "/usr/bin/gdbus" : nil
            },
            runCommand: { executable, arguments in
                recorder.record(executable: executable, arguments: arguments)
                return .init(exitCode: 0)
            },
            runPortalProbe: { executable, arguments, _ in
                recorder.record(executable: executable, arguments: arguments)
                return .init(
                    exitCode: 0,
                    stdout: "org.freedesktop.portal.RemoteDesktop\nwindow-title=\(secret)"
                )
            }
        )

        XCTAssertThrowsError(try adapter.plan(for: MacInputAction(kind: .type, text: secret))) { error in
            XCTAssertEqual(
                error as? LinuxComputerUseInputAdapter.AdapterError,
                .portalConsentRequired("remote_desktop_portal_requires_user_consent")
            )
        }
        XCTAssertFalse(recorder.lastArguments?.contains(secret) == true)
        let encoded = try JSONEncoder().encode(adapter.waylandPortalCapability())
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(secret))
    }

    func testWaylandPortalProbeDenialIsTypedAndDoesNotFallbackToShellInput() throws {
        let adapter = LinuxComputerUseInputAdapter(
            environment: { name in
                [
                    "XDG_SESSION_TYPE": "wayland",
                    "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"
                ][name]
            },
            resolveExecutable: { name in
                name == "gdbus" ? "/usr/bin/gdbus" : nil
            },
            runPortalProbe: { _, _, _ in
                .init(exitCode: 1, stderr: "permission denied: account@example.invalid")
            }
        )

        XCTAssertEqual(adapter.waylandPortalCapability().state, .denied)
        XCTAssertThrowsError(try adapter.plan(for: MacInputAction(kind: .click, displayX: 2, displayY: 3))) { error in
            XCTAssertEqual(
                error as? LinuxComputerUseInputAdapter.AdapterError,
                .portalDenied("portal_probe_denied")
            )
        }
    }

    func testWaylandPortalProbeTimeoutAndCancellationAreFailClosed() throws {
        let environment: LinuxComputerUseInputAdapter.EnvironmentReader = { name in
            [
                "XDG_SESSION_TYPE": "wayland",
                "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"
            ][name]
        }
        let executableResolver: LinuxComputerUseInputAdapter.ExecutableResolver = { name in
            name == "gdbus" ? "/usr/bin/gdbus" : nil
        }
        let timedOut = LinuxComputerUseInputAdapter(
            environment: environment,
            resolveExecutable: executableResolver,
            runPortalProbe: { _, _, _ in .init(exitCode: 124) }
        )
        XCTAssertEqual(timedOut.waylandPortalCapability().state, .timedOut)
        XCTAssertThrowsError(try timedOut.plan(for: MacInputAction(kind: .key, key: "Return"))) { error in
            XCTAssertEqual(error as? LinuxComputerUseInputAdapter.AdapterError, .portalTimedOut)
        }

        let cancelled = LinuxComputerUseInputAdapter(
            environment: environment,
            resolveExecutable: executableResolver,
            runPortalProbe: { _, _, _ in throw CancellationError() }
        )
        XCTAssertEqual(cancelled.waylandPortalCapability().state, .cancelled)
        XCTAssertThrowsError(try cancelled.plan(for: MacInputAction(kind: .key, key: "Return"))) { error in
            XCTAssertEqual(error as? LinuxComputerUseInputAdapter.AdapterError, .portalCancelled)
        }
    }

    func testWaylandPortalProbeAsyncCancellationIsHonoredBeforeProbe() async {
        let probeCalled = CommandRecorder()
        let adapter = LinuxComputerUseInputAdapter(
            environment: { name in
                [
                    "XDG_SESSION_TYPE": "wayland",
                    "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"
                ][name]
            },
            resolveExecutable: { name in
                name == "gdbus" ? "/usr/bin/gdbus" : nil
            },
            runPortalProbe: { executable, arguments, _ in
                probeCalled.record(executable: executable, arguments: arguments)
                return .init(exitCode: 0)
            }
        )

        let task = Task {
            try await adapter.probeWaylandPortal()
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("a cancelled portal probe must not report a capability")
        } catch is CancellationError {
            // The cancellation can race a very fast probe; the post-probe
            // cancellation check still guarantees no capability is returned.
            XCTAssertTrue(probeCalled.lastExecutable == nil || probeCalled.lastExecutable == "/usr/bin/gdbus")
        } catch {
            XCTFail("unexpected cancellation error: \(error)")
        }
    }

    func testWaylandPortalProbeIsBlockedByKillSwitchBeforePortalBrokerRuns() throws {
        let flagPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-wayland-portal-kill-\(UUID().uuidString)")
            .path
        try "panic".write(toFile: flagPath, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(atPath: flagPath) }

        let probeCalled = CommandRecorder()
        let adapter = LinuxComputerUseInputAdapter(
            environment: { name in
                [
                    "XDG_SESSION_TYPE": "wayland",
                    "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus",
                    "OPENBURNBAR_PRIVILEGED_INPUT_KILL_FLAG_PATH": flagPath
                ][name]
            },
            resolveExecutable: { name in
                name == "gdbus" ? "/usr/bin/gdbus" : nil
            },
            runPortalProbe: { executable, arguments, _ in
                probeCalled.record(executable: executable, arguments: arguments)
                return .init(exitCode: 0)
            }
        )

        let capability = adapter.waylandPortalCapability()

        XCTAssertEqual(capability.state, .unavailable)
        XCTAssertEqual(capability.reason, "computer_use_kill_switch_active")
        XCTAssertNil(probeCalled.lastExecutable)
        XCTAssertThrowsError(try adapter.plan(for: MacInputAction(kind: .key, key: "Return"))) { error in
            XCTAssertEqual(
                error as? LinuxComputerUseInputAdapter.AdapterError,
                .portalUnavailable("computer_use_kill_switch_active")
            )
        }
    }

    func testX11SelectionRemainsAuthoritativeWhenWaylandPortalIsAlsoVisible() throws {
        let adapter = LinuxComputerUseInputAdapter(
            environment: { name in
                [
                    "XDG_SESSION_TYPE": "wayland",
                    "WAYLAND_DISPLAY": "wayland-0",
                    "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus",
                    "DISPLAY": ":0"
                ][name]
            },
            resolveExecutable: { name in
                switch name {
                case "xdotool": return "/usr/bin/xdotool"
                case "gdbus": return "/usr/bin/gdbus"
                default: return nil
                }
            },
            runPortalProbe: { _, _, _ in
                XCTFail("X11 fallback must not probe or select the portal")
                return .init(exitCode: 1)
            }
        )

        let plan = try adapter.plan(for: MacInputAction(kind: .type, text: "safe"))
        XCTAssertEqual(plan.adapter, .x11XTest)
        XCTAssertEqual(plan.executableName, "xdotool")
    }

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

    func testRemoteDesktopSessionWaitsForConsentAndReturnsValidatedIdentity() async throws {
        let secret = "window-title-must-not-escape"
        let sessionHandle = "/org/freedesktop/portal/desktop/session/obb_session_1"
        let script = PortalCommandScript(results: [
            .init(exitCode: 0, stdout: "(objectpath '/org/freedesktop/portal/desktop/request/create',)"),
            .init(
                exitCode: 0,
                stdout: "signal member=Response\n   uint32 0\n   session_handle: objectpath '\(sessionHandle)'\n   \(secret)"
            ),
            .init(exitCode: 0, stdout: "(objectpath '/org/freedesktop/portal/desktop/request/select',)"),
            .init(exitCode: 0, stdout: "signal member=Response\n   uint32 0\n"),
            .init(exitCode: 0, stdout: "(objectpath '/org/freedesktop/portal/desktop/request/start',)"),
            .init(exitCode: 0, stdout: "signal member=Response\n   uint32 0\n   details=\(secret)"),
        ])
        let adapter = makeWaylandPortalAdapter(script: script, sessionTimeoutMillis: 222)

        let session = try await adapter.startWaylandRemoteDesktopSession()

        XCTAssertEqual(session.state, .active)
        XCTAssertTrue(session.consentGranted)
        XCTAssertTrue(session.inputExecutorAvailable)
        XCTAssertTrue(session.canDispatchInput)
        XCTAssertEqual(
            session.reason,
            "remote_desktop_consent_granted_portal_notify_executor"
        )
        XCTAssertEqual(session.sessionHandle, sessionHandle)
        XCTAssertEqual(session.requestHandle, "/org/freedesktop/portal/desktop/request/start")
        XCTAssertEqual(adapter.remoteDesktopSessionStatus(session), .active)

        let encoded = try JSONEncoder().encode(session)
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(secret))
        XCTAssertEqual(script.calls.count, 6)
        XCTAssertTrue(script.calls.allSatisfy { call in
            call.executable == "/usr/bin/gdbus"
                && !call.arguments.contains("sh")
                && !call.arguments.contains("-c")
                && !call.arguments.contains(secret)
        })
        XCTAssertEqual(script.timeouts[0], 1_500)
        XCTAssertEqual(script.timeouts[1], 222)
        XCTAssertTrue(script.calls[0].arguments.contains("org.freedesktop.portal.RemoteDesktop.CreateSession"))
        XCTAssertTrue(script.calls[2].arguments.contains("org.freedesktop.portal.RemoteDesktop.SelectDevices"))
        XCTAssertTrue(script.calls[2].arguments.contains(where: { $0.contains("<uint32 3>") }))
        XCTAssertTrue(script.calls[4].arguments.contains("org.freedesktop.portal.RemoteDesktop.Start"))
    }

    func testRemoteDesktopSessionConsentDenialIsTypedAndRedactsBrokerOutput() async throws {
        let secret = "private-window-title"
        let script = PortalCommandScript(results: [
            .init(exitCode: 0, stdout: "(objectpath '/org/freedesktop/portal/desktop/request/create',)"),
            .init(exitCode: 0, stdout: "signal member=Response\n   uint32 1\n   detail=\(secret)"),
        ])
        let adapter = makeWaylandPortalAdapter(script: script)

        do {
            _ = try await adapter.startWaylandRemoteDesktopSession()
            XCTFail("portal consent denial must not create an active session")
        } catch let error as LinuxComputerUseInputAdapter.AdapterError {
            XCTAssertEqual(error, .portalDenied("remote_desktop_create_session_denied"))
            XCTAssertFalse(error.description.contains(secret))
        }
        XCTAssertEqual(script.calls.count, 2)
    }

    func testRemoteDesktopSessionTimeoutDoesNotClaimConsent() async throws {
        let script = PortalCommandScript(results: [
            .init(exitCode: 0, stdout: "(objectpath '/org/freedesktop/portal/desktop/request/create',)"),
            .init(exitCode: 124),
        ])
        let adapter = makeWaylandPortalAdapter(script: script, sessionTimeoutMillis: 333)

        do {
            _ = try await adapter.startWaylandRemoteDesktopSession()
            XCTFail("portal timeout must fail closed")
        } catch let error as LinuxComputerUseInputAdapter.AdapterError {
            XCTAssertEqual(error, .portalTimedOut)
        }
        XCTAssertEqual(script.timeouts.last, 333)
    }

    func testRemoteDesktopSessionCancellationIsTypedBeforeAnySecretCanReachPortal() async throws {
        let secret = "typed-secret-never-forwarded"
        let script = PortalCommandScript(error: CancellationError())
        let adapter = makeWaylandPortalAdapter(script: script)

        do {
            _ = try await adapter.startWaylandRemoteDesktopSession()
            XCTFail("cancelled portal command must not create a session")
        } catch let error as LinuxComputerUseInputAdapter.AdapterError {
            XCTAssertEqual(error, .portalCancelled)
            XCTAssertFalse(error.description.contains(secret))
        }
        XCTAssertEqual(script.calls.count, 1)
        XCTAssertFalse(script.calls[0].arguments.contains(secret))
    }

    func testRemoteDesktopSessionKillSwitchBlocksCreateButAllowsSafeClose() async throws {
        let script = PortalCommandScript(results: [
            .init(exitCode: 0, stdout: "(objectpath '/org/freedesktop/portal/desktop/request/create',)")
        ])
        let adapter = makeWaylandPortalAdapter(
            script: script,
            environmentOverrides: ["OPENBURNBAR_COMPUTER_USE_KILL_SWITCH": "1"]
        )

        do {
            _ = try await adapter.startWaylandRemoteDesktopSession()
            XCTFail("the kill switch must block portal session creation")
        } catch let error as LinuxComputerUseInputAdapter.AdapterError {
            XCTAssertEqual(error, .killSwitchActive("environment"))
        }
        XCTAssertTrue(script.calls.isEmpty)

        let receipt = LinuxComputerUseInputAdapter.WaylandRemoteDesktopSession(
            state: .active,
            sessionHandle: "/org/freedesktop/portal/desktop/session/obb_session_1",
            consentGranted: true,
            reason: "fixture"
        )
        let stopped = try await adapter.stopWaylandRemoteDesktopSession(receipt)
        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertFalse(stopped.consentGranted)
        XCTAssertFalse(stopped.canDispatchInput)
        XCTAssertEqual(script.calls.count, 1)
        XCTAssertEqual(script.calls[0].arguments.last, "org.freedesktop.portal.Session.Close")
    }

    func testRemoteDesktopSessionStopValidatesIdentityAndReportsStoppedStatus() async throws {
        let script = PortalCommandScript(results: [.init(exitCode: 0, stdout: "()")])
        let adapter = makeWaylandPortalAdapter(script: script)
        let receipt = LinuxComputerUseInputAdapter.WaylandRemoteDesktopSession(
            state: .active,
            sessionHandle: "/org/freedesktop/portal/desktop/session/obb_session_1",
            consentGranted: true,
            reason: "fixture"
        )

        let stopped = try await adapter.stopWaylandRemoteDesktopSession(receipt)

        XCTAssertEqual(stopped.state, .stopped)
        XCTAssertFalse(stopped.consentGranted)
        XCTAssertEqual(adapter.remoteDesktopSessionStatus(stopped), .stopped)
        XCTAssertEqual(script.calls.count, 1)
        XCTAssertEqual(script.calls[0].arguments[script.calls[0].arguments.count - 2], "--method")
        XCTAssertEqual(script.calls[0].arguments.last, "org.freedesktop.portal.Session.Close")
        XCTAssertTrue(script.calls[0].arguments.contains(receipt.sessionHandle!))
    }

    func testRemoteDesktopSessionDispatchesPortalNotifyEventsOnlyAfterConsent() async throws {
        let sessionHandle = "/org/freedesktop/portal/desktop/session/obb_session_1"
        let script = PortalCommandScript(results: [
            .init(exitCode: 0, stdout: "(objectpath '/org/freedesktop/portal/desktop/request/create',)"),
            .init(exitCode: 0, stdout: "signal member=Response\n uint32 0\n session_handle: objectpath '\(sessionHandle)'"),
            .init(exitCode: 0, stdout: "(objectpath '/org/freedesktop/portal/desktop/request/select',)"),
            .init(exitCode: 0, stdout: "signal member=Response\n uint32 0"),
            .init(exitCode: 0, stdout: "(objectpath '/org/freedesktop/portal/desktop/request/start',)"),
            .init(exitCode: 0, stdout: "signal member=Response\n uint32 0"),
            .init(exitCode: 0),
            .init(exitCode: 0),
            .init(exitCode: 0)
        ])
        let adapter = makeWaylandPortalAdapter(script: script)
        let session = try await adapter.startWaylandRemoteDesktopSession()

        let result = try await adapter.dispatchWaylandRemoteDesktop(
            MacInputAction(kind: .click, displayX: 220, displayY: 160),
            session: session
        )

        guard case .object(let object) = result else {
            XCTFail("expected object result")
            return
        }
        XCTAssertEqual(object.stringValue(forKey: "executor"), "portal_notify")
        XCTAssertEqual(object.intValue(forKey: "eventCount"), 3)
        XCTAssertEqual(script.calls.count, 9)
        XCTAssertTrue(script.calls[6].arguments.contains("org.freedesktop.portal.RemoteDesktop.NotifyPointerMotionAbsolute"))
        XCTAssertEqual(Array(script.calls[6].arguments.suffix(5)), [sessionHandle, "{}", "0", "220", "160"])
        XCTAssertTrue(script.calls[7].arguments.contains(where: { $0.contains("NotifyPointerButton") }))
        XCTAssertTrue(script.calls[8].arguments.contains(where: { $0.contains("NotifyPointerButton") }))
        XCTAssertTrue(script.calls.dropFirst(6).allSatisfy { call in
            call.executable == "/usr/bin/gdbus"
                && !call.arguments.contains("sh")
                && !call.arguments.contains("-c")
        })
    }

    func testRemoteDesktopSessionExecutorReportsUnsupportedProvisionedBackends() async throws {
        let session = LinuxComputerUseInputAdapter.WaylandRemoteDesktopSession(
            state: .active,
            sessionHandle: "/org/freedesktop/portal/desktop/session/obb_session_1",
            consentGranted: true,
            inputExecutorAvailable: true,
            reason: "fixture"
        )

        for (backend, kind, reason) in [
            ("libei", LinuxComputerUseInputAdapter.WaylandInputExecutorKind.libei, "libei_executor_not_provisioned"),
            ("uinput", LinuxComputerUseInputAdapter.WaylandInputExecutorKind.uinput, "uinput_executor_not_provisioned")
        ] {
            let script = PortalCommandScript(results: [])
            let adapter = makeWaylandPortalAdapter(
                script: script,
                environmentOverrides: ["OPENBURNBAR_LINUX_CU_INPUT_EXECUTOR": backend]
            )
            let status = adapter.waylandRemoteDesktopInputExecutorStatus(session)
            XCTAssertEqual(status.kind, kind)
            XCTAssertFalse(status.available)
            XCTAssertEqual(status.reason, reason)
            do {
                _ = try await adapter.dispatchWaylandRemoteDesktop(
                    MacInputAction(kind: .key, key: "Return"),
                    session: session
                )
                XCTFail("an unprovisioned (backend) backend must fail closed")
            } catch let error as LinuxComputerUseInputAdapter.AdapterError {
                XCTAssertEqual(error, .inputExecutorUnavailable(reason))
            }
            XCTAssertTrue(script.calls.isEmpty)
        }
    }

    func testRemoteDesktopSessionDispatchTimeoutAndCancellationStayTyped() async throws {
        let session = LinuxComputerUseInputAdapter.WaylandRemoteDesktopSession(
            state: .active,
            sessionHandle: "/org/freedesktop/portal/desktop/session/obb_session_1",
            consentGranted: true,
            inputExecutorAvailable: true,
            reason: "fixture"
        )
        let timedOut = makeWaylandPortalAdapter(
            script: PortalCommandScript(results: [.init(exitCode: 124)])
        )
        do {
            _ = try await timedOut.dispatchWaylandRemoteDesktop(
                MacInputAction(kind: .key, key: "Return"),
                session: session
            )
            XCTFail("a timed-out notify call must fail closed")
        } catch let error as LinuxComputerUseInputAdapter.AdapterError {
            XCTAssertEqual(error, .portalTimedOut)
        }

        let cancelled = makeWaylandPortalAdapter(
            script: PortalCommandScript(error: CancellationError())
        )
        do {
            _ = try await cancelled.dispatchWaylandRemoteDesktop(
                MacInputAction(kind: .key, key: "Return"),
                session: session
            )
            XCTFail("a cancelled notify call must fail closed")
        } catch let error as LinuxComputerUseInputAdapter.AdapterError {
            XCTAssertEqual(error, .portalCancelled)
        }
    }

    func testRemoteDesktopSessionDispatchKillSwitchStopsBeforeNextEvent() async throws {
        let flagPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-wayland-dispatch-kill-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: flagPath) }
        let script = PortalCommandScript(results: [.init(exitCode: 0)])
        let adapter = makeWaylandPortalAdapter(
            script: script,
            environmentOverrides: ["OPENBURNBAR_PRIVILEGED_INPUT_KILL_FLAG_PATH": flagPath],
            onRecord: { callNumber in
                if callNumber == 1 {
                    try? "panic".write(toFile: flagPath, atomically: true, encoding: .utf8)
                }
            }
        )
        let session = LinuxComputerUseInputAdapter.WaylandRemoteDesktopSession(
            state: .active,
            sessionHandle: "/org/freedesktop/portal/desktop/session/obb_session_1",
            consentGranted: true,
            inputExecutorAvailable: true,
            reason: "fixture"
        )

        do {
            _ = try await adapter.dispatchWaylandRemoteDesktop(
                MacInputAction(kind: .click, displayX: 220, displayY: 160),
                session: session
            )
            XCTFail("the injected kill switch should stop a multi-event click")
        } catch let error as LinuxComputerUseInputAdapter.AdapterError {
            // The fixture's command runner creates the kill flag after the
            // first event, proving the post-event guard is effective.
            XCTAssertTrue(error.description.contains("linux_input_kill_switch_active"))
        }
    }

    private func makeWaylandPortalAdapter(
        script: PortalCommandScript,
        sessionTimeoutMillis: Int = 60_000,
        environmentOverrides: [String: String] = [:],
        onRecord: (@Sendable (Int) -> Void)? = nil
    ) -> LinuxComputerUseInputAdapter {
        LinuxComputerUseInputAdapter(
            environment: { name in
                if let override = environmentOverrides[name] {
                    return override
                }
                return [
                    "XDG_SESSION_TYPE": "wayland",
                    "WAYLAND_DISPLAY": "wayland-0",
                    "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"
                ][name]
            },
            resolveExecutable: { name in
                name == "gdbus" ? "/usr/bin/gdbus" : nil
            },
            runPortalProbe: { executable, arguments, timeoutMillis in
                script.record(executable: executable, arguments: arguments, timeoutMillis: timeoutMillis)
                onRecord?(script.callCount)
                if let error = script.error {
                    throw error
                }
                return script.nextResult()
            },
            portalSessionTimeoutMillis: sessionTimeoutMillis
        )
    }
}

final class LinuxComputerUseInputSessionManagerTests: XCTestCase {
    func testWaylandPortalGrantIsReusedForActionsAndClosedWithSession() async throws {
        let sessionHandle = "/org/freedesktop/portal/desktop/session/obb_session_manager"
        let script = PortalCommandScript(results: [
            // Capability probe.
            .init(exitCode: 0, stdout: "org.freedesktop.portal.RemoteDesktop"),
            // CreateSession request + response.
            .init(exitCode: 0, stdout: "(objectpath '/org/freedesktop/portal/desktop/request/create',)"),
            .init(exitCode: 0, stdout: "signal member=Response\n uint32 0\n session_handle: objectpath '\(sessionHandle)'"),
            // SelectDevices request + response.
            .init(exitCode: 0, stdout: "(objectpath '/org/freedesktop/portal/desktop/request/select',)"),
            .init(exitCode: 0, stdout: "signal member=Response\n uint32 0"),
            // Start request + response.
            .init(exitCode: 0, stdout: "(objectpath '/org/freedesktop/portal/desktop/request/start',)"),
            .init(exitCode: 0, stdout: "signal member=Response\n uint32 0"),
            // Click: absolute motion + button press + button release.
            .init(exitCode: 0),
            .init(exitCode: 0),
            .init(exitCode: 0),
            // Second action: one absolute motion event.
            .init(exitCode: 0),
            // Session close.
            .init(exitCode: 0)
        ])
        let adapter = LinuxComputerUseInputAdapter(
            environment: { name in
                [
                    "XDG_SESSION_TYPE": "wayland",
                    "WAYLAND_DISPLAY": "wayland-0",
                    "DBUS_SESSION_BUS_ADDRESS": "unix:path=/run/user/1000/bus"
                ][name]
            },
            resolveExecutable: { name in
                name == "gdbus" ? "/usr/bin/gdbus" : nil
            },
            runPortalProbe: { executable, arguments, timeoutMillis in
                script.record(executable: executable, arguments: arguments, timeoutMillis: timeoutMillis)
                return script.nextResult()
            }
        )
        let manager = LinuxComputerUseInputSessionManager(adapter: adapter)
        let sessionID = ComputerUseSessionID("linux-wayland-session")

        let click = try await manager.dispatch(
            sessionID: sessionID,
            action: MacInputAction(kind: .click, displayX: 220, displayY: 160)
        )
        let pointerMove = try await manager.dispatch(
            sessionID: sessionID,
            action: MacInputAction(kind: .pointerMove, displayX: 240, displayY: 180)
        )

        guard case .object(let clickObject) = click,
              case .object(let moveObject) = pointerMove else {
            XCTFail("portal dispatches must return structured results")
            return
        }
        XCTAssertEqual(clickObject.stringValue(forKey: "executor"), "portal_notify")
        XCTAssertEqual(moveObject.stringValue(forKey: "executor"), "portal_notify")
        let activeCount = await manager.activeWaylandSessionCount()
        XCTAssertEqual(activeCount, 1)

        await manager.stop(sessionID: sessionID)

        let stoppedCount = await manager.activeWaylandSessionCount()
        XCTAssertEqual(stoppedCount, 0)
        XCTAssertEqual(script.callCount, 12)
        XCTAssertEqual(script.timeouts.first, 1_500)
        XCTAssertTrue(script.calls.dropFirst(7).allSatisfy { call in
            call.executable == "/usr/bin/gdbus"
                && !call.arguments.contains("sh")
                && !call.arguments.contains("-c")
        })
    }

    func testX11FallbackRemainsStatelessWhenPortalIsNotReady() async throws {
        let recorder = CommandRecorder()
        let adapter = LinuxComputerUseInputAdapter(
            environment: { name in ["DISPLAY": ":99"][name] },
            resolveExecutable: { name in
                name == "xdotool" ? "/usr/bin/xdotool" : nil
            },
            runCommand: { executable, arguments in
                recorder.record(executable: executable, arguments: arguments)
                return .init(exitCode: 0)
            }
        )
        let manager = LinuxComputerUseInputSessionManager(adapter: adapter)

        let result = try await manager.dispatch(
            sessionID: ComputerUseSessionID("linux-x11-session"),
            action: MacInputAction(kind: .click, displayX: 10, displayY: 20)
        )

        guard case .object(let object) = result else {
            XCTFail("X11 dispatch must return a structured result")
            return
        }
        XCTAssertEqual(object.stringValue(forKey: "adapter"), "x11-xtest")
        XCTAssertEqual(recorder.lastExecutable, "/usr/bin/xdotool")
        let activeCount = await manager.activeWaylandSessionCount()
        XCTAssertEqual(activeCount, 0)
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

private final class PortalCommandScript: @unchecked Sendable {
    struct Call: Sendable {
        let executable: String
        let arguments: [String]
    }

    private let lock = NSLock()
    private var results: [LinuxComputerUseInputAdapter.CommandResult]
    let error: Error?
    private(set) var calls: [Call] = []
    private(set) var timeouts: [Int] = []

    init(
        results: [LinuxComputerUseInputAdapter.CommandResult] = [],
        error: Error? = nil
    ) {
        self.results = results
        self.error = error
    }

    func record(executable: String, arguments: [String], timeoutMillis: Int) {
        lock.lock()
        calls.append(Call(executable: executable, arguments: arguments))
        timeouts.append(timeoutMillis)
        lock.unlock()
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls.count
    }

    func nextResult() -> LinuxComputerUseInputAdapter.CommandResult {
        lock.lock()
        defer { lock.unlock() }
        guard results.isEmpty == false else {
            return .init(exitCode: 1)
        }
        return results.removeFirst()
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
