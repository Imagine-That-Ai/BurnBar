#!/usr/bin/env bash
# Diff coverage gate for Android Kotlin changes.
#
# Uses JaCoCo XML reports from Gradle test tasks. Production changes never
# fall back to test-file presence because presence is not coverage evidence.
#
# Usage:
#   diff-coverage-android.sh <base-ref>

set -euo pipefail

default_root="$(cd "$(dirname "$0")/.." && pwd)"
repo_root="${OPENBURNBAR_COVERAGE_REPO_ROOT:-$default_root}"
cd "$repo_root"

base_ref="${1:-origin/main}"
threshold="${COVERAGE_THRESHOLD:-80}"

ANDROID_DIFF_COVERAGE_ALLOWLIST_JSON="$(cat <<'JSON'
{
  "android/app/src/main/java/com/openburnbar/BurnBarApplication.kt": "Android Application lifecycle composition: Firebase, WorkManager, media wiring, and process startup require framework/instrumented coverage; extracted registries and route/controller logic remain JVM-covered. Firebase App Check provider selection is additionally fail-closed through BuildConfig.DEBUG and verified by release compilation, artifact inspection, and Firebase contract tests.",
  "android/app/src/main/java/com/openburnbar/BurnBarApplicationMediaControlSections.kt": "Application-level media-control wiring crosses Android services and retained process state; unit-testable transport/coordinator logic remains covered separately.",
  "android/app/src/main/java/com/openburnbar/BurnBarApplicationMercuryTrustSections.kt": "Application-level Mercury trust wiring: the Firestore escrow-trust snapshot listener and coroutine retry scheduling depend on Firebase SDK runtime and application-scope lifecycle requiring emulator/instrumented coverage; the retry backoff policy and trust-state mapping are pure and JVM-covered by MercuryRegistrationRetryPolicyTest.",
  "android/app/src/main/java/com/openburnbar/BurnBarApplicationStartupSections.kt": "Application startup orchestration depends on Android process lifecycle, Firebase initialization, and notification/service registration; owned helpers remain covered by focused JVM tests.",
  "android/app/src/main/java/com/openburnbar/MainActivityE2EComputerUseActions.kt": "Debug E2E activity hooks are Android intent/UI glue exercised by instrumented flows, not local JVM line attribution.",
  "android/app/src/main/java/com/openburnbar/MainActivityE2EComputerUseStreamSetup.kt": "Debug E2E stream setup is Android activity/intent integration glue; protocol and transport behavior remain covered by JVM/unit tests.",
  "android/app/src/main/java/com/openburnbar/MainActivity.kt": "Living Themes adds Android deep-link activity routing at the host lifecycle boundary; URI parsing and fallback selection are isolated in LivingThemeIntent and covered by JVM tests, while Activity launch dispatch requires instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/data/budget/BudgetNotificationCenter.kt": "Android notification/PendingIntent presentation boundary: redacted notification content is JVM-covered by BudgetNotificationCenterTest, while explicit-intent construction and NotificationManager delivery require framework/instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/data/assistants/CLIAgentMissionDispatcher.kt": "Firebase Functions mission-dispatch integration: callable transport, auth context, and cloud error mapping require Firebase emulator/instrumented coverage; the seal/canonical payload logic remains covered by mobile and cloud tests.",
  "android/app/src/main/java/com/openburnbar/data/cloud/AndroidCloudVaultRevocationRotation.kt": "CloudVault revocation/rotation orchestration crosses Firestore transactions, trusted-device state, and Android crypto providers; pure crypto helpers remain JVM-covered, while live rotation requires emulator/instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/data/computeruse/AgentWatchControlFrameReceiver.kt": "Agent-watch control-frame receiver is lifecycle and stream integration glue around Android runtime callbacks; frame signing/canonicalization logic remains covered in JVM tests.",
  "android/app/src/main/java/com/openburnbar/data/computeruse/ComputerUseSecurityCallableClient.kt": "Firebase Functions security callable client: transport and App Check/authenticated callable behavior require Firebase emulator/instrumented coverage; request models remain covered by contract tests.",
  "android/app/src/main/java/com/openburnbar/data/computeruse/ComputerUseMissionPlaneCallables.kt": "Mission/attachment plane split out of ComputerUseSecurityCallableClient: the same Firebase Functions callable transport boundary (App Check high-risk envelope + live callables) requiring emulator/instrumented coverage; payload sealing and dispatch logic remain covered by the dispatcher and payload-factory JVM tests.",
  "android/app/src/main/java/com/openburnbar/data/computeruse/ComputerUseSessionGrantNotificationCenter.kt": "Android notification/PendingIntent presentation boundary: challenge validation and receiver behavior are JVM-covered, while notification manager delivery requires framework/instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/data/computeruse/ForegroundFragmentActivityTracker.kt": "FragmentActivity foreground tracking depends on Android lifecycle callbacks; call sites and foreground gating are covered through receiver/registrar tests and instrumented UI flows.",
  "android/app/src/main/java/com/openburnbar/data/computeruse/RemoteUnlockSavedCredentialStore.kt": "Android Keystore/EncryptedSharedPreferences credential persistence cannot execute faithfully under local JVM JaCoCo; it is an Android-framework storage boundary requiring instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/data/hermes/relay/HermesCompositeRelayTransport.kt": "Composite relay selection is integration glue over Firestore/iroh transports; the concrete iroh transport and retained-pool behavior remain covered by JVM tests.",
  "android/app/src/main/java/com/openburnbar/data/inbox/AIInboxStore.kt": "Firestore listener store for the AI Inbox: snapshot lifecycle, coroutine cancellation, and Firestore write paths (archive, snooze, feedback) depend on Firebase SDK runtime and need emulator/instrumented coverage; inbox document parsing, grouping, and refresh policy remain JVM-covered by AIInboxRefreshPartsTest.",
  "android/app/src/main/java/com/openburnbar/data/media/VideoReceivePipeline.kt": "MediaCodec/Surface decode pipeline: codec configuration, async decoder callbacks, and Surface rendering require device codecs and cannot execute under local JVM JaCoCo; the pure helpers — receive stats, decoder configuration payloads, and the surface lifecycle gate — remain JVM-covered by VideoReceivePipelineStatsTest, VideoDecoderConfigurationPayloadTest, and SurfaceLifecycleGateTest.",
  "android/app/src/main/java/com/openburnbar/data/models/generated/IrohPairingModels.kt": "Generated schema mirror from shared pairing contracts; source-of-truth drift is guarded by schema sync and consumer contract tests rather than local line coverage.",
  "android/app/src/main/java/com/openburnbar/data/stores/AccountStore.kt": "FirebaseAuth-backed singleton access boundary; behavior depends on Firebase SDK runtime and is covered by higher-level account lifecycle tests.",
  "android/app/src/main/java/com/openburnbar/data/stores/AuthStore.kt": "FirebaseAuth-backed singleton access boundary; behavior depends on Firebase SDK runtime and is covered by higher-level auth lifecycle tests.",
  "android/app/src/main/java/com/openburnbar/data/stores/DevicesStore.kt": "Firestore listener store with snapshot lifecycle, coroutine cancellation, and Firebase SDK types; it needs emulator/instrumented coverage rather than local JVM line attribution.",
  "android/app/src/main/java/com/openburnbar/data/stores/UserStore.kt": "Firestore/Firebase user-store singleton access boundary; behavior depends on Firebase SDK runtime and is covered by higher-level account lifecycle tests.",
  "android/app/src/main/java/com/openburnbar/menubar/MenuBarService.kt": "Foreground Service notification boundary: explicit-component tap PendingIntents and NotificationManager delivery are Android framework entry points that local JVM JaCoCo cannot execute; instrumented flows exercise the live notification.",
  "android/app/src/main/java/com/openburnbar/menubar/MenuBarTileService.kt": "Quick Settings TileService is an Android framework entry point; tile lifecycle and the explicit launch PendingIntent require instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/services/media/AIInboxNotificationRouting.kt": "Android notification presentation boundary: buildAIInboxNotification/postAIInboxNotification construct NotificationCompat, PendingIntent, and NotificationManagerCompat framework objects that require instrumented coverage; the pure push-routing decision remains JVM-covered by AIInboxNotificationRoutingTest.",
  "android/app/src/main/java/com/openburnbar/services/media/MediaSessionForegroundService.kt": "Foreground media Service notification boundary: CallStyle notification and explicit launch PendingIntent construction require framework/instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/services/media/MercuryFcmService.kt": "FirebaseMessagingService push entry point: incoming-call full-screen notification and explicit accept/decline PendingIntent construction require framework/instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/services/media/MercuryFcmServiceSupport.kt": "FCM notification presentation glue: agent-reply Intent/NotificationCompat/RemoteInput construction depends on Android framework types unavailable to local JVM JaCoCo, and thread/call routing resolution requires the Firebase SDK runtime; delivery is exercised through instrumented push flows.",
  "android/app/src/main/java/com/openburnbar/ui/pulse/layout/HomeLivingLayoutSections.kt": "Compose rendering for the living layout: six @Composable sections that place, stagger, and animate slots. Recomposition and measurement cannot be proven by JVM line attribution. The solver these sections render — HomeSpaceBudgetSections' fit/feed/breathe placement — is pure and JVM-covered at 90.6%, and the motion vocabulary is covered by PensieveMotionTest.",
  "android/app/src/main/java/com/openburnbar/ui/pulse/PulseView.kt": "Compose screen composition and store collection for the Pulse tab; recomposition and lifecycle-scoped state cannot execute under local JVM JaCoCo. The one pure helper, avatarInitials, is JVM-covered by AvatarInitialsTest.",
  "android/app/src/main/java/com/openburnbar/ui/settings/WallpaperGeneratorScreenSections.kt": "Compose rendering sections for the wallpaper generator (24 @Composable); layout and interaction require instrumented UI coverage.",
  "android/app/src/main/java/com/openburnbar/ui/components/AuroraComponents.kt": "Compose Canvas/aurora component rendering (22 @Composable) depends on Android graphics DrawScope and the animation frame clock; pixel output requires screenshot or instrumented coverage, matching the other aurora glyphs.",
  "android/app/src/main/java/com/openburnbar/ui/hermes/AssistantsScreenSections.kt": "Compose rendering sections for the Assistants screen; the presentation tables they render (providerFor, readyTagline, quickPromptsFor) are pure and JVM-covered by CliAgentChatPresentationTotalityTest.",
  "android/app/src/main/java/com/openburnbar/ui/hermes/ChatTilesSettingsScreen.kt": "Compose settings screen rendering; the persisted preference keys it reads and writes are JVM-covered by CliAgentChatPresentationTotalityTest.",
  "android/app/src/main/java/com/openburnbar/ui/hermes/CliAgentChatViewSections.kt": "Compose rendering sections for the CLI agent chat view; the messaging and presentation logic behind them is JVM-covered by CliAgentChatPresentationTotalityTest.",
  "android/app/src/main/java/com/openburnbar/ui/pulse/PulseLiveCostCurve.kt": "Compose height-constraint modifier on the live cost curve; a heightIn(min, max) bound is layout, provable only by measurement.",
  "android/app/src/main/java/com/openburnbar/ui/pulse/atlas/ModelLaneScene.kt": "Compose height-constraint modifier on the model lane scene; a heightIn(min, max) bound is layout, provable only by measurement.",
  "android/app/src/main/java/com/openburnbar/ui/pulse/atlas/SpendStreamScene.kt": "Compose height-constraint modifier on the spend stream scene; a heightIn(min, max) bound is layout, provable only by measurement.",
  "android/app/src/main/java/com/openburnbar/ui/pulse/atlas/SpendStreamSceneSections.kt": "Compose height-constraint modifier on the spend stream sections; a heightIn(min, max) bound is layout, provable only by measurement.",
  "android/app/src/main/java/com/openburnbar/ui/chartstudio/ChartStudioScreenUiSections.kt": "Compose Chart Studio scroll/layout surface; JVM unit coverage cannot prove recomposition/layout, while digest-to-prompt mapping is JVM-covered by ChartStudioPromptSuggestionsTest.",
  "android/app/src/main/java/com/openburnbar/ui/components/aurora/AuroraInboxGlyph.kt": "Compose Canvas glyph rendering depends on Android graphics DrawScope and animation frame-clock behavior; pixel output and recomposition require screenshot or instrumented coverage, matching the other aurora glyphs and MobileKernelBackdrop.",
  "android/app/src/main/java/com/openburnbar/ui/computeruse/ComputerUseAgentWatchScreen.kt": "Compose screen rendering and interaction surface; JVM unit coverage cannot prove recomposition/layout behavior, while presentation helpers remain covered by local tests.",
  "android/app/src/main/java/com/openburnbar/ui/hermes/AssistantsScreen.kt": "Compose navigation/rendering wrapper; local JVM coverage cannot prove recomposition/layout, while backing stores and formatting helpers are tested.",
  "android/app/src/main/java/com/openburnbar/ui/hermes/HermesView.kt": "Compose navigation/rendering wrapper; local JVM coverage cannot prove recomposition/layout, while backing stores and formatting helpers are tested.",
  "android/app/src/main/java/com/openburnbar/ui/inbox/InboxDetail.kt": "Compose rendering surface for the AI Inbox detail sheet; recomposition, scroll, and dialog behavior require instrumented UI coverage, while the callback contract and presentation vocabulary remain JVM-covered by InboxDetailCallbacksTest and InboxPresentationTest.",
  "android/app/src/main/java/com/openburnbar/ui/inbox/InboxDetailSections.kt": "Compose rendering sections for the AI Inbox detail sheet; layout and interaction require instrumented UI coverage, while markdown rendering and presentation mapping remain JVM-covered by InboxMarkdownTest and InboxPresentationTest.",
  "android/app/src/main/java/com/openburnbar/ui/inbox/InboxRow.kt": "Compose rendering surface for AI Inbox list rows; recomposition/layout requires instrumented UI coverage, while icon, tint, label, and priority mapping remain JVM-covered by InboxPresentationTest.",
  "android/app/src/main/java/com/openburnbar/ui/inbox/InboxScreen.kt": "Compose screen rendering and interaction surface for the AI Inbox tab; JVM unit coverage cannot prove recomposition/layout behavior, while the backing store grouping/refresh policy and presentation helpers remain covered by AIInboxRefreshPartsTest and InboxPresentationTest.",
  "android/app/src/main/java/com/openburnbar/ui/media/PairedMacControlsPreviewSections.kt": "Compose preview-only rendering section for paired-device controls; preview presentation requires screenshot or instrumented coverage, while the live control surfaces keep their own gating.",
  "android/app/src/main/java/com/openburnbar/ui/media/PairedMacControlsScreenSections.kt": "Compose rendering section for paired-device controls; interaction/layout coverage belongs to instrumented UI, while transport/control models remain unit-tested.",
  "android/app/src/main/java/com/openburnbar/ui/media/PairedMacControlsScreenSupport.kt": "Compose/UI support layer for paired-device controls; presentation behavior requires instrumented UI coverage and model/control logic remains JVM-covered.",
  "android/app/src/main/java/com/openburnbar/ui/media/ScreenShareViewerActivity.kt": "FragmentActivity lifecycle host for the screen-share viewer; onResume/onDestroy and window wiring require instrumented coverage, while reconnect decisions remain JVM-covered by ScreenShareViewerConnectionRecoveryTest and counter persistence by ScreenShareViewerCounterStoreTest.",
  "android/app/src/main/java/com/openburnbar/ui/media/ScreenShareViewerActivityControlSupport.kt": "Activity-scoped control transport glue: ensurePhoneControlSender and mirror reconnect require a live iroh transport and Activity lifecycle; the pure sender-reuse decision remains JVM-covered by ScreenShareViewerControlSenderReuseTest and mirror ack/reconnect policies by ScreenShareViewerActivityMirrorAckTest and ScreenShareViewerActivityReconnectMirrorTest.",
  "android/app/src/main/java/com/openburnbar/ui/media/ScreenShareViewerActivitySections.kt": "Compose LaunchedEffect wiring for the screen-share viewer activity; the mirror rebind decision is JVM-covered in ScreenShareViewerConnectionRecoveryTest, while effect scheduling requires instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/ui/media/ScreenShareViewerActivityUiState.kt": "Compose remember/collectAsState state plumbing for the screen-share viewer; snapshot values derive from JVM-covered coordinator and store types, while state collection requires instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/ui/media/ScreenShareViewerScreenMainSections.kt": "Compose effect wiring for the screen-share viewer; auto-type open/close transitions are JVM-covered in ScreenShareAutoTypeFollowPolicy, while LaunchedEffect scheduling and rememberSaveable state plumbing require instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/ui/media/ScreenShareViewerScreenSections.kt": "Compose rendering/effect section for the screen-share viewer; keyboard dismissal decisions are JVM-covered in ScreenShareViewerScreenModels, while IME visibility, focus requests, and lifecycle-driven keyboard reopen are Android framework behavior exercised by the instrumented ScreenShareViewerDockTest.",
  "android/app/src/main/java/com/openburnbar/ui/navigation/BurnBarNavHost.kt": "Compose navigation host wiring; route graph rendering requires instrumented UI coverage, while route selection helpers are covered separately.",
  "android/app/src/main/java/com/openburnbar/ui/navigation/BurnBarNavHostSections.kt": "Compose navigation section wiring; route graph rendering requires instrumented UI coverage, while route selection helpers are covered separately.",
  "android/app/src/main/java/com/openburnbar/ui/pulse/PulseViewSections.kt": "Compose rendering wrapper; local JVM coverage cannot prove recomposition/layout, while backing data and formatting helpers are tested.",
  "android/app/src/main/java/com/openburnbar/ui/pulse/atlas/AtlasSceneSections.kt": "Compose Trend Atlas card rendering; JVM unit coverage cannot prove recomposition/layout, while insight resolution is JVM-covered by AtlasInsightResolutionTest.",
  "android/app/src/main/java/com/openburnbar/ui/settings/GlobalVisualSettingsTabs.kt": "The changed line is a compile-time const default for the primary tab order; JaCoCo emits no line-coverage entries for const vals, so changed-line evidence is impossible here, while tab parsing and persistence remain JVM-covered by GlobalVisualSettingsTabsTest.",
  "android/app/src/main/java/com/openburnbar/ui/square/HermesSquareScreenSections.kt": "Compose rendering wrapper; local JVM coverage cannot prove recomposition/layout, while backing data and formatting helpers are tested.",
  "android/app/src/main/java/com/openburnbar/ui/you/ConnectedDevicesScreen.kt": "Compose screen rendering and interaction surface for trusted-device management; recomposition, dialog, and layout behavior require the instrumented ConnectedDevicesScreenTest, while device trust, escrow registry, and store logic remain JVM-covered by AndroidEscrowDeviceRegistryTest and the safety-code tests.",
  "android/app/src/main/java/com/openburnbar/ui/you/YouView.kt": "Compose navigation/rendering wrapper; local JVM coverage cannot prove recomposition/layout, while backing stores and formatting helpers are tested.",
  "android/app/src/main/java/com/openburnbar/ui/you/YouViewSections.kt": "Compose navigation section wiring for the You tab; row rendering and click routing require instrumented UI coverage, while backing stores remain JVM-covered.",
  "android/openburnbar-iroh-relay/src/main/java/com/openburnbar/irohrelay/Generated/HermesRealtimeRelayGeneratedTypes.kt": "Generated relay schema mirror from shared Hermes wire contracts; drift is covered by schema/vector tests and consumers rather than local line attribution.",
  "android/openburnbar-iroh-relay/src/main/java/com/openburnbar/irohrelay/OpenBurnBarIrohFfiBridge.kt": "Reflection bridge over the optional UniFFI native AAR; availability and fallback are covered by transport tests, while real UniFFI calls require native AAR/instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/ui/components/MobileKernelBackdrop.kt": "Compose Canvas backdrop rendering depends on Android graphics and frame-clock behavior; catalog identity and selection logic remain JVM-covered, while pixel output and recomposition require screenshot or instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/ui/computeruse/ComputerUseAgentWatchScreen.kt": "Compose screen rendering and interaction surface; JVM unit coverage cannot prove recomposition/layout behavior, while presentation helpers remain covered by local tests.",
  "android/app/src/main/java/com/openburnbar/ui/settings/SettingsRootScreen.kt": "Compose settings navigation router; page routing and rendering require instrumented UI coverage, while the settings manifest and search logic remain JVM-covered.",
  "android/app/src/main/java/com/openburnbar/ui/settings/SettingsSearchResultsScreen.kt": "Compose search-results rendering; breadcrumb labels are presentation glue verified through instrumented settings flows, while search matching stays JVM-covered.",
  "android/app/src/main/java/com/openburnbar/ui/settings/SettingsRootScreenThemeSections.kt": "Settings integration is a Compose navigation and rendering boundary; catalog order and persisted kernel resolution are JVM-covered, while click routing and layout require instrumented Compose coverage.",
  "android/app/src/main/java/com/openburnbar/wallpaper/livingthemes/LivingThemePreviewView.kt": "TextureView surface lifecycle and GLES renderer ownership require a real Android SurfaceTexture; theme and FPS contracts are JVM-covered, while pause, resize, and release behavior require instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/wallpaper/livingthemes/LivingThemeWallpaperService.kt": "WallpaperService engine visibility and surface callbacks are Android framework entry points unavailable to local JVM tests; selection parsing is JVM-covered and service rendering is verified on physical Android hardware.",
  "android/app/src/main/java/com/openburnbar/wallpaper/livingthemes/LivingThemesActivity.kt": "Living Themes is a Compose Activity that launches the system wallpaper picker; catalog and deep-link contracts are JVM-covered, while layout, ActivityManager capability checks, and system intent recovery require instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/wallpaper/livingthemes/ShaderKernelRenderer.kt": "EGL, GLES3 shader compilation, Android asset loading, and native-window swap behavior require a device graphics driver and cannot execute under local JVM JaCoCo; all 42 shader assets are contract-verified and compiled on physical Android hardware.",
  "android/app/src/main/java/com/openburnbar/data/media/MediaControlPresence.kt": "Media-session presence is Android service/session integration glue; transport and coordinator logic remain JVM-covered.",
  "android/app/src/main/java/com/openburnbar/data/missions/MobileMissionConsoleHost.kt": "Mission console host is Android composition/lifecycle glue around Firebase and UI; seal and payload contracts remain JVM-covered.",
  "android/app/src/main/java/com/openburnbar/data/stores/ActivityStore.kt": "Firestore/ViewModel activity feed store: snapshot lifecycle, debounce, and cloud-search wiring depend on the Firebase SDK runtime and need emulator/instrumented coverage; token-usage mapping remains JVM-covered.",
  "android/app/src/main/java/com/openburnbar/data/stores/QuotaStore.kt": "AndroidViewModel quota store is a Firestore/Functions listener boundary; bucket parsing remains JVM-covered, while snapshot lifecycle requires emulator/instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/data/stores/CloudSyncHealthStore.kt": "Firestore listener store for Cloud Sync health: snapshot lifecycle and Firebase exception mapping depend on the Firebase SDK runtime and need emulator/instrumented coverage; freshness and ownership policy remain JVM-covered.",
  "android/app/src/main/java/com/openburnbar/data/stores/CloudSyncHealthStoreSupport.kt": "Cloud Sync health store support is Firestore/ViewModel glue around the listener store; policy mapping remains JVM-covered.",
  "android/app/src/main/java/com/openburnbar/data/stores/CredentialTransferStore.kt": "Credential-transfer store is a Firebase Functions + ViewModel boundary; envelope crypto helpers remain JVM-covered by CredentialTransferStoreSecurityTest, while callable transport requires emulator/instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/data/stores/ProviderSummaryStore.kt": "Firestore listener store for provider summaries; snapshot lifecycle depends on the Firebase SDK runtime and needs emulator/instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/data/text/TextExpansionSyncWorker.kt": "WorkManager worker is an Android framework entry point; expansion sync policy remains JVM-covered, while enqueue/doWork requires instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/data/widget/BurnBarWidgetSyncWorker.kt": "WorkManager widget refresh worker is an Android framework entry point; snapshot privacy policy remains JVM-covered, while enqueue/doWork requires instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/services/media/AgentReplyNotificationState.kt": "Agent-reply notification presentation and FCM rebind glue depend on Android notification/framework types; consumed-event persist/bind and escrow cross-reference remain JVM-covered by AgentReplyNotificationStateTest.",
  "android/app/src/main/java/com/openburnbar/services/media/IncomingCallActivity.kt": "Incoming-call Activity is a full-screen notification host; payload routing remains JVM-covered, while Activity lifecycle and NotificationManager delivery require instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/ui/auth/AuthGateView.kt": "Compose auth gate rendering and navigation; JVM unit coverage cannot prove recomposition/layout, while auth session policy remains JVM-covered.",
  "android/app/src/main/java/com/openburnbar/ui/burn/QuotaRingItem.kt": "Compose quota-ring rendering; JVM unit coverage cannot prove recomposition/layout, while quota formatting helpers remain JVM-covered.",
  "android/app/src/main/java/com/openburnbar/ui/hermes/HermesChatViewLocalState.kt": "Compose remember/local state plumbing for Hermes chat; snapshot values derive from JVM-covered service types, while state collection requires instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/ui/hermes/HermesSettingsView.kt": "Compose settings rendering wrapper; local JVM coverage cannot prove recomposition/layout, while preference and connection helpers are tested.",
  "android/app/src/main/java/com/openburnbar/ui/hermes/HermesViewChatComposerSections.kt": "Compose chat-composer rendering; local JVM coverage cannot prove recomposition/layout, while backing stores and formatting helpers are tested.",
  "android/app/src/main/java/com/openburnbar/ui/hermes/HermesViewChatStateSections.kt": "Compose chat-state rendering; local JVM coverage cannot prove recomposition/layout, while backing stores and formatting helpers are tested.",
  "android/app/src/main/java/com/openburnbar/ui/hermes/HermesViewRouteSections.kt": "Compose Hermes route wiring; route graph rendering requires instrumented UI coverage, while route selection helpers are covered separately.",
  "android/app/src/main/java/com/openburnbar/ui/hermes/HermesViewSections.kt": "Compose Hermes section wiring; local JVM coverage cannot prove recomposition/layout, while backing stores and formatting helpers are tested.",
  "android/app/src/main/java/com/openburnbar/ui/hermes/HermesViewUiState.kt": "Compose remember/collectAsState plumbing for Hermes; snapshot values derive from JVM-covered service types, while state collection requires instrumented coverage.",
  "android/app/src/main/java/com/openburnbar/ui/hermes/PiAssistantView.kt": "Compose Pi assistant rendering wrapper; local JVM coverage cannot prove recomposition/layout, while backing stores and formatting helpers are tested.",
  "android/app/src/main/java/com/openburnbar/ui/hermes/PiAssistantViewSections.kt": "Compose Pi assistant section rendering; local JVM coverage cannot prove recomposition/layout, while backing stores and formatting helpers are tested.",
  "android/app/src/main/java/com/openburnbar/ui/pulse/PulseHeroBurnCardSections.kt": "Compose Pulse hero card rendering; local JVM coverage cannot prove recomposition/layout, while Pulse window metrics remain JVM-covered.",
  "android/app/src/main/java/com/openburnbar/ui/pulse/PulseLiveCostCurveSections.kt": "Compose Pulse cost-curve rendering; local JVM coverage cannot prove recomposition/layout, while Pulse window metrics remain JVM-covered.",
  "android/app/src/main/java/com/openburnbar/ui/pulse/VelocityForecastCardSections.kt": "Compose velocity-forecast card rendering; local JVM coverage cannot prove recomposition/layout, while Pulse window metrics remain JVM-covered.",
  "android/app/src/main/java/com/openburnbar/ui/store/CloudStoreView.kt": "Compose store rendering wrapper; local JVM coverage cannot prove recomposition/layout, while entitlement policy remains JVM-covered.",
  "android/app/src/main/java/com/openburnbar/ui/store/CloudStoreViewPlanSections.kt": "Compose store plan rendering; local JVM coverage cannot prove recomposition/layout, while entitlement policy remains JVM-covered.",
  "android/app/src/main/java/com/openburnbar/ui/streams/StreamsView.kt": "Compose Streams rendering wrapper; local JVM coverage cannot prove recomposition/layout, while list policy remains JVM-covered.",
  "android/app/src/main/java/com/openburnbar/ui/streams/StreamsViewSections.kt": "Compose Streams section rendering; local JVM coverage cannot prove recomposition/layout, while list policy remains JVM-covered.",
  "android/app/src/main/java/com/openburnbar/ui/you/CloudSyncDetailsView.kt": "Compose Cloud Sync details rendering; local JVM coverage cannot prove recomposition/layout, while sync-health policy remains JVM-covered.",
  "android/app/src/main/java/com/openburnbar/ui/you/IdentityHeroSections.kt": "Compose identity-hero rendering; local JVM coverage cannot prove recomposition/layout, while backing stores remain JVM-covered.",
  "android/app/src/main/java/com/openburnbar/ui/support/BugReportBottomSheet.kt": "Compose bug-report sheet rendering; JVM unit coverage cannot prove recomposition/layout, while BugReportSubmission mapping remains JVM-covered by BugReportServiceTest.",
  "android/app/src/main/java/com/openburnbar/ui/support/HelpSupportScreen.kt": "Compose Help & Support rendering; JVM unit coverage cannot prove recomposition/layout, while AndroidDiagnosticsSnapshot mapping remains JVM-covered by BugReportServiceTest."
}
JSON
)"
export ANDROID_DIFF_COVERAGE_ALLOWLIST_JSON

