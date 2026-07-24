#if os(Linux)
import Foundation
import XCTest
@testable import OpenBurnBarDaemon

final class BurnBarLinuxTextExpansionAdapterTests: XCTestCase {
    func testReportsReachableIBusWithoutClaimingExternalExpansion() {
        let adapter = makeAdapter(
            environment: [
                "XDG_SESSION_TYPE": "wayland",
                "GTK_IM_MODULE": "ibus"
            ],
            executables: ["ibus": "/usr/bin/ibus"],
            exitCode: 0
        )

        let status = adapter.status()

        XCTAssertEqual(status.status, "degraded")
        XCTAssertEqual(status.backend, "ibus")
        XCTAssertEqual(status.sessionType, "wayland")
        XCTAssertEqual(status.registration, "opt_in_required")
        XCTAssertFalse(status.supportsExternalExpansion)
        XCTAssertTrue(status.noGlobalCapture)
        XCTAssertEqual(status.secureFieldPolicy, "deny-unless-inspectable-and-explicitly-nonsecure")
        XCTAssertTrue(status.detail.contains("ibus"))
        XCTAssertEqual(adapter.typedStatus().registration, .optInRequired)
    }

    func testDetectsFcitxWithoutEnvironmentOverridesOnX11() {
        let adapter = makeAdapter(
            environment: ["DISPLAY": ":0"],
            executables: ["fcitx5-remote": "/usr/bin/fcitx5-remote"],
            exitCode: 0
        )

        let status = adapter.status()

        XCTAssertEqual(status.status, "degraded")
        XCTAssertEqual(status.backend, "fcitx5")
        XCTAssertEqual(status.sessionType, "x11")
        XCTAssertEqual(status.registration, "opt_in_required")
        XCTAssertTrue(status.detail.contains("opt-in"))
    }

