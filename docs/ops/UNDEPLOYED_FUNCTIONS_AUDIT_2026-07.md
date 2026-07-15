# Undeployed Cloud Functions Audit — 2026-07

**Packet:** P-OPS-1 (Operation 9 Wave 0, agent-prep portion)
**Originating finding:** Diligence 2026-07-14, Ops §LB-1 — "Backend compute deploy plane unproven; production functions 26+ days stale."
**Baseline commit:** `994bc552885908d05852ce9955e39109a872e790` (origin/main, 2026-07-14)
**Audit date:** 2026-07-15
**Scope:** read-only inspection of the deployment workflow, env wiring, and reachable `functions/` commit diff. **No production or secret mutation.** This audit does NOT perform A1 deploys and does NOT close #1091 — both are Alberto-only operator actions.

---

## 1. Live production state (read-only evidence)

### 1.1 Cloud Functions — frozen at 2026-06-18

Every production Cloud Function `updateTime` is `2026-06-18T16:42–16:45Z`. This is confirmed by a live `gcloud functions list` capture (2026-07-15), which lists ~150 functions all stamped the same deploy window. Key security-relevant callables in the frozen set:

| Function | updateTime |
|---|---|
| `healthReady` | 2026-06-18T16:42:37Z |
| `healthLive` | 2026-06-18T16:42:41Z |
| `burnBarHermesGateway` | 2026-06-18T16:42:37Z |
| `searchKnowledge` | 2026-06-18T16:44:06Z |
| `triggerVoIPCall` | 2026-06-18T16:42:53Z |
| `submitAgentNotificationReply` | 2026-06-18T16:42:38Z |
| `deleteDomainData` | 2026-06-18T16:45:50Z |
| `insightsHostedAnswer` | 2026-06-18T16:43:47Z |
| `bindAppCheckAttestation` | 2026-06-18T16:44:13Z |
| `issueHighRiskActionNonce` | 2026-06-18T16:44:23Z |

> **Evidence source:** live `gcloud functions list --project burnbar --format value(name,updateTime)` (capture provided by Main, 2026-07-15). Full list available as `artifact://135`.

### 1.2 Cloud Run services (from diligence report)

Per diligence 2026-07-14 §LB-1:
- `openburnbar-hosted-mcp`: Cloud Run deploy lane (`deploy-cloud-run.yml`) — 1 success in ~150 runs; issue #1091 tracks 41 consecutive failures.
- `openburnbar-quota-runner`: last deployed 2026-05-09 (`LAST_MODIFIER = alberto8793@gmail.com`).
- `openburnbar-ots-verifier`: last deployed 2026-05-18 (same modifier).

### 1.3 Issue #1091 — OPEN, 41 failures

- **State:** OPEN
- **Labels:** `P0 - Critical`, `area: infra`, `lane:deploy-cloud-run`, `failures:41`
- **Created:** 2026-06-30
- **Last update:** 2026-07-06 (41 recurrence comments, all Cloud Run deploy failures from `refs/tags/v1.0.6` through `v1.0.29`)
- **This audit does NOT close #1091.** Closure is an Alberto-only action (A1 step 4) contingent on a successful real deploy.

---

## 2. Release tag stop condition (critical pre-deploy blocker)

### 2.1 Tag mismatch — independently verified

| Artifact | Commit | Date |
|---|---|---|
| Latest release tag `v1.0.29` | `ba39ea388fb9775938d4f51fd76cb16ec2cb38b1` | 2026-07-06 14:38:45 -0500 |
| PR #1572 merge (deploy env-policy fix) | `bf7462683c6bad2e9ac7c537279397cc9ba8ae26` | 2026-07-12 17:48:25 -0500 |

**Ancestry check (read-only):**
```
git merge-base --is-ancestor bf7462683c v1.0.29 → NO (tag predates the fix)
git merge-base --is-ancestor bf7462683c origin/main → YES (fix is on main)
```

All ten most-recent `v*` tags (v1.0.29 through v1.0.21, plus `v2026.7.1`) **predate PR #1572**. No existing release tag contains the environment-policy fix.

### 2.2 Stop condition

**A new immutable release tag whose commit contains `bf7462683c` (and the vetted function state) is required before the A1 deploy sequence.** Do not move, reuse, or re-tag `v1.0.29` — it is immutable and points at pre-fix code. Dispatching from `refs/tags/v1.0.29` cannot exercise the workflow/environment fix merged in PR #1572.

### 2.3 Additional stranded commits beyond the latest tag

27 `functions/` commits exist between `v1.0.29` and `origin/main` that no tag covers:
```
git log --oneline v1.0.29..origin/main -- functions/ → 27 commits
```

---

## 3. Undeployed `functions/` commit enumeration

### 3.1 Method

```bash
git log --oneline 994bc55288 --since=2026-06-18 -- functions/
```

**Total: 174 reachable commits** (the diligence report cited 173; the exact `git log` count at baseline is 174 — the difference is likely a boundary-inclusive commit).