changed_files="$(git diff --name-only --diff-filter=ACMR "$base_ref" HEAD -- '*.kt' 2>/dev/null || true)"
if [[ -z "$changed_files" ]]; then
    echo '{"diffCoverage":{"percent":100.0,"passed":true,"changedFiles":0,"surface":"android","method":"no_kotlin_changes"}}'
    exit 0
fi

production_changed="$(printf '%s\n' "$changed_files" | awk '
  /\/src\/main\// &&
  $0 !~ /^android\/macrobenchmark\// &&
  $0 != "android/app/src/main/java/com/openburnbar/ui/tokens/PensieveTokens.kt" &&
  $0 != "android/app/src/main/java/com/openburnbar/data/catalog/MissionRuntimeCatalog.kt" &&
  $0 !~ /^android\/(burnbar-remote|openburnbar-domain-core|openburnbar-iroh-relay)\/src\/main\/java\/uniffi\//
')"
if [[ -z "$production_changed" ]]; then
    echo '{"diffCoverage":{"percent":100.0,"passed":true,"changedFiles":0,"surface":"android","method":"no_production_kotlin"}}'
    exit 0
fi

jacoco_xmls=()
jacoco_xml_env="${ANDROID_JACOCO_XMLS:-${ANDROID_JACOCO_XML:-}}"
if [[ -n "$jacoco_xml_env" ]]; then
    IFS=':' read -r -a jacoco_xmls <<< "$jacoco_xml_env"
