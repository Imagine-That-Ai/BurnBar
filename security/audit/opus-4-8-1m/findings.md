# Findings — Opus 4.8 1M lane

Commit `60faa70227` · branch `security/run-09-privacy-invariants-hardening` · 2026-06-16.
All findings are code-verified. IDs namespaced `OPUS-F-NNN`. No Critical or High findings were identified on this branch.

Severity legend: Critical / High / Medium / Low / Informational. Status: open / fixed / partially-fixed / accepted-pending-owner / needs-decision / needs-evidence.

---

## OPUS-F-001 — Collaboration / shared-source artifacts written plaintext to Firestore
- **Severity:** Medium · **Status:** open · **Category:** Cryptography / Privacy (TM-006 CloudVault)
- **Affected:** `AgentLens/Services/CloudSync/CollaborationSyncService.swift:1001-1003` (`commitSharedArtifactHead`), `AgentLens/Services/CloudSyncSharedArtifactModels.swift:236-272` (`SharedArtifactCloudCodec.encode`, `:245` keyless `contentHash`); rules `firestore.rules:4412-4419`.
- **Description:** Unlike the six content types the "sealed before Firestore" claim enumerates (chat threads, mobile assistant chats, CLI session mirrors, mission prompts/results/events, text snippets, conversation recall), shared collaboration artifacts write the full file `body` (source content), `title`, and `relativePath` to `workspaces/workspace-{uid}/.../artifacts/{id}` and the full `versions/{revisionID}` history as **raw strings** — the codec contains zero seal calls. A keyless SHA-256 `contentHash` over the plaintext is a confirmation/dedup oracle. Firestore rules enforce owner-scoping + size + the secret-field denylist, but the denylist does not catch a field named `body` carrying source code.
- **Attack path / impact:** Firebase (and anyone with read access to the user's Firestore namespace — backend, support, a future rules regression) can read private source content and titles. The keyless hash lets an observer confirm whether a candidate file matches.
- **Nuance:** The threat model lists "owner-scoped shared-artifact heads/revisions" as **synced data Firestore can read** (it is *not* in the "cannot read sealed" list), so this is a **disclosed** sync surface, not a contradicted claim. It is nonetheless private user content in cleartext in the cloud and likely surprises users who assume parity with the sealed surfaces.
- **Recommendation:** Seal `body`/`title`/`relativePath` with path-bound AAD (mirror `validPathBoundSealedPayloadForUser`), and replace the keyless `contentHash` with a vault-keyed HMAC (mirror the `pensieveDedupHash` pattern). If sealing is deferred, make the UX explicit that shared artifacts are cloud-readable.
- **Acceptance criteria:** artifact write path emits a sealed payload; rules require it; a rules test proves a plaintext `body` write `assertFails`; hash is keyed.
- **Suggested test:** `firestore-rules-tests/shared-artifact-sealed.test.js` (+ Swift writer test asserting no plaintext `body` leaves the device).

## OPUS-F-002 — macOS crash-telemetry scrubber + per-install ID have no unit test
- **Severity:** Medium (test-coverage) · **Status:** open · **Category:** Privacy / Testing (M-014 sibling)
- **Affected:** `AgentLens/.../AgentLensApp.swift:1867,1889-1890` (`MacSentryScrubber`, `MacCrashReportingConsent.perInstallAnonymizedID`); only `OpenBurnBarMobile/.../MobileSentryScrubberTests.swift` exists.
- **Description:** The macOS Sentry scrubber and per-install anonymized-ID logic are pure/testable but asserted only on iOS. The two implementations are parallel, not shared code, so the macOS crash-scrub path can regress silently and ship PII to Sentry.
- **Impact:** A future refactor could leak unscrubbed crash data (paths, identifiers) from macOS clients without any test catching it.
- **Recommendation:** Add `MacSentryScrubberTests` mirroring the iOS cases (PII redaction, install-id non-PII, `sendDefaultPii=false`, consent gate).
- **Acceptance criteria:** macOS scrubber + install-id covered by unit tests run in CI.

## OPUS-F-003 — CloudVault path-bound AAD only partially enforced
- **Severity:** Low-Medium · **Status:** partially-fixed (improved since M-007) · **Category:** Cryptography
- **Affected:** `firestore.rules:944` (comment: surfaces "stay on `validSealedPayloadForUser` until their clients migrate"), enforced path-bound at `:1563` (`conversations`), `:1612` (`mobile_assistant_chats`), `:619` (`session_logs`); global-AAD writers `ChatThreadSyncService.swift` (`chat_threads`), `CLIAgentSessionRecord.swift` (`cli_sessions`), sealed-text surfaces (e.g. `MediaAttachmentManifestStore.swift`).
- **Description:** Seal envelopes bind ciphertext to `uid|collection|docID|field` via AAD. This is now enforced for `conversations`, `mobile_assistant_chats`, and `session_logs`, but other sealed surfaces still use global/legacy AAD, allowing a **same-account** attacker to relocate their own ciphertext between documents undetected.
- **Impact:** Integrity/binding gap; same-account only (the account owner). No cross-user exposure.
- **Recommendation:** Migrate remaining writers to path-bound AAD, then tighten the rules to `validPathBoundSealedPayloadForUser` for each (the migration order is documented in `security-audit/HANDOFF_REMAINING_RISKS_2026-06-14.md` §2).

## OPUS-F-004 — Local SQLite is plaintext at rest (SQLCipher not vendored)
- **Severity:** Low · **Status:** accepted-pending-owner (disclosed non-claim) · **Category:** Cryptography (M-020 area)
- **Affected:** `AgentLens/Services/DataStore/DataStoreCoordinator.swift:216-261`; `CSQLite` module links stock `sqlite3` (no `SQLITE_HAS_CODEC`).
- **Description:** Despite the `GRDB-SQLCipher` package name, the linked SQLite is stock system `libsqlite3`, so `PRAGMA key` is a no-op. The runtime takes a **loud, disclosed** plaintext fallback (`openDisclosedPlaintext`, sets `...PlaintextFallbackAcknowledged`, logs an error) and the `cipher_version` self-check fails closed when encryption is genuinely requested. The on-disk DB at `~/Library/Application Support/OpenBurnBar/OpenBurnBar.sqlite` is therefore readable by any same-user process.
- **Impact:** Same-user/local-filesystem read of cached usage/metadata. Consistent with the unsandboxed local-first threat model; the threat model honestly states this.
- **Recommendation:** To deliver at-rest DB encryption, vendor an actual SQLCipher amalgamation (`SQLITE_HAS_CODEC`). Until then, do not state or imply the local DB is encrypted at rest. (Already honored in docs.)

## OPUS-F-005 — `accountDeletion.ts` logs full UID + storage path via raw `console.warn`
- **Severity:** Low · **Status:** open · **Category:** Privacy / Logging (M-023 sibling)
- **Affected:** `functions/src/accountDeletion.ts:113,156` (uses `options.logger ?? console`, `:98`), bypassing the structured scrubber.
- **Description:** On a secret-destroy or storage-delete failure, the full 28-char UID and `users/${uid}/` storage prefix are written un-truncated to Cloud Logging — the one prod path not routed through `logInfo/logWarn/logError` (which apply `redactUidPaths` + uid truncation). The privacy gate I3 bans the raw `firebase-functions/logger` import but does not catch a bare `console.warn`.
- **Impact:** Full UID lands in logs on an error branch; weakens the "no full UIDs in logs" invariant.
- **Recommendation:** Route through `logWarn` (applies `redactUidPaths` + truncation) or hash the UID before logging. Add this path to the privacy-invariant gate's scan.

## OPUS-F-006 — `buildFcmMessage` push payload ships a stable `thread_id` correlator
- **Severity:** Low · **Status:** open · **Category:** Privacy (M-021)
- **Affected:** `functions/src/agentNotifications.ts:234-272` (`thread_id`, `deep_link` embedding `runtime`+`threadId`, APNs `thread-id`); gate `scripts/ci/check-privacy-invariants.mjs:68` (`PUSH_PAYLOAD_BUILDERS`) covers only the two voip builders.
- **Description:** Invariant I5 strips stable correlators from the two VoIP push builders, but the third sender (`buildFcmMessage`, agent notifications) forwards a stable per-conversation `thread_id` to APNs/FCM (third-party processors). `preview` is correctly forced to a generic value. A `thread_id` is a weaker correlator than the removed `connection_id` but is still cross-session-stable and visible to the push processor.
- **Recommendation:** Add `buildFcmMessage` to the I5 gate with a tuned banned-key list, or document the conscious exception and rotate/opaque the `thread_id` per push.

## OPUS-F-007 — SSRF guard misses IPv4 alt-encodings and DNS rebinding
- **Severity:** Low (latent; unreachable today) · **Status:** open · **Category:** App/API (SSRF, LLM05)
- **Affected:** `functions/src/ssrfGuard.ts:65,76` (`/^\d{1,3}(\.\d{1,3}){3}$/`, no DNS resolution).
- **Description:** `assertOutboundFetchTarget` blocks private ranges only for dotted-decimal literals — not decimal (`2130706433`), octal, hex, or short-form encodings — and does no DNS resolution, so a hostname resolving to `169.254.169.254` (rebinding) passes. **Currently unreachable:** there is no server-side fetch whose host comes from request bodies or user-writable docs (all fetch targets are hardcoded/env-config).
- **Recommendation:** Before wiring any user/config-supplied URL to `resilientFetch` (remote-MCP discovery, webhooks, link-unfurling are anticipated in the guard's own header), resolve DNS and re-check the resolved IP, and parse the host as an integer before range checks — the bar the guard's comment promises.

## OPUS-F-008 — Legacy `/var/run` privileged bridge lane writes login password without client-side server-peer auth
- **Severity:** Low · **Status:** open (mitigated) · **Category:** Desktop / IPC (M-001/M-028 residual)
- **Affected:** `AgentLens/Services/ComputerUse/Mac/RemoteUnlockVirtualHIDInputClient.swift:160-218` (`sendSocket`), password field `:248`.
- **Description:** The preferred XPC/socket lane calls `validateServerPeer` (peer-UID + first-party code-sign) before writing credentials, but the legacy `/var/run/openburnbar-virtual-hid.sock` fallback writes the JSON envelope (which can carry `password`) **without** that check. Mitigated: `/var/run` is root-only-writable (a non-root attacker cannot squat it) and this lane is only reached as a transport-fault fallback.
- **Recommendation:** Add `validateServerPeer` / `getpeereid` before the write in `sendSocket` for symmetry and root-malware defense-in-depth.

## OPUS-F-009 — Executable resolution via login shell (`zsh -lic`) is PATH/dotfile-hijackable
- **Severity:** Low · **Status:** open · **Category:** Desktop / process exec (M-030)
- **Affected:** `AgentLens/.../CLIExecutableResolver.swift:159` (`zsh -lic "command -v -- <name>"`).
- **Description:** Provider names come from a fixed catalog and are single-quote-escaped (no command injection), but a malicious `~/.zshrc`/`~/.zshenv` could shadow the resolved binary. Same-user precondition (attacker already owns the dotfiles); third-fallback after a fixed-directory allowlist.
- **Recommendation:** Prefer the absolute-path allowlist exclusively for the privileged/daemon resolution paths.

## OPUS-F-010 — `RestrictedLogPathValidator` tilde mismatch + no canonicalization
- **Severity:** Low (fail-safe) · **Status:** open · **Category:** Desktop / path handling
- **Affected:** `AgentLens/Services/RestrictedLogPathValidator.swift:14-36`.
- **Description:** `isKnownRoot` expands the candidate with `expandingTildeInPath` but compares `hasPrefix` against still-tilde-prefixed roots, so legitimate custom paths are over-rejected (fail-safe, not fail-open). Separately there is no `..`/`standardizingPath` canonicalization, so a crafted traversal is not normalized — currently unreachable because the validator over-rejects.
- **Recommendation:** Expand both sides (or the roots) before comparison and call `standardizingPath`/`resolvingSymlinksInPath` before the prefix test.

## OPUS-F-011 — Android diff-coverage retains a presence-based fallback path
- **Severity:** Low · **Status:** partially-fixed (CG-1 residual) · **Category:** CI / testing integrity
- **Affected:** `scripts/diff-coverage-android.sh:96-195` (`test_file_presence` / `jacoco_missing_test_presence`).
- **Description:** The Swift coverage gate's presence carve-outs are fully reverted (`scripts/diff-coverage.sh` counts unmeasured lines as uncovered). The Android script still contains presence-based verdict paths, but they are a **local-dev fallback only** — in CI the harness generates JaCoCo first (`openburnbar-pr-harness.yml:223-228`), so the live Android gate uses real line evidence.
- **Recommendation:** Make the Android presence path `exit 1` (fail-closed) outside CI to eliminate the gameable code path entirely.

## OPUS-F-012 — CODEOWNERS lacks explicit rules for security-sensitive trees
- **Severity:** Low · **Status:** open (by-design single-owner) · **Category:** SDLC
- **Affected:** `.github/CODEOWNERS` (relies on default `* @Ajnunezg`).
- **Description:** `functions/src/security/`, crypto paths, billing/entitlements, `scripts/ci/`, `Vendor/libsignal`, `firestore.indexes.json` are owned only via the catch-all, with no path-specific review signal. Solo-operator model is documented (`docs/SOLO_OPERATOR_POLICY.md`).
- **Recommendation:** Add explicit path rules so review routing for those trees is intentional, not incidental.

## OPUS-F-013 — Client-mirrored quota counters allow a ≤1h under-report window
- **Severity:** Low · **Status:** open · **Category:** Billing / abuse
- **Affected:** `firestore.rules:3259` (`media_quota_usage`), `:3231` (`computer_use_quota_usage`); reconcile `functions/src/mediaQuota.ts:139-153` (hourly).
- **Description:** These counters are owner-writable; gating may read the client mirror until the hourly server reconcile (from authoritative `iroh_audit_events`). A client could deflate counters to delay hitting a monthly cap by up to one reconcile interval and one meter. Does not affect entitlement state or the server-only allowance ledger.
- **Recommendation:** Gate the consuming feature on the server-reconciled `billing/allowances` reservation, or shorten the reconcile interval if abuse is observed.

## OPUS-F-014 — Account-deletion root-collection coverage is a static allowlist
- **Severity:** Low (forward-maintenance) · **Status:** open · **Category:** Privacy / governance
- **Affected:** `functions/src/accountDeletion.ts:41` (`ROOT_COLLECTIONS_KEYED_BY_UID = ["voip_outbound","fcm_outbound"]`).
- **Description:** Current coverage is complete for today's schema, but a future root collection keyed by `uid` would silently escape erasure unless added here.
- **Recommendation:** Add a CI test that enumerates root collections writing a `uid` field and asserts each is in the deletion allowlist or explicitly exempted (mirror the BOLA catalog-completeness pattern).

---

## Informational

- **OPUS-F-015 (Info):** Operator (`burnbarOperator`) reads of `ops/**` aggregate metrics have no application-layer audit trail (only Firestore platform logs). `firestore.rules:3244-3254,4431-4440`. No per-user PII exposed.
- **OPUS-F-016 (Info):** GPG checksum signing is best-effort — `release.yml:680-697` skips if `RELEASE_SIGNING_KEY` absent; cosign attestation still covers integrity. Recommend fail-closed/loud-warn.
- **OPUS-F-017 (Info):** `docs/security/LLM_GENAI_AGENT_THREAT_MODEL.md` understates current controls (stale 2-tool allowlist + stale `/Users/.../Windsurf/BurnBar` paths); code is materially stronger (default-deny wrap, deny-regions over signed authority, leaf kill re-check). Refresh the doc.
- **OPUS-F-018 (Info):** Daemon-side T-DMN-04 local-auth-proof verifier is `nil` in production (`OpenBurnBarDaemonMain.swift:80`), a documented deferral pending a pairing-key store; the primary peer code-sign gate + capability attenuation ARE enforced.
- **OPUS-F-019 (Info):** Legacy no-`appAccountToken` Apple S2S fallback attributes via single-owner `originalTransactionID` (`reconciler.ts:428-440`) — safe but worth retiring once all live subs carry a token.
- **OPUS-F-020 (Info):** Mission-event top-level `messageLength`/`messageTruncated` (`CLIAgentMissionEventFactory.swift:30-31`) leak sealed-body byte length; `agent_import_jobs.errorMessage` can embed a local file path (`CLIAgentMissionRequestListener.swift:2880-2888`). Drop/quantize the length; path-strip the import error.

---

## Verified-fixed (disposition updates to prior lineages)

| Prior ID | Item | Evidence |
|---|---|---|
| P0-6 (06-11) | Privileged-input `/tmp` credential capture | Per-uid 0700 dir `PrivilegedInputXPCConstants.swift:16-28`; client server-peer auth `PrivilegedInputXPCClient.swift:237-248`; `LOCAL_PEERTOKEN=0x006` `PrivilegedSocketTrust.swift:87`; launchd `RunAtLoad/KeepAlive` `RemoteUnlockVirtualHIDBridgeInstaller.swift:241-242`. |
| LB-2 (06-11) | Updater integrity | Real Ed25519 verify `DirectDownloadArtifactVerifier.swift:134`; pinned `SUPublicEDKey` `OpenBurnBar-Info.plist:48-49`; SHA-256 `:95-101`; codesign + readonly-mount install. |
| LB-5 (06-11) | Stripe watermark-erase | `entitlements.ts:202-207` preserves `sourceEventID`/`sourceEventCreatedMillis`; same-second tie addressed `:311-327`. |
| M-005 (06-14) | session_logs fail-open | `validSessionLogManifestKeys()` `hasOnly` allowlist wired as first conjunct `firestore.rules:651-660`. |
| M-025 (06-14) | BOLA tests not executing | 16 `*.bola.test.ts` + `bolaCoverage.test.ts` run in `fast-feedback.yml:69`, `openburnbar-pr-harness.yml:129`, `release.yml:214`. |
| CG-1 (06-11) | Coverage-gate gaming | `scripts/diff-coverage.sh` carve-outs reverted; unmeasured lines = uncovered. (Android residual: OPUS-F-011.) |
| — | qa.yml secret exposure | Honest-conclusion exit + narrowed secret scope `qa.yml:91-110,181-211`. |
| — | deploy submodule checkout | `deploy-production.yml:46,68` `submodules: recursive` + re-sync. |
