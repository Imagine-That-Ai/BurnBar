#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

run_xctest_attempt() {
    local binary="$1"
    local selector="$2"
    local output_file
    local status
    local timeout_seconds="${OPENBURNBAR_LINUX_XCTEST_TIMEOUT_SECONDS:-30}"
    local kill_after_seconds="${OPENBURNBAR_LINUX_XCTEST_KILL_AFTER_SECONDS:-5}"

    output_file="$(mktemp)"

    if timeout --signal=TERM --kill-after="$kill_after_seconds" "$timeout_seconds" \
        "$binary" "$selector" 2>&1 | tee "$output_file"; then
        status=0
    else
        status=$?
    fi

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
    sleep 0.25
    if run_xctest_attempt "$binary" "$selector"; then
        return 0
    else
        status=$?
    fi

    if [[ $status -ne 124 ]]; then
        return "$status"
    fi

    local retry
    for retry in 1 2; do
        echo "Linux XCTest runner timed out for $selector; retrying in a fresh process ($retry/2)." >&2
        sleep 1
        if run_xctest_attempt "$binary" "$selector"; then
            return 0
        else
            status=$?
        fi
        if [[ $status -ne 124 ]]; then
            return "$status"
        fi
    done
    return 124
}

assert_xctest_suite_coverage() {
    local binary="$1"
    local test_module="$2"
    shift 2
    local tests=("$@")
    local expected_file
    local discovered_file

    expected_file="$(mktemp)"
    discovered_file="$(mktemp)"
    printf '%s\n' "${tests[@]}" | sed "s|^|$test_module.|" | sort > "$expected_file"
    "$binary" --list-tests | awk -v prefix="$test_module." 'index($0, prefix) == 1' | sort > "$discovered_file"

    if ! diff -u "$expected_file" "$discovered_file"; then
        echo "Linux native test manifest is stale for $test_module; include every discovered test." >&2
        rm -f "$expected_file" "$discovered_file"
        return 65
    fi
    rm -f "$expected_file" "$discovered_file"
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
    if timeout 900 swift test \
        --disable-automatic-resolution \
        --package-path "$package_path" \
        --filter "$first_test" \
        --scratch-path "$scratch_path" 2>&1 | tee "$first_output"; then
        first_status=0
    else
        first_status=$?
    fi
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
    assert_xctest_suite_coverage "$binary" "$test_module" "${tests[@]}"

    # Swift 6.0 XCTest on Linux can deadlock while advancing between cases in a
    # mounted Docker worktree. Every remaining case runs in a fresh, bounded
    # process; deterministic assertion failures still fail without a retry.
    local test_case
    for test_case in "${tests[@]:1}"; do
        run_xctest_case "$binary" "$test_module.$test_case"
    done
}

build_attestd_test_harness() {
    local manifest="$1"
    local cargo_messages
    local harnesses
    local test_binary

    cargo_messages="$(mktemp)"
    harnesses="$(mktemp)"
    if ! RUSTUP_TOOLCHAIN=1.94.0 \
        CARGO_BUILD_JOBS="${OPENBURNBAR_LINUX_CARGO_BUILD_JOBS:-1}" \
        cargo test --manifest-path "${manifest}" --locked --lib --no-run \
            --message-format=json >"${cargo_messages}"; then
        rm -f "${cargo_messages}" "${harnesses}"
        return 1
    fi

    if ! jq -r '
        select(
            .reason == "compiler-artifact"
            and .target.name == "openburnbar_attestd"
            and (.target.kind | type == "array" and index("lib") != null)
            and .profile.test == true
            and (.executable | type == "string")
        )
        | .executable
    ' "${cargo_messages}" | LC_ALL=C sort -u >"${harnesses}"; then
        rm -f "${cargo_messages}" "${harnesses}"
        return 1
    fi
    local harness_count
    harness_count="$(wc -l <"${harnesses}" | tr -d '[:space:]')"
    if [[ "${harness_count}" -ne 1 ]]; then
        printf 'cargo identified %s openburnbar-attestd library test harnesses; expected exactly one\n' \
            "${harness_count}" >&2
        rm -f "${cargo_messages}" "${harnesses}"
        return 1
    fi
    test_binary="$(<"${harnesses}")"
    rm -f "${cargo_messages}"
    rm -f "${harnesses}"

    if [[ ! -x "${test_binary}" ]]; then
        printf '%s\n' "cargo-reported openburnbar-attestd test harness is not executable: ${test_binary}" >&2
        return 1
    fi
    if ! "${test_binary}" --list 2>/dev/null \
        | grep -F 'backend::tests::attest_collects_tpm_quote_and_sealed_bundle' >/dev/null; then
        printf '%s\n' "cargo-reported openburnbar-attestd library harness is missing the root fixture test: ${test_binary}" >&2
        return 1
    fi

    printf '%s\n' "${test_binary}"
}

