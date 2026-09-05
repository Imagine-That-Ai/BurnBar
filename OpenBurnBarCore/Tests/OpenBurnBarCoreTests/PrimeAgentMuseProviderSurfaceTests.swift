import XCTest
@testable import OpenBurnBarCore
@testable import OpenBurnBarKernel

/// Pins Prime Agent / Muse catalog identity and the CLI launch/auth surfaces that
/// the package diff-coverage gate measures for this provider landing.
final class PrimeAgentMuseProviderSurfaceTests: XCTestCase {
    override func tearDown() {
        CLILaunchAdapter.executableResolver = nil
        CLILaunchAdapter.environmentProvider = { ProcessInfo.processInfo.environment }
        CLILaunchAdapter.homeDirectoryProvider = { FileManager.default.homeDirectoryForCurrentUser.path }
        super.tearDown()
    }

    func test_agentProvider_catalogAliasesAndPresentation() {
        XCTAssertEqual(AgentProvider.fromCatalogProviderID("prime"), .primeAgent)
        XCTAssertEqual(AgentProvider.fromCatalogProviderID("prime-agent"), .primeAgent)
        XCTAssertEqual(AgentProvider.fromCatalogProviderID("muse"), .muse)
        XCTAssertEqual(AgentProvider.fromCatalogProviderID("meta-muse"), .muse)

        XCTAssertEqual(AgentProvider.primeAgent.providerID.rawValue, "prime-agent")
        XCTAssertEqual(AgentProvider.primeAgent.bundledLogoName, "PrimeAgentLogo")
        XCTAssertEqual(AgentProvider.primeAgent.iconName, "arrow.triangle.2.circlepath")
        XCTAssertEqual(AgentProvider.muse.bundledLogoName, "MetaLogo")
        XCTAssertEqual(AgentProvider.muse.iconName, "brain.head.profile")

        XCTAssertTrue(AgentProvider.swarmGlyphProviders.contains(.primeAgent))
        XCTAssertTrue(AgentProvider.swarmGlyphProviders.contains(.muse))
    }

    func test_switcherCLIProfileType_primeAgentSurface() {
        XCTAssertEqual(SwitcherCLIProfileType.primeAgent.displayName, "Prime Agent")
        XCTAssertEqual(SwitcherCLIProfileType.primeAgent.bundledLogoName, "PrimeAgentLogo")
        XCTAssertEqual(SwitcherCLIProfileType.primeAgent.rawValue, "prime-agent")
        XCTAssertEqual(SwitcherCLIProfileType.primeAgent.canonicalAgentProvider, .primeAgent)
        XCTAssertTrue(
            SwitcherCLIProfileType.primeAgent.trustedExecutablePaths.contains("$HOME/.prime/bin/prime-agent")
        )
    }

    func test_buildCLILaunch_exportsPrimeHomeKeys() throws {
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("obb-prime-launch-\(UUID().uuidString)", isDirectory: true)
        let executableURL = tempRoot.appendingPathComponent("prime-agent")
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: executableURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        CLILaunchAdapter.executableResolver = { cliType in
            cliType == .primeAgent ? executableURL : nil
        }
        CLILaunchAdapter.environmentProvider = { [:] }

        let profile = SwitcherProfileRecord(
            id: "prime-profile",
            targetKind: .cli,
            cliType: .primeAgent,
            cliMetadata: SwitcherCLIProfileMetadata(
                displayLabel: "Prime",
                configDirectory: "\(tempRoot.path)/.prime"
            ),
            sortKey: 1
        )

        let launch = try CLILaunchAdapter.buildCLILaunch(profile: profile).get()
        XCTAssertEqual(launch.env["PRIME_HOME"], "\(tempRoot.path)/.prime")
        XCTAssertEqual(launch.env["PRIME_AGENT_HOME"], "\(tempRoot.path)/.prime")
    }

    func test_quotaClassifier_matchesPrimeAgentPhrases() {
        let detail = "Prime Agent quota exhausted for this workspace"
        XCTAssertEqual(
            CLIQuotaExhaustionClassifier.classify(for: .primeAgent, in: detail),
            detail
        )
        let limitReached = "prime-agent quota limit reached"
        XCTAssertEqual(
            CLIQuotaExhaustionClassifier.classify(for: .primeAgent, in: limitReached),
            limitReached
        )
    }

