# BurnBar Master Remediation Plan — B+ → Frontier-Grade-For-Its-Size

**Owner:** Lead engineer / autonomous agent crew · **Date:** 2026-06-02 · **Scope:** correctness, security honesty, transport proof, backend resilience, data integrity, AI/retrieval, multi-platform modernization. Derived from a verified architecture review; every claim below was re-checked against the live tree (e.g. Android `DataDomains.kt:43` still emits `END_TO_END` for `conversations_chat`; `OpenBurnBarDatabase.swift:16` hardcodes `v45` while the real last migration is `v46_drain_target_per_provider` at line 1565; `retryStuckVoIPPushes` exists only as a TODO comment at `apnsSender.ts:227`).

> Status note (2026-06-03): the `conversations_chat` honesty item below is
> historical. The follow-up hardening pass sealed `chat_threads`,
> `mobile_assistant_chats`, `cli_sessions`, `cli_agent_mission_requests`,
> `text_snippets`, and `conversations` private fields at rest, restored the
> registry tier to `end_to_end`, and added static/scrub tooling. Treat the
> remaining references to `SERVER_READABLE` as the pre-hardening plan state, not
> the current implementation.

---

## 1. Executive summary

**Goal.** Move BurnBar from "solid B+ that mostly works" to **frontier-grade for a solo/early-commercial product**: every public security claim is provably true, no silent data-loss path exists, the P2P transport is measured not asserted, the backend survives a data-loss or availability incident with rehearsed recovery, and the AI stack actually recalls what it stored. This is *not* a hyperscaler wishlist — it is the minimum bar to defensibly charge money and sleep at night, plus a deferred depth track that unlocks on growth triggers.

**Shape of the work.** Three phases:
- **Phase 0 — correctness & honesty (this week):** three small, contained fixes that close an active user-facing lie (Android "end-to-end encrypted" chat that the server can read) and a latent data-loss bug (backup gate skipped on the newest schema). Hours-to-days, no cross-platform coordination.
- **Phase 1 — production-grade before GA (2–4 weeks):** the items that gate calling this commercially production-ready — security teeth + claim honesty, iroh transport proof, backend resilience (PITR/backup, tracing, cold-start, fast rollback), and data-layer safety (delete propagation, encryption-at-rest default-on).
- **Phase 2 — SOTA depth (post-GA, scale-triggered):** real embedder + MCP spec compliance + eval harness, Android M3/Hilt/KSP + Swift 6, multi-region, Terraform ops plane, conflict convergence, second relay vendor. Each gated by an explicit trigger so nothing is built before it earns its keep.

**The single most important sequencing principle: *measure / make-honest first, then fix, then modernize.*** Land the honesty + measurement scaffolding (drift CI gate, the iroh `connType` label, the eval harness, the audit truncation detector) *before* the deep fixes, because (a) a fix you can't measure is a fix you can't trust, and (b) the launch-blocking exposure is the **oversold claim**, not the missing crypto. You can ship with "geometry leakage is an accepted, documented limitation"; you cannot ship "end-to-end encrypted" over a server-readable mirror.

---

## 2. Phase 0 — correctness & honesty (this week)

