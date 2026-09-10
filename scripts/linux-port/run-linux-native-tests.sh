#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

# SwiftPM repositories are not safe to reuse after an interrupted Docker
# build: a partially written mirror can make the next clone fail with an
# "existing refs" error. Keep each native-test invocation isolated from the
# checkout by default, while allowing a caller to retain a stable scratch path
# for debugging or CI caches.
linux_native_swift_scratch_root() {
    local configured_root="${OPENBURNBAR_LINUX_SWIFT_SCRATCH_ROOT:-}"
    if [[ -n "$configured_root" ]]; then
        mkdir -p "$configured_root"
        printf '%s\n' "$configured_root"
        return 0
    fi

    local temporary_root="${TMPDIR:-/tmp}/openburnbar-linux-native-tests-$$"
    mkdir -p "$temporary_root"
    printf '%s\n' "$temporary_root"
}

assert_linux_native_host() {
    local platform="${1:-}"
    if [[ "$platform" == "Linux" ]]; then
        return 0
    fi

    cat >&2 <<'EOF'
Linux native behavior tests require a Linux userspace. Run this script inside
the pinned tools/linux-toolchain container, on a Linux host, or in the Linux
VM. The Linux-only XCTest classes are not compiled on macOS, so continuing
here would produce a misleading zero-test filter failure.
EOF
    return 78
}

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

core_foundation_tests=(
    AgentProviderLogDiscoveryLinuxTests/testPartialLogFilePatternDocumentsCodexSessionJsonl
    AgentProviderLogDiscoveryLinuxTests/testResolveLogSourceUsesInjectedHomeForHeadlessLinuxFixtures
    AgentProviderLogDiscoveryLinuxTests/testResolveLogSourceUsesLinuxXDGStylePathsForVSCodeProviders
    AgentProviderLogDiscoveryLinuxTests/testRotationScenarioKeepsDirectoryScopedIdentity
    AgentProviderLogDiscoveryLinuxTests/testSessionIdentityKeyUsesProviderAndStandardizedResolvedDirectory
    AgentProviderLogDiscoveryLinuxTests/testSymlinkedHomeExpansionDoesNotSilentlyRewriteSessionKeyWithoutRealpath
    LinuxCoreFoundationTests/testCloudVaultSignalFallbackExportsCoreContractsAndFailsClosedForSignalAtRestOnLinux
    LinuxCoreFoundationTests/testIrohPairingSignatureAndDiscoveryPathMappingOnLinux
    LinuxCoreFoundationTests/testMediaAndComputerUseAeadSeamsRoundTripOnLinux
    LinuxCoreFoundationTests/testSignalFallbackWrapFailsClosedWithoutLibSignal
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
    OpenBurnBarLinuxSecurityTests/testHeadlessCredentialBoundaryRejectsTraversalAndMultilineValues
    OpenBurnBarLinuxSecurityTests/testHeadlessSecretStoreReadsEnvAndSystemdCredentialMetadata
    OpenBurnBarLinuxSecurityTests/testHeadlessEnvironmentSecretsRequireExplicitTestOrDevOptIn
    OpenBurnBarLinuxSecurityTests/testKWalletCRUDUsesFolderEntryAndStdinContract
    LinuxAuthTokenStoreValueTests/testMissingRefreshTokenFailsClosed
    LinuxAuthTokenStoreValueTests/testRefreshTokenValueIsAvailableOnlyThroughExplicitSecretAccessor
    OpenBurnBarLinuxSecurityTests/testLockedNativeKeyringFallsBackToExplicitApprovedEnvironmentSecret
    OpenBurnBarLinuxSecurityTests/testMembershipProtocolAndDaemonShellCacheUpdate
    OpenBurnBarLinuxSecurityTests/testNativeBackendRejectsValuesTheLineProtocolCannotRoundTrip
    OpenBurnBarLinuxSecurityTests/testNativeBackendRoundTripsSignificantWhitespaceWithoutPuttingItInArguments
    OpenBurnBarLinuxSecurityTests/testPKCELoopbackAuthAndTokenCustody
    OpenBurnBarLinuxSecurityTests/testSecretServiceHealthCheckAcceptsMissingProbeItemOnFreshKeyring
    OpenBurnBarLinuxSecurityTests/testSecretServiceHealthCheckStillFailsForLockedOrUnavailableBackend
    OpenBurnBarLinuxSecurityTests/testSecretStoreCommandFailureDoesNotExposeRetrievedSecretOutput
    OpenBurnBarLinuxSecurityTests/testSecretStoreSetupProbeIncludesLibsecretTPMAndUXBlockers
    OpenBurnBarLinuxSecurityTests/testSecretStoreSetupProbeReportsAvailableKWalletOnlyWithSessionBus
    OpenBurnBarLinuxSecurityTests/testSecretStoreTrustMetadataAndNoPlaintextFallbackForHighValueSecrets
    OpenBurnBarLinuxSecurityTests/testNativeSecretServiceCRUDKeepsSecretOutOfArguments
    OpenBurnBarLinuxSecurityTests/testSignOutClearsLocalTokenWhenRemoteRevocationFails
    OpenBurnBarLinuxSecurityTests/testStripeMembershipRestoreFixtureHasNoStoreKitDependency
    OpenBurnBarLinuxSecurityTests/testRequireHighValueSecretFallsBackWhenDesktopKeyringIsUnavailable
    OpenBurnBarLinuxSecurityTests/testRequireHighValueSecretReportsLastBackendFailureWhenAllStoresAreUnavailable
    OpenBurnBarLinuxSecurityTests/testRequireHighValueSecretDoesNotSkipPlaintextFallbackRefusal
    OpenBurnBarLinuxSecurityTests/testSystemdCredentialReaderRequiresOwnerOnlyRegularFilesAndRejectsSymlinks
    OpenBurnBarLinuxSecurityTests/testTelemetryBridgeControlsAndRedactionSurfaceProofs
    OpenBurnBarLinuxSecurityTests/testTelemetryConsentRedactionAndSupportBundleSample
    OpenBurnBarLinuxSecurityTests/testTelemetryRedactorCoversJSONBearerAndLinuxPathForms
)