else
    while IFS= read -r report; do
        jacoco_xmls+=("$report")
    done < <(find "$repo_root/android" -path '*/build/reports/jacoco/testDebugUnitTest/jacocoTestReport.xml' -type f | sort)
fi
if [[ "${#jacoco_xmls[@]}" -eq 0 ]]; then
    echo "::error::No JaCoCo reports found. Run affected Android module jacocoTestReport tasks before gating production Kotlin changes." >&2
    exit 1
fi
for jacoco_xml in "${jacoco_xmls[@]}"; do
    if [[ ! -f "$jacoco_xml" ]]; then
        echo "::error::JaCoCo report not found at $jacoco_xml. Run affected Android module jacocoTestReport tasks before gating production Kotlin changes." >&2
        exit 1
    fi
done
jacoco_xmls_joined="$(IFS=:; printf '%s' "${jacoco_xmls[*]}")"

export BASE_REF="$base_ref"
export REPO_ROOT="$repo_root"
export JACOCO_XMLS="$jacoco_xmls_joined"
export COVERAGE_THRESHOLD="$threshold"

python3 <<'PY'
import json
import os
import re
import subprocess
import xml.etree.ElementTree as ET

base_ref = os.environ["BASE_REF"]
repo_root = os.environ["REPO_ROOT"]
jacoco_xmls = [p for p in os.environ["JACOCO_XMLS"].split(os.pathsep) if p]
threshold = int(os.environ["COVERAGE_THRESHOLD"])
allowlist = json.loads(os.environ.get("ANDROID_DIFF_COVERAGE_ALLOWLIST_JSON") or "{}")
for path, reason in allowlist.items():
    if not isinstance(reason, str) or not reason.strip():
        print(f"::error::Android coverage allowlist entry {path!r} has no reason.")
        raise SystemExit(1)