Three items. Do **0-C first** (one Swift file + one test, highest-severity latent data loss, lands in an hour). **0-A** next (produces the corrected Android files + the mechanism). **0-B last** (the CI gate runs 0-A's task in `--check` mode, so it must follow). 0-A and 0-C are independent and parallelizable; 0-B strictly follows 0-A.

### 0-C — Migration-backup gate keyed to a stale identifier *(do first)*
**What.** `OpenBurnBarDatabase.swift:16` hardcodes `latestMigrationIdentifier = "v45_conversation_working_directory"`, but the real last registered migration is `v46_drain_target_per_provider` (`registerMigration` at line 1565). `needsBackupBeforeMigration()` (lines 116–138) returns `false` when `grdb_migrations` already contains the hardcoded id — so a DB at v45 upgrading to **v46 skips the integrity_check and the backup entirely**. Any data-destructive step in v46+ runs with no safety net, and this silently re-breaks on every future migration.
**Fix.** Replace the stored constant with a computed property derived from the migrator: `private static var latestMigrationIdentifier: String { migrator.migrations.last ?? "" }` (GRDB exposes `DatabaseMigrator.migrations` as an ordered `[String]`; `Self.migrator` is the static var already at line 240). Optionally tighten the gate to "backup if not at the latest registered migration" via `Self.migrator.hasCompletedMigrations(db)` (self-heals for every future migration).
**Files.** `AgentLens/Services/DataStore/OpenBurnBarDatabase.swift` (line 16 + 116–138); `AgentLensTests/Active/OpenBurnBarDatabaseMigrationTests.swift`.
**Effort.** S (≈1 hr).
**Verification.** Add `test_latestMigrationIdentifier_equalsLastRegisteredMigration` (assert `migrator.migrations.last == "v46_drain_target_per_provider"`) and `test_runMigrationsSafely_createsBackup_whenUpgradingV45toV46` (stamp `grdb_migrations` v1..v45, run `runMigrationsSafely()`, assert a `.backup.*` file exists — fails on current code, passes after). Existing "skips backup when current" tests must still pass against a v46 DB. `xcodebuild test` green.

### 0-A — Android false E2E label + stale hand-edited generated file
**What.** `android/app/src/main/java/com/openburnbar/data/domains/DataDomains.kt:43` is stamped `GENERATED-DO-NOT-EDIT` but hand-diverged: it labels `conversations_chat` as **`END_TO_END`** while the registry and `packages/data-domains/gen/DataDomains.kt:43` correctly say **`SERVER_READABLE`** with an explicit honesty NOTE that the server can read the `mobile_assistant_chats` / `cli_sessions` mirror (verified: `diff` exits 1). It is also missing `account_recovery_methods` in `device_trust_keys.firestorePaths`. **The Android Privacy Control Center is actively telling users their chats are end-to-end encrypted when they are not.** Apple consumes gen output directly via `project.yml` source paths; Android hand-copies — which is exactly how this drift happened.
**Fix.** Stop hand-editing. (a) `node packages/data-domains/codegen.mjs` to (re)emit gen. (b) Copy `gen/DataDomains.kt` → the Android path and `dist/compose/PensieveTokens.kt` → `android/.../ui/tokens/PensieveTokens.kt` (package decls already match — byte-for-byte copy, no rewriting). (c) Add a `syncGeneratedSources` Gradle task in `android/app/build.gradle.kts` doing both copies from `rootProject ../packages`, wired as `tasks.named("preBuild").dependsOn("syncGeneratedSources")` so a fresh build always pulls latest gen — mirroring Apple's `project.yml` mechanism. Commit the regenerated files in the same PR.
**Files.** `android/app/src/main/java/com/openburnbar/data/domains/DataDomains.kt`, `android/.../ui/tokens/PensieveTokens.kt`, `android/app/build.gradle.kts`.
**Effort.** M.
**Verification.** `diff packages/data-domains/gen/DataDomains.kt android/.../DataDomains.kt` exits 0; `grep` shows `conversations_chat` → `SERVER_READABLE`; `./gradlew :app:syncGeneratedSources` then `git status --porcelain android/` is empty (idempotent); the Android Privacy Control Center renders the server-readable badge + honesty note, not an E2EE badge.

### 0-B — Codegen→Android CI drift gate *(follows 0-A)*
**What.** `registry.test.mjs:41` only asserts gen matches the registry; nothing compares the in-tree Android copies. `driftcheck.mjs` only checks `firestore.rules` coverage. So a future registry edit regenerates gen and passes CI while the Android labels stay stale. The drift must be caught by **CI, not a human reviewer.**
**Fix.** (a) Extend `registry.test.mjs` with a test reading the Android in-tree `DataDomains.kt` and asserting equality to `generateAll(registry)['gen/DataDomains.kt']` byte-for-byte, failing with "android DataDomains.kt is stale — run ./gradlew :app:syncGeneratedSources"; add the analogous `PensieveTokens.kt` check in `design-tokens/tokens.test.mjs`. (b) In `.github/workflows/fast-feedback.yml` control-center-foundations job, after the existing codegen+driftcheck+test step, add `git diff --exit-code` over the two Android files (catches manual edits that bypass the test). Update `codegen.mjs`'s banner to state Android is consumed via the Gradle task.
**Files.** `packages/data-domains/registry.test.mjs`, `packages/design-tokens/tokens.test.mjs`, `.github/workflows/fast-feedback.yml`, `packages/data-domains/codegen.mjs` (doc comment).
**Effort.** S.
**Verification.** With 0-A committed, `node --test` passes including the new android-drift tests. Sabotage check: revert the Android tier to `END_TO_END`, re-run → FAILS with the stale message; the `git diff --exit-code` CI step also fails. Throwaway PR that edits `registry.json` without regenerating Android → CI goes red.

---

## 3. Phase 1 — production-grade before GA

**Ordered by risk-reduction-per-effort.** Wave A = cheap, high-impact, no cross-platform coordination (ship in days). Wave B = the medium fixes that make claims true and data safe. Wave C = the few large items that genuinely gate GA. Run the four sub-tracks (security, transport, backend, data) largely in parallel — they touch different code — but respect the within-track sequencing.

### Wave A — cheap + critical, ship immediately (days, all S/M)

| ID | Item | Effort | Why first |
|----|------|--------|-----------|
| **A1** | **Gateway per-launch token** — `GatewaySettings.gatewayAuthToken` defaults to `""` (verified line 23) and `validationError` only requires a token when binding non-loopback. Any same-host process can POST `127.0.0.1:8317/v1/chat/completions` and spend the user's provider credits with zero auth. Auto-generate a per-launch bearer token, persist to keychain (reuse `controllerRuntimeSecrets`/`OpenBurnBarIdentity.gatewayAuthTokenAccount`), set `OPENBURNBAR_GATEWAY_AUTH_TOKEN` env var in the launch plist, have CLIBridge gateway clients send `Authorization: Bearer`, and make `validationError` fail-closed on loopback unless an explicit `allowUnauthenticatedLoopback` opt-in. *Files:* `OpenBurnBarDaemonManager+Lifecycle.swift`, `OpenBurnBarDaemonConfiguration.swift`, `OpenBurnBarHTTPGatewayServer.swift`, `GatewaySettings.swift`, `OpenAICompatibleChatGatewayClient.swift`, `DaemonSettingsView.swift`. *Verify:* curl without auth → 401, with keychain token → 200, token absent from `ps auxww`. | M | Self-contained, highest value/effort, reuses proven socket-token infra |
| **A2** | **VoIP retry sweeper** — `retryStuckVoIPPushes` is a TODO comment (`apnsSender.ts:227`), so `voip_outbound` docs stuck `pending` after a transient APNs blip are never re-sent → remote VoIP wake (entry point to iroh media/call sessions) silently never fires. Implement as a `onSchedule` gen2 function (1-min), query `collectionGroup('voip_outbound')` where `status=='pending' && retryAt<=now`, re-push via existing `pushToAPNs` (apns-id=docId gives Apple-side idempotency), exponential backoff, seal `rejected` after MAX_ATTEMPTS. Add `(status, retryAt)` collectionGroup index. *Files:* `functions/src/apnsSender.ts`, `index.ts`, `firestore.indexes.json`, `functions/src/__tests__/`. *Verify:* due doc re-pushed within one tick → `sent`; over-MAX → `rejected`. | M | Functions-only, no deps, durability win today |
| **A3** | **iOS selected-model integrity (fallback parity)** — Android `HermesCompositeRelayTransport.kt:49` refuses Firestore fallback for streaming `CHAT_COMPLETIONS` (won't silently reroute the user's selected model); iOS falls back for **all** streaming ops unless `stopsRelayFallback`, which covers only model-binding errors + relayTimeout, not a generic iroh dial failure. So an iroh NAT failure mid-chat silently reroutes the selected model over Firestore on iOS while Android hard-fails. Add `allowsFirestoreFallback(for:)` consulted in `sendUnary`/`sendStreaming`; for `.chatCompletions` rethrow rather than fall back, mirroring the Kotlin message. *Files:* `OpenBurnBarMobile/Services/HermesService.swift`, mobile tests, (cross-ref) `HermesCompositeRelayTransport.kt`. *Verify:* iOS XCTest — stub iroh throws for chatCompletions → composite rethrows; unary control-plane payload still falls back. | M | Swift-only; must land before the soak so the soak measures genuine iroh outcomes |
| **A4** | **Cold-start mitigation** — zero `minInstances` anywhere; hot revenue paths (`stripeBurnBarProWebhook`, `appStoreServerNotificationsV2`, checkout, provider connect, hermes gateway, cliLink) pay full cold start on first request → webhook timeouts/retries at launch. Add `HOT_PATH_OPTIONS { minInstances: 1, concurrency: 40 }` (env-overridable via `HOT_MIN_INSTANCES`) on a curated allowlist; leave scheduled rollups at 0. *Files:* `runtimeOptions.ts` (see B-backend), `callables/stripe.ts`, `appstore/notifications.ts`, `appstore/callable.ts`, `callables/providerAccounts.ts`, `callables/cliLink.ts`, `docs/runbooks/slos.md`. *Verify:* `gcloud run services describe` shows `minScale>=1`; post-idle request is warm-path. | S | Best built on B-backend's `runtimeOptions.ts`; tiny effort, prevents launch-day webhook failures |
| **A5** | **Fast revision-pin rollback** — `scripts/rollback.sh` does git checkout + full rebuild + monolithic `firebase deploy` (interactive), MTTR tens of minutes. Add `scripts/ops/rollback-revision.sh` that does `gcloud run services update-traffic <svc> --to-revisions=<prev>=100` (Gen2 functions are Cloud Run services) → sub-minute flip, no rebuild. Add `--yes` non-interactive mode to the old script; relabel it "full source rollback (slow)". *Files:* `scripts/ops/rollback-revision.sh`, `scripts/rollback.sh`, `deploy-production.yml`, `docs/runbooks/rollback-automation.md`. *Verify:* deploy v2, pin to v1 in <60s, health check 200. | M | No architectural change; converts MTTR from minutes to seconds |

### Wave B — make claims true & data safe (1–2 weeks)

**Security honesty (do honesty-first, then teeth):**
- **B-SEC-1 — Cloak claim honesty + leakage one-pager** *(M, no deps, do now).* `docs/PENSIEVE.md:85-93` + the Swift/TS cloak docstrings sell the orthonormal Householder cloak as an "embedding-inversion defense." It is exactly orthonormal, so `<Qx,Qy>=<x,y>` — a server holding cloaked vectors computes the full pairwise cosine matrix without the key (dedup, clustering, k-NN graph). Rewrite the claim to proven properties only (hides the public-model basis from off-the-shelf inversion; per-user Q defeats cross-tenant correlation — a *real* win; does **not** hide relative geometry). Ship `docs/pensieve-leakage-analysis.md`. *Verify:* Vitest proving `cosine(raw_a,raw_b)==cosine(cloak_a,cloak_b)` within 1e-9 (the proof the claim is rewritten around) + cross-user cloak of the same vector → cosine ~0; `grep "inversion defense"` returns zero. *Files:* `docs/PENSIEVE.md`, `docs/pensieve-leakage-analysis.md`, `tools/openburnbar-mcp-remote/src/embed.ts`, `OpenBurnBarCore/.../PensieveVectorCloak.swift`.
- **B-SEC-2 — Plaintext metadata side channels** *(M, depends on B-SEC-1 decision).* `knowledgeMemory.ts` writes per-vector cleartext `contentHash` (SHA-256 of plaintext → confirm-guessed-plaintext), `sourcePath` (real repo file paths), `sourceSlug`. Replace `contentHash` with a vault-keyed HMAC (`dedupHash`, HKDF), drop the cleartext `sourcePath` column (already in `sealedMetadata`), store `HMAC(slug)` as the filter key. Document `sourceKind`/`byteCount` as accepted leakage. Needs a `contentHashVersion` migration coordinated with the ingestion owner. *Verify:* two users committing the same plaintext produce different stored hashes; harness dump asserts no field equals the known plaintext SHA-256 or contains a cleartext path.
- **B-SEC-3 — Audit log fail-closed + truncation detection** *(L).* `appendAuditEvent` (`auditLog.ts:89-118`) is best-effort and every caller swallows the error — a server can suppress events at will; the SHA-256 chain is tamper-evident but freely truncatable. Split into `appendAuditEventRequired` (no try/catch — action refused if the write fails) for `data.export` / `access.revoke_all` / `recovery.confirm`; add a transactional `audit_meta/head {maxSeq,headHash}` so a tail delete leaves `head.maxSeq` unreachable; anchor the head daily via the **existing** OTS infra (`computerUseOpenTimestamps.ts`); client `verifyAuditLog` asserts the chain reaches the anchored seq → truncation FAILS. *Verify:* truncation harness case → `valid:false`; `dataExport` propagates the error when the audit write fails.

**Transport proof (Wave B-Rust batch — land in ONE xcframework/aar rebuild):**
- **B-TX-1 — Truthful connType monitoring** *(L, prerequisite for the soak).* `HermesIrohRelayTransport.swift` hardcodes `transport: .irohDirect` on every audit row (verified lines 443/464/601/620/637) even on a relayed connection; the Rust binding never reports direct-vs-relay. So `irohMonitoring.ts` `directShare` is **always 1.0** and the `directShare>=0.75` gate is self-fulfilling and worthless. Export `conn_type()` from `crates/openburnbar-iroh/src/lib.rs` (iroh exposes `Direct|Relay|Mixed|None`), thread it through the Swift/Kotlin bridges, map to `.irohDirect`/`.irohRelay`. Document `iroh_fallback_to_wss` as iOS-N/A. *Verify:* same-LAN → Direct, pfctl-blocked UDP → Relay land as distinct values; monitoring fixture with both → `directShare` strictly between 0 and 1.
- **B-TX-2 — Multi-relay list + self-hosted relay** *(L, same Rust batch).* Single n0 vendor for protocol + default relay set + paid hosted relay, pinned to `iroh=1.0.0-rc.0`. Stand up one self-hosted `iroh-relay` (VPS/Cloud Run); change `bootstrap()` to parse a relay **list** into a `RelayMap`; drive from the existing `hermes_iroh_hosted_relay_url` Remote Config (extend to `_urls`); keep `RelayMode::Default` as third tier. An n0 outage becomes a one-line Remote Config change.
- **B-TX-3 — Runtime threading + reproducible binary** *(L, same Rust batch).* `bootstrap()` builds a 2-worker runtime per handle and every FFI method calls `block_on`; `recv_frame` blocks a worker, so concurrent long-lived streams (media + chat + computer-use + remote-unlock) can starve both workers. Raise workers to `num_cpus.min(4)`+ and/or make `recv_frame` a cancellable timed recv. Commit `Cargo.lock` + `rust-toolchain.toml`, emit + verify SHA256 of the 442MB xcframework/aar (kept out of git but hash-pinned). *Verify:* cargo test opens K>workers streams parked in recv, asserts a concurrent send/close completes; double-build → identical SHA256.
- **B-TX-4 — Cross-network soak** *(L, depends on B-TX-1 + A3).* Build `scripts/e2e/iroh-soak.sh` that enforces network topology (reject runs whose `networkInterfaces` ≠ required), runs a 4-cell matrix (cellular/home-wifi CGNAT, two-ISP, emulated symmetric NAT, same-LAN control) ≥30 completions each, emits a CSV + a published rollup, and flips the gate from "directShare>=0.75 asserted" to "directShare>=X **measured** across cellular/symmetric-NAT runs, relay path proven on the rest." *Verify:* run on real cellular → CSV with a non-trivial mix of `direct`/`relay`, soak summary written to `docs/runbooks/iroh-rollout-status.md`, rollup `successRate>0`. **Production rollout % increase is gated on this.**

**Backend resilience:**
- **B-BE-1 — Firestore PITR + scheduled backups** *(M, single highest backend priority).* Firestore is the system-of-record (Stripe state, entitlements, encrypted manifests); PITR is off, no exports, and `rollback-automation.md` says "restore from backup" with no backup to restore from. Enable 7-day PITR + daily/weekly GCS exports as checked-in idempotent `.mjs` (mirror `apply-ops-alert-policies.mjs`), write `docs/runbooks/firestore-backup-restore.md` with explicit `gcloud firestore databases restore` commands and a hard **RPO (0 within the 7-day PITR window; ≤24h catastrophic) / RTO (≤2h)**, and add a quarterly restore drill. *Verify:* `describe ... pointInTimeRecoveryEnablement` → ENABLED; restore into a throwaway DB, confirm doc counts match. *Needs:* deploy SA gets `datastore.importExportAdmin` + `storage.admin`.
- **B-BE-2 — Centralize region** *(M, precursor to A4/B-BE-3).* 102 hardcoded `us-central1` across `functions/src`, region const duplicated. Add `runtimeOptions.ts` exporting `FUNCTIONS_REGION`, codemod the literals, `setGlobalOptions({region})` in `adminRuntime.ts`, write `docs/ARCHITECTURE/region-strategy.md` recording "single-region accepted for GA" + flip-triggers, add a CI guard against new raw literals. (Single-region is the *right* call now — see §7.)
- **B-BE-3 — OpenTelemetry → Cloud Trace** *(M).* `trace_id` is a `randomUUID()` log-join key; latency debugging is log archaeology across 48 modules. Add `@opentelemetry/sdk-node` + auto-instrumentations + Cloud Trace exporter, init first in `adminRuntime.ts`, bridge the existing `trace_id` to the OTel span id (log lines + spans share an id), wrap `withCallableLogging` in `startActiveSpan`, instrument the Stripe/Apple webhooks + `resilientFetch`. Sample 0.05 default, 1.0 for webhooks. *Verify:* Cloud Trace shows a span tree with Firestore/provider children; log `trace_id` == 16-hex Cloud Trace id.

**Data-layer safety:**
- **B-DATA-1 — Encryption-at-rest default-on** *(M, no deps, land first in this track).* `DatabaseEncryptionService.makeConfiguration` returns an **unencrypted** Configuration when GRDBCipher is absent (logs only), gated behind `databaseEncryptionEnabled` defaulting **false**. A misconfigured build ships plaintext SQLite silently. Make the default `true`; throw `cipherUnavailable` instead of silently falling back; provide a single explicit, persisted, user-acknowledged plaintext escape hatch with a standing banner; add a `PRAGMA cipher_version` self-check that hard-fails on silent no-op; fix the doc/code mismatch (docs claim hex `x''` keys, code uses passphrase mode). *Verify:* `makeConfiguration` throws when GRDBCipher unlinked; open with encryption on, then prove a plaintext `DatabasePool` cannot open the file.
- **B-DATA-2 — Cross-device delete propagation (tombstones)** *(L).* `deleteConversation` does a hard `DELETE`; `firestore.rules` conversations is `delete:if false`; no `deletedAt` column → a delete on device A never reaches device B and GCS/Firestore grow forever. Replicate the proven `text_snippets` tombstone pattern: migration `v47_conversation_tombstones` (`deletedAt`, `version`), soft-delete + `version+1`, `AND deletedAt IS NULL` on all reads, emit `deletedAt` in sync, `upsertRemoteConversation` honors remote tombstones, client-side GC after 30d retention that also deletes the GCS body + Firestore manifest + chunks + search index. *Verify:* delete on A → soft-deleted on B after one sync; GC purges cloud body+manifest. **The `v47` migration's `deletedAt`/`version` columns are prerequisites for Phase 2 conflict convergence and the reconciler.**

### Wave C — the large GA-gating items

- **C-SEC — Per-request App Attest** *(L, depends on B-SEC chain + real iOS hardware).* "App Attest-bound" is currently only a 30-day `appId`-equality custom-claim check (`appCheckAttestation.ts:98-129`) — no per-request `DCAppAttestService` challenge/assertion, no server nonce, no replay protection, `consume:true` off. A leaked/replayed App Check token within 30 days passes, guarding the highest-risk callables (`cliLink`, `remoteMcp` grant, `computerUseSecurity`, OTS). Implement a real challenge→assertion handshake (single-use server nonce, signCount monotonicity), turn on App Check token consumption, wire `DCAppAttestService` in the iOS client. *Verify:* replay harness case → permission-denied; real-iPhone test (App Attest is simulator-unavailable). *Note:* this is the gate for any GA marketing of "attestation-bound."
- **C-SEC-AGG — Security spec + harness + external review prep** *(M, aggregates B-SEC + C-SEC).* Write `docs/SECURITY-SPEC.md` (threat model, key hierarchy, envelope formats, cloak proven-properties + accepted leakage, App Attest handshake, audit-anchor design, "what the provider CAN/CANNOT see" tables); fold the four adversarial cases (cloak-geometry, metadata-no-cleartext, attestation-replay, audit-truncation) into `scripts/test-hosted-mcp-security.sh`; prepare a scoped external crypto-review package (1–2 week engagement fits a solo launch). *Verify:* spec's HKDF info/salt strings grep-match `CloudVaultCrypto.swift`; harness cases all pass or skip-loudly; CI job green on no-op, red on a deliberately broken test.

> **Deferred to Phase 2 (not GA-gating):** the three-tier GCS⇄Firestore⇄SQLite **reconciler** (the dangling `chunks[].body` read it fixes is real and should be patched as a *targeted* fix in B-DATA, but the full scheduled reconciler is XL and post-GA), and shared-mutable-doc **conflict convergence** (LWW only hurts users with concurrent multi-device edits — acceptable for early launch, scheduled when multi-device usage grows).

---

## 4. Phase 2 — SOTA depth (post-GA, scale-triggered)

Each item carries an explicit **trigger** — build it when the trigger fires, not before.

### AI / retrieval / MCP
- **P2-AI-0 (do as a Phase-1 tail, cheap):** **jti revocation** (`hosted-mcp/auth.verifyBearerToken` never checks the `jti` against a revocation list → a stolen 15-min token can't be killed) + the **routing golden harness** (lock in current router behavior before anyone touches weights). *Trigger: now — both are S and lock in current behavior.*
- **P2-AI-1 — Real on-device embedder.** The shipping embedder is a deterministic **BoW** (`hashing-bow-v1`) on Apple while the Node shim uses real bge — a silent model-version split where Apple-committed chunks are **unreachable** by Node queries. Ship one CoreML/ONNX embedder (Qwen3-Embedding-0.6B), prove Apple↔Node cosine parity >0.999, flip BoW behind a test flag. *Trigger: before marketing "semantic memory" as a headline feature; this is the single biggest "it doesn't actually work" gap, so prioritize early in Phase 2.* **XL.**
- **P2-AI-2 — Registry-driven model/dim + resumable re-embed migration.** De-hardcode the 4 pinned `384`/`bge` sites, add a second `vectorConfig` alongside 384, build `PensieveReindexService`. *Trigger: when changing the embedder (couple with P2-AI-1 so the device bundle ships once).* **XL.**
- **P2-AI-3 — MCP 2026 spec compliance.** Asymmetric JWKS/ES256 tokens (the shared `MCP_TOKEN_HMAC_SECRET` lets the verifier forge), real persisted sessions, protocol negotiation, Streamable HTTP/SSE; pass MCP Inspector. *Trigger: when third-party agents/clients connect to the hosted MCP (until then, first-party clients are fine).* **L.**
- **P2-AI-4 — Dense cloaked ANN + RRF for conversation search** (currently lexical-hash only). *Trigger: after P2-AI-1 lands (must share the vector space).* **L.**
- **P2-AI-5 — Eval harness** (routing golden sets + recall@k/nDCG + Hermes scorecard, CI-gated). *Trigger: scaffold now (P2-AI-0), expand as each AI fix needs measuring.* **L.**

### Client / multi-platform
- **kapt→KSP** (single Room consumer, clean migration) → **Gradle version catalog** → **Compose BOM bump + M3 Expressive** (currently pinned to 2024.12.01) → **Hilt** (zero DI across 749 Kotlin files). *Trigger: when Android becomes a marketed first-class sibling or the team grows past one Android dev.* kapt→KSP is S and unblocks Hilt — do it as a quick win whenever Android work starts. **S→L each.**
- **Swift 6 language mode** (currently 5.10 + strict-concurrency complete; 78 `@unchecked Sendable`). Incremental, module-by-module (Core → Daemon → app). *Trigger: do **build-hack de-risk first** (remove the awk GRDB.o dedupe + PlistBuddy URL/AppCheck patching), then flip modules.* **XL.**
- **Build-hack de-risk** (toolchain-coupled `project.yml` hacks that rot on the next Xcode bump). *Trigger: before the Swift 6 flip (shared files, cleaner bisect).* **M.**

### Backend / infra
- **Split functions into codebases** (billing/entitlements deploy + roll back independently from media/iroh). *Trigger: when a bad deploy of one domain has blocked a billing fix, or the function count makes monolith deploys risky.* **L.**
- **Terraform ops plane + Cloud Monitoring SLO objects + burn-rate alerts** (currently imperative `.mjs` with no plan/diff; SLOs are paper log-ratios). Import-then-codify. *Trigger: when ops surface area or team size makes click-ops drift a real risk.* **L.**
- **Multi-region.** *Trigger: first regional-outage post-mortem, or >$X MRR. Until then single-region is the documented, accepted decision (B-BE-2).* **XL — explicitly deferred.**

### Data convergence
- **Conflict convergence for shared mutable docs** (monotonic version + per-field LWW + rules-enforced monotonicity guard, reusing the `v47` `version` column). *Trigger: when multi-device concurrent-edit reports appear or multi-device usage is common.* **L.**
- **Three-tier reconciler + server-side GC sweep.** *Trigger: when storage growth or missing-body errors become operationally visible (the targeted dangling-read fix lands in Phase 1; the scheduled reconciler is the deferred part).* **XL.**

---

## 5. Effort roll-up & critical path

**Effort scale:** S ≈ ≤½ day · M ≈ 1–2 days · L ≈ 3–6 days · XL ≈ 1.5–3 weeks (human-dev). CC+agent multiplier ≈ **0.3–0.5×** wall-clock for S/M/L mechanical items (codegen, tests, scripts, codemods), closer to **0.6–0.8×** for XL items needing real-device or cross-platform parity testing.

| Phase | Items | Human-team (1–2 devs) | CC+agent-assisted | Notes |
|-------|-------|----------------------|-------------------|-------|
| **Phase 0** | 0-A, 0-B, 0-C | ~2–3 days | **~1 day** | Parallelizable; 0-C is ~1 hr |
| **Phase 1 Wave A** | A1–A5 | ~1 week | ~3 days | All S/M, mostly independent |
| **Phase 1 Wave B** | B-SEC-1/2/3, B-TX-1/2/3/4, B-BE-1/2/3, B-DATA-1/2 | ~3–4 weeks | ~2 weeks | Rust batch (B-TX-1/2/3) is one rebuild |
| **Phase 1 Wave C** | C-SEC, C-SEC-AGG | ~1.5 weeks | ~1 week | C-SEC gated on iOS hardware |
| **Phase 1 total** | | **~5–6.5 weeks** | **~3–3.5 weeks** | |
| **Phase 2** | all triggered items | ~10–14 weeks if all built | n/a — spread over quarters | Build per-trigger, not upfront |

**Critical path to GA** (the longest dependency chain that can't be parallelized away):
`0-C/0-A → 0-B` (honesty + drift gate) → **B-DATA-1** (encryption default-on, land before reconciler/launch claims) → **A3** (iOS fallback parity) → **B-TX-1** (truthful connType, Rust) → **B-TX-4** (soak, needs a binary that reports real connType + A3) → **rollout % increase**. In parallel: **B-BE-1** (PITR — independent, but blocks the "restore from backup" claim) and **B-SEC-1 → B-SEC-2/3 → C-SEC → C-SEC-AGG** (the security honesty/teeth chain, which gates "attestation-bound"/"zero-knowledge" marketing). The two longest real-world poles are the **iroh soak** (needs physical cellular + a symmetric-NAT path) and **C-SEC App Attest** (needs a physical iPhone) — start provisioning the self-hosted relay (B-TX-2) and the App Attest server-verification library early because they have lead time.

---

## 6. Definition of "SOTA-done" (frontier-grade-for-its-size checklist)

**Correctness & honesty** ☐ Every privacy label on every platform is byte-identical to `registry.json`, enforced by CI (red, not a reviewer); `conversations_chat` reads `SERVER_READABLE` everywhere. ☐ The migration-backup gate derives from `migrator.migrations.last`; a v45→v46 upgrade provably takes a backup.

**Security** ☐ Zero docs grep-match the old overstated cloak claim; a committed leakage one-pager + Vitest prove the cloak's actual properties. ☐ No per-vector cleartext channel confirms guessed plaintext or leaks file paths. ☐ The 4 highest-risk callables require a real per-request App Attest assertion bound to a single-use nonce; a replayed request is rejected by a harness case. ☐ The audit chain is fail-closed for irreversible actions, OTS-anchored, and a truncated tail FAILS verification. ☐ `docs/SECURITY-SPEC.md` exists and matches the code; an external-review package is ready.

**Transport** ☐ A published cross-network soak (cellular + symmetric-NAT + two-ISP, ≥30 each) shows a **measured** directShare with a proven relay fallback. ☐ iOS and Android have identical selected-model integrity semantics. ☐ Audit rows carry real `connType` (Direct/Relay) from iroh. ☐ The client dials a relay list incl. one self-hosted relay, switchable via Remote Config. ☐ `retryStuckVoIPPushes` self-heals transient APNs failures. ☐ The native binding is concurrency-safe (proven by a Rust test) and the shipped binary is hash-pinned.

**Backend** ☐ PITR + scheduled exports as code, with a drill-tested restore runbook and an explicit RPO/RTO. ☐ Region is one constant + a documented single-region-for-GA decision. ☐ Hot paths emit Cloud Trace spans with `log trace_id == traceId`. ☐ Rollback is a sub-minute revision flip. ☐ Hot revenue functions have `minInstances>=1`.

**Data** ☐ A delete on any device propagates within one sync cycle with tombstone GC. ☐ Encryption-at-rest is default-on; a build without GRDBCipher fails hard (or proceeds only with an explicit acknowledged plaintext flag + standing banner).

**AI/retrieval** *(Phase 2)* ☐ One real on-device embedder with Apple↔Node parity >0.999 is the only production path. ☐ Model/dim are registry-driven with a resumable re-embed migration. ☐ Hosted MCP passes MCP Inspector with JWKS tokens + jti revocation. ☐ An eval harness gates routing/recall/Hermes in CI.

---

## 7. What NOT to do

- **Do NOT add Postgres, ClickHouse, or pgvector.** The prior stack audit confirmed the SQLite + Firestore + GCS + Firestore-vector-search architecture is the right call for this size. Pensieve already uses Firestore `findNearest` (not pgvector). Adding a relational/columnar/vector DB is net-new operational surface, a second system-of-record to keep consistent, and a backup/region/IAM burden — all cost, no product. The data-layer work here is **convergence and integrity of the existing stores**, not a new store.
- **Do NOT build multi-region before the trigger.** Firestore single-region cannot be migrated in place; multi-region is an XL dual-write migration. Single-region is the *documented, accepted* GA decision (B-BE-2), with cross-region restore (B-BE-1) as the outage recovery mechanism. Build it on the first regional-outage post-mortem or a revenue trigger — not speculatively.
- **Do NOT big-bang the modernization tracks** (Compose BOM across 343 files, Swift 6 across all targets, Hilt across 28 ViewModels). Every one is incremental, module-by-module, bisectable, and trigger-gated.
- **The real net-new product gap is orgs / RBAC / team accounts** — multi-user tenancy, role-based access, shared workspaces. That is a **separate product track**, not a remediation item, and is out of scope for this plan. Flag it for the product roadmap: it is the largest *additive* opportunity once the foundation here is frontier-grade, but it should not compete with Phase 0/1 for engineering time at early commercial launch.

---

**Bottom line.** Phase 0 (≈1 day with agent assist) stops an active privacy lie and a latent data-loss bug — do it this week. Phase 1 (≈3 weeks agent-assisted) makes BurnBar defensibly chargeable: honest claims, measured transport, recoverable backend, safe data. Phase 2 is real depth, built per-trigger so you never boil the ocean before the ocean asks for it.

---

## 8. Implementation progress (living log)

**Updated 2026-06-02** — autonomous agent crew. Each "done" item below was implemented **and verified in-repo** (tests run, not just written). Items needing hardware/cloud/Rust are flagged with their activation gate.

### Done + verified this pass (7 items)

| ID | What landed | Verification (actually run) |
|----|-------------|------------------------------|
| **0-C** | `OpenBurnBarDatabase.latestMigrationIdentifier` is now a migrator-derived computed property (`migrator.migrations.last`), self-healing for every future migration. | `xcodebuild test` `OpenBurnBarDatabaseMigrationTests` — **14/14 pass**, incl. new `test_latestMigrationIdentifier_equalsLastRegisteredMigration` + `test_runMigrationsSafely_createsBackup_whenUpgradingV45toV46` (fails on old code, passes now). |
| **0-A** | Regenerated gen; copied `gen/DataDomains.kt` + `dist/compose/PensieveTokens.kt` into Android; added `syncGeneratedSources` Gradle task wired to `preBuild`. `conversations_chat` now reads **SERVER_READABLE** with the honesty note; `account_recovery_methods` restored. | `diff gen android` exits 0; codegen idempotent (gen/dist clean). |
| **0-B** | Android-drift tests in `registry.test.mjs` + `tokens.test.mjs`; `git diff --exit-code` CI gate in `fast-feedback.yml`; `codegen.mjs` banner documents the Android Gradle-sync mechanism. | `node --test` green (data-domains 8/8, design-tokens 5/5). **Sabotage check:** reverting the Android tier → test `not ok` **and** CI git-diff red; restore → clean. |
| **A2** | `retryStuckVoIPPushes` gen2 `onSchedule` (1-min) sweeper: `collectionGroup('voip_outbound')` where `status==pending && retryAt<=now`, re-push via `pushToAPNs` (apns-id=docId), exp backoff (30s→15m cap), seal `rejected` after 8 attempts; exported; `(status,retryAt)` COLLECTION_GROUP index added. | `vitest` targeted **8/8 pass**; full unit suite **147 pass / 4 skip**; `tsc --noEmit`, eslint, `firestore.indexes.json` JSON all clean. |
| **A3** | iOS composite relay now mirrors Android: a generic iroh failure on `.chatCompletions` **hard-fails** (no silent Firestore reroute of the selected model); control-plane unary still falls back. Added `allowsFirestoreFallback(for:)` + `selectedModelNoFallbackError`. | `xcodebuild test` (iOS sim) — both new tests pass; selected-model stream proves the secondary transport is never invoked. |
| **A5** | `scripts/ops/rollback-revision.sh` (sub-minute `gcloud run services update-traffic` revision-pin, `--yes/--dry-run/--region/--project`); `rollback.sh` gains `--yes` + "slow source rollback" relabel; deploy workflow hint + runbook document both with an MTTR table. | `bash -n` + `shellcheck` clean (0 warnings) on both; executable; workflow YAML valid; arg/usage/error paths exercised. **Gate:** end-to-end `gcloud` plumbing unverified (no cloud creds) — needs one real revision-pin against `burnbar`. |
| **B-SEC-1** | Rewrote the cloak claim to proven properties only (zero "inversion defense" left); shipped `docs/pensieve-leakage-analysis.md`; honest docstrings in `embed.ts` + `PensieveVectorCloak.swift`; added a proof test. | `node --test` cloak proof **4/4 pass**; full mcp-remote suite **44/44**; `grep "inversion defense"` = 0 (excl. this plan); `swift build OpenBurnBarCore` OK. |

### New findings surfaced while implementing (more severe than originally written)

- **B-DATA-1 is worse than "default-off + silent fallback."** The encryption path is gated on `#if canImport(GRDBCipher)`, but the linked package (`SahebRoy92/GRDB-SQLCipher`) exposes its module as **`GRDB`**, not `GRDBCipher` (no such product/target exists). So the `PRAGMA key` block is **dead code and database encryption has never been applied for anyone**, on app *or* daemon (the daemon doesn't use the encryption service at all). The remediation is therefore not just "default the flag true + throw" — it must (a) apply the key via the real `import GRDB`/SQLCipher build, (b) add the `PRAGMA cipher_version` self-check that would have caught this, **and critically (c) migrate existing _plaintext_ databases to encrypted** (every install is plaintext today; blindly applying a cipher key would fail to open their DB). This is L/XL and touches the production DB-open path — **do it deliberately with a build that proves `cipher_version` is non-empty, not as a quick flag flip.** *(Severity upgraded; sequence it carefully.)*
- **B-SEC-1's cross-tenant claim was itself optimistic.** The plan assumed per-user Q makes the same vector "cosine ~0" across tenants. Empirically, at the shipped **24** Householder reflections the cross-tenant cosine is **≈0.77** — per-user Q gives byte-distinct storage (defeats *exact-match* joins) but **not** geometric unlinkability. The leakage one-pager + proof tests now state this honestly. If true cross-tenant unlinkability is later required, raise the reflection count toward a full random orthogonal mix (or change schemes) — tracked in the leakage analysis.

### Remaining Phase 1 — code-ready next (no external gate; do in focused passes)

- **B-DATA-1** encryption-at-rest (see upgraded finding above — top data priority, needs the plaintext→encrypted migration).
- **B-SEC-2** plaintext metadata side channels (HMAC dedup hash, drop cleartext `sourcePath`) — functions/TS, testable.
- **B-SEC-3** audit log fail-closed + truncation detection (`appendAuditEventRequired`, `audit_meta/head`, OTS anchor) — functions/TS, testable.
- **B-BE-2** centralize region (`runtimeOptions.ts` + codemod of 102 literals) — then **A4** cold-start `minInstances` builds on it.
- **A1** gateway per-launch bearer token — Swift daemon; code-implementable, but full verify needs a running daemon (curl 401/200).
- **B-DATA-2** conversation tombstones (migration `v47`) — Swift; prerequisite for Phase-2 conflict convergence.
- **B-BE-3** OpenTelemetry → Cloud Trace — code-implementable; verify needs a deploy.

### Remaining Phase 1 — externally gated (cannot be completed by an in-repo agent)

- **B-TX-1/2/3/4** (truthful `connType`, multi-relay + self-hosted relay, runtime threading + reproducible binary, cross-network soak) — need the **Rust crate rebuilt into the 442 MB xcframework/aar**, a **self-hosted `iroh-relay`**, and **physical cellular + symmetric-NAT** networks.
- **B-BE-1** Firestore PITR + scheduled exports — needs **GCP IAM** (`datastore.importExportAdmin` + `storage.admin`) and project-level enablement.
- **C-SEC** per-request App Attest — needs a **physical iPhone** (App Attest is simulator-unavailable).

> The work above is on a branch with other in-flight changes and has **not** been committed — review the diff, then commit/branch as you prefer.
