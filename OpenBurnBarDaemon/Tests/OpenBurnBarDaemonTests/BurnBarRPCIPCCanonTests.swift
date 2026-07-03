import OpenBurnBarCore
import XCTest

final class BurnBarRPCIPCCanonTests: XCTestCase {
    func testGeneratedCanonCoversEveryBurnBarRPCMethod() {
        let generatedIDs = Set(BurnBarRPCIPCCanon.methods.map(\.id))
        let methodIDs = Set(BurnBarRPCMethod.allCases.map(\.rawValue))

        XCTAssertEqual(generatedIDs, methodIDs)
        XCTAssertEqual(BurnBarRPCIPCCanon.methods.count, BurnBarRPCMethod.allCases.count)
    }

    func testSubscriptionCanonRowsAreTypedAndCapabilityScoped() throws {
        let start = try XCTUnwrap(BurnBarRPCIPCCanon.methods.first { $0.id == "subscription.start" })
        XCTAssertEqual(start.params, "BurnBarSubscriptionStartRequest")
        XCTAssertEqual(start.result, "BurnBarSubscriptionResponse")
        XCTAssertEqual(start.capability, "subscription")
        XCTAssertEqual(start.domain, "subscription")

        let resume = try XCTUnwrap(BurnBarRPCIPCCanon.methods.first { $0.id == "subscription.resume" })
        XCTAssertEqual(resume.params, "BurnBarSubscriptionResumeRequest")
        XCTAssertEqual(resume.result, "BurnBarSubscriptionResponse")
        XCTAssertEqual(resume.capability, "subscription")
        XCTAssertEqual(resume.domain, "subscription")
    }
}