changed = subprocess.check_output(
    ["git", "diff", "--name-only", "--diff-filter=ACMR", base_ref, "HEAD", "--", "*.kt"],
    cwd=repo_root,
    text=True,
).splitlines()
changed = [c.strip() for c in changed if c.strip() and "/src/main/" in c]
# android/macrobenchmark is on-device benchmark tooling (instrumented-only module, no JVM unit-test source set).
changed = [c for c in changed if not c.startswith("android/macrobenchmark/")]
# These three UniFFI trees are generated from Rust APIs and covered by binding drift/ABI gates.
generated_uniffi_prefixes = (
    "android/burnbar-remote/src/main/java/uniffi/",
    "android/openburnbar-domain-core/src/main/java/uniffi/",
    "android/openburnbar-iroh-relay/src/main/java/uniffi/",
)
changed = [c for c in changed if not c.startswith(generated_uniffi_prefixes)]
# Style Dictionary owns this exact compile-time-constant file; token drift gates
# validate the generator output, while JaCoCo cannot instrument const vals.
generated_source_paths = {
    "android/app/src/main/java/com/openburnbar/ui/tokens/PensieveTokens.kt",
    "android/app/src/main/java/com/openburnbar/data/catalog/MissionRuntimeCatalog.kt",
}
changed = [c for c in changed if c not in generated_source_paths]
if not changed:
    print(json.dumps({"diffCoverage": {"percent": 100.0, "passed": True, "surface": "android", "method": "no_production_kotlin"}}))
    raise SystemExit(0)

