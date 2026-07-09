#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

run_xctest_attempt() {
    local binary="$1"
    local selector="$2"
    local output_file
    local status

    output_file="$(mktemp)"

    set +e
    timeout 20 "$binary" "$selector" 2>&1 | tee "$output_file"
    status=$?
    set -e

    if [[ $status -eq 0 ]] && ! grep -Fq "Executed 1 test" "$output_file"; then
        echo "Linux XCTest selector executed zero or multiple tests: $selector" >&2
        status=65
    fi
    rm -f "$output_file"
    return "$status"
}

run_xctest_case() {
    local binary="$1"
    local selector="$2"
    local status

    # Let libdispatch tear down the previous Linux XCTest process before the
    # next Swift concurrency runtime initializes in the same PID namespace.
    sleep 0.05
    set +e
    run_xctest_attempt "$binary" "$selector"
    status=$?
    set -e

    if [[ $status -eq 0 ]]; then
        return 0
    fi
    if [[ $status -ne 124 ]]; then
        return "$status"
    fi

    echo "Linux XCTest runner timed out for $selector; retrying once in a fresh process." >&2
    run_xctest_attempt "$binary" "$selector"
}

run_swift_suite() {
    local package_path="$1"
    local scratch_path="$2"
    local test_module="$3"
    shift 3
    local tests=("$@")
    local first_test="${tests[0]}"
    local binary

    # The first invocation performs the cold build and proves the first case.
    local first_output
    local first_status
    first_output="$(mktemp)"
    set +e
    timeout 900 swift test \
        --disable-automatic-resolution \
        --package-path "$package_path" \
        --filter "$first_test" \
        --scratch-path "$scratch_path" 2>&1 | tee "$first_output"
    first_status=$?
    set -e
    if [[ $first_status -eq 0 ]] && ! grep -Fq "Executed 1 test" "$first_output"; then
        echo "Linux Swift test filter executed zero or multiple tests: $first_test" >&2
        first_status=65
    fi
    rm -f "$first_output"
    if [[ $first_status -ne 0 ]]; then
        return "$first_status"
    fi

    binary="$(find "$scratch_path" -type f -name '*PackageTests.xctest' -perm -111 -print -quit)"
    if [[ -z "$binary" ]]; then
        echo "Unable to locate the XCTest binary under $scratch_path." >&2
        return 1
    fi

    # Swift 6.0 XCTest on Linux can deadlock while advancing between cases in a
    # mounted Docker worktree. Every remaining case runs in a fresh, bounded
    # process; deterministic assertion failures still fail without a retry.
    local test_case
    for test_case in "${tests[@]:1}"; do
        run_xctest_case "$binary" "$test_module.$test_case"
    done
}

core_foundation_tests=(
    AgentProviderLogDiscoveryLinuxTests/testPartialLogFilePatternDocumentsCodexSessionJsonl
    AgentProviderLogDiscoveryLinuxTests/testResolveLogSourceUsesInjectedHomeForHeadlessLinuxFixtures
    AgentProviderLogDiscoveryLinuxTests/testResolveLogSourceUsesLinuxXDGStylePathsForVSCodeProviders
    AgentProviderLogDiscoveryLinuxTests/testRotationScenarioKeepsDirectoryScopedIdentity
    AgentProviderLogDiscoveryLinuxTests/testSessionIdentityKeyUsesProviderAndStandardizedResolvedDirectory
    AgentProviderLogDiscoveryLinuxTests/testSymlinkedHomeExpansionDoesNotSilentlyRewriteSessionKeyWithoutRealpath
    LinuxCoreFoundationTests/testCloudVaultSignalFallbackExportsCoreContractsOnLinux
    LinuxCoreFoundationTests/testIrohPairingSignatureAndDiscoveryPathMappingOnLinux
    LinuxCoreFoundationTests/testMediaAndComputerUseAeadSeamsRoundTripOnLinux
    LinuxCoreFoundationTests/testSignalFallbackWrapCannotBeOpenedWithPublicRecipientMaterial
    LinuxLocalPeerDiscoveryTests/testAvahiBrowseParserConflictTeardownAndDisabledState
    LinuxLocalPeerDiscoveryTests/testAvahiPublishPlanUsesStablePrivacySafeMetadata
    LinuxLocalPeerDiscoveryTests/testPixelClockAdapterBuildsControlPlansAndDoesNotSilentlyDemoteFirmwareFlashing
    LinuxLocalPeerDiscoveryTests/testSmartHubCastAndHomeAssistantAdaptersConsumeResolvedAvahiServices
)

