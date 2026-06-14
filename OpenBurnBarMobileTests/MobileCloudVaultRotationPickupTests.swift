import Foundation
import XCTest
@testable import OpenBurnBarMobile

/// RR-5: a surviving iOS device picks up pending Cloud Vault rotation requirements
/// when the revoking device is offline or on a platform that cannot rotate. These
/// cover the pure survivor filter and payload decode that gate the rotation chain.
final class MobileCloudVaultRotationPickupTests: XCTestCase {

    private typealias Requirement = MobileCloudVaultRevocationRotation.PendingCloudVaultRotationRequirement

    // MARK: - Survivor filter

    func test_eligibleRequirements_keepsOnlyRequirementsWhereDeviceSurvives() {
        let requirements = [
            Requirement(requirementId: "r1", survivorDeviceIds: ["iphone-1", "ipad-1"]),
            Requirement(requirementId: "r2", survivorDeviceIds: ["ipad-1"]),
            Requirement(requirementId: "r3", survivorDeviceIds: ["iphone-1"])
        ]
        let eligible = MobileCloudVaultRevocationRotation.eligibleRequirements(
            from: requirements,
            rotatingDeviceId: "iphone-1"
        )
        XCTAssertEqual(eligible, ["r1", "r3"])
    }

    func test_eligibleRequirements_excludesAlreadyActioned() {
        let requirements = [
            Requirement(requirementId: "r1", survivorDeviceIds: ["iphone-1"]),
            Requirement(requirementId: "r2", survivorDeviceIds: ["iphone-1"])
        ]
        let eligible = MobileCloudVaultRevocationRotation.eligibleRequirements(
            from: requirements,
            rotatingDeviceId: "iphone-1",
            alreadyActioned: ["r1"]
        )
        XCTAssertEqual(eligible, ["r2"])
    }

    func test_eligibleRequirements_deduplicatesRepeatedRequirementIds() {
        let requirements = [
            Requirement(requirementId: "r1", survivorDeviceIds: ["iphone-1"]),
            Requirement(requirementId: "r1", survivorDeviceIds: ["iphone-1"])
        ]
        let eligible = MobileCloudVaultRevocationRotation.eligibleRequirements(
            from: requirements,
            rotatingDeviceId: "iphone-1"
        )
        XCTAssertEqual(eligible, ["r1"], "a single pass runs each requirement at most once")
    }

    func test_eligibleRequirements_trimsRotatingDeviceIdAndEmptyIsNoop() {
        let requirements = [Requirement(requirementId: "r1", survivorDeviceIds: ["iphone-1"])]
        XCTAssertEqual(
            MobileCloudVaultRevocationRotation.eligibleRequirements(from: requirements, rotatingDeviceId: "  iphone-1  "),
            ["r1"]
        )
        XCTAssertEqual(
            MobileCloudVaultRevocationRotation.eligibleRequirements(from: requirements, rotatingDeviceId: "   "),
            []
        )
    }

    func test_eligibleRequirements_emptyWhenNotASurvivor() {
        let requirements = [Requirement(requirementId: "r1", survivorDeviceIds: ["ipad-1", "iphone-2"])]
        XCTAssertEqual(
            MobileCloudVaultRevocationRotation.eligibleRequirements(from: requirements, rotatingDeviceId: "iphone-1"),
            []
        )
    }

    // MARK: - Payload decode

    func test_parsePendingRequirements_decodesRequirementIdOrId() {
        let raw: [[String: Any]] = [
            ["requirementId": "r1", "survivorDeviceIds": ["iphone-1", " ipad-1 "]],
            ["id": "r2", "survivorDeviceIds": ["iphone-2"]],
            ["survivorDeviceIds": ["iphone-1"]],
            ["requirementId": "", "survivorDeviceIds": []]
        ]
        let parsed = MobileCloudVaultRevocationRotation.parsePendingRequirements(raw)
        XCTAssertEqual(parsed.map(\.requirementId), ["r1", "r2"])
        XCTAssertEqual(parsed.first?.survivorDeviceIds, ["iphone-1", "ipad-1"], "survivor ids are trimmed and empties dropped")
    }

    func test_parsePendingRequirements_missingSurvivorsYieldsEmptyList() {
        let parsed = MobileCloudVaultRevocationRotation.parsePendingRequirements([["requirementId": "r1"]])
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.survivorDeviceIds, [])
    }

    // MARK: - Filter composes with decode end-to-end (no Firebase)

    func test_decodeThenFilter_endToEnd() {
        let raw: [[String: Any]] = [
            ["requirementId": "r1", "survivorDeviceIds": ["iphone-1"]],
            ["requirementId": "r2", "survivorDeviceIds": ["android-1"]]
        ]
        let parsed = MobileCloudVaultRevocationRotation.parsePendingRequirements(raw)
        let eligible = MobileCloudVaultRevocationRotation.eligibleRequirements(from: parsed, rotatingDeviceId: "iphone-1")
        XCTAssertEqual(eligible, ["r1"], "iPhone survives r1; r2 (Android-only survivor) is skipped")
    }
}