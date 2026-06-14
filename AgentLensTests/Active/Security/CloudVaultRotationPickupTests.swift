import Foundation
import XCTest
@testable import OpenBurnBar

/// RR-5: a surviving Mac picks up pending Cloud Vault rotation requirements when
/// the revoking device is offline/Android. These cover the pure survivor filter
/// and the payload decode that gate the rotation chain.
final class CloudVaultRotationPickupTests: XCTestCase {

    private typealias Requirement = ComputerUseSecurityCallableClient.PendingCloudVaultRotationRequirement

    // MARK: - Survivor filter

    func test_eligibleRequirements_keepsOnlyRequirementsWhereDeviceSurvives() {
        let requirements = [
            Requirement(requirementId: "r1", survivorDeviceIds: ["mac-1", "ipad-1"]),
            Requirement(requirementId: "r2", survivorDeviceIds: ["ipad-1"]),
            Requirement(requirementId: "r3", survivorDeviceIds: ["mac-1"])
        ]
        let eligible = ComputerUseSecurityCallableClient.eligibleRequirements(
            from: requirements,
            rotatingDeviceId: "mac-1"
        )
        XCTAssertEqual(eligible, ["r1", "r3"])
    }

    func test_eligibleRequirements_excludesAlreadyActioned() {
        let requirements = [
            Requirement(requirementId: "r1", survivorDeviceIds: ["mac-1"]),
            Requirement(requirementId: "r2", survivorDeviceIds: ["mac-1"])
        ]
        let eligible = ComputerUseSecurityCallableClient.eligibleRequirements(
            from: requirements,
            rotatingDeviceId: "mac-1",
            alreadyActioned: ["r1"]
        )
        XCTAssertEqual(eligible, ["r2"])
    }

    func test_eligibleRequirements_deduplicatesRepeatedRequirementIds() {
        let requirements = [
            Requirement(requirementId: "r1", survivorDeviceIds: ["mac-1"]),
            Requirement(requirementId: "r1", survivorDeviceIds: ["mac-1"])
        ]
        let eligible = ComputerUseSecurityCallableClient.eligibleRequirements(
            from: requirements,
            rotatingDeviceId: "mac-1"
        )
        XCTAssertEqual(eligible, ["r1"], "a single pass runs each requirement at most once")
    }

    func test_eligibleRequirements_trimsRotatingDeviceIdAndEmptyIsNoop() {
        let requirements = [Requirement(requirementId: "r1", survivorDeviceIds: ["mac-1"])]
        XCTAssertEqual(
            ComputerUseSecurityCallableClient.eligibleRequirements(from: requirements, rotatingDeviceId: "  mac-1  "),
            ["r1"]
        )
        XCTAssertEqual(
            ComputerUseSecurityCallableClient.eligibleRequirements(from: requirements, rotatingDeviceId: "   "),
            []
        )
    }

    func test_eligibleRequirements_emptyWhenNotASurvivor() {
        let requirements = [Requirement(requirementId: "r1", survivorDeviceIds: ["ipad-1", "mac-2"])]
        XCTAssertEqual(
            ComputerUseSecurityCallableClient.eligibleRequirements(from: requirements, rotatingDeviceId: "mac-1"),
            []
        )
    }

    // MARK: - Payload decode

    func test_parsePendingRequirements_decodesRequirementIdOrId() {
        let raw: [[String: Any]] = [
            ["requirementId": "r1", "survivorDeviceIds": ["mac-1", " ipad-1 "]],
            ["id": "r2", "survivorDeviceIds": ["mac-2"]],
            ["survivorDeviceIds": ["mac-1"]],            // missing id — dropped
            ["requirementId": "", "survivorDeviceIds": []] // empty id — dropped
        ]
        let parsed = ComputerUseSecurityCallableClient.parsePendingRequirements(raw)
        XCTAssertEqual(parsed.map(\.requirementId), ["r1", "r2"])
        XCTAssertEqual(parsed.first?.survivorDeviceIds, ["mac-1", "ipad-1"], "survivor ids are trimmed and empties dropped")
    }

    func test_parsePendingRequirements_missingSurvivorsYieldsEmptyList() {
        let parsed = ComputerUseSecurityCallableClient.parsePendingRequirements([["requirementId": "r1"]])
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.survivorDeviceIds, [])
    }

    func test_listPendingCallablePayload_includesCallerDeviceId() {
        let payload = ComputerUseSecurityCallableClient.listPendingCallablePayload(callerDeviceId: "  mac-1  ")
        XCTAssertEqual(payload["callerDeviceId"] as? String, "mac-1")
    }

    // MARK: - Filter composes with decode end-to-end (no Firebase)

    func test_decodeThenFilter_endToEnd() {
        let raw: [[String: Any]] = [
            ["requirementId": "r1", "survivorDeviceIds": ["mac-1"]],
            ["requirementId": "r2", "survivorDeviceIds": ["android-1"]]
        ]
        let parsed = ComputerUseSecurityCallableClient.parsePendingRequirements(raw)
        let eligible = ComputerUseSecurityCallableClient.eligibleRequirements(from: parsed, rotatingDeviceId: "mac-1")
        XCTAssertEqual(eligible, ["r1"], "Mac survives r1; r2 (Android-only survivor) is skipped")
    }
}
