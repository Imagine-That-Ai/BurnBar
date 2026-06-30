#!/usr/bin/env bash
# Shared release-critical OpenBurnBarMobile XCTest selectors.
#
# The full OpenBurnBarMobileTests suite stays in PR/CI. The release workflow
# needs a bounded iOS/iPad smoke that still covers the surfaces most likely to
# break a shipped TestFlight/App Store build: review metadata, Firebase/App
# Check, auth startup safety, iPad navigation, mobile kernel/backdrop parity,
# Pulse/theme basics, Sentry scrubbing, and provider setup copy/model contracts.

openburnbar_release_mobile_test_filters() {
  cat <<'EOF'
OpenBurnBarMobileTests/AppStoreReviewComplianceTests
OpenBurnBarMobileTests/AuthStoreTests
OpenBurnBarMobileTests/ConversationCockpitAuthTests
OpenBurnBarMobileTests/iPadNavigationUITests
OpenBurnBarMobileTests/MobileBackdropKernelTests
OpenBurnBarMobileTests/MobileProviderWizardCopyTests
OpenBurnBarMobileTests/MobileProviderWizardModelTests
OpenBurnBarMobileTests/MobileSentryScrubberTests
OpenBurnBarMobileTests/MobileThemeTests
OpenBurnBarMobileTests/PulseWindowMetricsTests
EOF
}

openburnbar_release_mobile_test_filters_env() {
  openburnbar_release_mobile_test_filters | paste -sd, -
}