run_attestd_tests() {
    local manifest="crates/openburnbar-attestd/Cargo.toml"
    if [[ "${EUID}" -eq 0 ]]; then
        RUSTUP_TOOLCHAIN=1.94.0 \
            CARGO_BUILD_JOBS="${OPENBURNBAR_LINUX_CARGO_BUILD_JOBS:-1}" \
            cargo test --manifest-path "${manifest}" --locked
        return
    fi

    if ! sudo -n true >/dev/null 2>&1; then
        printf '%s\n' \
            "openburnbar-attestd tests require root-owned security fixtures; run in the canonical root toolchain container or configure non-interactive sudo." >&2
        return 1
    fi

    local test_binary=""
    if ! test_binary="$(build_attestd_test_harness "${manifest}")"; then
        printf '%s\n' "could not resolve the current openburnbar-attestd library test harness from Cargo output" >&2
        return 1
    fi

    sudo -n "${test_binary}" --test-threads=1
    RUSTUP_TOOLCHAIN=1.94.0 \
        CARGO_BUILD_JOBS="${OPENBURNBAR_LINUX_CARGO_BUILD_JOBS:-1}" \
        cargo test --manifest-path "${manifest}" --locked --doc
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
    OpenBurnBarLinuxSecurityTests/testDeletingSecretSkipsWritableBackendsWithoutTheItem
    OpenBurnBarLinuxSecurityTests/testDesktopOwnerLocalAuthenticationFailsClosedForDeniedAndUnavailablePaths
    OpenBurnBarLinuxSecurityTests/testDesktopOwnerLocalAuthenticationFallsBackToPAMWhenPolkitUnavailable
    OpenBurnBarLinuxSecurityTests/testDesktopOwnerLocalAuthenticationUsesPolkitAllowUserInteraction
    OpenBurnBarLinuxSecurityTests/testFirebaseAuthProtocolFixturesAndBrowserLaunchAreRedacted
    OpenBurnBarLinuxSecurityTests/testHeadlessSecretStoreReadsEnvAndSystemdCredentialMetadata
    OpenBurnBarLinuxSecurityTests/testHeadlessEnvironmentSecretsRequireExplicitTestOrDevOptIn
    OpenBurnBarLinuxSecurityTests/testKWalletCRUDUsesFolderEntryAndStdinContract
    OpenBurnBarLinuxSecurityTests/testLockedNativeKeyringFailsClosedWithoutEnvironmentFallback
    OpenBurnBarLinuxSecurityTests/testMembershipProtocolAndDaemonShellCacheUpdate
    OpenBurnBarLinuxSecurityTests/testNativeBackendRejectsValuesTheLineProtocolCannotRoundTrip
    OpenBurnBarLinuxSecurityTests/testNativeBackendRoundTripsSignificantWhitespaceWithoutPuttingItInArguments
    OpenBurnBarLinuxSecurityTests/testPKCELoopbackAuthAndTokenCustody
    OpenBurnBarLinuxSecurityTests/testSecretStoreCommandFailureDoesNotExposeRetrievedSecretOutput
    OpenBurnBarLinuxSecurityTests/testSecretStoreSetupProbeIncludesLibsecretTPMAndUXBlockers
    OpenBurnBarLinuxSecurityTests/testSecretStoreTrustMetadataAndNoPlaintextFallbackForHighValueSecrets
    OpenBurnBarLinuxSecurityTests/testNativeSecretServiceCRUDKeepsSecretOutOfArguments
    OpenBurnBarLinuxSecurityTests/testSignOutClearsLocalTokenWhenRemoteRevocationFails
    OpenBurnBarLinuxSecurityTests/testStripeMembershipRestoreFixtureHasNoStoreKitDependency
    OpenBurnBarLinuxSecurityTests/testTelemetryBridgeControlsAndRedactionSurfaceProofs
    OpenBurnBarLinuxSecurityTests/testTelemetryConsentRedactionAndSupportBundleSample
)

