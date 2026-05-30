import XCTest
import OpenBurnBarCore
@testable import OpenBurnBarComputerUseCore

/// Verifies the central blocker→copy mapper that keeps raw Remote Unlock
/// blocker identifiers out of user-facing UI. The product invariant: a normal
/// user never sees a raw blocker string, an entitlement/signing reference, or
/// an "Apple approval" mention — only action-oriented setup copy.
final class RemoteUnlockBlockerPresentationTests: XCTestCase {

    // MARK: - Named blockers from the handoff

    private let coveredBlockers = [
        "virtual_hid_driver_rejected",
        "virtual_hid_driver_missing",
        "virtual_hid_driver_inactive",
        "remote_desktop_permission_missing",
        "remote_unlock_report_missing",
        "lock_screen_capture_probe_missing",
        "credential_input_probe_missing",
        "unlock_probe_missing"
    ]

    func test_emptyBlockersReturnNil() {
        XCTAssertNil(RemoteUnlockBlockerPresentationMap.presentation(forBlockers: []))
        XCTAssertNil(RemoteUnlockBlockerPresentationMap.presentation(forBlockers: ["", "   "]))
    }

    func test_everyCoveredBlockerResolvesToProductReadyCopy() {
        for blocker in coveredBlockers {
            guard let presentation = RemoteUnlockBlockerPresentationMap.presentation(forBlockers: [blocker]) else {
                return XCTFail("Expected a presentation for \(blocker)")
            }
            assertProductSafe(presentation, blocker: blocker)
            // The raw identifier survives only as a diagnostic.
            XCTAssertEqual(presentation.diagnosticBlockers, [blocker])
        }
    }

    func test_unknownBlockerFallsBackToSafeGenericCopy() {
        guard let presentation = RemoteUnlockBlockerPresentationMap.presentation(
            forBlockers: ["some_future_blocker_we_have_not_seen"]
        ) else {
            return XCTFail("Expected a generic fallback presentation")
        }
        assertProductSafe(presentation, blocker: "some_future_blocker_we_have_not_seen")
        XCTAssertEqual(presentation.recommendedAction, .finishOnMac)
        XCTAssertEqual(presentation.title, "Finish Remote Unlock setup")
    }

    // MARK: - Specific copy mappings

    func test_virtualHidMissingMapsToSetUpInput() {
        let presentation = require(["virtual_hid_driver_missing"])
        XCTAssertEqual(presentation.title, "Set up locked-screen input")
        XCTAssertEqual(presentation.recommendedAction, .setUpMacInput)
        XCTAssertEqual(presentation.primaryActionTitle, "Set up input on Mac")
    }

    func test_virtualHidInactiveMapsToInstalledButNotActive() {
        let presentation = require(["virtual_hid_driver_inactive"])
        XCTAssertEqual(presentation.title, "Input driver installed but not active")
        XCTAssertEqual(presentation.recommendedAction, .setUpMacInput)
    }

    func test_virtualHidRejectedMapsToApproveInPrivacySettings() {
        let presentation = require(["virtual_hid_driver_rejected"])
        XCTAssertEqual(presentation.title, "Approve OpenBurnBar in Privacy & Security")
        XCTAssertEqual(presentation.recommendedAction, .approveInPrivacySettings)
        XCTAssertEqual(presentation.primaryActionTitle, "Set up input on Mac")
    }

    func test_remoteDesktopMapsToPermissionNeeded() {
        let presentation = require(["remote_desktop_permission_missing"])
        XCTAssertEqual(presentation.title, "Remote Desktop permission needed")
        XCTAssertEqual(presentation.recommendedAction, .grantRemoteDesktop)
    }

    func test_probeBlockersReadAsFinishingSetup() {
        for blocker in ["remote_unlock_report_missing",
                        "lock_screen_capture_probe_missing",
                        "credential_input_probe_missing",
                        "unlock_probe_missing"] {
            let presentation = require([blocker])
            XCTAssertEqual(presentation.title, "Reconnect after setup", "for \(blocker)")
            XCTAssertEqual(presentation.recommendedAction, .reconnect, "for \(blocker)")
        }
    }