waived = []
coverage_candidates = []
for rel_path in changed:
    reason = allowlist.get(rel_path)
    if reason:
        waived.append({
            "file": rel_path,
            "method": "allowlist_waiver",
            "reason": reason,
        })
    else:
        coverage_candidates.append(rel_path)
changed = coverage_candidates

if not changed:
    print(json.dumps({
        "diffCoverage": {
            "percent": 100.0,
            "threshold": threshold,
            "passed": True,
            "changedFiles": 0,
            "changedLines": 0,
            "surface": "android",
            "method": "all_changes_waived",
        },
        "details": [],
        "waived": waived,
    }, indent=2))
    raise SystemExit(0)

git_output = subprocess.run(
    ["git", "diff", "-U0", base_ref, "HEAD", "--"] + changed,
    cwd=repo_root,
    capture_output=True,
    text=True,
).stdout

file_blocks = {}
current = None
for line in git_output.splitlines():
    m = re.match(r"^diff --git a/.* b/(.*)$", line)
    if m:
        current = m.group(1)
        file_blocks.setdefault(current, [])
        continue
    if current and line.startswith("@@"):
        nm = re.search(r"\+(\d+)(?:,(\d+))?", line)
        if not nm:
            continue
        start = int(nm.group(1))
        count = int(nm.group(2) or "1")
        for ln in range(start, start + count):
            file_blocks[current].append(ln)

