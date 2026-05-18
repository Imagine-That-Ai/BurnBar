import XCTest
import OpenBurnBarCore
import OpenBurnBarMedia
@testable import OpenBurnBarMobile

/// Mercury Phase 8 — locks in the `device://paired-mac/<id>` URI
/// resolution path. The registry synthesizes a `AgentIdentity` for
/// the Mercury Live tile only when `pairedMacPeer` is set, and the
/// returned identity carries the silver palette + macbook glyph.
@MainActor
final class AgentIdentityRegistryMacURITests: XCTestCase {
    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testPairedMacURIResolvesToSynthesizedIdentity() {
        let registry = AgentIdentityRegistry(seed: [])
        registry.pairedMacPeer = MercuryPeer(
            connectionID: "macbook-pro-alberto",
            displayName: "Alberto's MacBook",
            isOnline: true,
            lastSeenAt: referenceDate,
            capabilities: MercuryPeer.macFallbackCapabilities
        )

        let identity = registry.identity(for: "device://paired-mac/macbook-pro-alberto")
        XCTAssertNotNil(identity)
        XCTAssertEqual(identity?.displayName, "Alberto's MacBook")
        XCTAssertEqual(identity?.glyph, "🖥")
        XCTAssertEqual(identity?.paletteHex, "8B9DC3")
        XCTAssertEqual(identity?.availability, .online)
        XCTAssertEqual(identity?.tagline, "Mirror, call, or send a file")
    }

    func testPairedMacURIReturnsNilWhenPeerSourceEmpty() {
        let registry = AgentIdentityRegistry(seed: [])
        XCTAssertNil(registry.pairedMacPeer)
        XCTAssertNil(registry.identity(for: "device://paired-mac/anything"))
    }

    func testOfflinePeerYieldsOfflineAvailability() {
        let registry = AgentIdentityRegistry(seed: [])
        registry.pairedMacPeer = MercuryPeer(
            connectionID: "mac-1",
            displayName: "Backup Mac",
            isOnline: false,
            lastSeenAt: referenceDate,
            capabilities: []
        )

        let identity = registry.identity(for: "device://paired-mac/mac-1")
        XCTAssertEqual(identity?.availability, .offline)
    }

    func testKnownBuiltInURIStillResolvesEvenWithMercuryPeerSet() {
        let registry = AgentIdentityRegistry()
        registry.pairedMacPeer = MercuryPeer(
            connectionID: "mac-1",
            displayName: "Mac",
            isOnline: true,
            lastSeenAt: referenceDate,
            capabilities: []
        )
        // Built-in lookups must keep working alongside the new
        // device path.
        let builtIn = registry.identity(for: AgentIdentity.builtInURI(.hermes))
        XCTAssertNotNil(builtIn)
        XCTAssertEqual(builtIn?.runtimeID, .hermes)
    }
}
