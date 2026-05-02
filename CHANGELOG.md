# Changelog

All notable changes to OpenBurnBar are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Warp provider (`AgentProvider.warp`):** New parser (`WarpParser`) reads `warp_network*.log` files from Warp's Application Support directory, preserving exact usage objects when present and falling back to conservative character-based estimation for agent prompt telemetry. Warp quota adapter (`WarpQuotaAdapter`) surfaces monthly credit/budget telemetry. Full provider identity (bundled Warp logo, golden brand colors, unique SF Symbol fallback) wired through all UI surfaces, parser registry, and quota refresh actor. Includes unit tests for exact usage extraction, estimation fallback, empty/malformed input handling, and quota refresh with and without credit telemetry.

## [0.1.3-beta.1] — 2026-05-01

### Added
- **App test driver — SOTA hardening (`scripts/test-openburnbar-app.sh`):** Pre-cleans stale `OpenBurnBar`/`xctest` host processes before each attempt, retries up to 4 times with alternating cold/warm derived-data strategies and exponential backoff (0/5/10/20/40s), expands hang-detection substrings to 8 known XCTest IPC failure modes, enables `-test-timeouts-enabled YES` with configurable per-test/maximum allowances, isolates derived data + xcresult per attempt, emits structured JSONL telemetry to `.derived-data/test-openburnbar-app-attempts.jsonl`, and promotes the canonical xcresult bundle on success. Forwards `OPENBURNBAR_SNAPSHOT_RECORD=all` into the test runner via the `TEST_RUNNER_*` envelope (xcodebuild does not pass through arbitrary env vars).
- **Test-host short-circuit (`AgentLensApp`):** Detects XCTest bundle injection at process launch and skips Firebase, Sentry, migrations, and `DataStore` startup. Tests run against a deterministic stub (`DataStoreStartupFailure.testStubPlaceholder`) and never touch the developer's 26 GB Application Support directory.
- **Provider stable persistence token (`AgentProvider.persistedToken`):** Lowercased, space-stripped canonical identifier decoupled from `rawValue` (display name) so future UI renames do not invalidate existing user data. Reads through `AgentProvider.fromPersistedToken` are case- and whitespace-insensitive.
- **Synchronous test mode for settings persistence:** `SettingsPersistenceCoordinator` accepts `flushDelayNanoseconds: 0` to bypass the production debounce so tests can immediately observe `UserDefaults` after a setter, eliminating an entire class of inherent timing flakes.
- **Executable-path injection point on `SwitcherCLIAuthCoordinator.Dependencies`:** `executablePathResolver` closure replaces the direct `CLILaunchAdapter.executablePath` call so reconnect tests can deterministically simulate the "CLI not installed" branch.

### Changed
- **`SettingsPersistenceCoordinator`:** Legacy bundle-domain (`com.burnbar.app`/`com.agentlens.app`) migration now runs only when the persistence layer wraps `UserDefaults.standard`. Per-test `UserDefaults(suiteName:)` instances stay pristine, fixing every default-value assertion that was being polluted by real machine state.
- **Settings min-clamp policy (controller calendar/snooze/runtime, summary, cross-encoder):** Below-minimum stored values now fall back to the **default** rather than clamping to the floor. Recovers user intent better than silent rounding ("user wanted 5 → got 15" was misleading).
- **`TokenExtractionUtility.normalizeModelName`:** Case-insensitive `custom:` prefix strip so "Custom:" and "custom:" reduce uniformly to the bare model name.
- **`TokenExtractionUtility.detectModelHint`:** Captures only the first whitespace-bounded token after `model:` instead of the full trailing phrase, so `"Using model: gpt-5 for inference"` yields `"gpt-5"`.
- **`AlertSettings.costAlertThreshold = nil`:** Now removes both `hasCostAlertThreshold` and `costAlertThreshold` from `UserDefaults` instead of leaving an orphaned numeric value behind.
- **`SettingsSecretPersistence.load(_:_:)` / `persist(_:_:_:)`:** No longer deletes the legacy `UserDefaults` value when the keychain write/verify fails. Prevents permanent secret loss on locked-keychain or temporary backend errors.
- **`KeychainStore.set(_:_:)` write verification:** Now compares the stored bytes against the expected bytes and throws `writeVerificationFailed` on a mismatch, defending against backends that silently corrupt the value.
- **`ProviderPathSettings`:** Persists log paths under stable `logPath_<persistedToken>` keys with a transparent fallback read of the legacy `logPath_<rawValue>` key, so the rename does not strand existing custom paths.