daemon_linux_tests=(
    LinuxCloudDataControlBridgeTests/testDeletionConfirmationIsCheckedBeforeTrustedDevicePrompt
    LinuxCloudDataControlBridgeTests/testMalformedTrustedDeviceAuthorizationNeverReachesCloud
    LinuxCloudDataControlBridgeTests/testMissingTrustedDeviceBridgeFailsClosedWithRedactedUnavailableStatus
    LinuxCloudDataControlTests/testDeleteDecodesAuthoritativeSummaryAfterConfirmation
    LinuxCloudDataControlTests/testDeleteRequiresExactConfirmationToken
    LinuxCloudDataControlTests/testAccountErasureRPCSummaryDoesNotExposeAuthorizationMaterial
    LinuxCloudDataControlTests/testExportForwardsProofHeadersAndReturnsOnlyCallablePayload
    LinuxCloudDataControlTests/testExportRejectsOversizedDomainSelectionBeforeTransport
    LinuxCloudDataControlTests/testExportRejectsExpiredJWTBeforeTransport
    LinuxCloudDataControlTests/testExportRejectsMalformedCallableResponse
    LinuxCloudDataControlTests/testExportRejectsSignedOutTokenBeforeTransport
    LinuxCloudReplicaEngineTests/testFailedPushRetainsStableIdempotencyKeyAcrossRetryAndRestart
    LinuxCloudReplicaEngineTests/testPushReconcilesStaleLocalMutationToAuthoritativeRemoteWinner
    LinuxCloudReplicaEngineTests/testTransportFailurePersistsCappedBackoffAndSuccessClearsIt
    BurnBarChatThreadServiceTests/testAppendRetryIsIdempotentAndConflictingReuseFails
    BurnBarChatThreadServiceTests/testAppendedTimestampsUseGRDBTextFormatForMixedMacOSThreads
    BurnBarChatThreadServiceTests/testAttachmentColumnIsAddedToOlderChatSchema
    BurnBarChatThreadServiceTests/testAttachmentMetadataPersistsAcrossReadAndIdempotentRetry
    BurnBarChatThreadServiceTests/testChatMethodsHaveDedicatedCapabilityAndSocketDomain
    BurnBarChatThreadServiceTests/testChatRPCUsesTypedContractsAndUnavailableCode
    BurnBarChatThreadServiceTests/testChatServiceCreatesDatabaseOnFreshProfile
    BurnBarChatThreadServiceTests/testCursorPaginationUsesMessageIDAsTieBreaker
    BurnBarChatThreadServiceTests/testExactThreadsPersistInCanonicalOrderAndSearchRealContent
    BurnBarChatThreadServiceTests/testLegacyNumericTimestampsAreNormalizedToGRDBText
    BurnBarChatThreadServiceTests/testValidationRejectsUnboundedOrMalformedInputs
    BurnBarLinuxPeerManifestTests/testPathAndBasenameDriftAreRejectedEvenWhenSigned
    BurnBarLinuxPeerManifestTests/testReleasePolicyIgnoresRawEnvironmentPins
    BurnBarLinuxPeerManifestTests/testSignedManifestAdmitsExactImmutableAppImageExecutable
    BurnBarLinuxPeerManifestTests/testSymlinkedAndOversizedManifestFilesAreRejected
    BurnBarLinuxPeerManifestTests/testTamperedManifestAndExecutableAreRejected
    BurnBarLinuxPeerManifestTests/testUnknownKeyAndInvalidSignatureAreRejected
    BurnBarLinuxPeerManifestTests/testValidSignatureOverNonCanonicalManifestBytesIsRejected
    BurnBarLinuxPeerManifestTests/testWritableAppImageRootIsRejected
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
    BurnBarDaemonPeerAuthenticatorLinuxTests/testLinuxPeerCredentialReadsKernelExecutableLink
    BurnBarDaemonProjectCodeMemoryBootstrapTests/testCodeAndMemoryRPCsBootstrapAfterFreshChatDatabaseCreation
    BurnBarDaemonProjectCodeMemoryBootstrapTests/testCodeAndMemoryRPCsRemainUnavailableWithoutConfiguredDatabase
    BurnBarDaemonProjectCodeMemoryBootstrapTests/testFailedBootstrapIsCachedAndRemainsFailClosed
    BurnBarLinuxTextExpansionAdapterTests/testReportsReachableIBusWithoutClaimingExternalExpansion
    BurnBarLinuxTextExpansionAdapterTests/testDetectsFcitxWithoutEnvironmentOverridesOnX11
    BurnBarLinuxTextExpansionAdapterTests/testFailsClosedWhenSessionTypeOrControlProbeIsUnproven
    BurnBarLinuxTextExpansionAdapterTests/testOptInWithoutManifestFailsClosed
    BurnBarLinuxTextExpansionAdapterTests/testValidSignedManifestRegistersOnWaylandWithoutInputCapture
    BurnBarLinuxTextExpansionAdapterTests/testValidManifestRegistersOnX11OnlyWhenItDeclaresX11Support
    BurnBarLinuxTextExpansionAdapterTests/testManifestRejectsUnsafeCapabilitiesAndMalformedSignature
    BurnBarLinuxTextExpansionAdapterTests/testManifestRejectsUntrustedPathAndUnsafeOwnerPermissions
    BurnBarLinuxTextExpansionAdapterTests/testManifestRejectsEngineForWrongSessionOrBackend
    BurnBarLinuxTextExpansionAdapterTests/testControlProbeErrorsNeverBecomeDiagnostics
    BurnBarLinuxTextExpansionAdapterTests/testSecureFieldPolicyDeniesUnknownSecureAndExcludedContexts
    BurnBarLinuxTextExpansionAdapterTests/testExternalEngineCancellationAndKillSwitchFailClosed
    BurnBarLinuxTextExpansionAdapterTests/testExternalEngineExpansionCancellationTerminatesSession
    BurnBarLinuxTextExpansionAdapterTests/testExternalEngineExpansionRoundTripSendsOnlyCanonicalTrigger
    BurnBarLinuxTextExpansionAdapterTests/testExternalEngineExpansionTimeoutTerminatesSession
    BurnBarLinuxTextExpansionAdapterTests/testExternalEngineHandshakeTimeoutTerminatesWithoutDiagnostics
    BurnBarLinuxTextExpansionAdapterTests/testExternalEngineRejectsMismatchedExpansionResponseAndStops
    BurnBarLinuxTextExpansionAdapterTests/testExternalEngineRuntimeHandshakeStatusAndStop
    BurnBarTextExpansionServiceTests/testEncryptedPersistenceConsentRestartAndPermissions
    BurnBarTextExpansionServiceTests/testCorruptStoreAndInvalidConsentFailClosed
    BurnBarTextExpansionServiceTests/testEngineRuntimeStatusIsDaemonOwnedAndStartRequiresPersistedConsent
    BurnBarTextExpansionServiceTests/testEngineRuntimeTimeoutIsBoundedBeforeLaunch
    BurnBarTextExpansionServiceTests/testExternalExpansionRequiresPersistedConsentBeforeEngineSession
    BurnBarTextExpansionServiceTests/testMissingNativeSecretBackendDoesNotUsePlaintextFallback
    BurnBarTextExpansionServiceTests/testRPCExpansionRequestKeepsSecureFieldContextTextFreeAndRequiresConsent
    BurnBarDatabaseRecoveryBundleCryptoTests/testDeviceTransferResponseSeparatesStoredKeyFromDatabaseProof
    BurnBarDatabaseRecoveryBundleCryptoTests/testMacCompatibleBundleRoundTripsDatabaseKey
    BurnBarDatabaseRecoveryBundleCryptoTests/testMalformedVersionIterationsAndKeysAreRejected
    BurnBarDatabaseRecoveryBundleCryptoTests/testRecoveryStatusNeverUsesKeyCustodyAsIntegrityProof
    BurnBarDatabaseRecoveryBundleCryptoTests/testRecoveryStatusAllowsStagingBundleWhenCipherUnavailableAndDatabaseMissing
    BurnBarDatabaseRecoveryBundleCryptoTests/testWrongPassphraseAndTamperingFailClosed
    BurnBarLinuxPrivacyServiceTests/testInventoryAndPreviewExposeMetadataOnlyAndExecuteIsIdempotent
    BurnBarLinuxPrivacyServiceTests/testConfirmationAndScopeAreBoundToPreview
    BurnBarLinuxPrivacyServiceTests/testSymlinkIsBlockedAndOutsideFileSurvives
    BurnBarLinuxPrivacyServiceTests/testChangedStoreInvalidatesPreviewAndExpiryIsFailClosed
    BurnBarLinuxPrivacyServiceTests/testEncryptedExportIsBoundedOwnerOnlyAndContainsNoPlaintextOnDisk
    BurnBarLinuxPrivacyServiceTests/testExportRejectsUnsafeDestinationAndWeakPassphrase
    BurnBarLinuxPrivacyServiceTests/testRetentionStatusAndApplyTrimOnlyOutOfPolicyData
    BurnBarLinuxPrivacyServiceTests/testRetentionRejectsInvalidConfirmationAndCorruptStoreWithoutMutation
    BurnBarLinuxOnboardingServiceLinuxTests/testLinuxRequiredVerificationFailureBlocksWithoutAdvancing
    BurnBarLinuxOnboardingServiceLinuxTests/testLinuxOptionalProbePersistsRepairAndRecoversAfterRestart
    BurnBarLinuxOnboardingServiceLinuxTests/testLinuxSecretStoreProbeChecksHealthBeforeMutatingLockedBackend
    BurnBarLinuxOnboardingServiceLinuxTests/testLinuxSecretStoreProbeFailsClosedWhenCleanupCannotBeConfirmed
    BurnBarLinuxOnboardingServiceLinuxTests/testLinuxSecretStoreProbeRequiresReadbackAndCleansProbeOnMismatch
    BurnBarLinuxOnboardingServiceLinuxTests/testLinuxServicePersistsPrivateStateAndResumes
    BurnBarLinuxOnboardingServiceLinuxTests/testLinuxUnavailableOptionalProbeCanOnlyCompleteByExplicitSkip
    BurnBarLinuxOnboardingServiceLinuxTests/testLinuxWritableDirectoryProbeRoundTripsAndCleansUp
    LinuxTrustedDeviceManagementTests/testAuthRPCReturnsRedactedUnavailableErrorWithoutBridge
    LinuxTrustedDeviceManagementTests/testUnavailableManagerNeverTurnsMissingBridgeIntoLocalState
    BurnBarSubscriptionServiceLinuxTests/testLinuxRunSubscriptionIncludesItsValidatedRunIdentifier
    BurnBarSubscriptionServiceLinuxTests/testLinuxSubscriptionCursorRecoversAcrossDaemonRestart
    BurnBarSubscriptionServiceLinuxTests/testLinuxSubscriptionStopRejectsLateResume
    BurnBarProjectCodeMemoryStoreLinuxInotifyTests/testLinuxInotifyStreamAddsWatchesForCreatedDirectories
    BurnBarProjectCodeMemoryStoreLinuxInotifyTests/testLinuxInotifyStreamDeliversEventsAndCancelClosesFileDescriptor
    BurnBarProjectCodeMemoryStoreLinuxInotifyTests/testLinuxInotifyStreamDeleteSelfRebuildsOnceAndContinuesWatching
    BurnBarProjectCodeMemoryStoreLinuxInotifyTests/testLinuxInotifyStreamQueueOverflowRebuildsAndContinuesWatching
    BurnBarProjectCodeMemoryStoreLinuxInotifyTests/testLinuxInotifyStreamRewatchDoesNotLeakFileDescriptors
    BurnBarLinuxDeviceAdaptersTests/testAvahiBrowseReadsConcurrentOutputAndCapsTranscript
    BurnBarLinuxDeviceAdaptersTests/testAvahiBrowseReportsLaunchFailureWithoutLeakingExecutablePath
    BurnBarLinuxDeviceAdaptersTests/testAvahiBrowseTerminatesAStalledProcessWithinBoundedTimeout
    BurnBarLinuxDeviceAdaptersTests/testDiscoveredEndpointURLBracketsIPv6Literal
    BurnBarLinuxDeviceAdaptersTests/testParityLedgerEvaluatesSmartHubStatusOnce
    BurnBarLinuxDeviceAdaptersTests/testParityLedgerKeepsSmartHubBlockerWhenControlProbeFails
    BurnBarLinuxLocalPeerDiscoveryTests/testBrowsePeersParsesSuccessfulAvahiOutput
    BurnBarLinuxLocalPeerDiscoveryTests/testBrowsePeersReportsNonZeroAvahiExit
    BurnBarLinuxLocalPeerDiscoveryTests/testBrowsePeersTerminatesAStalledAvahiProcessWithinTimeout
    BurnBarMissionControlProjectLifecycleLinuxTests/testDeletedSourceReassignmentResolvesStableIDAfterRestart
    BurnBarMissionControlProjectLifecycleLinuxTests/testDeletionTombstonesStableIDAndAliasAcrossRestart
    BurnBarMissionControlProjectLifecycleLinuxTests/testRestartReplaysDeletionWhenProjectionCheckpointLagsJournal
    BurnBarMissionHealthLinuxTests/testMissionHealth_missingMissionFailsClosed
    BurnBarMissionHealthLinuxTests/testMissionHealth_readsAuthoritativeProjectionAndSortsHistory
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
    ComputerUseServiceRunBindingTests/testApprovalCancellationStopsSuspendedPhonePublication
    ComputerUseServiceRunBindingTests/testPendingApprovalIncludesTypedSystemCapabilitySnapshot
    ComputerUseServiceRunBindingTests/testBrowserSessionRequiresRunBinding
    ComputerUseServiceRunBindingTests/testNonBrowserSessionCannotReserveAgentRunBinding
    ComputerUseServiceRunBindingTests/testConcurrentStartsCannotBindTheSameRunTwice
    ComputerUseServiceRunBindingTests/testExpiredSessionReleasesRunBindingBeforeRestart
    ComputerUseServiceRunBindingTests/testExternalInvokeCannotBypassManagedRunAndInternalDispatchChecksClient
    ComputerUseServiceRunBindingTests/testFilteredPendingPollReportsAuthoritativeSessionLifecycle
    ComputerUseServiceRunBindingTests/testGlobalPanicNotifiesSessionEndObserverForManifestedSession
    ComputerUseServiceRunBindingTests/testInvokeForUnboundRunFailsBeforeAnyBrowserDispatch
    ComputerUseServiceRunBindingTests/testRunIDChangesManifestAuditRoot
    ComputerUseServiceRunBindingTests/testRunBindingIsManifestBoundUniqueAndRemovedByPanicHalt
    ComputerUseSessionGrantBrokerTests/testExpiryWipesReadyGrantAndPreventsConsume
    ComputerUseSessionGrantBrokerTests/testConcurrentStartReservationIsTokenBoundAndNonReusable
    ComputerUseSessionGrantBrokerTests/testDefiniteStartFailureRestoresReadyForOneFreshRetry
    ComputerUseSessionGrantBrokerTests/testForgedProofFailsClosedAndLegitimateRetryCanSucceed
    ComputerUseSessionGrantBrokerTests/testPublishesExactChallengeAndConsumesVerifiedGrantOnce
    ComputerUseSessionGrantBrokerTests/testRecordBoundFailsClosedAndExpiryCleanupReleasesCapacity
    ComputerUseSessionGrantBrokerTests/testRejectsFieldMismatchWithoutCallingProofValidator
    ComputerUseSessionGrantBrokerTests/testRejectsWrongPeerWithoutBurningChallenge
    ComputerUseSessionGrantBrokerTests/testRendererProofFieldsAndChangedConsumeRequestAreRejected
    ComputerUseSessionGrantBrokerTests/testReplayIsRejectedBeforeAndAfterConsume
    ComputerUseSessionGrantBrokerTests/testStartingExpiryBecomesConsumedBeforeTerminalCleanup
    ComputerUseSessionGrantBrokerTests/testSuspendedPrevalidationCannotResurrectExpiredChallenge
    ComputerUseSessionGrantBrokerTests/testUnavailableTransportAndProofValidatorFailClosed
    ComputerUseSessionGrantRPCCompositionTests/testAcquireIngestStatusDenialAndKnownStartFailureRemainRetryableUntilSuccess
    ComputerUseSessionGrantRPCCompositionTests/testReadinessReportsBrokerPairingAndOperationalStates
    DaemonComputerUseApprovalReplayCounterStoreTests/testSeparateInstancesSerializeOneFileHighWaterMark
    DaemonComputerUsePanicAuthorityVerifierTests/testAcceptsFreshSignedPanicAndRejectsReplay
    DaemonComputerUsePanicAuthorityVerifierTests/testCorruptReplayStoreFailsClosedAndReportsUnhealthy
    DaemonComputerUsePanicAuthorityVerifierTests/testRejectsNonPanicWrongAuthorityAndStaleTimestamp
    DaemonLinuxLocalAuthProofVerifierTests/testLinuxFilePinBackingRoundTripsIntoLocalAuthProofVerifier
    DaemonLinuxLocalAuthProofVerifierTests/testLinuxVerifierRejectsBindingMismatchWithPersistedPin
    LinuxCLICapabilityTests/testCliSupportAdmitsEveryLinuxSocketCommandPath
    LinuxCLICapabilityTests/testCliSupportDoesNotExpandIntoUnrelatedAgency
    LinuxComputerUseInputAdapterTests/testAtspiClickPlanUsesPythonWhenSessionBusIsAvailable
    LinuxComputerUseServiceSystemInputTests/testConcurrentLinuxSystemSessionDeniesBeforeDispatch
    LinuxComputerUseInputAdapterTests/testDenyRegionInspectorChecksAbsolutePointerMoveTarget
    LinuxComputerUseInputAdapterTests/testDenyRegionInspectorFailsClosedWhenTargetIsUninspectable
    LinuxComputerUseInputAdapterTests/testDenyRegionInspectorMapsPasswordRoleAtPoint
    LinuxComputerUseInputAdapterTests/testDenyRegionInspectorUsesFocusedAccessibleForKeyboardInput
    LinuxComputerUseInputAdapterTests/testKillSwitchFlagBlocksDispatchBeforeCommandRuns
    LinuxComputerUseInputAdapterTests/testRemoteDesktopSessionCancellationIsTypedBeforeAnySecretCanReachPortal
    LinuxComputerUseInputAdapterTests/testRemoteDesktopSessionConsentDenialIsTypedAndRedactsBrokerOutput
    LinuxComputerUseInputAdapterTests/testRemoteDesktopSessionDispatchKillSwitchStopsBeforeNextEvent
    LinuxComputerUseInputAdapterTests/testRemoteDesktopSessionDispatchTimeoutAndCancellationStayTyped
    LinuxComputerUseInputAdapterTests/testRemoteDesktopSessionDispatchesPortalNotifyEventsOnlyAfterConsent
    LinuxComputerUseInputAdapterTests/testRemoteDesktopSessionExecutorReportsUnsupportedProvisionedBackends
    LinuxComputerUseInputAdapterTests/testRemoteDesktopSessionKillSwitchBlocksCreateButAllowsSafeClose
    LinuxComputerUseInputAdapterTests/testRemoteDesktopSessionStopValidatesIdentityAndReportsStoppedStatus
    LinuxComputerUseInputAdapterTests/testRemoteDesktopSessionTimeoutDoesNotClaimConsent
    LinuxComputerUseInputAdapterTests/testRemoteDesktopSessionWaitsForConsentAndReturnsValidatedIdentity
    LinuxComputerUseOwnerAuthorizationCoordinatorTests/testAuthorizesExactStableAppPeerWithFreshPolkitProof
    LinuxComputerUseOwnerAuthorizationCoordinatorTests/testPromptReasonIsPrintableCollapsedAndBounded
    LinuxComputerUseOwnerAuthorizationCoordinatorTests/testRejectsNonPolkitOrMismatchedProof
    LinuxComputerUseOwnerAuthorizationCoordinatorTests/testRejectsPeerIdentityChangeAcrossPrompt
    LinuxComputerUseOwnerAuthorizationCoordinatorTests/testRejectsUnsupportedExecutableBeforePrompt
    LinuxComputerUseOwnerAuthorizationCoordinatorTests/testSingleFlightRejectsConcurrentPromptForSamePeer
    LinuxComputerUseServiceSystemInputTests/testLinuxKillSwitchProviderDeniesBeforeDispatch
    LinuxComputerUseServiceSystemInputTests/testPasswordFieldDenyRegionRejectsBeforeLinuxDispatchAndAudits
    LinuxComputerUseInputAdapterTests/testRuntimeDirectoryKillSwitchFlagBlocksDispatchByDefault
    LinuxComputerUseInputAdapterTests/testWaylandPortalPlanFailsClosedBeforeActionTextReachesAnyRunner
    LinuxComputerUseInputAdapterTests/testWaylandPortalProbeAsyncCancellationIsHonoredBeforeProbe
    LinuxComputerUseInputAdapterTests/testWaylandPortalProbeDenialIsTypedAndDoesNotFallbackToShellInput
    LinuxComputerUseInputAdapterTests/testWaylandPortalProbeIsBlockedByKillSwitchBeforePortalBrokerRuns
    LinuxComputerUseInputAdapterTests/testWaylandPortalProbeSelectsConsentOnlyStateWithoutEnablingInput
    LinuxComputerUseInputAdapterTests/testWaylandPortalProbeTimeoutAndCancellationAreFailClosed
    LinuxComputerUseServiceSystemInputTests/testSystemSessionApprovesAndDispatchesThroughInjectedLinuxInput
    LinuxComputerUseInputAdapterTests/testUnavailableInputAdapterFailsClosed
    LinuxComputerUseServiceSystemInputTests/testUninspectableLinuxRegionFailsClosedBeforeDispatch
    LinuxComputerUseServiceSystemInputTests/testWildcardPanicHaltActivatesLinuxKillFlag
    LinuxComputerUseInputAdapterTests/testX11FallbackDispatchDoesNotEchoTypedSecretInResult
    LinuxComputerUseInputAdapterTests/testX11SelectionRemainsAuthoritativeWhenWaylandPortalIsAlsoVisible
    LinuxComputerUseInputSessionManagerTests/testWaylandPortalGrantIsReusedForActionsAndClosedWithSession
    LinuxComputerUseInputSessionManagerTests/testX11FallbackRemainsStatelessWhenPortalIsNotReady
    LinuxComputerUseSystemCapabilityProbeTests/testRequiresPortalAndCaptureBeforeAdvertisingAvailability
    LinuxComputerUseSystemCapabilityProbeTests/testAdvertisesReadyWhenCaptureAndInputPrerequisitesAreLive
    LinuxComputerUseSystemCapabilityProbeTests/testKillSwitchFailsClosed
    LinuxLocalNotificationBridgeTests/testCommandFailureAndLaunchFailureAreSurfaced
    LinuxLocalNotificationBridgeTests/testProcessRunnerTerminatesStalledNotifySendWithinBoundedTimeout
    LinuxLocalNotificationBridgeTests/testDeliveryUsesFixedNotifySendArgumentsWithoutActions
    LinuxLocalNotificationBridgeTests/testMissingNotifySendIsReportedAsUnavailableAndDoesNotRunCommand
    LinuxLocalNotificationBridgeTests/testValidationBoundsAndControlCharactersBeforeLaunching
    LinuxNativeSecretStoreWiringTests/testProviderAndConnectorStoresUseInjectedLinuxCustodianForCRUD
    MissionControlNotificationSecretStoreLinuxTests/testTelegramTokenRoundTripsThroughInjectedCustodian
    MissionControlNotificationSecretStoreLinuxTests/testMissingTelegramTokenIsReportedAsUnconfigured
    MissionControlNotificationSecretStoreLinuxTests/testClearingTelegramTokenDeletesCustodianSecret
    MissionControlNotificationSecretStoreLinuxTests/testLockedBackendErrorIsPropagatedAndPlaintextTrustIsRefused
    BurnBarDaemonLinuxAuthSocketTests/testAuthMethodsRoundTripAndResponsesNeverExposeCredentials
    BurnBarDaemonLinuxAuthSocketTests/testReadOnlyCapabilityAllowsStatusAndDeniesAuthMutationsBeforeDispatch
    LinuxDaemonCloudCredentialAuthorityTests/testCredentialMintIsSingleFlightBoundAndForceRefreshesIDToken
    LinuxDaemonCloudCredentialAuthorityTests/testVerifiedIdentityLabelMigratesLegacyTokenAndSurvivesDaemonRestart
    LinuxDaemonCloudCredentialAuthorityTests/testIdentityLabelRejectsTokenClaimsForAnotherFirebaseUID
    LinuxDaemonCloudCredentialAuthorityTests/testSignOutInvalidatesRefreshInFlightAndStopsBeforeMint
    LinuxDaemonCloudCredentialAuthorityTests/testStaleRefreshFailureCannotOverwriteSignedOutStatus
    LinuxDaemonCloudCredentialAuthorityTests/testSignOutLifecycleReentryCannotRemintOrResurrectSession
    LinuxDaemonCloudCredentialAuthorityTests/testStatusPollingDoesNotReadRefreshTokenBytes
    LinuxDaemonCloudCredentialAuthorityTests/testBoundedHTTPTransportCancellationAbortsLiveURLSession
    LinuxDaemonCloudCredentialAuthorityTests/testAccountSwitchTearsDownWithOldSnapshotBeforeMintingNewAccount
    LinuxDaemonCloudCredentialAuthorityTests/testPostTeardownStoreFailureUnblocksNextSignInAttempt
    LinuxDaemonCloudCredentialAuthorityTests/testFirstSignInNetworkFailureAllowsImmediateRetry
    LinuxDaemonCloudCredentialAuthorityTests/testSameUserReauthRetainsVerifiedIdentityLabel
    LinuxDaemonCloudCredentialAuthorityTests/testCancelDuringAccountSwitchTeardownIsRejectedUntilTransitionCompletes
    LinuxDaemonCloudCredentialAuthorityTests/testSignOutDuringAccountSwitchTeardownCannotResurrectNewAccount
    LinuxDaemonCloudCredentialAuthorityTests/testSuccessfulSignOutAllowsAFreshBrowserSignIn
    LinuxDaemonCloudCredentialAuthorityTests/testFailedAccountSwitchRetainsReadyOldAccount
    LinuxDaemonCloudCredentialAuthorityTests/testMalformedRefreshFailsClosedWithoutPersistingResponseTokens
    LinuxDaemonCloudCredentialAuthorityTests/testExplicitPendingApprovalReasonSchedulesApprovalState
    LinuxDaemonCloudCredentialAuthorityTests/testPermanentLinuxDeviceRejectionsDoNotEnterApprovalPolling
    LinuxDaemonCloudCredentialAuthorityTests/testApprovalRetryBackoffStaysBelowPublicEndpointQuotaAndSurvivesRateLimit
    LinuxDaemonCloudCredentialAuthorityTests/testApprovalRetryRecoversAfterRateLimitWithoutWaitingForWallClock
    LinuxDaemonCloudCredentialAuthorityTests/testInvalidRefreshAndMalformedResponsesNeverEnterApprovalPolling
    LinuxDaemonCloudCredentialAuthorityTests/testRejectedInstallationCanRotateIdentityAndReturnToPendingApproval
    LinuxDaemonCloudCredentialAuthorityTests/testRotationPersistenceFailureKeepsRejectedStateRetryable
    LinuxDaemonCloudCredentialAuthorityTests/testCommittedRotationReturnsNewDescriptorAndRetriesTransientEnrollmentFailure
    LinuxDaemonCloudCredentialAuthorityTests/testExpiredAppCheckChallengeFailsBeforeMintOrBind
    LinuxDaemonCloudCredentialAuthorityTests/testAppCheckTTLAboveThirtyMinutesFailsBeforeBind
    LinuxDaemonCloudCredentialAuthorityTests/testSecureStoreFailureIsRedactedAndFailsClosed
    LinuxDaemonCloudCredentialAuthorityTests/testDaemonLoggerRedactsFirebaseAndAuthorizationCredentials
    LinuxDaemonCloudCredentialAuthorityTests/testShippingServerExposesRedactedAuthorityStatus
    LinuxDaemonCloudCredentialAuthorityTests/testProductionConfigurationAcceptsOnlyPrivateExplicitRegularFile
    LinuxDaemonCloudCredentialAuthorityTests/testProductionConfigurationRejectsPartialEnvironmentAndPlaceholders
    LinuxIrohControllerDirectoryClientTests/testResolveBindsAuthenticatedAccountAndCanonicalRoute
    LinuxIrohControllerDirectoryClientTests/testResolveRejectsRouteFromDifferentAuthenticatedAccount
    LinuxIrohControllerDirectoryClientTests/testResolveRejectsStaleServerTimeline
    LinuxIrohControllerDirectoryClientTests/testResolveReturnsAuthoritativeEmptyRoute
    LinuxIrohControllerDirectoryClientTests/testScopedRevokeUsesOldCredentialSnapshotWithoutReacquiringProvider
    LinuxIrohControllerRuntimeTests/testAccountGenerationChangeBeforeBindFailsClosed
    LinuxIrohControllerRuntimeTests/testAmbiguousHostRecordPublicationIsCompensatedBeforeStateClears
    LinuxIrohControllerRuntimeTests/testCredentialInvalidationIsSingleFlightAndOwnerStopCannotRaceCleanup
    LinuxIrohControllerRuntimeTests/testExactRouteControlsReadinessPublicationAndShutdownRevocation
    LinuxIrohControllerRuntimeTests/testInboundFrameAfterAuthorityRevocationStopsRuntimeBeforeDispatch
    LinuxIrohControllerRuntimeTests/testOlderRefreshCannotResurrectRouteAfterNewerAuthoritativeEmpty
    LinuxIrohControllerRuntimeTests/testRouteExpiryClosesEstablishedStreamAndRevokesBoundSession
    LinuxIrohControllerRuntimeTests/testStopCompensatesRecordAppliedByCancelledStartup
    LinuxIrohControllerRuntimeTests/testStopInvalidatesAndAwaitsInProgressStartEpoch
    LinuxOAuthLoopbackListenerTests/testAccessDeniedCancelsListenerWithoutReportingSuccess
    LinuxOAuthLoopbackListenerTests/testExplicitCancellationAndTimeoutFailClosed
    LinuxOAuthLoopbackListenerTests/testWrongStateProbeCannotConsumeFollowingValidCallback
    LinuxSwitcherAndPensieveTests/testPensieveWatcherWritesPrivateManifestAndStopsIdempotently
    LinuxSwitcherAndPensieveTests/testShimInstallerQuotesExecutablePathAndSetsExecutableMode
    LinuxSwitcherAndPensieveTests/testSwitcherExecutesFromInjectedPathAndStripsDaemonSecrets
    LinuxSwitcherAndPensieveTests/testSwitcherBoundsLargePTYOutputBeforeReportingTerminalFailure
    LinuxSwitcherAndPensieveTests/testSwitcherCancellationTerminatesPTYProcessGroup
    MercuryLinuxMediaTests/testAcceptWithoutSealKeyFailsClosedBeforeCaptureStarts
    MercuryLinuxMediaTests/testCapabilityModelRepresentsUnknownWhenMediaBackendUnavailable
    MercuryLinuxMediaTests/testCapabilityProbeReportsMediaBackendTruth
    MercuryLinuxMediaTests/testCaptureFrameHandoffIsBoundedAndOrdered
    MercuryLinuxMediaTests/testCaptureFrameQueueBuffersNewestAndPreservesRetainedOrder
    MercuryLinuxMediaTests/testCapturePipelineEndedTransitionsToCooldown
    MercuryLinuxMediaTests/testCapturedFrameWithoutSealKeyFailsClosedAndDoesNotEgressPlaintext
    MercuryLinuxMediaTests/testCollisionSafeDownloadNaming
    MercuryLinuxMediaTests/testCollisionSafeDownloadURLAtomicallyReservesDistinctPaths
    MercuryLinuxMediaTests/testFileOfferAcceptDownloadsToCollisionSafePathAndAcknowledges
    MercuryLinuxMediaTests/testFileOfferDeclineSendsRejectedAckWithoutFetch
    MercuryLinuxMediaTests/testFileTransferErrorTaxonomy
    MercuryLinuxMediaTests/testMediaChannelWritesLengthPrefixedShellFrames
    MercuryLinuxMediaTests/testAudioCaptureRequestCarriesPortalGrantWithoutReinterpretingIt
    MercuryLinuxMediaTests/testAudioCaptureRejectsNonLivePortalGrantBeforeNativeStart
    MercuryLinuxMediaTests/testAudioCaptureRejectsInvalidPipeWireFDBeforeNativeStart
    MercuryLinuxMediaTests/testAudioPortalAdapterRejectsNonLiveGrantBeforeNativeStart
    MercuryLinuxMediaTests/testAudioPortalAdapterStartsNativeAudioCaptureFromLiveGrant
    MercuryLinuxMediaTests/testPortalAdapterRejectsNonLiveGrantBeforeCapture
    MercuryLinuxMediaTests/testPortalAdapterStartsCaptureFromLivePortalGrant
    MercuryLinuxMediaTests/testRPCDecodeAndDispatchForMediaMethods
    MercuryLinuxMediaTests/testRouteEndPreservesNoControlRouteWhileOutboundPublishIsCancelled
    MercuryLinuxMediaTests/testRouteEndTerminatesCapturePendingDecisionsAndExactRouteTransfers
    MercuryLinuxAudioPlaybackTests/testPlaybackFailureFailsClosedAndTearsDownRoute
    MercuryLinuxMediaTests/testInboundPlaintextFrameIsDroppedAfterSealNegotiation
    MercuryLinuxMediaTests/testInboundSealedFrameOpensAfterSealNegotiation
    MercuryLinuxMediaTests/testSessionForwardsCapturedFramesSealed
    MercuryLinuxMediaTests/testSessionPhaseTransitionsAndAckEmission
    OpenBurnBarHTTPGatewayServerLinuxMemoryEgressTests/testDisabledPolicyIsDeniedWithCloudConsentRequired
    OpenBurnBarHTTPGatewayServerLinuxMemoryEgressTests/testForbiddenStatusLineUsesTheForbiddenReasonPhrase
    OpenBurnBarHTTPGatewayServerLinuxMemoryEgressTests/testMemoryPurposeRequestsAreNeverStreamed
    OpenBurnBarHTTPGatewayServerLinuxMemoryEgressTests/testMemoryPurposeWithScopedTokenIsAllowedAndLogged
    OpenBurnBarHTTPGatewayServerLinuxMemoryEgressTests/testMissingEnforcerRefusesMemoryPurposeInsteadOfProxying
    OpenBurnBarHTTPGatewayServerLinuxMemoryEgressTests/testRetentionRequirementBlocksProvidersWithoutANoRetentionPromise
    OpenBurnBarHTTPGatewayServerLinuxMemoryEgressTests/testScopedTokensAreRejectedOutsideMemoryPurposesAndPaths
    OpenBurnBarHTTPGatewayServerLinuxMemoryEgressTests/testSpentDailyCapIsDeniedWithBudgetExceeded
    OpenBurnBarHTTPGatewayServerLinuxMemoryEgressTests/testStaleMembershipIsDeniedWithProRequired
    OpenBurnBarHTTPGatewayServerLinuxMemoryEgressTests/testStaticTokenMayCarryAMemoryPurpose
    OpenBurnBarHTTPGatewayServerLinuxMemoryEgressTests/testUnconsentedProviderIsDenied
    OpenBurnBarHTTPGatewayServerLinuxMemoryEgressTests/testUpstreamFailuresAreRecordedInTheEgressChain
    OpenBurnBarHTTPGatewayServerLinuxTests/testBindsIPv6LoopbackWhenAvailable
    OpenBurnBarHTTPGatewayServerLinuxTests/testFailoverRecordsModelHealthAndSkipsCoolingRoute
    OpenBurnBarHTTPGatewayServerLinuxTests/testGatewayCORSAllowsLoopbackOriginsOnlyAndHandlesPreflight
    OpenBurnBarHTTPGatewayServerLinuxTests/testMalformedAndOversizedHTTPFramesFailWithTypedResponses
    OpenBurnBarHTTPGatewayServerLinuxTests/testMidStreamUpstreamDropClosesWithoutSecondHTTPResponse
    OpenBurnBarHTTPGatewayServerLinuxTests/testModelsCatalogIncludesBaseVariantAliasAndCustomRows
    OpenBurnBarHTTPGatewayServerLinuxTests/testProxiesAnthropicMessagesThroughConfiguredProviderAndRecordsUsage
    OpenBurnBarHTTPGatewayServerLinuxTests/testProxiesResponsesThroughConfiguredProviderAndRecordsUsage
    OpenBurnBarHTTPGatewayServerLinuxTests/testRejectsMalformedChatCompletionsRequestBeforeRouting
    OpenBurnBarHTTPGatewayServerLinuxTests/testStreamsAnthropicChatCompletionsThroughMessagesTransformerAndRecordsUsage
    OpenBurnBarHTTPGatewayServerLinuxTests/testStreamsChatCompletionsThroughConfiguredProviderAndRecordsUsage
    SessionGrantAuthorityVerifierTests/testAcceptsExactFreshGrantWithoutConsumingLocalAuthProofAndRejectsReplay
    SessionGrantAuthorityVerifierTests/testPersistedCounterRejectsReplayAfterRestartAndCorruptStoreFailsClosed
    SessionGrantAuthorityVerifierTests/testPersistenceFailurePoisonsVerifierFailClosed
    SessionGrantAuthorityVerifierTests/testRejectsTimestampExpiryKeySignatureAndLocalProofFailures
    SessionGrantAuthorityVerifierTests/testRejectsWrongAuthorityIntentAndMissingLocalAuthentication
    BurnBarDaemonLinuxAuthSocketTests/testCloudSyncRPCsUseDaemonOwnedRuntimeAndRedactReplicaMaterial
    BurnBarDaemonMembershipRPCTests/testCheckoutRejectsNonStripeOrInsecureExternalURLs
    BurnBarDaemonMembershipRPCTests/testCheckoutUsesProductionCallableEnvelopeAndApprovedRedirects
    BurnBarDaemonMembershipRPCTests/testPortalRejectsUnownedReturnURLBeforeCallingStripe
    BurnBarDaemonMembershipRPCTests/testPortalRejectsUntrustedCallableURL
    BurnBarDaemonMembershipRPCTests/testPortalUsesProductionCallableEnvelopeDaemonAuthAppCheckAndValidatedStripeURL
    BurnBarLinuxPrivacyServiceTests/testCloudAccountExportWriteIsBoundedOwnerOnlyAndReturnsReceiptOnly
    BurnBarLinuxPrivacyServiceTests/testCloudAccountExportWriteRejectsExistingDestination
    BurnBarLinuxTextExpansionAdapterTests/testPackagedPythonEngineMatchesSwiftProtocolEndToEnd
    BurnBarTextExpansionServiceTests/testInvalidKeyNamespaceFailsClosedWithoutCreatingAKey
    BurnBarTextExpansionServiceTests/testIsolatedKeyNamespaceDoesNotReadOrReplaceDefaultKey
    BurnBarTextExpansionServiceTests/testRevokingSystemIMEConsentStopsRunningEngineBeforeReturning
    BurnBarTextExpansionServiceTests/testSystemIMEConsentCannotRemainEnabledWhenInAppConsentIsRevoked
    FirebaseLinuxCloudReplicaGatewayTests/testEndpointRequiresExactHTTPSAllowlistedHostAndRootPath
    FirebaseLinuxCloudReplicaGatewayTests/testPushUsesExactCallableContractAndDaemonOwnedCredentials
    LinuxCloudReplicaEngineTests/testChangingDomainConsentInvalidatesPriorPullCursor
    LinuxCloudReplicaEngineTests/testEngineRejectsUnknownDirectAndPersistedPolicyDomains
    LinuxCloudReplicaEngineTests/testEqualRevisionConcurrentEditsConvergeByTimestampThenDeviceID
    LinuxCloudReplicaEngineTests/testGlobalCloudConsentStopsStatusAndRunBeforeIdentityOrVaultAccess
    LinuxCloudReplicaEngineTests/testIncompleteOrRegressivePushResultRetainsDurableOutbox
    LinuxCloudReplicaEngineTests/testInvalidRemoteEnvelopeDoesNotAdvanceCursorOrMutateReplica
    LinuxCloudReplicaEngineTests/testProductionFactoryFailsClosedWhenCanonicalDatabasePathIsNotConfigured
    LinuxCloudReplicaEngineTests/testRuntimeFactoryOwnsDatabaseAndPreservesDaemonOnlyProviders
    LinuxCloudReplicaEngineTests/testRuntimeOwnsIdentityKeyAndExposesOnlyRedactedLifecycle
    LinuxCloudReplicaEngineTests/testStagesCiphertextOnlyAndRequiresSeparateRemoteAccessConsent
    LinuxCloudReplicaEngineTests/testStatusAndPolicyRemainAvailableWhileVaultKeyIsLocked
    LinuxCloudReplicaEngineTests/testStatusCountsOnlyMutationsEligibleUnderCurrentConsent
    LinuxIrohControllerDirectoryClientTests/testExplicitlyAllowlistedHTTPSHostCanServeAConfiguredDeployment
    LinuxIrohControllerDirectoryClientTests/testRejectsUnallowlistedHTTPSHostBeforeTransport
    LinuxIrohRemoteReadCredentialEscrowTests/testCredentialEscrowEncryptsWithMetadataAADAndNeverReturnsPlaintext
    LinuxIrohRemoteReadCredentialEscrowTests/testCredentialEscrowRejectsTargetFingerprintOrApprovalMismatch
    LinuxIrohRemoteReadCredentialEscrowTests/testRemoteReadRejectsAuthorizationForAnotherRequest
    LinuxIrohRemoteReadCredentialEscrowTests/testRemoteReadRequiresLiveRouteBeforeTrustedDeviceApproval
    LinuxIrohRemoteReadCredentialEscrowTests/testRemoteReadRequiresNonceBoundAuthorizationAndReturnsBoundedPayload
    LinuxTrustedDeviceHTTPAdapterTests/testApproveInjectsNonceAndActionProofAndMapsResult
    LinuxTrustedDeviceHTTPAdapterTests/testListUsesNativeManagerCredentialsAndReturnsRedactedDevices
    LinuxTrustedDeviceHTTPAdapterTests/testMalformedMutationProofFailsBeforeTransport
    LinuxTrustedDeviceManagementTests/testAuthRPCUsesInjectedBridgeForListAndMutations
    LinuxTrustedDeviceManagementTests/testBridgeAdapterValidatesRedactedListAndMutationBinding
    MercuryLinuxAudioPlaybackTests/testCapabilityAdvertisesInboundOpusPlaybackSeparately
    MercuryLinuxAudioPlaybackTests/testInboundSealedOpusFrameIsPlayedBeforeShellForwarding
    MercuryLinuxAudioPlaybackTests/testRecordingPlaybackAdapterOwnsLifecycleAndPackets
    MercuryLinuxAudioPlaybackTests/testRouteEndStopsAnActiveNativePlaybackPipeline
    MercuryLinuxMediaTests/testCallAcceptFailsClosedWithoutCallMediaSealBeforeAudioStarts
    MercuryLinuxMediaTests/testCallAcceptStartsPortalAudioAndForwardsSealedOpusOnAudioClass
    MercuryLinuxMediaTests/testCallRouteLossStopsAudioCaptureAndEntersCooldown
)

main() {
    assert_linux_native_host "$(uname -s)"

    local scratch_root
    scratch_root="$(linux_native_swift_scratch_root)"
    echo "Linux Swift scratch root: $scratch_root" >&2

    run_swift_suite \
        OpenBurnBarCore \
        "$scratch_root/core" \
        OpenBurnBarLinuxCoreFoundationTests \
        "${core_foundation_tests[@]}"

    run_swift_suite \
        OpenBurnBarCore \
        "$scratch_root/core" \
        OpenBurnBarLinuxSecurityTests \
        "${linux_security_tests[@]}"

    run_swift_suite \
        OpenBurnBarDaemon \
        "$scratch_root/daemon" \
        OpenBurnBarDaemonLinuxGatewayTests \
        "${daemon_linux_tests[@]}"

    CARGO_BUILD_JOBS="${OPENBURNBAR_LINUX_CARGO_BUILD_JOBS:-1}" \
        cargo test --manifest-path apps/linux-desktop/src-tauri/Cargo.toml --locked
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