    func test_switcherCLIProfileType_museSurface() {
        XCTAssertEqual(SwitcherCLIProfileType.muse.displayName, "Muse Code")
        XCTAssertEqual(SwitcherCLIProfileType.muse.bundledLogoName, "MetaLogo")
        XCTAssertEqual(SwitcherCLIProfileType.muse.rawValue, "muse")
        XCTAssertEqual(SwitcherCLIProfileType.muse.executableName, "muse")
        XCTAssertEqual(SwitcherCLIProfileType.muse.canonicalAgentProvider, .muse)
        XCTAssertTrue(
            SwitcherCLIProfileType.muse.trustedExecutablePaths.contains("$HOME/.local/bin/muse")
        )
    }

    func test_museResumeTargetIsHandoffOnly() {
        XCTAssertEqual(CLIAgentResumeTarget.muse.wireID, "muse")
        XCTAssertEqual(CLIAgentResumeTarget.muse.displayName, "Muse Code")
        XCTAssertFalse(CLIAgentResumeTarget.muse.supportsNativeResume)
        XCTAssertEqual(CLIAgentResumeTarget.muse.capability, .handoff)
        XCTAssertEqual(CLIAgentResumeTarget.muse.agentProvider, .muse)
        XCTAssertEqual(CLIAgentResumeTarget.muse.cliRuntime, .muse)
        XCTAssertEqual(CLIAgentRuntime.muse.canonicalProviderID, "muse")
        XCTAssertFalse(cliAgentProviderSupportsNativeResume(canonicalWireID: "muse"))
    }

    func test_museRuntimeIdentityMappings() {
        XCTAssertEqual(CLIAgentRuntime.muse.displayName, "Muse Code")
        XCTAssertEqual(CLIAgentRuntime(assistant: .muse), .muse)
        XCTAssertEqual(CLIAgentRuntime.muse.assistantRuntime, .muse)
        XCTAssertEqual(AssistantRuntimeID.muse.displayName, "Muse Code")
        XCTAssertTrue(AssistantRuntimeID.muse.hasMobileChatSurface)
        XCTAssertEqual(AgentIdentity.builtInProvider(for: .muse), .muse)
        XCTAssertEqual(AssistantRuntimeID.fromHarnessProvider(.muse), .muse)
        let catalogOption = CLIRuntimeModelCatalog.defaultProfileOption(for: .muse)
        XCTAssertEqual(catalogOption?.providerID, "meta")
    }

    func test_quotaClassifier_matchesMusePhrases() {
        let detail = "muse quota exhausted for this workspace"
        XCTAssertEqual(
            CLIQuotaExhaustionClassifier.classify(for: .muse, in: detail),
            detail
        )
        let limitReached = "muse-spark quota limit reached"
        XCTAssertEqual(
            CLIQuotaExhaustionClassifier.classify(for: .muse, in: limitReached),
            limitReached
        )
    }

    func test_museTrustedSearchIncludesLocalBin() {
        let home = "/tmp/openburnbar-muse-home"
        let explicitPaths = SwitcherCLIProfileType.muse.trustedExecutablePaths.map {
            CLILaunchAdapter.expandPath($0, homeDirectory: home)
        }
        XCTAssertTrue(explicitPaths.contains("\(home)/.local/bin/muse"))
        XCTAssertTrue(explicitPaths.contains("\(home)/.muse/bin/muse"))
        XCTAssertTrue(CLILaunchAdapter.ambientFallbackExecutableSearchDirectories(
            for: .muse,
            homeDirectory: home
        ).contains("\(home)/.local/bin"))
    }

    func test_primeAgentTrustedSearchIncludesPrimeManagedBin() {
        let home = "/tmp/openburnbar-prime-home"
        let explicitPaths = SwitcherCLIProfileType.primeAgent.trustedExecutablePaths.map {
            CLILaunchAdapter.expandPath($0, homeDirectory: home)
        }
        XCTAssertTrue(explicitPaths.contains("\(home)/.prime/bin/prime-agent"))
        XCTAssertTrue(explicitPaths.contains("\(home)/.local/bin/prime-agent"))
        XCTAssertTrue(CLILaunchAdapter.ambientFallbackExecutableSearchDirectories(
            for: .primeAgent,
            homeDirectory: home
        ).contains("\(home)/.local/bin"))
    }
}
