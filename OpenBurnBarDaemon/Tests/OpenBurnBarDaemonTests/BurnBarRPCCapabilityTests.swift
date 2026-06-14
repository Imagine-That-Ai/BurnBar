import OpenBurnBarCore
@testable import OpenBurnBarDaemon
import XCTest

/// T-DMN-01: per-operation capability attenuation on the main control socket.
/// Each RPC method maps to exactly one capability group, and an attenuated peer
/// profile must refuse — fail closed — any method outside its scoped set.
final class BurnBarRPCCapabilityTests: XCTestCase {
    func test_everyMethodHasACapability() {
        // Totality: the classification switch covers every case, so this simply
        // proves no method resolves to an unexpected group and the map is stable.
        for method in BurnBarRPCMethod.allCases {
            _ = BurnBarRPCCapability.capability(for: method)
        }
    }

    func test_highRiskMethodsMapToExpectedGroups() {
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .computerUseInvoke), .computerUse)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .computerUseSessionStart), .computerUse)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .configUpdate), .config)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .providerCredentialSlotUpsert), .config)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .runCreate), .run)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .health), .lifecycle)
        XCTAssertEqual(BurnBarRPCCapability.capability(for: .searchQuery), .search)
    }

    func test_fullProfilePermitsEveryMethod() {
        let profile = BurnBarPeerCapabilityProfile.full
        for method in BurnBarRPCMethod.allCases {
            XCTAssertTrue(profile.permits(method), "full profile must permit \(method.rawValue)")
        }
    }

    func test_readOnlyProfileRefusesWritesAndComputerUse() {
        let profile = BurnBarPeerCapabilityProfile.readOnly
        // Allowed: read posture.
        XCTAssertTrue(profile.permits(.health))
        XCTAssertTrue(profile.permits(.usageRecent))
        XCTAssertTrue(profile.permits(.searchQuery))
        // Refused: every agency-bearing surface.
        XCTAssertFalse(profile.permits(.configUpdate))
        XCTAssertFalse(profile.permits(.providerCredentialSlotUpsert))
        XCTAssertFalse(profile.permits(.runCreate))
        XCTAssertFalse(profile.permits(.computerUseInvoke))
        XCTAssertFalse(profile.permits(.computerUseSessionStart))
        XCTAssertFalse(profile.permits(.browserAction))
    }

    func test_runClientProfileIsDeniedComputerUseAndConfig() {
        let profile = BurnBarPeerCapabilityProfile.runClient
        XCTAssertTrue(profile.permits(.runCreate))
        XCTAssertTrue(profile.permits(.clientAttach))
        XCTAssertTrue(profile.permits(.browserAction))
        // A compromised run client must NOT reach the HID-adjacent computer-use
        // surface or rewrite stored provider credentials.
        XCTAssertFalse(profile.permits(.computerUseInvoke))
        XCTAssertFalse(profile.permits(.configUpdate))
        XCTAssertFalse(profile.permits(.providerCredentialSlotUpsert))
    }

    func test_attenuationOnlyNarrows() {
        let narrowed = BurnBarPeerCapabilityProfile.full
            .attenuated(to: .readOnly)
        XCTAssertEqual(narrowed.capabilities, BurnBarPeerCapabilityProfile.readOnly.capabilities)
        // Intersecting with full cannot widen readOnly.
        let stillNarrow = BurnBarPeerCapabilityProfile.readOnly.attenuated(to: .full)
        XCTAssertEqual(stillNarrow.capabilities, BurnBarPeerCapabilityProfile.readOnly.capabilities)
    }
}