def consume_annotation(source_line, start):
    """Consume a single-line Kotlin annotation starting at `start` ('@').

    Returns the index just past the annotation, or None when the text is not
    a complete single-line annotation (fail closed: unparsed text counts as
    executable code and keeps requiring coverage evidence). Handles optional
    use-site targets (@file:Suppress), dotted names, and balanced constant
    argument lists containing string/char literals.
    """
    def read_identifier(index):
        if index < len(source_line) and (source_line[index].isalpha() or source_line[index] == "_"):
            index += 1
            while index < len(source_line) and (source_line[index].isalnum() or source_line[index] == "_"):
                index += 1
            return index
        return None

    end = read_identifier(start + 1)
    if end is None:
        return None
    if end < len(source_line) and source_line[end] == ":":
        end = read_identifier(end + 1)
        if end is None:
            return None
    while end is not None and end < len(source_line) and source_line[end] == ".":
        end = read_identifier(end + 1)
    if end is None:
        return None
    if end < len(source_line) and source_line[end] == "(":
        depth = 1
        index = end + 1
        while index < len(source_line) and depth > 0:
            char = source_line[index]
            if char in {'"', "'"}:
                index += 1
                closed = False
                while index < len(source_line):
                    if source_line[index] == "\\":
                        index += 2
                        continue
                    if source_line[index] == char:
                        index += 1
                        closed = True
                        break
                    index += 1
                if not closed:
                    return None
                continue
            if char == "(":
                depth += 1
            elif char == ")":
                depth -= 1
            index += 1
        if depth != 0:
            return None
        end = index
    return end

