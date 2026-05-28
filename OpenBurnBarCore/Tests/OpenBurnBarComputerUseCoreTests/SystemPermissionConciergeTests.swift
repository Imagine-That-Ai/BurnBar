import XCTest
import CryptoKit
@testable import OpenBurnBarCore
@testable import OpenBurnBarComputerUseCore

final class SystemPermissionConciergeTests: XCTestCase {

    // MARK: - Wire types

    func test_systemPermissionRequest_roundTripsThroughJSON() throws {
        let authority = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "phone-abc",
            counter: 7,
            timestamp: Date(timeIntervalSince1970: 1_730_000_000),
            intentHashBlake3: "deadbeef",
            signatureEd25519: "AAAA"
        )
        let request = HermesRealtimeRelaySystemPermissionRequest(
            requestId: "req-1",
            clientIntentId: "intent-1",
            kind: .automation,
            bundleId: "com.apple.Notes",
            originatingToolCallId: "tool-1",
            originatingToolName: "openNote",
            action: .promptAndOpenSettings,
            requestedAt: Date(timeIntervalSince1970: 1_730_000_001),
            authority: authority
        )

        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(HermesRealtimeRelaySystemPermissionRequest.self, from: data)

        XCTAssertEqual(decoded, request)
    }

    func test_systemPermissionStatus_roundTripsThroughJSON() throws {
        let status = HermesRealtimeRelaySystemPermissionStatus(
            kind: .screenRecording,
            bundleId: nil,
            status: .granted,
            originatingToolCallId: "tool-2",
            originatingToolName: "macScreenshot",
            deepLink: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            instructions: nil,
            failureCategory: "tccd_screen_recording",
            lastChangedAt: Date(timeIntervalSince1970: 1_730_000_500)
        )
        let data = try JSONEncoder().encode(status)
        let decoded = try JSONDecoder().decode(HermesRealtimeRelaySystemPermissionStatus.self, from: data)
        XCTAssertEqual(decoded, status)
    }

    // MARK: - Signing

    func test_signSystemPermissionRequest_verifiesAgainstSameRequest() throws {
        let signer = ComputerUsePhoneControlSigner()
        let key = Curve25519.Signing.PrivateKey()
        let placeholder = HermesRealtimeRelayAuthorityEnvelope(
            peerNodeId: "",
            counter: 0,
            timestamp: Date(timeIntervalSince1970: 0),
            intentHashBlake3: "",
            signatureEd25519: ""
        )
        let request = HermesRealtimeRelaySystemPermissionRequest(
            requestId: "req-1",
            clientIntentId: "intent-1",
            kind: .accessibility,
            bundleId: nil,
            originatingToolCallId: nil,
            originatingToolName: nil,
            action: .promptAndOpenSettings,
            requestedAt: Date(timeIntervalSince1970: 1_730_000_100),
            authority: placeholder
        )

        let counter: UInt64 = 4
        let timestamp = Date(timeIntervalSince1970: 1_730_000_100)
        let signed = try signer.sign(
            systemPermissionRequest: request,
            peerNodeId: "phone-abc",
            counter: counter,
            timestamp: timestamp,
            privateKey: key
        )

        XCTAssertNoThrow(
            try signer.verify(
                systemPermissionRequest: request,
                authority: signed,
                peerPublicKey: key.publicKey,
                lastSeenCounter: 0,
                now: timestamp,
                freshnessSeconds: 30
            )
        )
    }

    // MARK: - Classifier

    func test_classifier_recognizesScreenRecordingFailure() {
        let classifier = SystemPermissionToolFailureClassifier()
        let detail = "screencapture: cannot grab the screen because Screen Recording permission is required"
        let match = classifier.classify(toolResult: detail)
        XCTAssertEqual(match?.kind, .screenRecording)
    }

    func test_classifier_recognizesAccessibilityFailure() {
        let classifier = SystemPermissionToolFailureClassifier()
        let detail = "AXIsProcessTrusted returned false — accessibility permission is required"
        let match = classifier.classify(toolResult: detail)
        XCTAssertEqual(match?.kind, .accessibility)
    }

    func test_classifier_recognizesAutomationWithBundleId() {
        let classifier = SystemPermissionToolFailureClassifier()
        let detail = "NSAppleScript error: not allowed to send apple events to com.apple.Safari"
        let match = classifier.classify(toolResult: detail)
        XCTAssertEqual(match?.kind, .automation)
        XCTAssertEqual(match?.bundleId, "com.apple.safari")
    }

    func test_classifier_recognizesMicrophoneBeforeCamera() {
        let classifier = SystemPermissionToolFailureClassifier()
        let detail = "AVCaptureDevice.audio: no permission to access the microphone"
        let match = classifier.classify(toolResult: detail)
        XCTAssertEqual(match?.kind, .microphone)
    }

    func test_classifier_recognizesFullDiskAccess() {
        let classifier = SystemPermissionToolFailureClassifier()
        let detail = "Operation not permitted: ~/Library/Safari/Bookmarks.plist (full disk access)"
        let match = classifier.classify(toolResult: detail)
        XCTAssertEqual(match?.kind, .fullDiskAccess)
    }

    func test_classifier_ignoresPlainModelRefusal() {
        let classifier = SystemPermissionToolFailureClassifier()
        let detail = "Sorry, I can't take a screenshot for you right now."
        XCTAssertNil(classifier.classify(toolResult: detail))
    }

    func test_classifier_assistantTextRequiresPermissionAnchor() {
        let classifier = SystemPermissionToolFailureClassifier()
        XCTAssertNil(classifier.classify(assistantText: "I cannot help with that"))
        let match = classifier.classify(assistantText: "Screen Recording permission is required on your Mac.")
        XCTAssertEqual(match?.kind, .screenRecording)
    }

    // MARK: - SystemPermissionItem

    func test_systemPermissionItem_dedupeKey_isStableAcrossSources() {
        let kind = SystemPermissionKind.automation
        let macItem = SystemPermissionItem(
            kind: kind,
            bundleId: "com.apple.Notes",
            threadId: "thread-1",
            source: .macStructured
        )
        let phoneItem = SystemPermissionItem(
            kind: kind,
            bundleId: "com.apple.Notes",
            threadId: "thread-1",
            source: .iosHeuristic
        )
        XCTAssertEqual(macItem.dedupeKey, phoneItem.dedupeKey)
    }

    func test_accessibilityDeepLink_pointsToPrivacyAccessibilityPane() {
        XCTAssertEqual(
            SystemPermissionKind.accessibility.systemSettingsDeepLink,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        )
    }
}
