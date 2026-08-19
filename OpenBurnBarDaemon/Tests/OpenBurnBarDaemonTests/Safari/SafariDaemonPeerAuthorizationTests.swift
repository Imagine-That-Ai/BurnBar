import OpenBurnBarComputerUseCore
import OpenBurnBarKernel
@testable import OpenBurnBarDaemon
import XCTest

final class SafariDaemonPeerAuthorizationTests: XCTestCase {
    func test_signedSafariIdentityMapsToExactAttenuatedProfile() throws {
        let pair = try DaemonTestUnixSocketConnection.establish()
        defer { pair.closeAll() }

        let authenticator = BurnBarDaemonPeerAuthenticator(enforced: true) { _ in
            .safariExtension
        }
        let profile = try authenticator.validatePeer(
            socketFD: pair.acceptedFD,
            peerPID: nil
        )

        XCTAssertEqual(
            BurnBarDaemonPeerIdentity(
                bundleIdentifier: "com.openburnbar.app.safari-extension"
            ),
            .safariExtension
        )
        XCTAssertEqual(profile, .safariExtension)
        XCTAssertNotNil(
            profile.allowedMethods,
            "The WebExtension must use an exact method allowlist, not a broad capability grant."
        )
    }

    func test_safariProfilePermitsOnlyItsCreateBridgeAndLearningLanes() {
        let profile = BurnBarPeerCapabilityProfile.safariExtension

        let requiredMethods: Set<BurnBarRPCMethod> = [
            .health,
            .catalog,
            .membershipStatus,
            .clientAttach,
            .clientDetach,
            .runCreate,
        ]
        for method in requiredMethods {
            XCTAssertTrue(
                profile.permits(method),
                "Safari profile unexpectedly denies required method \(method.rawValue)"
            )
        }

        let safariMethods = BurnBarRPCMethod.allCases.filter {
            $0.rawValue.hasPrefix("daemon.safari.")
        }
        XCTAssertFalse(safariMethods.isEmpty)
        for method in safariMethods {
            XCTAssertTrue(
                profile.permits(method),
                "Safari profile must permit its own bridge method \(method.rawValue)"
            )
        }

        XCTAssertEqual(
            BurnBarRPCCapability.capability(for: .safariApprovalRespond),
            .safari
        )
    }

    func test_safariProfileDeniesGenericRunApprovalComputerUseAndCredentialAgency() {
        let profile = BurnBarPeerCapabilityProfile.safariExtension
        let forbiddenMethods: Set<BurnBarRPCMethod> = [
            .configGet,
            .configUpdate,
            .providerCredentialSlotUpsert,
            .providerCredentialSlotRemove,
            .connectorConfigUpdate,
            .browserAction,
            .computerUseCapabilityStateUpdate,
            .computerUseInvoke,
            .computerUseSessionStart,
            .computerUseApprovalPending,
            .computerUseApprovalRespond,
            .computerUsePanicHalt,
            .computerUseAuditExport,
            .runList,
            .runGet,
            .runPoll,
            .runCancel,
            .runResume,
            .approvalRespond,
            .workspaceExecuteTool,
            .workspaceToolResult,
            .memoryRemember,
            .memoryForget
        ]

        for method in forbiddenMethods {
            XCTAssertFalse(
                profile.permits(method),
                "Safari profile unexpectedly permits \(method.rawValue)"
            )
        }
    }

    func test_daemonTrustAdmitsSafariWithoutWideningPrivilegedInputTrust() {
        let extensionIdentifier = "com.openburnbar.app.safari-extension"

        XCTAssertTrue(
            OpenBurnBarPrivilegedTrust.daemonRPCPeerBundleIdentifiers
                .contains(extensionIdentifier)
        )
        XCTAssertTrue(
            OpenBurnBarPrivilegedTrust.daemonRPCPeerDesignatedRequirement
                .contains("identifier \"\(extensionIdentifier)\"")
        )

        XCTAssertFalse(
            OpenBurnBarPrivilegedTrust.privilegedInputPeerBundleIdentifiers
                .contains(extensionIdentifier)
        )
        XCTAssertFalse(
            OpenBurnBarPrivilegedTrust.privilegedInputPeerDesignatedRequirement
                .contains("identifier \"\(extensionIdentifier)\"")
        )
    }
}
