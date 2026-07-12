import XCTest
@testable import OpenBurnBarCore

final class AgentProviderCapabilityManifestTests: XCTestCase {
    func testManifestCoversEveryAgentProviderExactlyOnce() {
        XCTAssertEqual(AgentProvider.allCases.count, 33)
        XCTAssertEqual(AgentProviderCapabilities.byProvider.count, AgentProvider.allCases.count)
        XCTAssertEqual(Set(AgentProviderCapabilities.byProvider.keys), Set(AgentProvider.allCases))
        XCTAssertEqual(Set(AgentProviderCapabilities.all.map(\.providerID)).count, 33)
        for provider in AgentProvider.allCases {
            let record = provider.capabilityRecord
            XCTAssertEqual(record.providerID, provider.providerID.rawValue)
            XCTAssertEqual(record.displayName, provider.rawValue)
        }
    }

    func testManifestCapabilitySetsMatchProductRegistries() {
        XCTAssertEqual(Set(AgentProviderCapabilities.all.filter(\.quotaSupported).map(\.provider)), Set(AgentProvider.quotaSignalProviders))
        XCTAssertEqual(Set(AgentProviderCapabilities.all.filter(\.accountConnectSupported).map(\.provider)), Set(AgentProvider.mobileAccountConnectableProviders))
        XCTAssertEqual(Set(AgentProviderCapabilities.all.compactMap(\.chatRuntimeID)), Set(AssistantRuntimeID.allCases.map(\.rawValue)))
    }
}
