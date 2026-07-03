#!/usr/bin/env bash

# Release publication runs a bounded app-host smoke, not the full app XCTest
# corpus. The full suite stays in PR/CI; this list covers the shipped-binary
# surfaces that have repeatedly blocked public releases.
OPENBURNBAR_RELEASE_APP_TEST_FILTERS=(
    "OpenBurnBarTests/DirectDownloadReleaseMetadataTests"
    "OpenBurnBarTests/DirectDownloadUpdatePromptPolicyTests"
    "OpenBurnBarTests/DirectDownloadArtifactVerifierTests"
    "OpenBurnBarTests/OpenBurnBarAppCheckProviderFactoryTests"
    "OpenBurnBarTests/MacAppStoreReviewComplianceTests"
    "OpenBurnBarTests/AccountManagerMattersTests"
    "OpenBurnBarTests/OpenBurnBarRuntimeTests"
    "OpenBurnBarTests/PopoverContentPrewarmerTests"
    "OpenBurnBarTests/DashboardChatWorkspaceViewTests"
    "OpenBurnBarTests/PaneWorkspaceModelTests"
    "OpenBurnBarTests/ChatSessionControllerPaneModeTests"
)

openburnbar_release_app_test_filters_env() {
    local IFS=';'
    printf '%s' "${OPENBURNBAR_RELEASE_APP_TEST_FILTERS[*]}"
}