    func testFailsClosedWhenSessionTypeOrControlProbeIsUnproven() {
        let unknownSession = makeAdapter(
            environment: ["GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            exitCode: 0
        ).status()
        XCTAssertEqual(unknownSession.status, "blocked")
        XCTAssertEqual(unknownSession.sessionType, "unknown")
        XCTAssertEqual(unknownSession.registration, "engine_missing")

        let stoppedBackend = makeAdapter(
            environment: ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            exitCode: 1
        ).status()
        XCTAssertEqual(stoppedBackend.status, "blocked")
        XCTAssertEqual(stoppedBackend.backend, "ibus")
        XCTAssertFalse(stoppedBackend.supportsExternalExpansion)
    }

    func testOptInWithoutManifestFailsClosed() {
        let status = makeAdapter(
            environment: ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            exitCode: 0,
            externalExpansionEnabled: true,
            manifestPath: nil
        ).status()

        XCTAssertEqual(status.status, "blocked")
        XCTAssertEqual(status.registration, "engine_missing")
        XCTAssertFalse(status.supportsExternalExpansion)
    }

    func testValidSignedManifestRegistersOnWaylandWithoutInputCapture() throws {
        let manifest = makeManifest(backend: .ibus, supportsWayland: true, supportsX11: false)
        let data = try JSONEncoder().encode(manifest)
        let metadata = [
            "/trusted/text-expansion-engine.json": BurnBarLinuxTextExpansionAdapter.FileMetadata(ownerUID: 0, mode: 0o644),
            "/trusted/bin/openburnbar-ibus": BurnBarLinuxTextExpansionAdapter.FileMetadata(ownerUID: 0, mode: 0o755)
        ]
        let adapter = makeExternalAdapter(
            environment: ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            manifestData: data,
            metadata: metadata,
            verifySignature: { _ in true }
        )

        let typed = adapter.typedStatus()

        XCTAssertEqual(typed.state, .available)
        XCTAssertEqual(typed.sessionType, .wayland)
        XCTAssertEqual(typed.backend, .ibus)
        XCTAssertEqual(typed.registration, .registered)
        XCTAssertTrue(typed.supportsExternalExpansion)
        XCTAssertTrue(typed.noGlobalCapture)
        XCTAssertEqual(typed.wireValue.registration, "registered")
        XCTAssertEqual(typed.wireValue.backendPath, "/trusted/bin/openburnbar-ibus")
    }

    func testValidManifestRegistersOnX11OnlyWhenItDeclaresX11Support() throws {
        let manifest = makeManifest(backend: .fcitx5, supportsWayland: false, supportsX11: true)
        let data = try JSONEncoder().encode(manifest)
        let adapter = makeExternalAdapter(
            environment: ["XDG_SESSION_TYPE": "x11"],
            executables: ["fcitx5-remote": "/usr/bin/fcitx5-remote"],
            manifestData: data,
            metadata: trustedMetadata(for: manifest),
            verifySignature: { _ in true }
        )

        XCTAssertEqual(adapter.typedStatus().registration, .registered)
        XCTAssertEqual(adapter.status().sessionType, "x11")
    }

    func testManifestRejectsUnsafeCapabilitiesAndMalformedSignature() throws {
        let unsafe = makeManifest(backend: .ibus, supportsWayland: true, supportsX11: true, readsClipboard: true)
        let unsafeAdapter = makeExternalAdapter(
            environment: ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            manifestData: try JSONEncoder().encode(unsafe),
            metadata: trustedMetadata(for: unsafe),
            verifySignature: { _ in true }
        )
        XCTAssertEqual(unsafeAdapter.typedStatus().registration, .manifestInvalid)

        let valid = makeManifest(backend: .ibus, supportsWayland: true, supportsX11: true)
        let invalidSignatureAdapter = makeExternalAdapter(
            environment: ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            manifestData: try JSONEncoder().encode(valid),
            metadata: trustedMetadata(for: valid),
            verifySignature: { _ in false }
        )
        XCTAssertEqual(invalidSignatureAdapter.typedStatus().registration, .signatureInvalid)
    }

    func testManifestRejectsUntrustedPathAndUnsafeOwnerPermissions() throws {
        let manifest = makeManifest(backend: .ibus, supportsWayland: true, supportsX11: true)
        let data = try JSONEncoder().encode(manifest)
        let pathAdapter = BurnBarLinuxTextExpansionAdapter(
            environment: { name in ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"][name] },
            resolveExecutable: { name in name == "ibus" ? "/usr/bin/ibus" : nil },
            runCommand: { _, _ in .init(exitCode: 0) },
            manifestPath: "/tmp/engine.json",
            externalExpansionEnabled: true,
            allowedManifestRoots: ["/trusted"],
            allowedExecutableRoots: ["/trusted"],
            trustedOwnerUIDs: [0],
            readManifest: { _ in data },
            readFileMetadata: { _ in .init(ownerUID: 0, mode: 0o644) },
            verifySignature: { _ in true }
        )
        XCTAssertEqual(pathAdapter.typedStatus().registration, .manifestPathRejected)

        let unsafeModeAdapter = makeExternalAdapter(
            environment: ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            manifestData: data,
            metadata: [
                "/trusted/text-expansion-engine.json": .init(ownerUID: 0, mode: 0o666),
                "/trusted/bin/openburnbar-ibus": .init(ownerUID: 0, mode: 0o755)
            ],
            verifySignature: { _ in true }
        )
        XCTAssertEqual(unsafeModeAdapter.typedStatus().registration, .ownerPermissionsInvalid)
    }

    func testManifestRejectsEngineForWrongSessionOrBackend() throws {
        let waylandOnly = makeManifest(backend: .ibus, supportsWayland: true, supportsX11: false)
        let x11Adapter = makeExternalAdapter(
            environment: ["XDG_SESSION_TYPE": "x11", "GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            manifestData: try JSONEncoder().encode(waylandOnly),
            metadata: trustedMetadata(for: waylandOnly),
            verifySignature: { _ in true }
        )
        XCTAssertEqual(x11Adapter.typedStatus().registration, .sessionUnsupported)

        let fcitxManifest = makeManifest(backend: .fcitx5, supportsWayland: true, supportsX11: true)
        let backendAdapter = makeExternalAdapter(
            environment: ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            manifestData: try JSONEncoder().encode(fcitxManifest),
            metadata: trustedMetadata(for: fcitxManifest),
            verifySignature: { _ in true }
        )
        XCTAssertEqual(backendAdapter.typedStatus().registration, .backendMismatch)
    }

    func testControlProbeErrorsNeverBecomeDiagnostics() {
        let status = BurnBarLinuxTextExpansionAdapter(
            environment: { name in
                ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"][name]
            },
            resolveExecutable: { name in name == "ibus" ? "/usr/bin/ibus" : nil },
            runCommand: { _, _ in throw NSError(domain: "probe", code: 1, userInfo: [NSLocalizedDescriptionKey: "surrounding secret text"]) }
        ).status()

        XCTAssertEqual(status.status, "blocked")
        XCTAssertTrue(status.detail.contains("ibus"))
        XCTAssertFalse(status.detail.contains("surrounding secret text"))
    }

    func testSecureFieldPolicyDeniesUnknownSecureAndExcludedContexts() {
        let adapter = BurnBarLinuxTextExpansionAdapter(
            environment: { _ in nil },
            resolveExecutable: { _ in nil },
            runCommand: { _, _ in BurnBarLinuxTextExpansionAdapter.CommandResult(exitCode: 1) },
            excludedApplicationIDs: ["com.example.vault"]
        )

        XCTAssertEqual(
            adapter.secureFieldDecision(for: .init(inspectable: false)),
            .deniedUninspectable
        )
        XCTAssertEqual(
            adapter.secureFieldDecision(for: .init(inspectable: true, isSecureField: true)),
            .deniedSecureField
        )
        XCTAssertEqual(
            adapter.secureFieldDecision(for: .init(inspectable: true, isSecureField: false, role: "password text")),
            .deniedSecureField
        )
        XCTAssertEqual(
            adapter.secureFieldDecision(for: .init(inspectable: true, isSecureField: false, applicationID: "COM.EXAMPLE.VAULT")),
            .deniedExcludedApplication
        )
        XCTAssertEqual(
            adapter.secureFieldDecision(for: .init(inspectable: true, isSecureField: false, role: "entry", inputPurpose: "free-form")),
            .allow
        )
    }

    func testExternalEngineRuntimeHandshakeStatusAndStop() async throws {
        let handshake = [
            "{\"protocol\":\"openburnbar.text-expansion\",\"protocolVersion\":1,",
            "\"engineID\":\"openburnbar.test.engine\",\"noGlobalCapture\":true,",
            "\"readsClipboard\":false,\"readsSurroundingText\":false,",
            "\"secureFieldPolicy\":\"deny-unless-inspectable-and-explicitly-nonsecure\"}"
        ].joined()
        let script = try makeRuntimeScript(handshake: handshake)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let manifest = makeManifest(
            backend: .ibus,
            supportsWayland: true,
            supportsX11: false,
            executablePath: script.path
        )
        let manifestPath = script.deletingLastPathComponent().appendingPathComponent("engine.json").path
        let adapter = makeExternalAdapter(
            environment: ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            manifestData: try JSONEncoder().encode(manifest),
            metadata: [
                manifestPath: .init(ownerUID: 0, mode: 0o600),
                script.path: .init(ownerUID: 0, mode: 0o700)
            ],
            verifySignature: { _ in true },
            manifestPath: manifestPath,
            allowedRoots: [script.deletingLastPathComponent().path]
        )

        let session = try await adapter.startExternalEngine(timeoutMillis: 1_000)
        XCTAssertEqual(session.engineID, manifest.engineID)
        XCTAssertEqual(session.executablePath, script.path)
        let readyStatus = await session.status()
        XCTAssertEqual(readyStatus.state, .ready)
        let secureDecision = await session.secureFieldDecision(
            for: .init(inspectable: true, isSecureField: true)
        )
        XCTAssertEqual(secureDecision, .deniedSecureField)

        let stopped = await session.stop()
        XCTAssertEqual(stopped.state, .stopped)
        let stoppedStatus = await session.status()
        XCTAssertEqual(stoppedStatus.state, .stopped)
    }

    func testExternalEngineExpansionRoundTripSendsOnlyCanonicalTrigger() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-text-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let captureURL = directory.appendingPathComponent("request.json")
        let response = "{\"operation\":\"expand_result\",\"protocol\":\"openburnbar.text-expansion\",\"protocolVersion\":1,\"requestID\":\"request-1\",\"status\":\"expanded\",\"replacement\":\"Thanks!\"}"
        let script = try makeRuntimeScript(
            handshake: "{\"protocol\":\"openburnbar.text-expansion\",\"protocolVersion\":1,\"engineID\":\"openburnbar.test.engine\",\"noGlobalCapture\":true,\"readsClipboard\":false,\"readsSurroundingText\":false,\"secureFieldPolicy\":\"deny-unless-inspectable-and-explicitly-nonsecure\"}",
            expansionResponse: response,
            requestCaptureURL: captureURL
        )
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let manifest = makeManifest(
            backend: .ibus,
            supportsWayland: true,
            supportsX11: false,
            executablePath: script.path
        )
        let manifestPath = script.deletingLastPathComponent().appendingPathComponent("engine.json").path
        let adapter = makeExternalAdapter(
            environment: ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            manifestData: try JSONEncoder().encode(manifest),
            metadata: [
                manifestPath: .init(ownerUID: 0, mode: 0o600),
                script.path: .init(ownerUID: 0, mode: 0o700)
            ],
            verifySignature: { _ in true },
            manifestPath: manifestPath,
            allowedRoots: [script.deletingLastPathComponent().path]
        )

        let session = try await adapter.startExternalEngine(timeoutMillis: 1_000)
        let replacement = try await session.expand(
            trigger: "&&Reply",
            context: .init(
                inspectable: true,
                isSecureField: false,
                applicationID: "org.example.editor",
                role: "entry",
                inputPurpose: "free-form"
            ),
            timeoutMillis: 1_000,
            requestID: "request-1"
        )
        XCTAssertEqual(replacement, "Thanks!")

        let request = try String(contentsOf: captureURL, encoding: .utf8)
        XCTAssertTrue(request.contains("\"operation\":\"expand\""))
        XCTAssertTrue(request.contains("\"trigger\":\"reply\""))
        XCTAssertFalse(request.contains("keyboard"))
        XCTAssertFalse(request.contains("clipboard"))
        XCTAssertFalse(request.contains("surrounding"))
        XCTAssertFalse(request.contains("field"))

        do {
            _ = try await session.expand(
                trigger: "reply",
                context: .init(inspectable: true, isSecureField: true),
                timeoutMillis: 1_000,
                requestID: "request-2"
            )
            XCTFail("secure fields must never reach the external engine")
        } catch let error as BurnBarLinuxTextExpansionAdapter.EngineRuntimeError {
            XCTAssertEqual(error, .expansionDenied(.deniedSecureField))
        }

        _ = await session.stop()
    }

    func testExternalEngineRejectsMismatchedExpansionResponseAndStops() async throws {
        let response = "{\"operation\":\"expand_result\",\"protocol\":\"openburnbar.text-expansion\",\"protocolVersion\":1,\"requestID\":\"wrong-request\",\"status\":\"expanded\",\"replacement\":\"not accepted\"}"
        let script = try makeRuntimeScript(
            handshake: "{\"protocol\":\"openburnbar.text-expansion\",\"protocolVersion\":1,\"engineID\":\"openburnbar.test.engine\",\"noGlobalCapture\":true,\"readsClipboard\":false,\"readsSurroundingText\":false,\"secureFieldPolicy\":\"deny-unless-inspectable-and-explicitly-nonsecure\"}",
            expansionResponse: response
        )
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let manifest = makeManifest(backend: .ibus, supportsWayland: true, supportsX11: false, executablePath: script.path)
        let manifestPath = script.deletingLastPathComponent().appendingPathComponent("engine.json").path
        let adapter = makeExternalAdapter(
            environment: ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            manifestData: try JSONEncoder().encode(manifest),
            metadata: [
                manifestPath: .init(ownerUID: 0, mode: 0o600),
                script.path: .init(ownerUID: 0, mode: 0o700)
            ],
            verifySignature: { _ in true },
            manifestPath: manifestPath,
            allowedRoots: [script.deletingLastPathComponent().path]
        )
        let session = try await adapter.startExternalEngine(timeoutMillis: 1_000)
        do {
            _ = try await session.expand(
                trigger: "reply",
                context: .init(inspectable: true, isSecureField: false),
                timeoutMillis: 1_000,
                requestID: "request-1"
            )
            XCTFail("a response for another request must fail closed")
        } catch let error as BurnBarLinuxTextExpansionAdapter.EngineRuntimeError {
            XCTAssertEqual(error, .expansionResponseInvalid)
        }
        let finalState = await session.status().state
        XCTAssertEqual(finalState, .stopped)
    }

    func testExternalEngineExpansionTimeoutTerminatesSession() async throws {
        let script = try makeRuntimeScript(
            handshake: "{\"protocol\":\"openburnbar.text-expansion\",\"protocolVersion\":1,\"engineID\":\"openburnbar.test.engine\",\"noGlobalCapture\":true,\"readsClipboard\":false,\"readsSurroundingText\":false,\"secureFieldPolicy\":\"deny-unless-inspectable-and-explicitly-nonsecure\"}"
        )
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let manifest = makeManifest(backend: .ibus, supportsWayland: true, supportsX11: false, executablePath: script.path)
        let manifestPath = script.deletingLastPathComponent().appendingPathComponent("engine.json").path
        let adapter = makeExternalAdapter(
            environment: ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            manifestData: try JSONEncoder().encode(manifest),
            metadata: [
                manifestPath: .init(ownerUID: 0, mode: 0o600),
                script.path: .init(ownerUID: 0, mode: 0o700)
            ],
            verifySignature: { _ in true },
            manifestPath: manifestPath,
            allowedRoots: [script.deletingLastPathComponent().path]
        )
        let session = try await adapter.startExternalEngine(timeoutMillis: 1_000)
        do {
            _ = try await session.expand(
                trigger: "reply",
                context: .init(inspectable: true, isSecureField: false),
                timeoutMillis: 100,
                requestID: "request-1"
            )
            XCTFail("expected bounded expansion timeout")
        } catch let error as BurnBarLinuxTextExpansionAdapter.EngineRuntimeError {
            XCTAssertEqual(error, .expansionTimedOut)
        }
        let finalState = await session.status().state
        XCTAssertEqual(finalState, .timedOut)
    }

    func testExternalEngineExpansionCancellationTerminatesSession() async throws {
        let script = try makeRuntimeScript(
            handshake: "{\"protocol\":\"openburnbar.text-expansion\",\"protocolVersion\":1,\"engineID\":\"openburnbar.test.engine\",\"noGlobalCapture\":true,\"readsClipboard\":false,\"readsSurroundingText\":false,\"secureFieldPolicy\":\"deny-unless-inspectable-and-explicitly-nonsecure\"}"
        )
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }
        let manifest = makeManifest(backend: .ibus, supportsWayland: true, supportsX11: false, executablePath: script.path)
        let manifestPath = script.deletingLastPathComponent().appendingPathComponent("engine.json").path
        let adapter = makeExternalAdapter(
            environment: ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            manifestData: try JSONEncoder().encode(manifest),
            metadata: [
                manifestPath: .init(ownerUID: 0, mode: 0o600),
                script.path: .init(ownerUID: 0, mode: 0o700)
            ],
            verifySignature: { _ in true },
            manifestPath: manifestPath,
            allowedRoots: [script.deletingLastPathComponent().path]
        )
        let session = try await adapter.startExternalEngine(timeoutMillis: 1_000)
        let task = Task {
            try await session.expand(
                trigger: "reply",
                context: .init(inspectable: true, isSecureField: false),
                timeoutMillis: 2_000,
                requestID: "request-1"
            )
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected expansion cancellation")
        } catch let error as BurnBarLinuxTextExpansionAdapter.EngineRuntimeError {
            XCTAssertEqual(error, .expansionCancelled)
        }
        let finalState = await session.status().state
        XCTAssertEqual(finalState, .cancelled)
    }

    func testExternalEngineHandshakeTimeoutTerminatesWithoutDiagnostics() async throws {
        let script = try makeRuntimeScript(handshake: nil)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let manifest = makeManifest(
            backend: .ibus,
            supportsWayland: true,
            supportsX11: false,
            executablePath: script.path
        )
        let manifestPath = script.deletingLastPathComponent().appendingPathComponent("engine.json").path
        let adapter = makeExternalAdapter(
            environment: ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            manifestData: try JSONEncoder().encode(manifest),
            metadata: [
                manifestPath: .init(ownerUID: 0, mode: 0o600),
                script.path: .init(ownerUID: 0, mode: 0o700)
            ],
            verifySignature: { _ in true },
            manifestPath: manifestPath,
            allowedRoots: [script.deletingLastPathComponent().path]
        )

        do {
            _ = try await adapter.startExternalEngine(timeoutMillis: 40)
            XCTFail("expected handshake timeout")
        } catch let error as BurnBarLinuxTextExpansionAdapter.EngineRuntimeError {
            XCTAssertEqual(error, .handshakeTimedOut)
            XCTAssertFalse(error.description.contains("secret"))
        }
    }

    func testExternalEngineCancellationAndKillSwitchFailClosed() async throws {
        let script = try makeRuntimeScript(handshake: nil)
        defer { try? FileManager.default.removeItem(at: script.deletingLastPathComponent()) }

        let manifest = makeManifest(
            backend: .ibus,
            supportsWayland: true,
            supportsX11: false,
            executablePath: script.path
        )
        let data = try JSONEncoder().encode(manifest)
        let manifestPath = script.deletingLastPathComponent().appendingPathComponent("engine.json").path
        let adapter = makeExternalAdapter(
            environment: ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            manifestData: data,
            metadata: [
                manifestPath: .init(ownerUID: 0, mode: 0o600),
                script.path: .init(ownerUID: 0, mode: 0o700)
            ],
            verifySignature: { _ in true },
            manifestPath: manifestPath,
            allowedRoots: [script.deletingLastPathComponent().path]
        )

        do {
            _ = try await adapter.startExternalEngine(timeoutMillis: 100, killSwitch: { true })
            XCTFail("expected kill switch denial")
        } catch let error as BurnBarLinuxTextExpansionAdapter.EngineRuntimeError {
            XCTAssertEqual(error, .killSwitchActive)
        }

        let task = Task {
            try await adapter.startExternalEngine(timeoutMillis: 2_000)
        }
        try await Task.sleep(nanoseconds: 50_000_000)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch let error as BurnBarLinuxTextExpansionAdapter.EngineRuntimeError {
            XCTAssertEqual(error, .handshakeCancelled)
        }
    }

    func testPackagedPythonEngineMatchesSwiftProtocolEndToEnd() async throws {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let engine = repository.appendingPathComponent("packaging/linux/openburnbar-text-expansion-engine.py")
        let manifestPath = repository.appendingPathComponent("packaging/linux/test-engine.json").path
        let manifest = makeManifest(
            backend: .ibus,
            supportsWayland: true,
            supportsX11: true,
            engineID: "org.openburnbar.TextExpansion",
            executablePath: engine.path
        )
        let adapter = makeExternalAdapter(
            environment: ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            manifestData: try JSONEncoder().encode(manifest),
            metadata: [
                manifestPath: .init(ownerUID: 0, mode: 0o600),
                engine.path: .init(ownerUID: 0, mode: 0o700)
            ],
            verifySignature: { _ in true },
            manifestPath: manifestPath,
            allowedRoots: [repository.path]
        )
        let session = try await adapter.startExternalEngine(timeoutMillis: 1_000)
        let replacement = try await session.expand(
            trigger: "&&reply",
            replacement: "Hello from daemon-owned storage",
            context: .init(inspectable: true, isSecureField: false),
            timeoutMillis: 1_000,
            requestID: "python-integration-1"
        )
        XCTAssertEqual(replacement, "Hello from daemon-owned storage")
        _ = await session.stop(timeoutMillis: 500)
    }

    private func makeAdapter(
        environment: [String: String],
        executables: [String: String],
        exitCode: Int32,
        externalExpansionEnabled: Bool = false,
        manifestPath: String? = nil
    ) -> BurnBarLinuxTextExpansionAdapter {
        BurnBarLinuxTextExpansionAdapter(
            environment: { name in environment[name] },
            resolveExecutable: { name in executables[name] },
            runCommand: { _, _ in BurnBarLinuxTextExpansionAdapter.CommandResult(exitCode: exitCode) },
            manifestPath: manifestPath,
            externalExpansionEnabled: externalExpansionEnabled
        )
    }

    private func makeExternalAdapter(
        environment: [String: String],
        executables: [String: String],
        manifestData: Data,
        metadata: [String: BurnBarLinuxTextExpansionAdapter.FileMetadata],
        verifySignature: @escaping BurnBarLinuxTextExpansionAdapter.SignatureVerifier,
        manifestPath: String = "/trusted/text-expansion-engine.json",
        allowedRoots: [String] = ["/trusted"]
    ) -> BurnBarLinuxTextExpansionAdapter {
        BurnBarLinuxTextExpansionAdapter(
            environment: { name in environment[name] },
            resolveExecutable: { name in executables[name] },
            runCommand: { _, _ in .init(exitCode: 0) },
            manifestPath: manifestPath,
            externalExpansionEnabled: true,
            allowedManifestRoots: allowedRoots,
            allowedExecutableRoots: allowedRoots,
            trustedOwnerUIDs: [0],
            readManifest: { _ in manifestData },
            readFileMetadata: { path in metadata[path] },
            verifySignature: verifySignature
        )
    }

    private func makeManifest(
        backend: BurnBarLinuxTextExpansionAdapter.Backend,
        supportsWayland: Bool,
        supportsX11: Bool,
        readsClipboard: Bool = false,
        engineID: String = "openburnbar.test.engine",
        executablePath: String = "/trusted/bin/openburnbar-ibus"
    ) -> BurnBarLinuxTextExpansionAdapter.EngineManifest {
        BurnBarLinuxTextExpansionAdapter.EngineManifest(
            backend: backend,
            engineID: engineID,
            executablePath: executablePath,
            supportsWayland: supportsWayland,
            supportsX11: supportsX11,
            readsClipboard: readsClipboard,
            signature: .init(
                publicKeyBase64: Data(repeating: 0, count: 32).base64EncodedString(),
                signatureBase64: Data(repeating: 0, count: 64).base64EncodedString()
            )
        )
    }

    private func trustedMetadata(
        for manifest: BurnBarLinuxTextExpansionAdapter.EngineManifest
    ) -> [String: BurnBarLinuxTextExpansionAdapter.FileMetadata] {
        [
            "/trusted/text-expansion-engine.json": .init(ownerUID: 0, mode: 0o644),
            manifest.executablePath: .init(ownerUID: 0, mode: 0o755)
        ]
    }

    private func makeRuntimeScript(
        handshake: String?,
        expansionResponse: String? = nil,
        requestCaptureURL: URL? = nil
    ) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("openburnbar-text-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = directory.appendingPathComponent("engine.sh")
        var source = "#!/bin/sh\nIFS= read -r request || exit 2\n"
        if let handshake {
            source += "printf '%s\\n' '\(handshake)'\n"
        }
        source += "while IFS= read -r command; do\n"
        if let requestCaptureURL {
            source += "  printf '%s' \"$command\" > \(shellQuote(requestCaptureURL.path))\n"
        }
        source += "  case \"$command\" in\n"
        if let expansionResponse {
            source += "    *'\"operation\":\"expand\"'*) printf '%s\\n' \(shellQuote(expansionResponse)) ;;\n"
        }
        source += "    *'\"operation\":\"stop\"'*) exit 0 ;;\n"
        source += "  esac\n"
        source += "done\n"
        try Data(source.utf8).write(to: script, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        return script
    }

    private func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
#endif