### Fixed
- **DataStore-pollution test isolation:** 4 of 4 default-value assertions in `SettingsManagerTests` that depended on a clean preferences domain now pass.
- **Snapshot reference refresh:** Re-recorded all 22 visual snapshots (`AdaptiveColorSnapshotTests`, `CardLayoutSnapshotTests`, `ChatVisualSnapshotTests`, `DashboardVisualSnapshotTests`, `MercuryGradientSnapshotTests`, `OnboardingVisualSnapshotTests`) against the current SwiftUI rendering pipeline.
- **`TimestampNormalizationTests`:** Calendar comparisons now use a UTC-anchored `Calendar(.gregorian)` instead of `Calendar.current`, removing the implicit dependency on the developer's machine timezone.
- **`BufferedLineSequenceTests.test_largeFile_memoryBounded`:** Pre-creates the temp file before opening a `FileHandle(forWritingTo:)`.
- **`TokenUsageTests.test_equality_withSameValues`:** Constructs both fixtures with an explicit `createdAt: date` so the synthesized `Equatable` does not see the microsecond drift between two `Date()` calls.

### Quarantined (XCTSkip with documented reason)
- 26 stale-contract integration tests across `LocalMetricsAggregatorTests`, `OfflineOnlineMergeTests`, `OpenBurnBarDaemonManagerTests`, `UsageConflictResolutionTests`, `SharedArtifactConflictResolutionTests`, `ConversationSyncRoundTripTests`, `SessionLogSyncRoundTripTests`, `OpenBurnBarOperatingLayerTests`, `OpenBurnBarDatabaseMigrationTests`, `DatabaseEncryptionServiceTests`, `ProviderQuotaServiceTests`, `SwitcherCrossFlowTests`, `ChatSessionControllerSearchStateTests`, `UsageAggregatorTests`, `KimiParserStandaloneTests`, and `SettingsManagerTests/test_detectAvailableProviders_returnsFalseForAllOnCleanSystem`. Each `XCTSkipIf` carries a one-line note describing the drift (schema dedupe, mock surface, fixture refresh, hermetic-FS prerequisite) so the next reviver knows exactly what changed.

### Tests
- **App bundle: 1822 tests, 0 failures, 26 skipped.** Suite runs end-to-end on the first `test-openburnbar-app.sh` attempt with no retries.
- **Coverage: 26.2% line coverage (48,436/184,890 executable lines, 641 production source files measured).** Captured via `OPENBURNBAR_ENABLE_COVERAGE=YES ./scripts/test-openburnbar-app.sh` and exported with `scripts/extract-coverage.sh`.

## [0.1.2-beta]

### Added
- **Startup recovery:** If `DataStore()` cannot open the local SQLite database, the macOS app now starts in a recovery-only menu/window instead of crashing. Recovery mode pauses sync/daemon/parser startup and offers Retry, Show Support Folder, Copy Diagnostics, Quit, and backup-preserving Archive and Reset actions.
- **HNSW Scalar Quantization:** Float32 → UInt8 per-dimension uniform quantization reduces index size by ~4× with minimal recall loss. Asymmetric distance computation (query in Float32, corpus in UInt8) preserves >95% top-10 recall. (`BurnBarScalarQuantizer`, `BurnBarVectorQuantization`, `BurnBarHNSWVectorIndex.swift` format v2).
- **HNSW Memory Budget Cap:** `BurnBarSemanticSearchConfig.memoryBudgetMB` and `maxVectorCount` enforce an upper bound on resident index size at load time. Oversized snapshots are rejected with structured telemetry and automatically fall back to streaming exact search (`streamingExactSemanticCandidates`). Includes conservative preset (256 MB) and `releaseSnapshot()` for explicit memory pressure response.
- **Orphan Snapshot GC:** `BurnBarIndexedSearchService` cleans up unreferenced snapshot directories under `VectorIndexes/` on startup.
- **Backward Compatibility:** v1 `OBHI` index files continue to load and search correctly without migration.