daemon_linux_tests=(
    BurnBarRunServiceComputerUseRoutingTests/testComputerUseDenialBecomesTerminalOperatorDeniedFailure
    BurnBarRunServiceComputerUseRoutingTests/testComputerUseDispatcherErrorFailsClosedWithoutLegacyPlaywrightFallback
    BurnBarRunServiceComputerUseRoutingTests/testComputerUseDispatcherOwnsBrowserExecutionAndPreservesToolOutput
    BurnBarRunServiceComputerUseRoutingTests/testComputerUsePolicyDenialIsNotAttributedToOperator
    BurnBarRunServiceComputerUseRoutingTests/testDefaultLinuxServerInstallsComputerUseBrowserDispatcher
    BurnBarRunServiceComputerUseRoutingTests/testExecutedComputerUseResponseRequiresMatchingRunAndCallIdentity
    BurnBarRunServiceComputerUseRoutingTests/testExecutedComputerUseResponseRequiresToolResult
    BurnBarRunServiceComputerUseHandshakeTests/testCancellationInvalidatesBeforeRevocationAwaitAndPreventsStaleResume
    BurnBarRunServiceComputerUseHandshakeTests/testBlockedTerminalRevocationDoesNotHoldClaimAcrossRetryGeneration
    BurnBarRunServiceComputerUseHandshakeTests/testComputerUseDenialFailsRunWithoutOpeningSecondApproval
    BurnBarRunServiceComputerUseHandshakeTests/testPostDispatchJournalFailureFailsRunAndRevokesAfterSingleAction
    BurnBarRunServiceComputerUseHandshakeTests/testPreDispatchJournalFailureFailsRunAndRevokesWithoutExecutingAction
    BurnBarRunServiceComputerUseHandshakeTests/testConcurrentExactResumesClaimInvocationOnce
    BurnBarRunServiceComputerUseHandshakeTests/testCreateReturnsStableRunIDAndExactComputerUseRequirement
    BurnBarRunServiceComputerUseHandshakeTests/testRestartRestoresRequirementButRequiresFreshBindingAuthority
    BurnBarRunServiceComputerUseHandshakeTests/testRestartFailsInterruptedBrowserActionWithoutRedispatchAndRequiresRetry
    BurnBarRunServiceComputerUseHandshakeTests/testAlreadyBoundSecondBrowserActionCheckpointsBeforeDispatchAndRestartNeverRedispatches
    BurnBarRunServiceComputerUseHandshakeTests/testEagerRestoreRetriesInterruptedNormalizationAfterJournalAppendFailure
    BurnBarRunServiceComputerUseHandshakeTests/testEagerRestoreRetriesInterruptedNormalizationAfterCheckpointWriteFailure
    BurnBarRunServiceComputerUseHandshakeTests/testLazyRestoreRetriesInterruptedNormalizationAfterJournalAppendFailure
    BurnBarRunServiceComputerUseHandshakeTests/testLazyRestoreRetriesInterruptedNormalizationAfterCheckpointWriteFailure
    BurnBarRunServiceComputerUseHandshakeTests/testResumeRejectsWrongCallAndGenerationWithoutConsumingRequirement
    BurnBarRunServiceComputerUseHandshakeTests/testRetryAllocatesNewGenerationAndRejectsPreRetryResumeToken
    BurnBarDaemonSocketOwnershipLinuxTests/testActiveLegacySocketWithoutLockIsNeverUnlinked
    BurnBarDaemonSocketOwnershipLinuxTests/testSecondDaemonCannotDisruptHealthyOwner
    BurnBarDaemonSocketOwnershipLinuxTests/testShutdownPreservesSocketPathReplacement
    BurnBarDaemonSocketOwnershipLinuxTests/testStaleSocketIsRecoveredOnlyWhileOwnershipLockIsHeld
    BurnBarDaemonSocketOwnershipLinuxTests/testStartupRefusesHardLinkedLockFileWithoutMutatingTarget
    BurnBarDaemonSocketOwnershipLinuxTests/testStartupRefusesAndPreservesNonSocketPath
    BurnBarDaemonMembershipRPCTests/testCheckoutAndRestoreUseTypedErrorsWithoutNetworkOrFakeURLs
    BurnBarDaemonMembershipRPCTests/testLocalCacheBackedStatusStatesSatisfyLinuxMembershipMapper
    BurnBarDaemonMembershipRPCTests/testMembershipHandlerEncodesStatusCheckoutAndRestoreEnvelopes
    BurnBarDaemonMembershipRPCTests/testMembershipRPCMethodStringsMatchLinuxShellWire
    BurnBarLinuxOnboardingServiceLinuxTests/testLinuxRequiredVerificationFailureBlocksWithoutAdvancing
    BurnBarLinuxOnboardingServiceLinuxTests/testLinuxServicePersistsPrivateStateAndResumes
    BurnBarLinuxOnboardingServiceLinuxTests/testLinuxWritableDirectoryProbeRoundTripsAndCleansUp
    BurnBarSubscriptionServiceLinuxTests/testLinuxSubscriptionCursorRecoversAcrossDaemonRestart
    BurnBarSubscriptionServiceLinuxTests/testLinuxSubscriptionStopRejectsLateResume
    BurnBarProjectCodeMemoryStoreLinuxInotifyTests/testLinuxInotifyStreamAddsWatchesForCreatedDirectories
    BurnBarProjectCodeMemoryStoreLinuxInotifyTests/testLinuxInotifyStreamDeliversEventsAndCancelClosesFileDescriptor
    BurnBarProjectCodeMemoryStoreLinuxInotifyTests/testLinuxInotifyStreamDeleteSelfRebuildsOnceAndContinuesWatching
    BurnBarProjectCodeMemoryStoreLinuxInotifyTests/testLinuxInotifyStreamQueueOverflowRebuildsAndContinuesWatching
    BurnBarProjectCodeMemoryStoreLinuxInotifyTests/testLinuxInotifyStreamRewatchDoesNotLeakFileDescriptors
    ComputerUseAuthorizationRegistryTests/testBindingRequiresReservationAndUnknownDevelopmentSessionIsDenied
    ComputerUseAuthorizationRegistryTests/testComputerUseSessionIntentCanonicalHashMatchesRustGolden
    ComputerUseAuthorizationRegistryTests/testConsumedProofLedgerRejectsReplayAcrossReconstruction
    ComputerUseAuthorizationRegistryTests/testDisabledEnforcementStillRequiresExactBindingIdentity
    ComputerUseAuthorizationRegistryTests/testEnforcedLeaseRejectsExpiryRunAndClientMismatch
    ComputerUseAuthorizationRegistryTests/testReservationAndBindingAreUniqueAndCompareAndRemove
    ComputerUseAuthorizationRegistryTests/testVerifiedSessionLeaseSupportsNonRunComputerUseSession
    DaemonComputerUseApprovalAuthorityVerifierTests/testAcceptsExactFreshSignedPendingApprovalAndRejectsReplay
    DaemonComputerUseApprovalAuthorityVerifierTests/testRejectsForgedResponderAndStaleAuthority
    DaemonComputerUseApprovalAuthorityVerifierTests/testPersistedCounterRejectsReplayAfterVerifierRestart
    DaemonComputerUseApprovalAuthorityVerifierTests/testCorruptPersistedCounterStoreFailsClosed
    DaemonComputerUseApprovalAuthorityVerifierTests/testLinuxApprovalRPCRequiresExactSignedAuthorityAndResolvesContinuationOnce
    DaemonComputerUseApprovalAuthorityVerifierTests/testRejectsWrongSessionAndPendingRequestHash
    ComputerUseCoordinatorRevocationLinuxTests/testAuthorizerIsRecheckedBeforeDispatchAndDenialIsAudited
    ComputerUseCoordinatorRevocationLinuxTests/testConcurrentInvocationFailsClosedWhileFirstActionOwnsSession
    ComputerUseCoordinatorRevocationLinuxTests/testPanicDuringApprovalCancelsAndCannotDispatchOrResurrectSession
    ComputerUseLocalAuthGrantEnforcementTests/testExactSessionIntentRetargetingIsDenied
    ComputerUseLocalAuthGrantEnforcementTests/testLinuxFilePinBackingCommitsAliasesTogetherAndRejectsPartialConflict
    ComputerUseLocalAuthGrantEnforcementTests/testExpiredAndOverlongSignedGrantsAreDenied
    ComputerUseLocalAuthGrantEnforcementTests/testTrustEscalationIsDenied
    ComputerUseLocalAuthGrantEnforcementTests/testUnderScopedCapabilityIsDenied
    ComputerUseLocalAuthGrantEnforcementTests/testValidExactSignedGrantIsAccepted
    ComputerUseServiceRunBindingTests/testBrowserSessionRequiresRunBinding
    ComputerUseServiceRunBindingTests/testNonBrowserSessionCannotReserveAgentRunBinding
    ComputerUseServiceRunBindingTests/testConcurrentStartsCannotBindTheSameRunTwice
    ComputerUseServiceRunBindingTests/testExpiredSessionReleasesRunBindingBeforeRestart
    ComputerUseServiceRunBindingTests/testExternalInvokeCannotBypassManagedRunAndInternalDispatchChecksClient
    ComputerUseServiceRunBindingTests/testFilteredPendingPollReportsAuthoritativeSessionLifecycle
    ComputerUseServiceRunBindingTests/testInvokeForUnboundRunFailsBeforeAnyBrowserDispatch
    ComputerUseServiceRunBindingTests/testRunIDChangesManifestAuditRoot
    ComputerUseServiceRunBindingTests/testRunBindingIsManifestBoundUniqueAndRemovedByPanicHalt
    DaemonLinuxLocalAuthProofVerifierTests/testLinuxFilePinBackingRoundTripsIntoLocalAuthProofVerifier
    DaemonLinuxLocalAuthProofVerifierTests/testLinuxVerifierRejectsBindingMismatchWithPersistedPin
    LinuxComputerUseInputAdapterTests/testAtspiClickPlanUsesPythonWhenSessionBusIsAvailable
    LinuxComputerUseServiceSystemInputTests/testConcurrentLinuxSystemSessionDeniesBeforeDispatch
    LinuxComputerUseInputAdapterTests/testDenyRegionInspectorChecksAbsolutePointerMoveTarget
    LinuxComputerUseInputAdapterTests/testDenyRegionInspectorFailsClosedWhenTargetIsUninspectable
    LinuxComputerUseInputAdapterTests/testDenyRegionInspectorMapsPasswordRoleAtPoint
    LinuxComputerUseInputAdapterTests/testDenyRegionInspectorUsesFocusedAccessibleForKeyboardInput
    LinuxComputerUseInputAdapterTests/testKillSwitchFlagBlocksDispatchBeforeCommandRuns
    LinuxComputerUseServiceSystemInputTests/testLinuxKillSwitchProviderDeniesBeforeDispatch
    LinuxComputerUseServiceSystemInputTests/testPasswordFieldDenyRegionRejectsBeforeLinuxDispatchAndAudits
    LinuxComputerUseInputAdapterTests/testRuntimeDirectoryKillSwitchFlagBlocksDispatchByDefault
    LinuxComputerUseServiceSystemInputTests/testSystemSessionApprovesAndDispatchesThroughInjectedLinuxInput
    LinuxComputerUseInputAdapterTests/testUnavailableInputAdapterFailsClosed
    LinuxComputerUseServiceSystemInputTests/testUninspectableLinuxRegionFailsClosedBeforeDispatch
    LinuxComputerUseServiceSystemInputTests/testWildcardPanicHaltActivatesLinuxKillFlag
    LinuxComputerUseInputAdapterTests/testX11FallbackDispatchDoesNotEchoTypedSecretInResult
    LinuxNativeSecretStoreWiringTests/testProviderAndConnectorStoresUseInjectedLinuxCustodianForCRUD
    LinuxSwitcherAndPensieveTests/testPensieveWatcherWritesPrivateManifestAndStopsIdempotently
    LinuxSwitcherAndPensieveTests/testShimInstallerQuotesExecutablePathAndSetsExecutableMode
    LinuxSwitcherAndPensieveTests/testSwitcherExecutesFromInjectedPathAndStripsDaemonSecrets
    MercuryLinuxMediaTests/testAcceptWithoutSealKeyFailsClosedBeforeCaptureStarts
    MercuryLinuxMediaTests/testCapabilityModelRepresentsUnknownWhenMediaBackendUnavailable
    MercuryLinuxMediaTests/testCapabilityProbeReportsMediaBackendTruth
    MercuryLinuxMediaTests/testCaptureFrameHandoffIsBoundedAndOrdered
    MercuryLinuxMediaTests/testCaptureFrameQueueBuffersNewestAndPreservesRetainedOrder
    MercuryLinuxMediaTests/testCapturePipelineEndedTransitionsToCooldown
    MercuryLinuxMediaTests/testCapturedFrameWithoutSealKeyFailsClosedAndDoesNotEgressPlaintext
    MercuryLinuxMediaTests/testCollisionSafeDownloadNaming
    MercuryLinuxMediaTests/testFileOfferAcceptDownloadsToCollisionSafePathAndAcknowledges
    MercuryLinuxMediaTests/testFileOfferDeclineSendsRejectedAckWithoutFetch
    MercuryLinuxMediaTests/testFileTransferErrorTaxonomy
    MercuryLinuxMediaTests/testMediaChannelWritesLengthPrefixedShellFrames
    MercuryLinuxMediaTests/testPortalAdapterRejectsNonLiveGrantBeforeCapture
    MercuryLinuxMediaTests/testPortalAdapterStartsCaptureFromLivePortalGrant
    MercuryLinuxMediaTests/testRPCDecodeAndDispatchForMediaMethods
    MercuryLinuxMediaTests/testSessionForwardsCapturedFramesSealed
    MercuryLinuxMediaTests/testSessionPhaseTransitionsAndAckEmission
    OpenBurnBarHTTPGatewayServerLinuxTests/testMidStreamUpstreamDropClosesWithoutSecondHTTPResponse
    OpenBurnBarHTTPGatewayServerLinuxTests/testProxiesAnthropicMessagesThroughConfiguredProviderAndRecordsUsage
    OpenBurnBarHTTPGatewayServerLinuxTests/testProxiesResponsesThroughConfiguredProviderAndRecordsUsage
    OpenBurnBarHTTPGatewayServerLinuxTests/testRejectsMalformedChatCompletionsRequestBeforeRouting
    OpenBurnBarHTTPGatewayServerLinuxTests/testStreamsAnthropicChatCompletionsThroughMessagesTransformerAndRecordsUsage
    OpenBurnBarHTTPGatewayServerLinuxTests/testStreamsChatCompletionsThroughConfiguredProviderAndRecordsUsage
)

main() {
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

    CARGO_BUILD_JOBS="${OPENBURNBAR_LINUX_CARGO_BUILD_JOBS:-1}" \
        cargo test --manifest-path apps/linux-desktop/src-tauri/Cargo.toml --locked
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