### 3.2 Classification: security-relevant vs. other

**96 security-relevant** | **78 other** (infrastructure, CI, features, rollups, deps)

Security-relevant commits are those touching auth, App Check, rate limiting, input validation, escrow, secrets, credentials, tokens, entitlement enforcement, BOLA/denial contracts, vault rotation, attestation, replay guards, or boundary/binding/proof logic — any of which changes the security posture of production callables.

### 3.3 Must-verify-before-deploy subset

Commits touching **auth / App Check / rate-limit / validation / escrow / secret / credential** are marked **must-verify-before-deploy**: each changes a security control that the July-14 Firestore rules enforce against, and the July-rules / June-functions combination has never been tested together.

---

## 4. Security-relevant commits (must-verify-before-deploy)

| # | SHA | Date | Subject | Category |
|---|---|---|---|---|
| 1 | `eb236816da` | 2026-07-13 | fix(firestore): consolidate rules under backend limit (#1687) | validation/rules |
| 2 | `8a1a493105` | 2026-07-12 | Merge branch 'main' into devin/1782960873-deletedomain-stepup | auth (step-up gate) |
| 3 | `f6706aee11` | 2026-07-11 | Hardening: close launch-readiness proof gaps (#1435) | boundary/proof |
| 4 | `e079224d40` | 2026-07-07 | fix(ci): make PR #1360 gates green — Linux daemon on merged main, lint, privacy, licenses | privacy |
| 5 | `c0b43834d5` | 2026-07-03 | fix(functions): drop dead App Check validation imports/exports (lint green) | **App Check + validation** |
| 6 | `ca2125f11b` | 2026-07-03 | Fix post-merge CI: unsafe casts, callable validation, symlinks, schema baseline | **validation + unsafe-cast** |
| 7 | `ca10356abe` | 2026-07-03 | Fix: reconcile publicRateLimit.ts — main's checkHostedInsightsAnswerRateLimit + feature's Linux/Windows AppCheck endpoints | **rate-limit + App Check** |
| 8 | `13d5829af8` | 2026-07-02 | Merge PR #1140 — remote MCP posture guard | **auth/token posture** |
| 9 | `87a0d950ef` | 2026-07-02 | Merge PR #1139 — hosted answer rate limit | **rate-limit** |
| 10 | `844b966e8c` | 2026-07-02 | test(functions): expose remote MCP HMAC binding mock | **HMAC/secret** |
| 11 | `eb5a659efe` | 2026-07-02 | fix(functions): cap hosted answer payload size | **validation/bound** |
| 12 | `b8deb667fb` | 2026-07-02 | Merge PR #1122 — callable input validation | **validation** |
| 13 | `0fc5bcf0bc` | 2026-07-02 | fix(functions): avoid binding remote MCP HMAC secret in production | **HMAC/secret** |
| 14 | `ad0c1a0378` | 2026-07-01 | fix(functions): harden callable validation ratchet | **validation** |
| 15 | `9d7bf9b695` | 2026-07-01 | fix(functions): clear callable validation CI ratchets | **validation** |
| 16 | `0658fcadaa` | 2026-07-02 | Gate deleteDomainData behind trusted-device step-up | **auth/step-up/escrow** |
| 17 | `2a1df0bc38` | 2026-07-02 | fix(functions): cap prompt size and rate-limit hosted OpenRouter proxy per user | **rate-limit + bound** |
| 18 | `ec6e6a96ff` | 2026-07-02 | Enforce Remote MCP issuer token posture at runtime | **auth/token/issuer** |
| 19 | `12dd7f62d5` | 2026-07-01 | Merge PR #1117 — security-escrow-failclosed | **escrow** |
| 20 | `7d654bf123` | 2026-07-01 | feat(functions): input validation for high-risk callables + shrink-only guard (R-S1) | **validation** |
| 21 | `9465603e71` | 2026-06-30 | fix(functions): fail-closed on Remote-Config kill/budget publish (R-L3f) | **kill/budget fail-closed** |
| 22 | `d055136513` | 2026-06-29 | Fix Firebase Hosting WIF deploy auth | **auth (WIF)** |
| 23 | `25fd89acc7` | 2026-06-28 | fix(security): harden local secret and quota boundaries | **secret/boundary** |
| 24 | `d1d8928723` | 2026-06-27 | fix(rules): keep mission updates within rules budget | **budget** |
| 25 | `14fe166f8c` | 2026-06-27 | fix(escrow): align credential envelope writes with rules (#1016) | **escrow/credential** |
| 26 | `d2bb725e00` | 2026-06-27 | fix(functions): keep provider refresh markers schema-valid (#1013) | **validation** |
| 27 | `38abb17bb2` | 2026-06-27 | fix(functions): harden hosted quota proof evidence | **proof/bound** |
| 28 | `d9a0a461b4` | 2026-06-26 | fix(functions): preserve queued grant key kind | **grant/secret** |
| 29 | `3475e70f3a` | 2026-06-26 | fix(functions): bound media freeze rollup inputs | **validation/bound** |
| 30 | `cc86f02688` | 2026-06-26 | fix(functions): reject malformed cloud vault aad parts | **vault/validation** |
| 31 | `e159c41d7a` | 2026-06-26 | fix(functions): bound quota payload harvesting | **validation/bound** |
| 32 | `a680aa3ec5` | 2026-06-26 | Merge PR #941 — repo-webhook-binding | **boundary/binding** |
| 33 | `f310924c59` | 2026-06-26 | Merge PR #945 — unsafe-cast-scanner | **unsafe-cast** |
| 34 | `3e596b2cea` | 2026-06-26 | Merge PR #944 — bola-denial-contract | **BOLA/denial** |
| 35 | `cea5e51ace` | 2026-06-26 | test(ci): strengthen unsafe-cast debt scanner | **unsafe-cast** |
| 36 | `b4c9aaec23` | 2026-06-26 | fix(functions): export opaque repo installation tokens | **token/secret** |
| 37 | `2acbbb7969` | 2026-06-26 | test(functions): require explicit BOLA denial outcomes | **BOLA/denial** |
| 38 | `77d0ad511f` | 2026-06-26 | test(functions): cover budget spend lower bound | **budget/bound** |
| 39 | `e8c8863d5c` | 2026-06-26 | fix(functions): cap computer use budget projection | **budget/bound** |
| 40 | `86f09a5473` | 2026-06-26 | fix(functions): harden Computer Use budget spend rollups | **budget** |
| 41 | `72a4b0ccde` | 2026-06-25 | fix(security): bind OTS validation to audit chain head | **validation** |
| 42 | `50b9d29e87` | 2026-06-25 | fix(functions): gate cloud provider credential methods | **credential** |
| 43 | `3dec348490` | 2026-06-25 | fix(provider): enforce credential routing eligibility | **credential** |
| 44 | `1be100baac` | 2026-06-25 | fix(functions): keep remote mcp knowledge scope opt-in | **boundary/scope** |
| 45 | `6215126793` | 2026-06-25 | fix(functions): rate limit account quota refresh | **rate-limit** |
| 46 | `8f55f2257c` | 2026-06-25 | fix(recovery): bind setup to current vault key | **vault/key** |
| 47 | `d15ad8dbfb` | 2026-06-24 | fix(functions): bind design arena benchmark secret | **secret** |
| 48 | `8b298e0d32` | 2026-06-24 | Bound session log facet tags | **validation/bound** |
| 49 | `354ba458c2` | 2026-06-24 | fix(rules): bound realtime relay metadata | **validation/bound** |
| 50 | `a69f61613f` | 2026-06-23 | fix(functions): bound cloud search index writes | **validation/bound** |
| 51 | `13b1e2ea3e` | 2026-06-23 | fix(rules): accept Play Cloud Pro for data vault | **vault** |
| 52 | `07a93d924e` | 2026-06-23 | fix(rules): gate memory fact writes by data vault entitlement | **entitlement/vault** |
| 53 | `b0c52b482b` | 2026-06-23 | test(functions): cover Pi Agent relay privacy boundary | **privacy/boundary** |
| 54 | `485a454a8b` | 2026-06-23 | fix(rules): harden signal identity bootstrap boundary | **identity/boundary** |
| 55 | `87eaca631b` | 2026-06-23 | fix(functions): harden App Store entitlement binding | **entitlement/binding** |
| 56 | `8b8ddad43c` | 2026-06-23 | fix(functions): reject stale Google Play top-up tokens | **token/stale** |
| 57 | `133b52119c` | 2026-06-23 | test(security): pin cloud allowance replay guards | **replay** |
| 58 | `5324f9e683` | 2026-06-23 | fix(security): bind relay sender key publication proof | **key/proof** |
| 59 | `9708607f1e` | 2026-06-23 | fix(security): bind phone-control authority attestation | **attestation** |
| 60 | `1f41e2f661` | 2026-06-22 | test(security): cover remote MCP token storage | **token/secret** |
| 61 | `847dad3bfe` | 2026-06-22 | security: enforce hosted MCP suspension gates | **suspension/gate** |
| 62 | `d7c185cb30` | 2026-06-22 | security: close escrow grant revoke race | **escrow/revoke** |
| 63 | `8d7af95d5c` | 2026-06-22 | security: seal CLI link credential delivery | **credential** |
| 64 | `5368034258` | 2026-06-22 | security(functions): harden BOLA catalog maintenance parsing | **BOLA** |
| 65 | `a884136571` | 2026-06-22 | security(functions): parse generated catalogs safely | **safe-parsing** |
| 66 | `fa3d4f5557` | 2026-06-22 | test(functions): cover cloud pro top-up replay | **replay** |
| 67 | `2d5c4a2973` | 2026-06-22 | security: reserve hosted search quota before provider work | **quota/reserve** |
| 68 | `74d398d019` | 2026-06-22 | security: bind App Store entitlement environment | **entitlement** |
| 69 | `85b155ab4a` | 2026-06-22 | security: gate knowledge resync queueing | **gate** |
| 70 | `71400698ed` | 2026-06-22 | Merge PR #676 — tier-cogs-path-boundary | **boundary** |
| 71 | `cbb23b4f8e` | 2026-06-22 | Merge PR #674 — hosted-entitlement-receipt-boundary | **entitlement/boundary** |
| 72 | `610933cb94` | 2026-06-22 | Merge PR #669 — runtime-secret-boundary | **secret/boundary** |
| 73 | `1eadca6cb9` | 2026-06-22 | fix(pi-agent): reject legacy redis pairing fields | **validation** |
| 74 | `fe4597e1f6` | 2026-06-22 | security: bind CloudVault rotation survivors | **vault/rotation** |
| 75 | `58a18fb49d` | 2026-06-22 | security: canonicalize mission approval states | **approval** |
| 76 | `c860df5f66` | 2026-06-22 | security: keep Pi relay registry secrets local | **secret** |
| 77 | `e2cd781d49` | 2026-06-21 | fix(appstore): bound entitlement owner lookup | **entitlement/bound** |
| 78 | `8f65506457` | 2026-06-21 | fix(appstore): handle same-user entitlement crossgrades | **entitlement** |
| 79 | `46d69a5577` | 2026-06-21 | Merge into security-remediation-wave26-entitlement-boundary | **entitlement/boundary** |
| 80 | `3e6499ae2f` | 2026-06-21 | fix(functions): reject ambiguous app store restores | **validation** |
| 81 | `ba41587b4d` | 2026-06-21 | fix: preserve entitlement restore compatibility | **entitlement** |
| 82 | `65f5511f65` | 2026-06-21 | fix(functions): preserve no-token app store restore | **token** |
| 83 | `0965d70968` | 2026-06-21 | test: cover relay sender key trust binding | **key/trust** |
| 84 | `82730a1b16` | 2026-06-21 | security: require app store entitlement binding proof | **entitlement/proof** |
| 85 | `81b21a9676` | 2026-06-21 | security: harden Cloud Pro allowance accounting | **allowance** |
| 86 | `be43883d2e` | 2026-06-21 | security: keep pairing revocation available | **revocation** |
| 87 | `4887ad7965` | 2026-06-21 | security: require entitlement for agent control callables | **entitlement/auth** |
| 88 | `60216e6912` | 2026-06-21 | security: redact telemetry issue sync payloads | **redaction/telemetry** |
| 89 | `cc81562655` | 2026-06-21 | test(functions): cover cloudvault rotation proof handoff | **vault/proof** |
| 90 | `2f14b9594a` | 2026-06-21 | fix(functions): require proof for cloudvault rotation source | **vault/proof** |
| 91 | `d5e41bd560` | 2026-06-21 | security: bind cloudvault rotation wrapper source | **vault/rotation** |
| 92 | `4fd4778528` | 2026-06-21 | security: harden app store entitlement ordering | **entitlement** |
| 93 | `7276e6ce41` | 2026-06-20 | security: harden BOLA coverage validation | **BOLA/validation** |
| 94 | `f6ac511480` | 2026-06-20 | security: harden release and credential boundaries | **credential/boundary** |
| 95 | `2417372bcd` | 2026-06-19 | fix(memory): retire stale review tombstones (#601) | **stale/review** |
| 96 | `618eb2707f` | 2026-06-18 | fix: clean up legacy shared artifact plaintext (#553) | **plaintext/privacy** |

---

## 5. Other commits (non-security)

Infrastructure, CI, features, rollups, deps, and data-path changes that do not alter security controls:

| SHA | Date | Subject |
|---|---|---|
| `8b254f3779` | 2026-07-14 | feat(domain-core): land shared Rust union and rollout evidence (#1722) |
| `1f25efcbfc` | 2026-07-13 | fix(core-decomp merge): repoint functions kimi-pricing test to catalog.json's Kernel path |
| `874c3b173d` | 2026-07-11 | deps(deps-dev): bump firebase-tools in /functions (#1502) |
| `4cad221ed5` | 2026-07-11 | feat(linux): complete parity foundations and fail-closed certification (#1431) |
| `ecd959d859` | 2026-07-11 | deps(deps-dev): bump morgan (#1466) |
| `ec83a7b088` | 2026-07-08 | Merge remote-tracking branch 'origin/main' into HEAD |
| `227c77cbe3` | 2026-07-08 | fix: refresh launch readiness branch after merge wave |
| `40b168cda3` | 2026-07-08 | Merge PR #1408 — ops/staging-environment-scaffold |
| `eca7c090df` | 2026-07-08 | fix: repair staging deploy scaffold |
| `a3fcbd7972` | 2026-07-08 | Merge main into launch readiness hardening |
| `3cc0a15616` | 2026-07-08 | Merge main into quota proxy SOTA |
| `9a49a4074e` | 2026-07-08 | ops(staging): scaffold pre-prod staging environment for rules/functions rehearsal |
| `722948d3b0` | 2026-07-08 | Hardening launch readiness gates |
| `a33a432d18` | 2026-07-08 | Repair quota proxy CI follow-ups |
| `14176c5db8` | 2026-07-08 | Merge main and repair quota proxy review gates |
| `555287cdea` | 2026-07-07 | Merge branch 'main' into dependabot/npm_and_yarn/functions/firebase-tools-15.22.4 |
| `478f8f8129` | 2026-07-06 | deps(deps-dev): bump firebase-tools in /functions |
| `387989d4d9` | 2026-07-05 | feat(linux): land mission-001 desktop port |
| `8092d19ea1` | 2026-07-04 | feat(windows): atomic integration — all 17 parity-burndown PRs + macOS app BUILD SUCCEEDED (#1267) |
| `94f31ab150` | 2026-07-04 | Fix functions CI export gates |
| `a7606ce7e4` | 2026-07-04 | Fix quota proxy CI gates |
| `ee02e957ce` | 2026-07-04 | Fix quota proxy PR gate failures |
| `cd4c22f5da` | 2026-07-04 | Implement quota proxy SOTA plan |
| `ff8a898277` | 2026-07-03 | Merge origin/main into feat/command-deck-dashboard |
| `9e6912bc8d` | 2026-07-03 | Windows port Phase 0 macOS milestone + worktree state |
| `e4ad35faad` | 2026-07-01 | fix(functions): avoid quota burn before OpenRouter preflight |
| `20d9c7c32b` | 2026-06-30 | fix(functions): honor Ultra entitlements for sync gates (#1097) |
| `5b8d860512` | 2026-06-27 | fix(rules): allow rainbow smart display palettes |
| `cf46af6a75` | 2026-06-27 | fix(functions): harden paid-tier proofs and usage telemetry |
| `d53673692c` | 2026-06-27 | fix(functions): keep Android call routing out of FCM |
| `70ab9d6bd7` | 2026-06-27 | fix(functions): align Android call push routing context |
| `71ecfd8140` | 2026-06-27 | fix(functions): order usage rollup delta drains deterministically |
| `a53dac8afb` | 2026-06-27 | fix(functions): honor recorded usage timestamps in rollups |
| `3c44062413` | 2026-06-27 | fix(rules): honor Cloud Pro mirror entitlements |
| `db4c9cbdca` | 2026-06-26 | test: repair post-merge scanner findings |
| `ac33485b28` | 2026-06-26 | test: repair post-merge review findings |
| `bd3e40ef36` | 2026-06-26 | fix(functions): avoid structural response casts |
| `2ed2c0831c` | 2026-06-26 | test(functions): exercise repo webhook test hooks |
| `5bc5bb0c94` | 2026-06-26 | fix(functions): preserve verified legacy repo webhooks |
| `a3130596fe` | 2026-06-26 | fix(functions): harden project memory legacy cleanup ids |
| `3f5d9cac45` | 2026-06-26 | fix(functions): bind knowledge repo GitHub app secrets |
| `9180fa61c8` | 2026-06-26 | fix(ci): satisfy repo webhook ratchets |
| `2274a0c102` | 2026-06-26 | fix(security): verify repo webhook registrations |
| `3dac9282e8` | 2026-06-26 | fix(functions): align billing data export paths |
| `b64d0e15af` | 2026-06-26 | fix: register iroh rollup trigger coverage |
| `cf0d340154` | 2026-06-26 | fix: close merged review residue |
| `ee6309c038` | 2026-06-25 | fix(functions): charge knowledge vector rewrites consistently |
| `faf2856a82` | 2026-06-25 | fix(functions): constrain hosted quota runner endpoint |
| `0d9ad30c45` | 2026-06-25 | fix(functions): rotate rollup resume task names |
| `919d9a91c6` | 2026-06-25 | fix(functions): declare Hermes gateway event indexes |
| `23c5c965a0` | 2026-06-25 | fix(functions): gate iroh audit rollups on server eligibility |
| `a3e3cd9fa2` | 2026-06-25 | fix(functions): isolate demo provider quota refresh |
| `439c1adc2d` | 2026-06-24 | fix(functions): hash device link log identifiers |
| `0c28889ea4` | 2026-06-24 | fix(functions): bind provider account secrets to provider |
| `20e0b298f5` | 2026-06-24 | fix(functions): validate knowledge search limits |
| `a554562e43` | 2026-06-24 | fix(functions): retain account erasure audit intent |
| `013ae129c3` | 2026-06-24 | fix(functions): disambiguate gateway pop query signing |
| `9b9a08d944` | 2026-06-24 | fix(functions): bind gateway attachment signed URLs |
| `f208b38234` | 2026-06-24 | fix(cloud): delete legacy session log chunks |
| `ed880ce18a` | 2026-06-24 | fix(rules): keep session tombstones sticky |
| `4d8237eb62` | 2026-06-24 | fix(cloud): honor session-log tombstones across reads |
| `c79ef1dd88` | 2026-06-24 | fix(cloud): hide tombstoned session logs |
| `7a1067d304` | 2026-06-24 | Merge PR #808 — fix-cloud-search-postmerge-806 |
| `a55c45a200` | 2026-06-24 | fix(search): close capped fallback review gaps |
| `0500eaeb99` | 2026-06-24 | fix(rules): keep provider account refresh entries server-owned |
| `7ee301e0c0` | 2026-06-24 | fix(search): preserve capped cloud-search recall |
| `523210f81a` | 2026-06-23 | fix(functions): retry app store webhook transient failures |
| `216e48ee84` | 2026-06-23 | fix(functions): preserve phone control peer bindings |
| `08db92ec70` | 2026-06-23 | fix(functions): prevent caching CLI link credentials |
| `cea73550af` | 2026-06-23 | fix(functions): harden Google Play top-up verification |
| `6093902302` | 2026-06-22 | deps(deps-dev): bump firebase-tools in /functions |
| `f17613bb26` | 2026-06-22 | fix(pi-agent): satisfy response sanitizer debt gate |
| `24a7f8209d` | 2026-06-22 | fix(functions): write tier cogs to day documents |
| `c477cba429` | 2026-06-21 | fix: satisfy telemetry redaction gates |
| `5dff3a1813` | 2026-06-21 | fix: harden Sentry issue redaction |
| `db5ae698c3` | 2026-06-19 | chore(release): repair 1.0.5 gate metadata |
| `13227bf03c` | 2026-06-19 | feat: opt-in Amplitude analytics across all platforms (#560) |
| `430df460e2` | 2026-06-19 | feat(memory): sync approved facts to cloud (#597) |

---

## 6. Production env file — presence and secret safety

### 6.1 File present and tracked

```
$ test -f functions/.env.burnbar.production → PRESENT
$ ls -l functions/.env.burnbar.production → -rw-r--r--  5563 bytes
$ git ls-files functions/.env.burnbar.production → tracked (committed)
$ git check-ignore functions/.env.burnbar.production → NOT GITIGNORED
```

The file is explicitly un-ignored by `functions/.gitignore:25` (`!.env.burnbar.production`), overriding the general `*.env` / `.env.*` patterns.

### 6.2 Contents are non-secret public IDs only

The file's own header states: "NON-SECRET VALUES ONLY. Every key below is a public identifier or URL." Keys present (values redacted — no secret values in this audit):

```
# Product & price IDs (public):
STRIPE_BURNBAR_PRO_PRICE_ID, STRIPE_BURNBAR_CLOUD_*_PRICE_ID, ...
BURNBAR_PRO_PRODUCT_ID, BURNBAR_PRO_MAX_PRODUCT_ID, BURNBAR_ULTRA_PRODUCT_ID, ...
GOOGLE_PLAY_*_PRODUCT_ID, GOOGLE_PLAY_PACKAGE_NAME, ...
APP_STORE_APPLE_APP_ID, APP_STORE_BUNDLE_ID, APP_STORE_ENV, ...
HOSTED_QUOTA_PRODUCT_ID, HOSTED_QUOTA_RUNNER_URL, ...
AGENT_CONTROL_100_ACTIONS_PRODUCT_ID, ELDER_WAND_SEARCHES_*_PRODUCT_ID, ...

# App Check enforcement:
ENFORCE_APP_CHECK

# APNs (public topic/host):
APNS_HOST, APNS_VOIP_TOPIC

# OTS verifier (public URLs):
OPENBURNBAR_OTS_STAMP_URL, OPENBURNBAR_OTS_VERIFY_URL, OPENBURNBAR_OTS_VERIFY_AUDIENCE

# Hosted quota limits:
HOSTED_QUOTA_DAILY_REFRESH_LIMIT, HOSTED_QUOTA_MONTHLY_REFRESH_LIMIT

# Provenance:
OPENBURNBAR_CORRESPONDING_SOURCE_URL

# Remote MCP:
REMOTE_MCP_RUNTIME_ENVIRONMENT
```

**No `SENTRY_DSN` in the committed file** — it is an Actions secret (see §7).

**No secret values (API keys, passwords, tokens) are committed.** The file header confirms: "Real secrets (FIREBASE_TOKEN, GCP_SA_KEY, Stripe SECRET key, APNs key) are NEVER stored here — they remain GitHub Actions secrets / Secret Manager."

### 6.3 Deploy-time env assembly

The deploy workflow (`deploy-production.yml` step "Deploy Cloud Functions") assembles the runtime env by:
1. Checking `$PROD_CONFIG` (`functions/.env.burnbar.production`) exists — fail-closed if missing.
2. Appending per-deploy dynamic values on top: `FUNCTION_VERSION`, `OPENBURNBAR_SOURCE_COMMIT`, `SENTRY_DSN` (from Actions secret), `SENTRY_ENVIRONMENT=production`.
3. Writing the combined file to `functions/.env.burnbar` (the firebase-tools target).

Both the deploy lane and `scripts/rollback.sh` source the **same** committed `functions/.env.burnbar.production`, so a deploy and a rollback can never disagree or ship empty config.

---

## 7. SENTRY_DSN wiring — required and fail-closed

### 7.1 How SENTRY_DSN is required

**Deploy-time gate** (`deploy-production.yml:232-235`):
```bash
if [[ -z "${SENTRY_DSN:-}" ]]; then
  echo "::error::Missing SENTRY_DSN — refusing to deploy production functions with crash reporting disabled."
  exit 1
fi
```

The `SENTRY_DSN` env var is sourced from the Actions secret `SENTRY_DSN_FUNCTIONS` (`deploy-production.yml:213`), injected into the `deploy-functions` job env under `environment: production`.

**Post-deploy health gate** (`deploy-production.yml:308`):
```yaml
HEALTH_GATE_REQUIRE_SENTRY: "1"
```

The `functions-health-gate` job asserts Sentry is live (not just provisioned) via `scripts/ci/post-deploy-health-gate.sh`, which probes the `healthReady`/`healthLive` endpoints for the Sentry status snapshot.

### 7.2 How SENTRY_DSN is wired at runtime

**`functions/src/sentry.ts:21`**:
```typescript
const dsn = process.env.SENTRY_DSN;
```

If set, Sentry is initialized with the DSN, release (`FUNCTION_VERSION`), and environment (`SENTRY_ENVIRONMENT`). If unset, `sentry.ts:95` logs `"sentry_disabled"` and continues — but the deploy gate (§7.1) prevents an empty DSN from reaching production.

**`sentry.ts:104-106`** exposes a health surface:
```typescript
export function sentryStatus(): { enabled: boolean; environment: string } {
  return { enabled: Boolean(dsn), environment };
}
```

This is read by the health-gate health endpoint to assert `enabled: true` in production.

### 7.3 DSN is NOT a committed secret

Per the workflow comments (`deploy-production.yml:208-212`): "DSNs are low-sensitivity (write-only ingest endpoints, not credentials), but are not public product IDs, so the value lives in an Actions secret rather than the committed `.env.burnbar.production`."

### 7.4 Staging uses a separate DSN

`deploy-staging.yml:278` sources `STAGING_SENTRY_DSN_FUNCTIONS` (optional, fail-open for bare staging projects), and writes `SENTRY_ENVIRONMENT=staging` — separate from production.

---

## 8. Deploy preflight steps (source-backed, read-only)

These are the exact steps from the production deploy workflow, annotated with the source location and evidence placeholder. **Agents must not execute these** — they are Alberto-only (A1) actions from a checked-out `refs/tags/<new-tag>`.

### Step 0 — Prerequisite: create a new release tag (STOP CONDITION)

> No existing tag contains PR #1572's fix. A new immutable release tag at a commit containing `bf7462683c` must be created through the normal release process before any dispatch. See §2.

```
# Verify the new tag contains PR #1572:
git merge-base --is-ancestor bf7462683c <new-tag>  # must succeed
# Verify the new tag is reachable from origin/main:
git merge-base --is-ancestor <new-tag-commit> origin/main  # must succeed
```

### Step 1 — Functions dry-run (build + verifiers, no deploy)

**Source:** `deploy-production.yml` `workflow_dispatch` with `dry_run=true`
**Workflow:** `.github/workflows/deploy-production.yml`

The dry-run runs these verification steps (lines 119-137):
1. `npm ci --prefix functions && npm run build --prefix functions`
2. `bash scripts/ci/verify-callable-logging.sh` — structured logging enforcement
3. `bash scripts/ci/verify-resilience-wiring.sh` — circuit breaker / no raw fetch
4. `node scripts/ci/check-callable-validation.mjs` — callable input validation
5. `bash scripts/ci/verify-production-deploy-auth.sh` — WIF auth posture
6. `node scripts/ci/write-firebase-hosting-ci-config.mjs --mode functions --check`
7. `bash scripts/ci/prepare-firebase-tools.sh`
8. `python3 scripts/ci/check_burnbar_release_preflight.py --source-provenance-only`
9. `python3 scripts/ci/check_burnbar_release_preflight.py`
10. Security config gate — `REQUIRE_HIGH_RISK_NONCE` must not be disabled (lines 139-158)
11. Sentry release creation (if `SENTRY_AUTH_TOKEN` present)

Dry-run **skips** the Google auth + Firestore drift check + firebase deploy (gated by `steps.tag.outputs.dry_run != 'true'`).

**Evidence placeholder:** _[paste dry-run workflow run URL after A1 execution]_

### Step 2 — Functions real deploy

**Source:** `deploy-production.yml` `workflow_dispatch` with `dry_run=false`

After the tag resolves and build passes, the real deploy runs:
1. **WIF auth** (`google-github-actions/auth` with workload identity federation — no JSON keys)
2. **Rules-first readback** — `node scripts/ci/check-firestore-deploy-drift.mjs burnbar` (line 198) — verifies prod Firestore rules hash-match main before functions deploy
3. **Deploy** — `firebase deploy --only functions --project burnbar` with the assembled env file (line 264-268)
4. **Health gate** — `functions-health-gate` job with `HEALTH_GATE_REQUIRE_SENTRY=1` (line 308-309), probes `healthReady`/`healthLive` for availability + AGPL source metadata compliance

**Evidence placeholders:**
- _[paste real deploy run URL]_
- _[paste `gcloud functions list --project burnbar --format value(name,updateTime)` showing today's date post-deploy]_
- _[paste prod `healthReady` response showing new commit hash]_

### Step 3 — Cloud Run dry-run

**Source:** `deploy-cloud-run.yml` `workflow_dispatch` with `dry_run=true`

Runs: build + test hosted MCP → Docker build smoke → artifact staging + SHA256 manifest. Skips the `deploy-hosted-mcp` job (gated by `dry_run != 'true'`).

**Evidence placeholder:** _[paste Cloud Run dry-run run URL]_

### Step 4 — Cloud Run real deploy

**Source:** `deploy-cloud-run.yml` `workflow_dispatch` with `dry_run=false`

Runs: WIF auth → deployer IAM verification (required roles, no Secret Manager payload access) → capture current state → build + deploy → health probe → **readback** (lines 579-666):
- 100% traffic on latest ready revision
- `OPENBURNBAR_STORAGE_BUCKET` matches (no env drift)
- `MCP_RESOURCE` matches
- `MCP_AUTH_ISSUER` matches
- Auto-rollback on failure (pins traffic to previous revision)

**Evidence placeholders:**
- _[paste Cloud Run real deploy run URL]_
- _[paste readback JSON showing latestReadyRevisionName + traffic=100%]_

### Step 5 — Close #1091 (Alberto-only)

After all four dispatches succeed, close issue #1091 with the run URLs as disposition.

---

## 9. July-rules / June-functions skew risk

The diligence report (§LB-1 sub-risk) identifies the combination of July-14 Firestore rules enforcing against June-18 function write patterns as "the most likely spontaneous production breakage." Specifically:

- **Append-only escrow:** rules may enforce write patterns the frozen functions don't produce
- **Spend caps:** rules may enforce budget limits the frozen functions don't check
- **Monotonic counters:** rules may enforce ordering the frozen functions don't guarantee

**Mitigation in the deploy path:** The `check-firestore-deploy-drift.mjs` step (§8 Step 2) runs before functions deploy and verifies prod rules hash-match main. This confirms the rules are current, but does NOT test that the functions' write patterns are compatible with those rules — that integration is untested.

**Recommendation:** after the first real deploy, run `firestore-rules-tests` against the newly-deployed functions to verify the rules/functions combination. If the audit finds a stranded security fix (§4), verify it deploys correctly and re-run the relevant rules tests.

---

## 10. Operator-only blockers (Alberto actions)

This audit is agent-prep only. The following are Alberto-only actions that must not be attempted by agents:

| Action | Description | Status |
|---|---|---|
| **A1** | Trigger production deploys (`deploy-production.yml`, `deploy-cloud-run.yml` `workflow_dispatch`) from `refs/tags/<new-tag>` | **BLOCKED** — no tag contains PR #1572; new tag required first |
| **A1 step 5** | Close issue #1091 with run URLs as disposition | **BLOCKED** — contingent on successful A1 deploy |
| **New tag** | Create a new immutable release tag containing `bf7462683c` + vetted function state | **Prerequisite for A1** |

---

## 11. Reproducibility

All evidence in this audit is reproducible from the repository at baseline `994bc55288`:

```bash
# Commit count
git log --oneline 994bc55288 --since=2026-06-18 -- functions/ | wc -l   # 174

# Tag ancestry
git merge-base --is-ancestor bf7462683c v1.0.29    # exit 1 (NOT ancestor)
git merge-base --is-ancestor bf7462683c origin/main # exit 0 (IS ancestor)

# Env file presence
test -f functions/.env.burnbar.production             # present
git ls-files functions/.env.burnbar.production        # tracked
git check-ignore functions/.env.burnbar.production    # not ignored

# SENTRY_DSN wiring
grep -n 'SENTRY_DSN' .github/workflows/deploy-production.yml  # lines 213, 232-234, 246
grep -n 'SENTRY_DSN' functions/src/sentry.ts                  # line 21

# Deploy workflow locations
ls .github/workflows/deploy-production.yml .github/workflows/deploy-cloud-run.yml  # both present
ls scripts/ci/check-firestore-deploy-drift.mjs scripts/ci/post-deploy-health-gate.sh  # both present
ls scripts/rollback.sh scripts/ops/verify-production-ops-plane.sh  # both present
```