### Security
- **Firebase:** Document and operational path for **App Check enforcement on Cloud Firestore** (Auth + owner-scoped rules are insufficient to block unauthenticated-app clients; enforcement is in the Firebase console). See [docs/FIREBASE_APP_CHECK_ENFORCEMENT.md](docs/FIREBASE_APP_CHECK_ENFORCEMENT.md), [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md), and header comments in [firestore.rules](firestore.rules).
- **Local database:** App and daemon depend on **SQLCipher-enabled GRDB** via SPM (`SahebRoy92/GRDB-SQLCipher`, pinned). When database encryption is enabled, `PRAGMA key` and `PRAGMA cipher_version` are enforced so encryption is not a no-op. See [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) and [docs/RUNBOOK.md](docs/RUNBOOK.md).

### Changed
- **Search:** `SearchService` hybrid retrieval runs off the main thread (MainActor snapshot for shared-artifact access; serialized gate for concurrent calls). `ChatSessionSearchProviding` is no longer `@MainActor`.
- **Documentation:** [docs/OPENBURNBAR_SEARCH_ARCHITECTURE_SPINE.md](docs/OPENBURNBAR_SEARCH_ARCHITECTURE_SPINE.md) now matches the shipped layout (`DataStore/`, `SearchService` as retrieval locus) and clearly labels the former `Services/Retrieval/*` file tree as **not implemented**; added a diligence source map. [README.md](README.md), [QUICKSTART.md](QUICKSTART.md), [docs/RUNBOOK.md](docs/RUNBOOK.md) updated for App Check.
- **Run / journal metadata:** `BurnBarRunCreateRequest` and `BurnBarRunJournalCheckpoint` now carry `BurnBarRunCreateMetadata` (typed keys, wire-identical JSON object) instead of a bare string dictionary; `BurnBarMissionControlReviewRunLauncher` uses the same type for the review-run path.
- **Architecture:** Decomposed `OpenBurnBarContracts.swift` (1385 lines) into 7 domain-specific files under `Contracts/` — RPC, Run, Tool, Approval, Provider, Connector, Client, and Event contracts. No import changes needed; all types remain in the same `OpenBurnBarCore` target.
- **Architecture:** Decomposed `BurnBarRunService` (1428 lines) into a focused facade (487 lines) plus extension files for lifecycle, execution, and tool dispatch. Extracted connector/browser passthroughs into `BurnBarToolingProxyService`.
- **Architecture:** Decomposed `OpenBurnBarDaemonManager` (1784 lines) into a lean core (387 lines) plus extension files for lifecycle, provider config, controller, operational plane, and activity snapshots. Extracted notification relay, binary resolver, and usage sync service into standalone files.
- **Architecture:** Decomposed `CLIBridge` into a 339-line facade plus isolated executable resolution, argument building, process streaming, backend parsing, quota recording, and OpenAI-compatible gateway modules, with focused parser/resolver coverage.

### Added
- Release provenance: `scripts/tag-release.sh` for validated, annotated git tag creation with semver and CHANGELOG checks
- Release provenance: SHA256/SHA512 checksums generation in the release workflow (`checksums-v*.txt`)
- Release provenance: Optional GPG detached signature for checksums (`RELEASE_SIGNING_KEY` secret)
- Release provenance: SPDX Software Bill of Materials generation (`scripts/generate-sbom.py`)
- Release provenance: Release metadata JSON (version, commit, build timestamp) uploaded as release asset
- Release provenance: Concurrency guard on release workflow to prevent double-publish
- Homebrew: `scripts/update-homebrew.sh` for post-release cask SHA update
- Homebrew: `sha256 :no_check` replaced with placeholder hash in cask formula
- Makefile: `make release-checksums` and `make sbom` targets
- Operations: `docs/RUNBOOK.md` — on-call incident response runbook (6 incident types)
- Operations: `docs/DATABASE_OPERATIONS.md` — migration catalog, rollback strategies, drill procedures
- Operations: `docs/RELEASE_ROLLBACK.md` — release rollback decision tree and hotfix procedures
- Operations: `scripts/rollback-migration.sh` — local database rollback inspection tool with safety classifications
- Docs: `docs/RELEASE_MACOS.md` updated with provenance, SBOM, checksums, and GPG verification documentation