    // MARK: - Priority ordering

    func test_rejectedOutranksMissingAndInactive() {
        // A policy rejection also leaves the lane missing + inactive; the user
        // should be told to approve, not to re-install.
        let presentation = require([
            "virtual_hid_driver_rejected",
            "virtual_hid_driver_missing",
            "virtual_hid_driver_inactive"
        ])
        XCTAssertEqual(presentation.recommendedAction, .approveInPrivacySettings)
    }

    func test_remoteDesktopOutranksInputLane() {
        // Remote Desktop is the earlier setup step, so it surfaces first.
        let presentation = require([
            "virtual_hid_driver_missing",
            "remote_desktop_permission_missing"
        ])
        XCTAssertEqual(presentation.recommendedAction, .grantRemoteDesktop)
    }

    func test_environmentBlockersOutrankEverything() {
        let presentation = require([
            "unlock_probe_missing",
            "virtual_hid_driver_missing",
            "remote_access_daemon_missing"
        ])
        XCTAssertEqual(presentation.recommendedAction, .finishOnMac)
        XCTAssertEqual(presentation.title, "Set up Remote Unlock on your Mac")
    }

    func test_diagnosticBlockersPreserveFullListWhitespaceTrimmed() {
        let presentation = require([" virtual_hid_driver_missing ", "", "unlock_probe_missing"])
        XCTAssertEqual(presentation.diagnosticBlockers, ["virtual_hid_driver_missing", "unlock_probe_missing"])
    }

    // MARK: - The hard invariant: nothing forbidden leaks, for ANY blocker

    func test_noBlockerEverLeaksRawOrForbiddenLanguage() {
        // Sweep every blocker the policy and certification report can emit,
        // plus a few synthetic unknowns, and assert none produce forbidden copy.
        let allBlockers = coveredBlockers + [
            "remote_unlock_flag_disabled",
            "direct_download_build_required",
            "remote_access_daemon_missing",
            "apple_screen_sharing_unavailable",
            "remote_unlock_recipient_key_missing",
            "loopback_firewall_guard_missing",
            "os_build_changed_recertification_required",
            "backend_certification_stale",
            "remote_unlock_not_certified",
            "totally_unknown_blocker_42"
        ]
        for blocker in allBlockers {
            let presentation = require([blocker])
            assertProductSafe(presentation, blocker: blocker)
        }
    }

    // MARK: - Helpers

    private func require(_ blockers: [String], file: StaticString = #filePath, line: UInt = #line) -> RemoteUnlockBlockerPresentation {
        guard let presentation = RemoteUnlockBlockerPresentationMap.presentation(forBlockers: blockers) else {
            XCTFail("Expected a presentation for \(blockers)", file: file, line: line)
            return RemoteUnlockBlockerPresentation(
                title: "", message: "", primaryActionTitle: nil,
                recommendedAction: .finishOnMac, symbolName: "", diagnosticBlockers: []
            )
        }
        return presentation
    }

    /// Asserts the user-facing copy is safe: non-empty, and free of raw blocker
    /// identifiers and the language the product explicitly forbids.
    private func assertProductSafe(_ presentation: RemoteUnlockBlockerPresentation, blocker: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(presentation.title.isEmpty, "empty title for \(blocker)", file: file, line: line)
        XCTAssertFalse(presentation.message.isEmpty, "empty message for \(blocker)", file: file, line: line)

        let userText = (presentation.title + " " + presentation.message).lowercased()

        // No raw blocker identifier (snake_case token) ever appears in copy.
        XCTAssertFalse(userText.contains(blocker.lowercased()), "raw blocker '\(blocker)' leaked into copy", file: file, line: line)
        XCTAssertFalse(userText.contains("_"), "snake_case identifier leaked into copy for \(blocker)", file: file, line: line)

        // Forbidden product language.
        for forbidden in ["virtual hid", "virtual_hid", "driverkit", "entitlement",
                          "apple approval", "waiting for apple", "rejected by apple", "unavailable"] {
            XCTAssertFalse(userText.contains(forbidden), "forbidden phrase '\(forbidden)' in copy for \(blocker)", file: file, line: line)
        }
    }
}