linux_security_tests=(
    OpenBurnBarLinuxSecurityTests/testCloudSyncLocalStagingTransportRetryConflictAndWatermarkEvidence
    OpenBurnBarLinuxSecurityTests/testCloudSyncPrivacyBOLASealedPayloadsAndWatermarkCommitBoundary
    OpenBurnBarLinuxSecurityTests/testFirebaseAuthProtocolFixturesAndBrowserLaunchAreRedacted
    OpenBurnBarLinuxSecurityTests/testHeadlessSecretStoreReadsEnvAndSystemdCredentialMetadata
    OpenBurnBarLinuxSecurityTests/testMembershipProtocolAndDaemonShellCacheUpdate
    OpenBurnBarLinuxSecurityTests/testPKCELoopbackAuthAndTokenCustody
    OpenBurnBarLinuxSecurityTests/testSecretStoreSetupProbeIncludesLibsecretTPMAndUXBlockers
    OpenBurnBarLinuxSecurityTests/testSecretStoreTrustMetadataAndNoPlaintextFallbackForHighValueSecrets
    OpenBurnBarLinuxSecurityTests/testStripeMembershipRestoreFixtureHasNoStoreKitDependency
    OpenBurnBarLinuxSecurityTests/testTelemetryBridgeControlsAndRedactionSurfaceProofs
    OpenBurnBarLinuxSecurityTests/testTelemetryConsentRedactionAndSupportBundleSample
)

daemon_linux_tests=(
    BurnBarDaemonMembershipRPCTests/testCheckoutAndRestoreUseTypedErrorsWithoutNetworkOrFakeURLs
    BurnBarDaemonMembershipRPCTests/testLocalCacheBackedStatusStatesSatisfyLinuxMembershipMapper
    BurnBarDaemonMembershipRPCTests/testMembershipHandlerEncodesStatusCheckoutAndRestoreEnvelopes
    BurnBarDaemonMembershipRPCTests/testMembershipRPCMethodStringsMatchLinuxShellWire
    BurnBarProjectCodeMemoryStoreLinuxInotifyTests/testLinuxInotifyStreamAddsWatchesForCreatedDirectories
    BurnBarProjectCodeMemoryStoreLinuxInotifyTests/testLinuxInotifyStreamDeliversEventsAndCancelClosesFileDescriptor
    BurnBarProjectCodeMemoryStoreLinuxInotifyTests/testLinuxInotifyStreamDeleteSelfRebuildsOnceAndContinuesWatching
    BurnBarProjectCodeMemoryStoreLinuxInotifyTests/testLinuxInotifyStreamQueueOverflowRebuildsAndContinuesWatching
    BurnBarProjectCodeMemoryStoreLinuxInotifyTests/testLinuxInotifyStreamRewatchDoesNotLeakFileDescriptors
    OpenBurnBarHTTPGatewayServerLinuxTests/testProxiesAnthropicMessagesThroughConfiguredProviderAndRecordsUsage
    OpenBurnBarHTTPGatewayServerLinuxTests/testProxiesResponsesThroughConfiguredProviderAndRecordsUsage
    OpenBurnBarHTTPGatewayServerLinuxTests/testRejectsMalformedChatCompletionsRequestBeforeRouting
    OpenBurnBarHTTPGatewayServerLinuxTests/testStreamsAnthropicChatCompletionsThroughMessagesTransformerAndRecordsUsage
    OpenBurnBarHTTPGatewayServerLinuxTests/testStreamsChatCompletionsThroughConfiguredProviderAndRecordsUsage
)

run_swift_suite \
    OpenBurnBarCore \
    OpenBurnBarCore/.build/linux-native \
    OpenBurnBarLinuxCoreFoundationTests \
    "${core_foundation_tests[@]}"

run_swift_suite \
    OpenBurnBarCore \
    OpenBurnBarCore/.build/linux-native \
    OpenBurnBarLinuxSecurityTests \
    "${linux_security_tests[@]}"

run_swift_suite \
    OpenBurnBarDaemon \
    OpenBurnBarDaemon/.build/linux-native \
    OpenBurnBarDaemonLinuxGatewayTests \
    "${daemon_linux_tests[@]}"

cargo test --manifest-path apps/linux-desktop/src-tauri/Cargo.toml --locked