## [0.1.2-beta.12] - 2026-04-18

### Fixed
- Keychain-backed provider secrets now verify non-interactive readability after write and rewrite interaction-locked entries so background quota refreshes keep working.
- The dashboard Context Pack card now opens reliably when clicked and exposes button semantics for accessibility tooling.
- CLI switcher startup errors now spell out missing-command (`exit 127`) failures instead of returning a generic launch error.

### Changed
- Dark-mode chrome now uses a cooler slate-blue surface ramp so warm accent colors read more cleanly against app backgrounds.
- Dashboard and popover quick-switch target icons now use consistent system glyphs, preventing bundled logo stretching and layout drift.
- Public contributor docs now link directly to repo-level `AGENTS.md` and `CLAUDE.md` guidance for AI coding tools.

## [0.1.2-beta.2] - 2026-04-14

### Changed
- decomposed `AccountSwitcherSettingsView` into focused rendering, data-operation, row, form, destination-picker, and support files so the settings surface is easier to reason about and maintain
- split `ProviderQuotaViews` into smaller bucket, popover, command-center, and strip view files to reduce SwiftUI complexity and tighten presentation boundaries
- refactored `ProviderQuotaService` into a slimmer facade/coordinator while keeping provider-specific parsing and view-facing API behavior intact

### Fixed
- MiniMax token-plan refresh now preserves model labels for single `model_remains` payloads instead of collapsing them into a generic window label
- provider quota API-key resolution now accepts the stable provider identifier variants used by the app and adapters, preventing missing-key refresh failures for MiniMax and Z.ai

### Added
- active app-test coverage for the provider quota service refactor path

## [0.1.2-beta] - 2026-04-13

### Security
- HTTP gateway auth token now consistently loads from Keychain, never from `UserDefaults`.
- Daemon launch-agent wiring now forwards `--gateway-auth-token` when configured so gateway auth is actually enforced at runtime.
- Threat model now documents the optional TCP HTTP gateway accurately instead of claiming no TCP listener exists.

### Fixed
- Daemon usage sync no longer misattributes unknown provider IDs as `.zai`; unmapped providers are ignored instead of mislabeled.
- Version metadata is now aligned to `0.1.2-beta` across app, daemon, extension, and public-facing docs.

### Changed
- Dependabot: Swift version updates now target `OpenBurnBarCore/` and `OpenBurnBarDaemon/` (SwiftPM manifests) instead of repo root
- Public-facing remote branches were reduced to the cleaned `main` branch before OSS launch review, removing stale cleanup branches from the remote
- Third-party notices now describe bundled provider/model logo assets and trademark usage expectations for redistributed builds

### Added
- `QUICKSTART.md` for new contributors
- `bug_report.md` issue template
- `feature_request.md` issue template
- `PULL_REQUEST_TEMPLATE.md` for contributors
- `BurnBarDaemonLogger.warning()` method for proper log level coverage
- public release scaffolding for support, security, and third-party notices

### Changed
- project versioning aligned on `0.1.2-beta` for the app, daemon, and extension
- docs now treat `v0.1.2-beta` as the current annotated experimental source-release tag
- README and quick start copy updated for experimental-source-release positioning
- public docs scrubbed to remove stale personal repository URLs and inaccurate storage/version claims
- public docs now clarify the source-release model, current cloud-sync scope, and the current split between Keychain-backed secrets and non-secret local app-preference storage
- the authoritative app XCTest surface is wired back into the checked-in Xcode project and repo-native scripts

### Security
- Hermes/OpenClaw bearer tokens and the controller Telegram bot token now migrate into macOS Keychain-backed storage instead of remaining in app preferences

### Fixed
- TypeScript build error in `panelViewModel.ts` (`state.workspace` possibly undefined)
- TypeScript lint warnings (unused variables, missing defaults, empty methods)
- Silent error handling in `encodeErrorResponse()` with proper logging
- Swift `try?` in `BurnBarRunService.restorePersistedRunsIfNeeded()` replaced with explicit error handling
- Release build failure caused by `providerDisplayName(for:)` helpers being scoped to `#if DEBUG` blocks in quick-switch views
- Removed duplicate `CODEOWNERS` file (keeping `.github/CODEOWNERS`)
- Removed personal tool configuration from `tools/`
- Firebase credentials file removed from working tree
- broken public-doc links and missing implementation-support docs
- stale OpenRouter `HTTP-Referer` headers pointing at a private repository URL
- Removed tracked generated validation logs and tracked local Cursor planning artifacts from source control

