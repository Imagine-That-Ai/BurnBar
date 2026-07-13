#if os(Linux)
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
        XCTAssertEqual(status.registration, "engine_not_registered")
        XCTAssertFalse(status.supportsExternalExpansion)
        XCTAssertTrue(status.noGlobalCapture)
        XCTAssertEqual(status.secureFieldPolicy, "deny-unless-inspectable-and-explicitly-nonsecure")
        XCTAssertTrue(status.detail.contains("ibus"))
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
        XCTAssertTrue(status.detail.contains("not registered"))
    }

    func testFailsClosedWhenSessionTypeOrControlProbeIsUnproven() {
        let unknownSession = makeAdapter(
            environment: ["GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            exitCode: 0
        ).status()
        XCTAssertEqual(unknownSession.status, "blocked")
        XCTAssertEqual(unknownSession.sessionType, "unknown")

        let stoppedBackend = makeAdapter(
            environment: ["XDG_SESSION_TYPE": "wayland", "GTK_IM_MODULE": "ibus"],
            executables: ["ibus": "/usr/bin/ibus"],
            exitCode: 1
        ).status()
        XCTAssertEqual(stoppedBackend.status, "blocked")
        XCTAssertEqual(stoppedBackend.backend, "ibus")
        XCTAssertFalse(stoppedBackend.supportsExternalExpansion)
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

    private func makeAdapter(
        environment: [String: String],
        executables: [String: String],
        exitCode: Int32
    ) -> BurnBarLinuxTextExpansionAdapter {
        BurnBarLinuxTextExpansionAdapter(
            environment: { name in environment[name] },
            resolveExecutable: { name in executables[name] },
            runCommand: { _, _ in BurnBarLinuxTextExpansionAdapter.CommandResult(exitCode: exitCode) }
        )
    }
}
#endif
