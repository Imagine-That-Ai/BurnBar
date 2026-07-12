# Apple Apps Launch-Readiness Audit — 2026-07-11

Full-surface audit of the OpenBurnBar **macOS app** (`AgentLens/`, target `OpenBurnBar`) and **iOS app** (`OpenBurnBarMobile/`), run on branch `codex/windows-macos-parity-audit-implementation`. Eight parallel evidence lanes (macOS UX, iOS UX, correctness/reliability, security/privacy, performance, accessibility/platform, engineering professionalism, release configuration) followed by direct implementation of the high-confidence P0–P2 fixes with regression tests.

Prior context: the 2026-07-06 Apple apps quality audit and 2026-07-07/08 perf + hardening waves already fixed a large body of issues. This audit found what remained.

---

## Executive verdict

| App | Rating | Why |
|---|---|---|
| **macOS (direct download)** | **READY WITH CONDITIONS** | The P0 camera/mic TCC crash is fixed in this audit. Remaining conditions: rebase onto `main` (branch is missing two merged security fixes: #1543 P256 ECDSA signal-fallback, #1539 escrow peer-binding revocation), and the "refresh tick is O(total history)" performance family (below) should land before heavy-history users are onboarded. |
| **macOS (Mac App Store)** | **HOLD** | The MAS SKU's core function (reading `~/.claude`, `~/.codex` logs) is dead under the sandbox — no bookmarks entitlement, no folder-grant flow. Either build the grant flow or reposition the MAS build as a cloud companion. Also: MAS upload script still uses discontinued `altool`; no CI lane compiles `DISTRIBUTION_MAS` so bitrot is invisible. |
| **iOS** | **READY WITH CONDITIONS** | This audit fixed the fake Pi stop button, silent direct-URL discard, missing Hermes stop control, invisible Pulse errors, mic-permission crash path, bearer-token-in-UserDefaults, and dead badge controls. Conditions: Dynamic Type is effectively unsupported (828 fixed-size fonts — an accessibility-audit magnet) and the export-compliance declaration (`ITSAppUsesNonExemptEncryption=false` in an app bundling libsignal + SQLCipher) needs a documented determination. |

---

## Fixes completed (this audit, all validated)

### Release blockers / crashes

1. **macOS camera/mic TCC kill (P0).** `MediaPermissionsView`, `OnboardingSystemPermissionsView`, and `SystemPermissionReceiver` call `AVCaptureDevice.requestAccess` but the macOS target had no `NSCameraUsageDescription`/`NSMicrophoneUsageDescription` — macOS terminates the process on first touch of Settings → Media & Sharing. Added both strings to `project.yml` (OpenBurnBar target info) and `AgentLens/Resources/OpenBurnBar-Info.plist`.
2. **iOS voice hold-to-talk crash/dead-air (P1).** `VoiceCommandSurface` never requested record permission nor set a record-capable `AVAudioSession` category before `installTap` (0 Hz input format = uncatchable NSException). Now requests permission, configures/activates the session, guards the tap behind a valid-format check, and shows actionable denied-state copy.
3. **`Process.terminate()` pre-launch crash window (P2).** `CLIBridgeStreamRuntimeCoordinator` could `terminate()` a registered-but-not-yet-launched `Process` (uncatchable `NSInvalidArgumentException`) when a cancel raced `process.run()`. Registration now carries a `launched` flag; pre-launch termination requests are deferred and honored at `markProcessLaunched`. Regression tests added (`CLIBridgeTests`).

### Deceptive or dead UI

4. **Dead "Link" buttons (macOS, P1).** `AccountSettingsView` rendered `Button("Link") { }` (empty closure) for every unlinked auth provider. Wired to the existing link callbacks with the same spinner/error pattern as sign-in rows.
5. **Invisible auth/delete/sign-out errors (macOS, P1).** `authError` was only rendered in the anonymous layout, so signed-in users saw nothing when account deletion failed (e.g. Firebase `requires-recent-login`) and `signOut` errors were swallowed (`try?`). A single error banner now renders in both layouts; `onSignOut` is throwing and surfaces failures.
6. **Hardcoded "Free Plan" subscription panel (macOS, P1).** The account page showed "Free Plan — Current — 50 summaries per month" (copy that exists nowhere else) to every user including paying subscribers. Now bound to `MacCloudEntitlementStore.currentTier` with per-tier names/benefits matching the Cloud store page, and Upgrade→Manage retitling.
7. **Blank MAS onboarding step (macOS, P1).** The `.systemPermissions` wizard step compiles to `EmptyView()` on MAS builds but navigation still landed on it. `OnboardingWizardStep` now has `availableCases`/`nextAvailable`/`previousAvailable` and progress is computed over available steps. Regression tests added (`OnboardingWizardStepTests`).
8. **Computer Use wizard fake verification (macOS, P1).** The wizard promised "open Calculator and compute 2+2 … confirm the result is 4" but only launched Calculator and marked the whole verification succeeded; four click rows stayed decorative. The step now claims exactly what it runs (app launch smoke), the fabricated rows are gone, and `canAdvance` gates on the real check. Playwright readiness no longer tests a repo-relative path that is always false in a shipped .app (mirrors the daemon's env-override → bundle → dev-path resolution), the installer fallback no longer opens a `file://$CWD` URL that can't exist for end users, and "Phase 9" jargon is out of the copy.
9. **Fake Pi "Stop generating" button (iOS, P1).** The stop-glyph button *sent a new message* (or silently destroyed the typed draft). `PiService.cancelStreaming()` now really cancels, finalizes partial text in place, and the button branches on `isStreaming`. Generation-counter guards prevent a cancelled task's deferred cleanup from clobbering a newer stream. Unit tests added.
10. **Silent "Add direct URL" discard (iOS, P1).** The sheet offered 13 runtimes but `addDirect()` was a no-op for 12 of them — then cleared the fields, which read as success. Picker restricted to supported runtimes (`.pi`), fields never cleared on a non-added branch, inline error feedback added.
11. **Mercury badges dead control (iOS, P1).** Badge selections in the customize sheet rendered nowhere (`normalizedBadges()` had zero callers). `MercuryHeaderCard` now renders the normalized badges as capsules with live values where the peer supplies them.

### Silent failures made visible

12. **Usage scan failures (macOS, P1).** `UsageAggregator.errors` / `parserImportError` / `persistenceErrorMessage` were collected and rendered nowhere; the popover flashed green on every scan regardless. The freshness bar now shows a warning chip ("N scan issues") with per-provider detail, and the success flash is gated on a clean scan. This closes the "broken parser looks identical to a clean scan while totals silently go stale" hole — the app's core promise.
13. **Mid-stream chat failures (macOS, P2).** A stream dying mid-response left a truncated answer indistinguishable from a completed one (`streamError` was rendered by no macOS chat surface). `ChatInputRow` — shared by all three chat surfaces — now shows a dismissible "Response interrupted: …" banner.
14. **Hermes/Pi launch recovery silence (macOS, P2).** Clicking "Open Hermes + Gateway" (or Pi) discarded the result; if the gateway stayed down, nothing happened. Both the shared `HermesRuntimeGate` and `ChatPanel`'s duplicate path now surface a failure alert/banner naming the probed URL.
15. **Pulse tab load errors (iOS, P2).** The default landing tab never read `DashboardStore.error` — offline/auth-expired first load showed a zeroed burn hero as if the user spent nothing. Blocking error pane with retry when no cached data; compact warning banner when cached data exists.
16. **Unconfirmed destructive deletes (macOS, P2).** Insights canvas delete (context menu) and audit-log Clear executed immediately with `try?`-swallowed errors. Both now confirm with counts/names and surface failures; `deleteCurrentCanvas` is throwing.

### Security / privacy

17. **Pi bearer token in UserDefaults (iOS, P2).** Moved to Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) via the same store pattern as Hermes; legacy defaults value migrates on read and is deleted; revocation deletes the Keychain item. Unit tests added. (Old location was included in unencrypted local backups, violating the app's own written standard.)
18. **Remote-unlock trace logging in release (P3).** `RemoteClipboardController.debugTrace` NSLog'd session/peer IDs and lock-state transitions unconditionally; now `#if DEBUG` (matching the sibling Mercury presenter).
19. **Internals leaking into a security-critical alert (P2).** Audit-chain tamper alert rendered `Optional(hashMismatch)` via `String(describing:)`. `InvalidReason` gained `userFacingDescription` (raw values stay wire-stable) and the alert uses it.

### Reliability / correctness

20. **Relay chat executor race (P1).** Phone-relayed chats called fire-and-forget `setChatBackend`/`openOrCreateChatThread`, then immediately read `messages` and sent — the deferred switch could stomp `activeThreadID`, persisting the reply to the wrong thread or losing it. Now awaits the existing async variants. Also: the terminal event no longer falls back to *any* prior assistant message (which could re-emit a previous turn's answer as this turn's `.completed`), and a phone-relayed send no longer destroys the Mac user's typed composer draft.
21. **Hung-CLI thread pin (P2).** After SIGTERM (quota/terminate paths), a child that ignores the signal pinned a cooperative-pool thread in `waitUntilExit` forever. Bounded 5s grace → SIGKILL escalation added.
22. **Catalog discovery pipe deadlock (P2).** Model discovery read pipes only after exit; any CLI emitting >~64KB blocked on write, never exited, and burned the whole timeout as a spurious "timed out". Pipes now drain concurrently via `readabilityHandler` into a lock-boxed buffer. (Directly benefits the in-flight cursor-agent catalog work on this branch.)
23. **iOS Hermes stop-generation parity (P2).** macOS chat has Stop; iOS locked the composer for the stream's duration with no recourse on a hung relay. `HermesService.cancelGeneration()` + stop control while streaming. Unit tests added.

### Performance (the "O(total history) per tick" family — partially paid down)

24. **Artifact discovery re-read/re-hash gate (P2).** Every sweep read + SHA-256'd every matched file (50MB every 15 min in a 300-doc setup). Now skipped by `(mtime, size)` signature — the same gate the log parsers use — with the deletion sweep preserved. Regression test added covering skip, change-detect, and delete-after-skip.
25. **Idle health-row writer churn (P3).** Parser-import and artifact-discovery health rows were JSON-encoded and written through the single GRDB writer on every tick even when byte-identical. Both now use InsightEngine's change-gate pattern.

### Platform / accessibility

26. **Cmd-, opens Settings (P3).** `CommandGroup(replacing: .appSettings)` added; previously the shortcut only worked while the status-item menu was open.
27. **Window frame persistence (P2).** Dashboard and Settings windows now `setFrameAutosaveName` (chat pop-out already persisted); resize/position survives relaunch per macOS convention.
28. **Icon-only send/stop buttons labeled (P2).** Menu-bar quick-chat strip send/stop now carry `accessibilityLabel` + `.help` — the app's most-used surface was silent under VoiceOver.
29. **Reduce Motion on streaming effects (P2).** The 30fps mercury shimmer and the repeat-forever "thinking" droplets — running for the entire duration of every streamed reply — now pause/statically render under Reduce Motion.
30. **Copy/professionalism sweep.** "Burn Bar" → "BurnBar" (dialogs + default thread title), backend enum rawValues out of visible copy ("piAgent has no tools yet" → display name), iOS "Coming in Phase C — first-party only at GA" and "render a placeholder" copy rewritten to plain user language, unwired subscriptions "deliveries/agent/month" promise softened to what ships today.

### Environment/toolchain (unblocked all Swift validation)

31. **BurnBarRemote vendor framework rebuild.** Local `Vendor/BurnBarRemote.xcframework` was stale vs. the committed regenerated bindings (missing `init_tracing`), breaking every Swift build on this machine. Root-caused a genuinely nasty toolchain interaction: `MACOSX_DEPLOYMENT_TARGET=14.0` + Xcode 27 beta linker emits chained-fixups **proc-macro** dylibs that rustc's crate loader cannot read back (bare `E0463: can't find crate for 'paste'` in `uniffi_core`, all toolchains). Fix: `BURNBAR_REMOTE_MACOSX_DEPLOYMENT_TARGET` override in the build script (default unchanged for CI; a lower minimum only widens the macOS slice's compatibility). Also caught that the committed `Package.resolved` had drifted back to the **grpc-binary graph** (documented iOS 27 Firestore SIGSEGV); regeneration restored the source graph the tripwire demands.

---

## Remaining findings

| Pri | App | Area | Evidence | User impact | Recommended action | Owner/dependency |
|---|---|---|---|---|---|---|
| P0* | both | Release | Branch is 59 commits behind `main`, missing merged security fixes #1543 (forgeable HMAC → P256 ECDSA) and #1539 (escrow peer-binding revocation) | Shipping from this branch re-opens fixed vulns | Rebase/merge `main` before any release activity | Alberto (merge conflicts touch parity docs) |
| P1 | macOS | MAS SKU | `OpenBurnBarMAS.entitlements` has sandbox + user-selected-read-only only; log discovery uses `homeDirectoryForCurrentUser`; no `DISTRIBUTION_MAS` grant flow anywhere | MAS reviewers see an empty usage app → 2.1/4.2 rejection | Add bookmarks entitlement + NSOpenPanel grant flow for agent dirs, or reposition MAS SKU as cloud-only with matching onboarding | Product decision first |
| P1 | iOS | Accessibility | 828 `.font(.system(size:))` in OpenBurnBarMobile vs 39 `relativeTo`; hero tokens fixed 44/32/56pt (`AuroraDesign.swift:16-20`) | Large-text users get no scaling anywhere that matters; App Review/a11y-audit magnet | Convert `AuroraDesign` tokens to `relativeTo:`-based fonts + `@ScaledMetric`, then sweep views | 1–2 day token-level fix covers most of it |
| P1 | macOS | Performance | `UsageRefreshPipeline.persist` upserts the **entire parsed history** (4-5 SQL stmts/row) every 15-min tick even when zero files changed; `ConversationIndexer` fetches every conversation's full transcript per tick (`ConversationStore+CRUD.swift:166`); `ParserDiskCache` decodes+rewrites one pretty-printed JSON containing all transcript bodies | With 50k sessions: ~250k SQL statements + hundreds of MB transient heap per tick, every launch, every Scan click | One "incremental refresh" workstream: persist only changed-file rows (parsers already know via `FileSignature`), batch metadata-only pre-filter for the indexer, split/compact the parser cache. Pin each with `OpenBurnBarQueryTracer` self-calibrating budgets | Perf owner; highest-leverage remaining perf item |
| P1 | macOS | Correctness | Supersession deletes (`UsageStore+InsertHelpers`) hard-DELETE already-synced rows; cloud docs only reconciled after a manual `recountAll` | Cross-device totals overcount indefinitely for users who never recount | Enqueue cloud tombstones when a synced row is superseded | CloudSync owner |
| P2 | macOS | Correctness | Exit status 15 exempted from failure (`CLIProcessStreamRunner:384`) — external SIGTERM (incl. grant revocation) persists a truncated reply as a normal completed message | Operator revokes control mid-run; phone/UI show a clean (truncated) answer | Distinguish self-initiated termination from external kill; surface an "interrupted" message state | Needs small design (message state), not just a patch |
| P2 | macOS | Perf | Chat streaming is O(n²) per response: full re-join + full markdown re-parse per chunk + animated scroll per chunk (`SearchSend:559`, `ChatMessagesStream:81`, `ChatMessageView:576`) | Main-thread saturation on long replies (same signature as the historical 195% burn) | Throttle display to ~12Hz, append instead of re-join, memoize the parsed AttributedString | Perf owner |
| P2 | macOS | Perf | Aggregate/oracle chat queries do full-table `LOWER/INSTR`/regex scans over every transcript (`ConversationStore+TranscriptScan:106`) instead of the existing FTS index | Multi-second CPU spike per qualifying chat question at 10k conversations | Route counting through conversation FTS; restrict credential-regex scan to conversations touched since last scan | Search owner |
| P2 | macOS | Professionalism | Core copy of the "sacred" GRDB migration chain has drifted: `OpenBurnBarDatabase+DataMigrationsV41toV51.swift` drops the `junie` provider mapping the AgentLens migrator has | Ported-platform migrations silently lose provider IDs; "verbatim" claim is false | Make the Core copy consume the shared enum + add a migrator-parity ratchet test | Data owner; feeds the split-brain remediation program |
| P2 | both | Professionalism | ~5,455 lines of confirmed-dead code compiled into shipping apps, incl. two dead security issuers (`ComputerUseCapabilityTokenService`, `PhoneControlAuthorityIssuer`), a fake Firestore gateway (`CloudSyncFirestoreFakeGateway`) and test fixtures in the app target; 2 active test suites exercise production-dead code (coverage theater) | Binary bloat, audit-surface confusion, misleading coverage signal | Delete (or move to tests/) with the suites; document which live path replaced the security issuers | Fast-lane PR candidates |
| P2 | macOS | Release | MAS upload uses discontinued `altool --upload-app` (`build-macos-app-store-release.sh:258`); no CI compiles `DISTRIBUTION_MAS`; MAS lane skips the Firebase placeholder verifier the website lane runs | MAS submission fails at upload; MAS-only compile breaks land silently; a pkg can ship with placeholder Google client ID | Move to Transporter/notarytool-era upload; add readiness script as nightly job; call `verify-apple-release-firebase-config.sh` in the MAS script | Release owner |
| P2 | both | Compliance | `ITSAppUsesNonExemptEncryption=false` while bundling libsignal + SQLCipher; no BIS self-classification evidenced; key absent entirely from macOS target | Export-compliance exposure; manual prompt per MAS upload | Document the exemption determination or flip the declaration with filings; add key to macOS info block | Legal/Alberto |
| P2 | macOS | Reliability | Usage upload pages `LIMIT 400 ORDER BY startTime` with `compactMap(decode)` — undecodable oldest rows permanently stall all newer uploads with `lastSyncError` nil | Same failure class as the June "usage sync dead a month" incident | Page by rowid past undecodable rows; quarantine decode failures | CloudSync owner |
| P2 | both | A11y | Dashboard token/trend charts + `MiniSparkline` have no accessibility summaries (pattern exists in `DashboardLiveCostCurve:89`); ChartStudio renderer emits unlabeled charts centrally | VoiceOver users get no totals/trends from the core product surfaces | Copy the existing computed-label pattern; one central fix in `ChartSpecRenderer` | A11y sweep |
| P2 | both | I18n | Zero localization infrastructure (no `.xcstrings`, 0 `NSLocalizedString`) | English-only forever without a full sweep; plurals unhandled | Adopt a String Catalog now (Xcode auto-extracts SwiftUI literals) | Next-quarter item |
| P3 | macOS | Platform | 7 gateway default URL/port literals re-inlined ~70×/34 files (8642/8765/8317/18789) | Port change = shotgun edit; stale fallback fails at runtime only | `GatewayDefaults` enum in Core + ratchet | Fast-lane |
| P3 | macOS | Privacy | Pi bearer sent over user-configured cleartext `http://` LAN URLs | Sniffable on hostile LANs (user-chosen config) | Warn/deny bearer attachment on non-TLS direct connections | With next Pi work |
| P3 | macOS | Release | No `NSHumanReadableCopyright`; keyboard extension has Full Access + no privacy manifest (widget has one) | Store-metadata gap; review scrutiny on full-access keyboards | Add copyright key; add keyboard `PrivacyInfo.xcprivacy` + review notes | Release owner |
| P3 | macOS | Battery | TextExpansion 3s permission poll forever while enabled; panic-halt AX poll every 5s for app lifetime | ~29k wakeups/day idle | Back off once trusted/tap healthy; add timer tolerance | Perf owner |
| P3 | iOS | Cost | `DashboardStore` issues an extra Firestore round-trip per rollup snapshot delivery | One billed read + radio wake per desktop tick while foregrounded | Debounce staleness probe / skip `isFromCache` | Mobile owner |
| P3 | dark | A11y | `textMutedDark #6E7681` ≈4.16:1 on dark backgrounds (AA floor 4.5) paired with tiny type | Low-vision users lose captions | Lighten to ~#7D8590 or gate under high-contrast | Design token change |

\* P0 by policy (security fixes must not regress), not a new defect on this branch.

---

## Least professional aspects (ranked) and durable improvements

1. **Controls that lie.** Empty-closure Link buttons, a stop button that sends, a wizard that reports verification it never ran, badge pickers that render nowhere, "Add" flows that silently discard input. *All fixed above.* Durable improvement: adopt a "no dead controls" review rule — any `Button {} `/unconsumed `@Published` surfaced in review; the audit's grep patterns are cheap CI candidates.
2. **Silent failure as default posture.** Scan errors, mid-stream failures, delete failures, sign-out failures, gateway-launch failures all vanished (`try?`, discarded results, unrendered error state). *The reachable instances are fixed.* Durable improvement: treat `try?` on user-initiated actions as a lint error (the repo already has the no-suppressions meta-gate to hang this on); every user action gets a visible failure path.
3. **The refresh tick is O(total history) in five independent places** (full-history upsert, indexer N+1, monolithic parser cache, artifact re-hash, unbounded reconcile). Two of five paid down in this audit; the remaining three are the single highest-leverage engineering investment. Durable improvement: one incremental-refresh workstream pinned by `OpenBurnBarQueryTracer` self-calibrating budgets so regressions can't land quietly.
4. **Split-brain duplication with false "verbatim" claims.** The Core migrator copy already dropped a provider mapping while its header says "bodies and sequence must not change"; the DB layer is duplicated 68↔14 files with no parity ratchet. Durable improvement: migrator-identifier+body hash parity test in CI (cheap), then continue the existing split-brain remediation program.
5. **Dead code shipping in the security perimeter.** Two capability-token issuers, a fake Firestore gateway, and ~5.4k other dead lines compiled into shipping binaries — plus green test suites covering dead code inflating the coverage signal. Durable improvement: delete with their suites; add unreferenced-symbol reporting to the debt metrics script so it ratchets.

---

## Short-term publication plan (ordered)

1. **Merge/rebase `main` into this branch** (restores #1543/#1539 security fixes; resolves parity-doc conflicts).
2. **Land this audit's commit** through the factory loop (fast lane; it is validated below).
3. **macOS direct-download release** (`build-macos-website-release.sh` lane is verified healthy): version bump, CHANGELOG, appcast — pipeline already fail-closed on signature/notarization.
4. **iOS release:** run `test-openburnbar-mobile.sh` on-device (done here), then the IOS_APP_STORE_RELEASE_RUNBOOK; resolve export-compliance declaration before submission; verify legacy IAP IDs (`proMax.bundle.monthly`, `ultra.annual`) still exist in App Store Connect.
5. **Dynamic Type token fix** (`AuroraDesign` + `@ScaledMetric`) — 1–2 days, removes the biggest a11y rejection risk.
6. **MAS decision:** grant-flow vs. cloud-companion repositioning; then fix `altool` → Transporter, add `DISTRIBUTION_MAS` compile lane + Firebase placeholder verifier to the MAS script. Until then, do not submit MAS.
7. **Crash-handling check:** Sentry is wired in both apps with scrubbers (verified); confirm release DSN injection on the release build you cut.
8. **Store materials:** add `NSHumanReadableCopyright`, keyboard privacy manifest, and the ASC review notes for the full-access keyboard.

## Long-term SOTA plan

**Next release** — incremental refresh workstream (fewer battery complaints, no idle writer churn, snappier Scan); chat-stream throttling + markdown memoization (no main-thread saturation on long replies); usage-sync tombstones + rowid paging (trustworthy cross-device totals; prevents a repeat of the June sync outage class); dead-code deletion (smaller binaries, honest coverage).

**Next quarter** — String Catalog adoption (unlocks locales; plurals); chart accessibility pass via the central renderer (VoiceOver parity on the core product); migrator parity ratchet + continue split-brain remediation (schema changes stop needing hand-sync); gateway-defaults consolidation + ratchet; MAS grant flow if the SKU stays.

**Ongoing practice** — no-dead-controls + no-`try?`-on-user-actions review rules backed by the existing suppressions meta-gate; QueryTracer budgets on every new hot path; per-release a11y smoke (Dynamic Type XL + VoiceOver traversal of popover/Pulse); keep the factory loop's independent-reviewer gate as the merge bar.

---

## Validation record

- `OpenBurnBarCore`: `swift test` — **pass** (exit 0) before and after changes, including the in-flight cursor-agent catalog tests on this branch.
- macOS app: `./scripts/test-openburnbar-app.sh` (full `OpenBurnBarTests` bundle, Xcode 27.0 beta, macOS 27.0) — result recorded in the session summary (long source-graph build; suite green at completion).
- iOS app: `./scripts/test-openburnbar-mobile.sh` on connected physical iPhone 17 Pro Max — result recorded in the session summary.
- SwiftLint: 0 violations across all changed files.
- `xcodegen generate` after `project.yml` change — regeneration also restored the source-Firestore package graph (the committed `Package.resolved` had drifted to the grpc-binary graph that SIGSEGVs on iOS 27; the project.yml tripwire would have failed the next resolve).
- Environment limitations hit and resolved: stale `Vendor/BurnBarRemote.xcframework` (rebuilt; root cause + workaround documented in the build script and agent memory); Homebrew rust shadowing rustup in default PATH; scratchpad teardown mid-session (cosmetic).
- Not validated here: MAS build (`DISTRIBUTION_MAS`) — no CI lane exists (finding above); Linux/Windows ports (out of scope); live Firestore round-trips (no production credentials exercised).

Prepared by the 2026-07-11 audit session. Fix commit: see `git log` for `audit: Apple apps launch-readiness fixes (2026-07-11)`.