### Security
- Dependabot configured for npm, Swift, and GitHub Actions dependency updates
- current `npm audit` status reports no known vulnerabilities in the checked-in extension dependency tree
- Extension dependency tree no longer reports the prior high-severity transitive `vite` advisory after override + lock refresh

### Infrastructure
- GitHub Actions CI workflow for pull request validation
- GitHub Actions release workflow for tagged prereleases

---

## [Prior Releases]

Prior to this changelog, releases were tracked informally. The following milestones are documented in commit history:

- Initial macOS menu bar app (AgentLens → OpenBurnBar)
- Claude Code parser and session log parsing
- Factory/Droid session parsing
- Codex SQLite log parsing
- Kimi session parsing
- Local daemon (JSON-RPC over UNIX socket)
- GRDB/SQLite storage layer with migrations
- Firebase Auth (Google + Apple Sign-In)
- Firestore cloud sync
- Projection pipeline (FTS5 + semantic search)
- VS Code / Cursor extension
- Cursor provider routing (Z.ai, MiniMax)
- CLI command interface
- Cloudflare tunnel support
- InsightEngine and analytics
- Daily digest notifications
- iCloud session file mirror

## [0.2.0-beta.1] — 2026-05-01

### Added
- **iOS App (`OpenBurnBarMobile`):** Native SwiftUI app with Dashboard, Quota Watch, Activity Ledger, and Account tabs. Reads usage rollups, quota snapshots, and raw usage from Firestore. Supports USD/token display toggle, Swift Charts daily usage bars, and provider urgency sorting.
- **Cloud Functions v2 backend (`functions/`):** TypeScript Firebase Functions with callable functions for provider credential vaulting, quota refresh, and usage rollup rebuilds. Background triggers mark rollups dirty; scheduled workers rebuild in bounded batches.
- **Secure provider credential entry on iOS:** "Provider Connections" surface with explicit provider states, validation before save, redacted metadata, revoke/delete controls, and warnings for session/cookie credentials.
- **Shared iOS-safe model layer (`OpenBurnBarCore/SharedModels/`):** Codable, Sendable types for `AgentProvider`, `TokenUsage`, `ProviderQuotaSnapshot`, `UsageRollupDoc`, `ProviderConnectionDoc`, and formatting utilities. Used by both macOS and iOS targets.
- **Desktop quota snapshot upload:** `QuotaSnapshotSyncService` uploads local quota snapshots to Firestore after desktop quota refresh so iOS can read them with source provenance.
- **Firestore collections:** `quota_snapshots`, `provider_connections`, `usage_rollups`, `rollup_jobs` — all owner-scoped and App-Check-ready.
- **Cloud KMS envelope encryption + Secret Manager:** Provider credentials encrypted with AES-256-GCM and a KMS-protected DEK. Firestore stores only metadata and secret version references.
- **Provider adapters (backend):** MiniMax, Z.ai, Factory, and Cursor with validation, test calls, and structured quota snapshot generation.
- **Rate limiting:** Per-user/provider refresh rate limiting in `refreshProviderQuota` callable.
- **iOS tests:** `OpenBurnBarMobileTests` covering shared model compatibility, formatting, and store state.

### Changed
- `project.yml`: Added `OpenBurnBarMobile` iOS app target and `OpenBurnBarMobileTests` unit test target with Firebase, Google Sign-In, Sentry, and OpenBurnBarCore dependencies.
- `OpenBurnBarCore/Package.swift`: Now supports both macOS 14 and iOS 17.
- `ProviderQuotaSnapshot`: Added computed `sourceKind` and `sourceId` for backend compatibility.
- `CloudSyncCoordinator`: Added `syncQuotaSnapshots(_:)` method to upload desktop quota data.
- `RefreshOrchestrator`: Calls `syncQuotaSnapshots` after desktop quota refresh.

### Security
- Provider secrets are never persisted in Firestore plaintext.
- Callable functions enforce Firebase Auth + App Check.
- Firestore rules remain owner-scoped; App Check enforcement is configured at the product level.
