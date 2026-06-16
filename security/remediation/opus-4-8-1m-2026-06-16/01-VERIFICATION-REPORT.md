# Cross-Audit Verification Report — OpenBurnBar

**Author lane:** Opus 4.8 (1M context) · **Date:** 2026-06-16 · **Commit audited:** `60faa70227` · **Branch at session start:** `security/run-09-privacy-invariants-hardening`

## What this is

Four independent models (GLM-5.2, Opus-4.8-1M, Kimi/K2, Codex-GPT-5) each produced a full 28-file security audit of the same commit. Their findings **overlap, contradict, and in several cases are simply wrong**. This document is the result of independently re-verifying **every** finding against the actual code — not trusting any auditor's line numbers or severity — using five parallel verification agents (daemon/IPC, CloudVault/rules, App-Check/Stripe, privacy/supply-chain, local-DB/Android/MCP).

Each finding below carries one of four verdicts:

- **CONFIRMED** — the gap exists as described (severity may be adjusted from the auditor's).
- **PARTIAL** — partly true; the auditor over- or under-stated it. The nuance is load-bearing.
- **FALSE** — the claimed mechanism does not exist / the code already does the safe thing.
- **ALREADY-FIXED** — was true in a prior run; current code mitigates it.

> **Headline:** Across ~60 raw findings from four audits, there is **exactly one Critical** real issue, and **no audit's remediation plan is fixing it**: shared collaboration artifacts are written to Firestore in **plaintext** (V-10 / Opus-F-001). Everything else is Medium or below. Four findings are **false or non-exploitable as framed** (V-08, V-09, V-23b, V-28) and should not consume remediation effort. Three are **already fixed** (V-14, V-33, and the SQLite "silent plaintext" framing of V-30).

---

## Master reconciliation table

Severity = my adjudicated severity after verification (not the auditor's). "Sources" maps to each audit's own finding ID.

| ID | Finding | Verdict | Severity | Sources | Who is fixing it (parallel agents) |
|----|---------|---------|----------|---------|------------------------------------|
| **V-10** | **Shared collaboration artifacts written PLAINTEXT to Firestore** | **CONFIRMED** | **Critical** | Opus-F-001 | **Nobody → this lane** |
| V-34 | Prompt/RAG injection: `lastAssistantMessage` injected unwrapped into system prompt | CONFIRMED | High (conditional) | Kimi-F-004 | **Nobody → this lane** |
| V-17 | Stripe redirect validation: `hostname.includes("localhost")` substring + http bypass | CONFIRMED | Medium | Codex-F-003 | GLM (done) |
| V-25 | Production deploy uses long-lived secrets; **no WIF/OIDC at all** | CONFIRMED | Medium | Codex-F-007 | GLM (deploy verification) |
| V-27b | CODEOWNERS is single-owner catch-all; no sensitive-path review routing | CONFIRMED | Medium | Opus-F-012 | Unclaimed |
| V-35 | Local MCP `burnbar_semantic_search_conversations` returns raw snippets, no gate | CONFIRMED | Medium | Kimi-F-008 | Unclaimed |
| V-36 | Cursor connector public Cloudflare quick tunnel (bearer+rate-limit gated) | CONFIRMED | Medium | Kimi-F-009 | Unclaimed |
| V-02 | Daemon local-auth-proof verifier `nil` in production (no-op, deferred) | CONFIRMED | Medium | Codex-F-001(H), GLM-F-002(M), Opus-F-018(I) | gpt-5.5 (in progress) |
| V-04 | Daemon browser Computer-Use uses `killSwitch:false` + synthetic entitlement | CONFIRMED | Medium | Codex-F-002 | gpt-5.5 (suggested) |
| V-01 | Kill-switch watchdog socket: no peer auth (root-owned 0600 → root-only) | CONFIRMED | Medium→Low | GLM-F-001 | GLM (fastest-wins) |
| V-15 | App Check enforcement for Firestore-REST not repo-verifiable (console-only) | PARTIAL | Med→Low | Kimi-F-005, Codex-F-004 | K2.7 (ops verifier) |
| V-16 | App Check attestation max-age 30 days (mitigated by 2-min nonce) | CONFIRMED | Low | GLM-F-007 | Unclaimed |
| V-03 | Phone trust-mode picker shows all modes; `setTrustMode` has no direction guard | PARTIAL | Low | GLM-F-003 | GLM (in progress) |
| V-05 | Legacy `/var/run` HID bridge: client skips `validateServerPeer` before writing password | CONFIRMED | Low | Opus-F-008 | Unclaimed |
| V-06 | Executable resolution falls back to `zsh -lic` (dotfile-hijackable, self-compromise) | CONFIRMED | Low | Opus-F-009 | Unclaimed |
| V-07 | `RestrictedLogPathValidator` tilde mismatch (over-rejects; fail-safe; no canon.) | CONFIRMED | Low | Opus-F-010 | GLM (in progress) |
| V-11 | Path-bound AAD partial: `chat_threads` + `cli_sessions` on global AAD | CONFIRMED | Low | GLM-F-008, Opus-F-003, Kimi-F-015 | Unclaimed |
| V-12 | CloudVault first-vault creation client-driven; rotation monotonic but no quorum | CONFIRMED | Low (accepted) | GLM-F-004 | Accepted-risk |
| V-13 | Signal/E2EE marketing wording: AES-GCM is live, Signal is flag-off/additive | CONFIRMED | Info (claims) | Codex-F-009 | Doc/claims |
| V-20 | `accountDeletion.ts` logs full UID via raw `console.warn` (bypasses scrubber) | CONFIRMED | Low | Opus-F-005 | GLM (done) |
| V-21 | `buildFcmMessage` ships stable `thread_id` to APNs/FCM; outside I5 gate | CONFIRMED | Low | Opus-F-006, Kimi-F-019 | GLM (queued) |
| V-22 | `androidDeviceId` persisted in `fcm_outbound` (15-min TTL) | CONFIRMED | Low | GLM-F-012 | Unclaimed |
| V-23a | `ROOT_COLLECTIONS_KEYED_BY_UID` is a static hand-maintained allowlist | CONFIRMED | Low (latent) | Opus-F-014 | Unclaimed |
| V-24 | SSRF guard: alt IP encodings + no DNS pinning (**latent — no user host today**) | CONFIRMED | Low (latent) | GLM-F-009, Opus-F-007 | Unclaimed |
| V-26 | GPG checksum signing is fail-open/silent (cosign attestation still covers) | CONFIRMED | Low | Opus-F-016, GLM-F-016 | Unclaimed |
| V-27a | Two workflows lack a top-level `permissions:` block | CONFIRMED | Low | GLM-F-016 | Unclaimed |
| V-29a | Mission-event top-level `messageLength`/`messageTruncated` leak sealed-body length | CONFIRMED | Low | Opus-F-020 | GLM (queued) |
| V-29b | `agent_import_jobs.errorMessage` embeds unredacted local file path | CONFIRMED | Low | Opus-F-020 | GLM (queued) |
| V-30 | Local SQLite is **disclosed** plaintext (stock sqlite3, no SQLCipher codec) | CONFIRMED | Low (accepted) | Opus-F-004 ✓; Kimi-F-001 ✗(Critical) | Doc/accepted |
| V-31 | SQLCipher key creation continues after Keychain failure (moot — codec inactive) | CONFIRMED | Low | Codex-F-008 | GLM (queued) |
| V-32 | macOS Sentry scrubber + per-install ID have **no unit test** | CONFIRMED | Low (coverage) | Opus-F-002 | Unclaimed |
| V-37 | Several log parsers `Data(contentsOf:)` unbounded + unbounded recursion (local) | CONFIRMED | Low-Med | Kimi-F-017 | Unclaimed |
| V-38 | Computer-Use adversarial tests: 4/6 scenarios covered; **scope-escalation gap** | PARTIAL | Med | Kimi-F-003 | Unclaimed |
| V-18 | Public endpoints rate-limiting: expensive ones limited; `latestRouterRundown` cached+capped | PARTIAL | Low | Codex-F-005, Kimi-F-012 | Adequate |
| V-19 | "No CI rules-drift test" | PARTIAL→mostly FALSE | Info | Kimi-F-011 | n/a |
| **V-08** | "Daemon has no per-method authorization matrix" | **FALSE** | — | Kimi-F-007 | n/a — do not action |
| **V-09** | "HID capability tokens not device/session-bound; cross-pairing reuse" | **FALSE** | — | Kimi-F-020 | n/a — do not action |
| **V-23b** | "Data-deletion audit logging is best-effort" | **FALSE** | — | Codex-F-006 | n/a — intent audit is fail-CLOSED |
| **V-28** | "Client can deflate quota counters to bypass caps" | **FALSE** | — | Opus-F-013 | n/a — gates never read the mirror |
| **V-14** | "session_logs validation gaps" | **ALREADY-FIXED** | — | Kimi-F-016 | n/a — M-005 allowlist wired |
| **V-33** | "Android iroh key cached in SharedPreferences" | **ALREADY-FIXED** | — | Kimi-F-014 | n/a — Keystore-wrapped + migrated |

---

## The one Critical: V-10 — shared collaboration artifacts written plaintext to Firestore

**Verdict: CONFIRMED. Severity: Critical (content confidentiality).** This is the highest-stakes finding and it breaks the zero-plaintext invariant the rest of CloudVault enforces.

**Evidence (verified against live code):**
- `AgentLens/Services/CloudSyncSharedArtifactModels.swift` — `SharedArtifactCloudCodec.encode` builds the Firestore payload with **raw strings**: `"title": record.title`, `"body": record.body` (full source content), `payload["relativePath"] = relativePath`. There is **zero** `CloudVaultCrypto.seal*` call in the file.
- `AgentLens/Services/CloudSync/CollaborationSyncService.swift:~1001-1003` (`commitSharedArtifactHead`) writes that plaintext payload directly to Firestore for **both** the head doc and the `versions/{revisionID}` history subdoc.
- Collection path: `workspaces/workspace-{uid}/teams/{teamID}/artifacts/{id}` and `.../versions/{revisionID}`.
- `contentHash` is a **keyless** SHA-256 over the plaintext (`ArtifactAuthoringService` → `ProjectionIdentity.sha256Hex`) — a confirmation/dedup oracle (moot here because `body` is already cleartext).
- `firestore.rules:~4411-4421` gates the path with `sharedArtifactOwnerWrite`, which enforces only workspace-path ownership + size + field-name matching. It does **not** call `forbidsSealedPlaintextContentFields()` (the helper that *does* list `"body"`, at rules ~874-895) and does **not** require a `sealedPayload`. The rules comment at ~4409 (`// --- Shared artifacts (unchanged) ---`) signals this surface was knowingly left behind.

**Why this matters:** Anyone with read access to the user's Firestore namespace — Google/Firebase, a compromised service account, a future rules regression, a subpoena — can read private source-file content, titles, and filesystem paths in cleartext. Every sibling content type (chat threads, conversations, CLI sessions, mission events, session logs, snippets) seals before Firestore; this one collection does not. The fix pattern is unambiguous because `ChatThreadSyncService.swift` already demonstrates it (build a sealed payload via `CloudVaultCrypto.sealPayload`, write only `sealedPayload`).

**Precondition:** user enables shared/team-artifact collaboration sync. Owner-scoped (not cross-tenant readable), but the **content-confidentiality** promise is fully defeated. → Remediated in this lane; see `03-REMEDIATION-PLAN.md` and the `remediation/opus-4-8-1m-2026-06-16` branch.

---

## The four findings that are FALSE / non-exploitable (do not spend effort here)

These were rated as real gaps by their auditors but do not hold against the code. Flagging them explicitly so remediation effort isn't wasted.

### V-08 — "Daemon has no per-method authorization matrix" (Kimi) → **FALSE**
The matrix exists and is enforced fail-closed *before* the handler: `OpenBurnBarDaemonServer.swift:451` `guard capabilityProfile.permits(method)`. `BurnBarRPCCapability.swift` defines 13 capability groups with a compile-exhaustive `capability(for:)` switch mapping every `BurnBarRPCMethod`; Computer Use is isolated as its own highest-risk `.computerUse` group. Peer code-signature gating (`validatePeer`) and constant-time bearer-token check also precede every RPC. *Kernel of truth:* the production profile defaults to `.full`, so attenuation is built and enforced but not yet exercised to deny Computer Use to a real peer.

### V-09 — "HID capability tokens not device/session-bound; cross-pairing reuse" (Kimi) → **FALSE**
`CapabilityToken` carries domain, single-use nonce, issued/expiry, `allowedActionKinds`, `scopeHash`, `actionBudget`, **`boundEscrowDeviceId`** (device binding) and **`attestationHashBlake3`** (attestation binding), all inside the **Ed25519-signed body** (`CapabilityTokenSigning.swift`). The verifier enforces device binding, attestation binding, expiry, scope, budget, and **single-use nonce replay** via a persisted 0600 domain-keyed ledger. Cross-pairing reuse is prevented by device binding + per-issuer pinned key + nonce ledger. There is no field literally named `sessionId`, but session/pairing scope is achieved in substance.

### V-23b — "Data-deletion audit logging is best-effort" (Codex) → **FALSE / misread**
The design is two-phase: `dataDeletion.ts:~90` writes a **fail-CLOSED intent audit** via `appendAuditEventRequired(...)` *before* any deletion — if it throws, deletion is refused. `dataExport.ts:~656` does the same before returning data. `auditLog.ts:179-185` documents `appendAuditEventRequired` as the "callers must NOT wrap in try/catch" fail-closed variant. Only the redundant **post-deletion completion** breadcrumb is best-effort (correctly — it can't undo a finished deletion). An irreversible privacy op cannot proceed without a durable audit record.

### V-28 — "Client can deflate quota counters to bypass caps" (Opus-F-013) → **FALSE / cosmetic**
The mirror collections *are* owner-writable with loose validation, but enforcement **never reads them back**: `MacMediaCapabilityGate`'s `usageProvider` is hardwired to a zero-initialized snapshot and `updateQuotaUsage` has **zero production callers**. Deflating the mirror changes no gate decision; attacker, writer, gate-runner, and victim are the same owner's Mac. (Out-of-scope observation: daily caps appear effectively *unenforced* because gates read zeroed in-memory state — a missing-wiring bug, not the claimed bypass.)

---

## The three already-fixed findings

- **V-14 — session_logs validation** (Kimi-F-016): `validSessionLogManifestKeys()` `hasOnly` allowlist is the first conjunct (`firestore.rules:651-660`); a plaintext denylist rejects `body`/`ciphertext`/`text`/… on create and refresh; sealed text fields are path-bound AAD'd. Kimi's M-018 is superseded by the landed M-005 fix.
- **V-33 — Android iroh key** (Kimi-F-014): secret is AES-256-GCM-wrapped under an Android-Keystore key (`IrohBlobKeyStore.kt`, `HermesRelayKeyStore.kt`); a legacy plaintext key is auto-migrated and deleted on first read.
- **V-30 (partial) — SQLite "silent plaintext"** (Kimi-F-001 rated Critical): the *silent* plaintext bug is fixed. Today it's a **loud, disclosed** plaintext fallback (`openDisclosedPlaintext`, sets `…PlaintextFallbackAcknowledged`, logs `encryption_unavailable_codec_absent`) and the cipher self-check fails closed when a codec is genuinely present. Kimi's "Critical/silent" framing is outdated; Opus-F-004's "Low/disclosed" is correct.

---

## The SQLCipher contradiction, resolved once

Three audits disagreed; here is the single ground truth. The Xcode project links `SahebRoy92/GRDB-SQLCipher`, **but** that package's `Package.swift` ships SQLite as `.systemLibrary(name: "CSQLite", … link "sqlite3")` — i.e. **stock system `libsqlite3`, no `SQLITE_HAS_CODEC`**. No SQLCipher amalgamation is vendored. Therefore `PRAGMA key` is a silent no-op and `PRAGMA cipher_version` returns empty.

- **Kimi (Critical, "silent plaintext"):** directionally right that the DB is plaintext, but the *silent* fallback it describes is already fixed (it's now loud/disclosed) and "Critical" overstates a local-only, FileVault-covered, honestly-disclosed state.
- **Opus (Low, accepted):** **correct.** Disclosed plaintext; fail-closed when a codec is actually present.
- **Codex (Low, "key creation continues after Keychain failure"):** **true as written** (`DatabaseEncryptionService.swift:95-117` returns the in-memory key on `SecItemAdd` failure rather than failing closed) — but **inert** today because the codec is inactive, so the key encrypts nothing. Worth fixing for correctness before any real SQLCipher codec is ever linked.

SOTA note (see `02-SOTA-2026-RESEARCH.md` §4): against a **same-user** adversary on an unsandboxed Mac, SQLCipher does **not** meaningfully help — the key must live somewhere the same user can reach. The high-value move is moving **OAuth/refresh tokens out of SQLite into the Keychain** (`…WhenUnlockedThisDeviceOnly` + signed ACL), and being honest that local-DB encryption protects only the at-rest/exfil/lost-disk boundary (which FileVault already covers).

---

## Auditor scorecard (which model to trust on what)

| Audit | Strengths | Weaknesses |
|-------|-----------|------------|
| **Opus-4.8-1M** | Most precise; found the only Critical (V-10); correct on SQLCipher; honest "disclosed/accepted" framing | One false positive (V-28 quota); rated V-10 only Medium |
| **Codex-GPT-5** | Best concrete logic bug (V-17 Stripe); good on deploy/WIF reality (V-25) | V-23b misreads the fail-closed audit; over-weights daemon local-auth (−12) |
| **GLM-5.2** | Good coverage breadth; correctly flagged watchdog/phone-UI; actionable roadmap | Some residuals are accepted-risk re-statements |
| **Kimi/K2** | A few real catches (MCP snippets V-35, Cursor tunnel V-36, prompt-injection V-34) | **Corrupted `findings.md`** (merge-conflict marker); two hallucinated absences (V-08, V-09); stale findings (V-14, V-33); SQLCipher "Critical" wrong |

**Practical guidance:** trust Opus/Codex line-level evidence; treat Kimi findings as leads to verify, not facts — but don't dismiss Kimi wholesale (V-34/V-35/V-36 are real and were missed by the others).
