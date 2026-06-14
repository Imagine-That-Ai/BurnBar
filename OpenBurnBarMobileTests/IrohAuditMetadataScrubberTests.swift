import XCTest
@testable import OpenBurnBarMobile

/// T-TRN-04 — control-plane metadata reduction for cloud-visible iroh audit
/// events. Identifiers are hashed (stable, non-reversible); counts are bucketed;
/// non-identifier fields pass through.
final class IrohAuditMetadataScrubberTests: XCTestCase {

    func testNodeIdsAreHashedNotStoredRaw() {
        let nodeId = "k51qzi5uqu5dlvj2baxnqndepeb86cbk3ng7n3i46uzyxzyqj2xjonzllnv0v8"
        let scrubbed = IrohAuditMetadataScrubber.scrub(["targetNodeId": nodeId])
        XCTAssertNotEqual(scrubbed["targetNodeId"], nodeId)
        XCTAssertFalse(scrubbed["targetNodeId"]?.contains(nodeId) ?? true)
        XCTAssertTrue(scrubbed["targetNodeId"]?.hasPrefix("h:") ?? false)
    }

    func testRelayURLIsHashed() {
        let scrubbed = IrohAuditMetadataScrubber.scrub(["relayURL": "https://relay.example.com:443"])
        XCTAssertTrue(scrubbed["relayURL"]?.hasPrefix("h:") ?? false)
        XCTAssertFalse(scrubbed["relayURL"]?.contains("example") ?? true)
    }

    func testSamePeerHashesStablyForCorrelation() {
        let a = IrohAuditMetadataScrubber.fingerprint("node-abc")
        let b = IrohAuditMetadataScrubber.fingerprint("node-abc")
        XCTAssertEqual(a, b, "Stable so support can correlate events for the same peer.")
        XCTAssertNotEqual(a, IrohAuditMetadataScrubber.fingerprint("node-xyz"))
    }

    func testEmptyIdentifierMapsToNone() {
        XCTAssertEqual(IrohAuditMetadataScrubber.fingerprint(""), "none")
        XCTAssertEqual(IrohAuditMetadataScrubber.fingerprint("   "), "none")
    }

    func testCountsAreBucketed() {
        XCTAssertEqual(IrohAuditMetadataScrubber.bucket("0"), "0")
        XCTAssertEqual(IrohAuditMetadataScrubber.bucket("1"), "1")
        XCTAssertEqual(IrohAuditMetadataScrubber.bucket("3"), "2-4")
        XCTAssertEqual(IrohAuditMetadataScrubber.bucket("7"), "5-9")
        XCTAssertEqual(IrohAuditMetadataScrubber.bucket("42"), "10+")
        XCTAssertEqual(IrohAuditMetadataScrubber.bucket("not-a-number"), "na")
    }

    func testNonIdentifierFieldsPassThrough() {
        let scrubbed = IrohAuditMetadataScrubber.scrub([
            "stage": "dial_start",
            "errorClass": "NSURLErrorDomain#-1009",
            "targetNodeId": "secret-node",
            "directAddressCount": "3"
        ])
        XCTAssertEqual(scrubbed["stage"], "dial_start")
        XCTAssertEqual(scrubbed["errorClass"], "NSURLErrorDomain#-1009")
        XCTAssertTrue(scrubbed["targetNodeId"]?.hasPrefix("h:") ?? false)
        XCTAssertEqual(scrubbed["directAddressCount"], "2-4")
    }
}