def non_executable_lines(rel_path):
    """Return source line numbers containing only whitespace, comments, and
    standalone annotations.

    JaCoCo intentionally emits no executable-line entry for KDoc, ordinary
    comments, or annotation lines (annotation arguments are compile-time
    constants with no bytecode). A diff touching only such lines therefore
    has strong evidence that there is nothing to cover, but only after we
    lex the source and prove every added line is outside strings and
    executable code.
    """
    path = os.path.join(repo_root, rel_path)
    with open(path, encoding="utf-8") as handle:
        source_lines = handle.read().splitlines()

    result = set()
    block_depth = 0
    in_triple_string = False

    for line_number, source_line in enumerate(source_lines, start=1):
        index = 0
        has_code = in_triple_string

        while index < len(source_line):
            if in_triple_string:
                closing = source_line.find('"""', index)
                if closing < 0:
                    index = len(source_line)
                    continue
                in_triple_string = False
                index = closing + 3
                continue

            if block_depth > 0:
                if source_line.startswith("/*", index):
                    block_depth += 1
                    index += 2
                elif source_line.startswith("*/", index):
                    block_depth -= 1
                    index += 2
                else:
                    index += 1
                continue

            if source_line[index].isspace():
                index += 1
                continue
            if source_line.startswith("//", index):
                break
            if source_line.startswith("/*", index):
                block_depth = 1
                index += 2
                continue
            if source_line.startswith('"""', index):
                has_code = True
                in_triple_string = True
                index += 3
                continue
            if source_line[index] == "@":
                annotation_end = consume_annotation(source_line, index)
                if annotation_end is None:
                    has_code = True
                    index += 1
                else:
                    index = annotation_end
                continue
            if source_line[index] in {'"', "'"}:
                has_code = True
                quote = source_line[index]
                index += 1
                while index < len(source_line):
                    if source_line[index] == "\\":
                        index += 2
                        continue
                    if source_line[index] == quote:
                        index += 1
                        break
                    index += 1
                continue

            has_code = True
            index += 1

        if not has_code:
            result.add(line_number)

    return result

# Build a package-qualified coverage map. JaCoCo sourcefile names are not
# unique: different packages and modules routinely contain Foo.kt. The
# package/name key must resolve to exactly one changed repo path.
coverage = {}
for jacoco_xml in jacoco_xmls:
    tree = ET.parse(jacoco_xml)
    root = tree.getroot()
    for package in root.iter("package"):
        package_name = (package.get("name") or "").strip("/")
        for sf in package.iter("sourcefile"):
            name = sf.get("name")
            key = f"{package_name}/{name}" if package_name else name
            lines = coverage.setdefault(key, {})
            for line_el in sf.iter("line"):
                ln = int(line_el.get("nr"))
                mi = int(line_el.get("mi", "0"))
                ci = int(line_el.get("ci", "0"))
                if mi + ci > 0:
                    lines[ln] = lines.get(ln, False) or ci > 0

def source_identity(rel_path):
    match = re.search(r"/src/main/(?:java|kotlin)/(.*)$", rel_path)
    return match.group(1) if match else None

changed_by_identity = {}
for rel_path in changed:
    identity = source_identity(rel_path)
    if not identity:
        print(f"::error::Cannot derive Kotlin source identity from {rel_path!r}.")
        raise SystemExit(1)
    changed_by_identity.setdefault(identity, []).append(rel_path)

ambiguous = {
    identity: paths
    for identity, paths in changed_by_identity.items()
    if len(paths) != 1
}
if ambiguous:
    print("::error::JaCoCo source identities map to multiple changed repo paths: " + json.dumps(ambiguous, sort_keys=True))
    raise SystemExit(1)

total_exc = 0
total_hit = 0
details = []
missing_evidence = []
for rel_path in changed:
    identity = source_identity(rel_path)
    line_cov = coverage.get(identity)
    changed_lines = set(file_blocks.get(rel_path, []))
    # A deletion-only diff (no added lines in the -U0 hunk) has zero
    # executable lines to cover.  Report it as deletion_only and skip
    # the JaCoCo lookup — there is nothing to instrument or attest.
    if not changed_lines:
        details.append({
            "file": rel_path,
            "executableLines": 0,
            "coveredLines": 0,
            "percent": 100.0,
            "method": "deletion_only",
            "sourceIdentity": identity,
        })
        continue
    if changed_lines.issubset(non_executable_lines(rel_path)):
        details.append({
            "file": rel_path,
            "executableLines": 0,
            "coveredLines": 0,
            "percent": 100.0,
            "method": "comment_or_annotation_only",
            "sourceIdentity": identity,
        })
        continue
    if line_cov is None:
        missing_evidence.append(rel_path)
        details.append({
            "file": rel_path,
            "executableLines": 0,
            "coveredLines": 0,
            "percent": 0.0,
            "method": "no_jacoco_source",
            "sourceIdentity": identity,
        })
        continue
    exc = sum(1 for ln in changed_lines if ln in line_cov)
    hit = sum(1 for ln in changed_lines if line_cov.get(ln))
    pct = round(hit * 100.0 / exc, 2) if exc > 0 else 0.0
    entry = {
        "file": rel_path,
        "executableLines": exc,
        "coveredLines": hit,
        "percent": pct,
        "method": "jacoco_line_intersection",
        "sourceIdentity": identity,
    }
    if changed_lines and exc == 0:
        entry["method"] = "no_changed_line_evidence"
        missing_evidence.append(rel_path)
    total_exc += exc
    total_hit += hit
    details.append(entry)

total_pct = 0.0 if total_exc <= 0 else round(total_hit * 100.0 / total_exc, 2)
# When every changed file is deletion-only (total_exc == 0) there are no
# executable lines to gate; the run passes trivially as long as no file
# is missing evidence.
passed = not missing_evidence and (total_exc > 0 and total_pct >= threshold or total_exc == 0)
print(json.dumps({
    "diffCoverage": {
        "percent": total_pct,
        "threshold": threshold,
        "passed": passed,
        "changedFiles": len(details),
        "changedLines": total_exc,
        "missingEvidenceFiles": len(missing_evidence),
        "surface": "android",
        "method": "jacoco_line_intersection",
    },
    "details": details,
    "missingEvidence": missing_evidence,
    "waived": waived,
}, indent=2))
if not passed:
    raise SystemExit(1)
PY
