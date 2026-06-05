# Master Signalification Swarm Runbook

**Repo:** OpenBurnBar · **Migration target:** official Signal libsignal `@signalapp/libsignal-client@0.94.4` (AGPL-3.0-only, upstream commit `03c449017b57eccbda715b8b018dce5dff603ac6`)
**Authored against live code at HEAD `718990e0f` on branch `fix/hermes-gateway-e2ee-remediation-20260603`.** Every file:symbol reference below was grep/read-verified, not inferred.

---

## Coordination (read this first — it is the load-bearing fact for the whole swarm)

**The AGPL agent owns the main worktree and its dirty tree is enormous.** `git status` shows ~70 modified manifests/docs plus untracked legal artifacts. Critically:

1. **`packages/libsignal-bridge/` and `third_party/` are UNTRACKED — they exist in NO commit.** Verified: `git ls-files packages/libsignal-bridge/ third_party/` returns **empty** at HEAD `718990e0f`; `git status` shows `?? packages/libsignal-bridge/` and `?? third_party/`. The bridge (`src/index.ts`, `src/index.test.ts`, `package.json`, `package-lock.json`, `tsconfig.json`) and the manifest (`third_party/libsignal/manifest.json`, `README.md`) live **only in the AGPL agent's working tree**.

   **Consequence:** *No stream can branch off the committed bridge, because there is no committed bridge.* Every stream that imports `@openburnbar/libsignal-bridge` (Streams 1, 3, 4, 5, 8) is blocked on the AGPL agent **first committing the bridge + third_party + the manifest license footprint** to a shared base commit. **Until that commit lands, those streams build only against in-tree crypto (HermesRelayCrypto / CloudVaultCrypto) and the published npm package `@signalapp/libsignal-client@0.94.4` directly, never against the bridge re-export.**

2. **The AGPL dirty tree touches nearly every package manifest and the bridge.** Modified: `OpenBurnBarCore/Package.swift`, `OpenBurnBarDaemon/Package.swift`, `functions/package.json(+lock)`, `services/*/package.json`, `crates/*/Cargo.toml`, `packages/data-domains/package.json`, `packages/README.md`, `LICENSE`, `THIRD_PARTY.md`, plus untracked `NOTICE`, `REUSE.toml`, `THIRD_PARTY_NOTICES.md`, `LICENSES/`, `docs/legal/`. **A stream that branches off the current `HEAD` and then the AGPL agent commits gets a guaranteed merge conflict on these manifests.**

   **Rule:** **Branch off the COMMITTED AGPL state.** The orchestrator must define a single **AGPL-base commit** — the commit where the AGPL agent has landed (a) the committed `packages/libsignal-bridge/` + `third_party/`, (b) all license-field manifest edits, (c) the LICENSE/NOTICE/THIRD_PARTY*/REUSE.toml/LICENSES legal footprint. **All `signal/*` branches fork from that commit, OR rebase onto it before their first PR.** Forking off a pre-AGPL-base commit and rebasing later is acceptable but every rebase must re-verify, not just auto-merge, the manifest files (the AGPL agent is editing license fields by hand and merges are not idempotent).

3. **`packages/libsignal-bridge/` is AGPL territory requiring handoff.** Per Rule 0 the entire bridge dir is AGPL-owned. **No stream edits the bridge.** Streams **consume** `import { libsignal } from '@openburnbar/libsignal-bridge'` (or, until committed, `@signalapp/libsignal-client` directly). Any work that grows the bridge's real crypto API (Stream 1's facade), or that forces a LICENSE/NOTICE/THIRD_PARTY*/REUSE.toml/`packages/README.md`/`fast-feedback.yml` change because new Signal native binaries get vendored into shipped Swift/Android/Rust artifacts, is a **handoff to the AGPL agent**, filed as a coordination ticket — never a unilateral edit.

4. **Worktree discipline (Rule 0).** Every stream works in a **separate git worktree** off the AGPL-base commit, branch `signal/<name>`. Use `git worktree add /private/tmp/burnbar-signal-<name> signal/<name>`. The main checkout stays the AGPL agent's. Existing worktrees confirm this is the house pattern (`/private/tmp/burnbar-*`).

### AGPL-owned avoid-list (Rule 0) — NO stream may edit these
```
LICENSE  NOTICE  REUSE.toml  THIRD_PARTY.md  THIRD_PARTY_NOTICES.md  LICENSES/  third_party/  docs/legal/
CONTRIBUTING.md  README.md  packages/README.md
packages/libsignal-bridge/                      (the bridge — consume only)
functions/src/health.ts  functions/src/sourceMetadata.ts(+test)
services/*/src/server.ts  services/*/src/sourceMetadata.ts(+test)
ALL package.json / package-lock.json / Package.swift / Cargo.toml   (license fields)
scripts/ci/verify-agpl-compliance.sh  scripts/create-corresponding-source.sh
scripts/build-macos-website-release.sh  scripts/upload-macos-downloads-r2.sh
website/  (CLAIMS.md, README.md, src/data/site.ts, pages, legal/*)
docs/HERMES_GATEWAY_E2EE_REMEDIATION_PLAN.md  docs/runbooks/hermes-gateway-3features*
docs/IOS_APP_STORE_RELEASE_RUNBOOK.md  docs/OSS_LAUNCH_CHECKLIST.md  docs/RELEASE_MACOS.md  docs/pricing/*
.github/workflows/fast-feedback.yml  .deepsec/package.json  mockups/molten-token-rain.html
firestore-rules-tests/package.json(+lock)  firestore-rules-tests/tools/CUClickSmoke/Package.swift  tools/CUClickSmoke/Package.swift
various tools/*/package.json
```

**`firestore-rules-tests/` is a decoy** — its `npm test` covers only computer-use/media-budget/session-log-backup and is AGPL-owned. The real emulator suite is `functions/scripts/test-firestore-rules.mjs` (NOT in the avoid-list; Stream 7 owns it).

---

## The hard prerequisite truth (verified)

**There is ZERO Signal Protocol crypto in production today.** Verified: `grep -rEl "processPreKeyBundle|signalEncrypt|signalDecrypt|@signalapp/libsignal"` across `*.ts/*.swift/*.kt/*.py/*.rs` (excluding `node_modules`, `libsignal-bridge`, `lib/`) returns **NOTHING**. The bridge is a 45-line load-test stub: `assertOfficialLibsignalReady()` (`packages/libsignal-bridge/src/index.ts:32`) only filters which of 11 `REQUIRED_SIGNAL_PROTOCOL_SYMBOLS` are `=== undefined` and re-exports the raw `libsignal` namespace. No X3DH, no Double Ratchet, no `signalEncrypt`, no `Fingerprint` is ever called. `grep "signalEnvelope|SignalEnvelope"` across `functions/src`, `OpenBurnBarMobile`, `OpenBurnBarCore` is **clean** — this is greenfield.

Production crypto today is five families, all P-256 + AES-GCM, **none of which is Signal**: (1) custom Double Ratchet `OpenBurnBar-HermesRatchet-v1-P256-HKDFSHA256-AESGCM` (`HermesRatchetCrypto.swift:132` — NOT libsignal), (2) HPKE v2 wrap (`gatewayRelayKeyVersion = 2`, `HermesRelayCrypto.swift:121`), (3) HPKE v3 RFC 9180 Auth (`gatewayRelayKeyVersionV3 = 3`, `relayEncryptionV3 = "hpke-auth-p256-hkdfsha256-aes256gcm"`, `:127/:132`), (4) realtime v1 ECIES (unauthenticated, byte-frozen, shared with iroh/Pi), (5) CloudVault AES-256-GCM at-rest. The Python `relay_e2ee`/`hermes_ratchet` mirrors are **external** (`adapter.py:44,55` `from gateway.crypto import ...` — not committed in this repo).

**Therefore every "land Signal behind a no-op flag" first-PR is a SHAPE + facade + KAT exercise. Real Signal ciphertext cannot be produced until Stream 1 grows the bridge into a callable seal/open+session API across four languages.**

---

## Integration order (the dependency spine)

The orchestrator's mandated order, made literal:

```
[0] AGPL-base lands        → bridge + third_party committed, all license manifests committed
        │
[1] Core bridge facade     → real Signal crypto round-trip, behind no-op flag, Stream-1-owned package
        │  (gates: 3,4,5,8 consuming real Signal ciphertext)
        ├──────────────┐
[3] Hermes text/control   [crypto-inventory: parallel, no Stream-1 dep — frozen golden vectors]
        │  (v4 relay envelope shape + Swift/Python/KAT, flag OFF)
        │
[4] Hermes attachments     → signalEnvelope on attachment manifest (needs 3's envelope shape + 1's session API)
        │
[5] CloudVault domains     → pensieve first, domain-by-domain (needs 1's self-encryption Signal mode)
        │
[6] Backend gates hard     [Stream 7: parallel, no Signal dep — close residual + coverage gaps]
        │
[7] Mobile trust UX blocker → escrow fingerprint/safety-number (Stream 6, mostly no Signal dep)
        │
[8] External review / proof harness → coverage report + Signal KAT lane drop point (needs 1)
```

**crypto-inventory (the second stream map)** is the *foundation that everything reads* and has **no Stream-1 dependency** — it freezes the five legacy wire shapes as golden vectors so every later migration can prove it still opens legacy envelopes. **Run it in parallel with Stream 1 from day one; its frozen-vector PR should land at or before AGPL-base.** It maps onto the `audit-timeline`/inventory role rather than a numbered execution slot; in the runbook below it is **Stream 2 (crypto-inventory)**.

**Streams 6 (trust UX) and 7 (backend gates) have NO Signal dependency** and can start immediately off AGPL-base — they close real P1s today (escrow trust-without-verification; knowledge_repos sourceSlug residual). Per the integration order they are sequenced *after* the crypto streams for *merge* purposes (so trust UX re-roots onto whatever identity the crypto streams pick), but their **first PRs are independent and should land early** to bank value.

---

## Stream 1 — libsignal Core Bridge facade

| | |
|---|---|
| **Worktree** | `/private/tmp/burnbar-signal-core-bridge` |
| **Branch** | `signal/core-bridge` |
| **Forks from** | **AGPL-base commit** (bridge must be committed first — hard block) |
| **Gated by** | AGPL-base (bridge + third_party + manifests committed). **Hard blocker.** |
| **Gates** | Streams 3, 4, 5, 8 (real Signal ciphertext); Stream 6 (Fingerprint safety number, later PR) |

**Owned file boundaries (NEW package — do NOT put this inside the AGPL bridge):**
```
packages/libsignal-protocol/src/index.ts            (NEW — the facade)
packages/libsignal-protocol/src/index.test.ts       (NEW — round-trip + replay + skipped-key)
packages/libsignal-protocol/src/stores.ts           (NEW — in-memory store impls)
packages/libsignal-protocol/tsconfig.json           (NEW)
packages/libsignal-protocol/package.json            (NEW — coordinate license field w/ AGPL agent at creation)
packages/libsignal-protocol/package-lock.json       (NEW — same)
```
> The orchestrator's stream map lists `packages/libsignal-bridge/*` and `third_party/*` as "owned" — **that is a trap.** Both are AGPL-owned (Rule 0) and untracked. Stream 1 **reads** `LIBSIGNAL_PIN` and the re-exported `libsignal` namespace from the bridge, and **reads** `third_party/libsignal/manifest.json`, but **builds its facade in a brand-new `packages/libsignal-protocol/` it fully owns**, importing via `import { libsignal } from '@openburnbar/libsignal-bridge'`.

**Rule-0 avoid-list it must NOT touch:**
- `packages/libsignal-bridge/` (all of it — index.ts/test/package.json/tsconfig — consume only)
- `third_party/` (read manifest.json, never edit)
- `packages/README.md` (documents the bridge readiness claim at lines 40-47 — AGPL handoff)
- `.github/workflows/fast-feedback.yml` (the `libsignal-bridge` CI job at lines 126-143 — request the AGPL owner add the Signal round-trip job; Stream 1 ships its own `.github/workflows/signal-protocol.yml` instead)
- `LICENSE / NOTICE / THIRD_PARTY* / REUSE.toml / LICENSES/` (any new vendored Signal binary → AGPL handoff)
- All `Package.swift` / `Cargo.toml` / `*/package.json` license fields
- `packages/data-domains/registry.json`, `firestore.rules`

**First-PR scope:** A new `packages/libsignal-protocol/` exposing the **single store-agnostic crypto-boundary API** (identical signatures across all four languages later): `generateIdentity()`, `generatePreKeys(count)` (**Kyber prekey mandatory** — `PreKeyBundle.new` in 0.94.4 *requires* `kyber_prekey_id/kyber_prekey/kyber_prekey_signature`), `buildPreKeyBundle(addr)`, `establishOutboundSession(addr, bundle)` (via `processPreKeyBundle`), `encrypt(addr, plaintext)` (`signalEncrypt`), `decrypt(addr, ct)` (`signalDecrypt`/`signalDecryptPreKey` by message type), `safetyNumber(local, remote)` (`Fingerprint → DisplayableFingerprint.toString()`/`ScannableFingerprint`), `verifySafetyNumber(a,b)`. Implement the **five abstract stores** in-memory (`IdentityKeyStore/SessionStore/PreKeyStore/SignedPreKeyStore/KyberPreKeyStore`). **All gated behind a flag that defaults OFF** — no production caller is wired; no `end_to_end` domain switches envelopes.

**Tests / DoD:**
- A **real Alice↔Bob X3DH + Double-Ratchet round-trip**: full session establishment, send/receive both directions, **safety-number match** between both parties.
- An **out-of-order / skipped-key** test and a **replay-rejection** test.
- `npm run build` exits 0; `node --test` green.
- A **frozen canonical cross-language session/ratchet KAT seed** (mirroring `BurnBarHpkeV3Vector.json`) so Swift/Android/Rust facades can later prove they open the same vector.
- New CI in `.github/workflows/signal-protocol.yml` (NOT fast-feedback.yml).
- **Honest status documented in the PR body:** "this proves a Node facade + round-trip; four-language parity, PQXDH state, and any production switch are downstream."

---

## Stream 2 — crypto-inventory (frozen legacy golden vectors)

| | |
|---|---|
| **Worktree** | `/private/tmp/burnbar-signal-crypto-inventory` |
| **Branch** | `signal/crypto-inventory` |
| **Forks from** | AGPL-base (or earlier — no bridge dep) |
| **Gated by** | **Nothing** (no Stream-1 dep). Run in parallel from day one. |
| **Gates** | 3, 4, 5, 8 (the legacy-fallback contract every migration must keep openable) |

**Owned file boundaries (Swift sources + Tests fixtures; do NOT touch the Python mirror — it is external):**
```
OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayCrypto.swift     (read-canonical; freeze)
OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRatchetCrypto.swift   (read-canonical; freeze)
OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift      (read-canonical; freeze)
OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/LegacyEnvelopeVectors.json   (NEW — the 5-family frozen golden set)
OpenBurnBarCore/Tests/OpenBurnBarCoreTests/LegacyEnvelopeContractTests.swift     (NEW — opens all 5)
tools/openburnbar-mcp-remote/src/seal.ts / decrypt.ts                            (read-canonical; freeze)
```
> The stream map also lists `HermesGatewayModels.swift`, `HermesGatewayRelayKeypair.swift`, `adapter.py` as owned. Treat those as **read-only references** in this stream — `adapter.py` imports the *external* `gateway.crypto.relay_e2ee`/`hermes_ratchet` (`adapter.py:44,55`), so the Python side cannot be inventoried from this repo and must be **byte-verified against the external Hermes checkout or it silently forks.**

**Rule-0 avoid-list:** all the global avoid-list; specifically `functions/src/health.ts`, `services/*/src/server.ts`, `OpenBurnBarCore/Package.swift` (license field), the bridge. **Do not change `HermesRelayCrypto` byte layout for realtime v1** — it is shared with the iroh/Pi realtime path and is byte-frozen by the file-top note.

**First-PR scope:** **Inventory-only + frozen golden vectors.** Check into `OpenBurnBarCore/Tests` a fixture capturing all **five** current wire shapes — (1) `ratchetEnvelope` (`HermesRatchetEnvelope`, algo `OpenBurnBar-HermesRatchet-v1-...`), (2) HPKE v2 (`relayKeyVersion=2`, no `enc` field), (3) HPKE v3 (`relayKeyVersion=3`, distinct `enc` field), (4) realtime v1 ECIES, (5) CloudVault `SealedText`/`Blob`/`Payload` (AAD `OpenBurnBar-CloudVault-aad-v2|`) — as the **"legacy read-only fallback" contract.** No production path changes; no emit flag flips. **This pins the byte layout BEFORE any Signal seam exists.**

**Tests / DoD:** Swift tests open every one of the five frozen vectors. **Must also keep reading schema-1 plaintext fallback** (`hermesGateway.ts:1114/1144` legacy `text`; CloudVault schema-1 no-AAD open) — the legacy set includes plaintext, not just old ciphertext. DoD includes a written note: the Signal swap reuses the **existing per-peer capability advertise-then-emit pattern** (`supportsRatchetV1`, `agentSupportsHpkeV3`, `preferredRelayEnvelopeVersion`) so it never downgrades a paired link.

> **Honesty correction this stream must carry:** the April-2026 "open leaks" list (approval-summary MITM, gateway/project_memory/dataExport/knowledge_repos) is **largely remediated** in current code — `handleArmApproval` server-derives the summary (`callables/hermesGateway.ts:1285-1293`), safety-code binds both keys + ratchet identities. **Re-verify each before treating any as open.** The one real residual is knowledge_repos `sourceSlug` (Stream 7).

---

## Stream 3 — Hermes text / control / approval (relay envelope v4)

| | |
|---|---|
| **Worktree** | `/private/tmp/burnbar-signal-hermes-text` |
| **Branch** | `signal/hermes-text` |
| **Forks from** | AGPL-base |
| **Gated by** | Stream 2 (frozen legacy vectors) for PR1; Stream 1 (real bridge API) for PR2 (ciphertext) |
| **Gates** | Stream 4 (attachments reuse this envelope shape + capability negotiation) |

**Owned file boundaries:**
```
functions/src/hermesGateway.ts
functions/src/callables/hermesGateway.ts
OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayCrypto.swift   (shared w/ Stream 2,4 — coordinate)
OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRatchetCrypto.swift (shared — coordinate)
OpenBurnBarMobile/Services/HermesGatewayRelayKeypair.swift                     (shared w/ Stream 4,6)
OpenBurnBarMobile/Services/FunctionsRepository.swift
OpenBurnBarMobile/Views/Hermes/HermesSettingsView.swift                        (shared w/ Stream 4,6)
OpenBurnBarMobile/Views/Hermes/HermesGatewayPrivacyView.swift
tools/hermes-platform-burnbar/adapter.py                                       (shared w/ Stream 2,4)
```

**Rule-0 avoid-list:** the bridge; `services/*/src/server.ts` (the **realtime relay** shares `HermesRelayCrypto` but is a *different transport* — the gateway HTTP surface is `burnBarHermesGateway` in `callables/hermesGateway.ts`, which IS fair game); `functions/src/health.ts`; all license manifests; `firestore.rules` + `packages/data-domains/registry.json` (shared driftchecked — Stream 5/7 own these). **High live-edit contention:** the AGPL agent has `docs/HERMES_GATEWAY_E2EE_REMEDIATION_PLAN.md`, `docs/runbooks/hermes-gateway-3features*`, and `services/hermes-realtime-relay/src/server.ts` modified in the dirty tree — **coordinate before touching the gateway.**

**First-PR scope:** **Land Signal as relay envelope VERSION 4 behind a no-op capability flag, additively.**
1. In `hermesGateway.ts` add `HERMES_GATEWAY_RELAY_KEY_VERSION_SIGNAL = 4` + a `relayEncryptionSignal` algorithm constant; extend `requireGatewayRelayEnvelope`/`sanitizeGatewayRelayEnvelope` to accept v4 shape **only when present** — but **do NOT add 4 to `HERMES_GATEWAY_PRODUCTION_RELAY_KEY_VERSIONS`** (negotiation/emit stays impossible).
2. Add `supportsSignalEnvelope` capability defaulting **false** in `sanitizeGatewayRelayEnvelopeCapabilities`; no shipping client sets it true in this PR.
3. Swift: add `HermesRelayCrypto.sealKeySignal`/`openKeySignal` wrapping the **same 32-byte content key**, leaving `sealToBase64`/`openBase64` and all AAD labels untouched (exactly as v3 did).
4. Add a cross-language KAT + Swift round-trip + downgrade-negative tests (mirror `HermesRelayHPKEv3VectorTests.swift`).

Result: real tested Signal crypto round-trips in tests; negotiation never selects it (`preferred` stays v3); production is byte-identical. **PR1 needs zero bridge edits** — defer real-ciphertext bridge consumption to PR2 once Stream 1 ships the API. **Ship Swift + Python + fixture together** or every real link fail-closes (`adapter.py:1773` refuses non-supported versions).

**Tests / DoD:**
- v4 stored opaque; plaintext text/senderDisplayName still forced `undefined`; `requireProductionGatewayRelayEnvelope` still rejects v1 writes.
- Per-version **algorithm-equality gate** preserved (no relay can strip v4→v3→weaker).
- **Replay invariant kept:** v4 must still emit the authenticated `replayCounter` inside the sealed payload (the agent's `_sealed_event_replay_counter` raises `_RelayPlaintextRefused` on a missing counter — `adapter.py:2239`), **or** teach the agent v4 derives replay from the ratchet.
- **Pin/safety-code extension, not fork:** integrate the Signal identity into `pinnedSafetyCode` + the `/runtime` immutability guard (`callables/hermesGateway.ts:902-934`) or you reopen the first-pin MITM window.
- **Decide ratchet coexistence:** `ratchetEnvelope` and `relayEnvelope` are mutually exclusive per write (`ambiguous_ciphertext`, `callables/hermesGateway.ts:374,1091`). Document whether Signal **replaces** the bespoke ratchet or is a third envelope — two ratchets is an audit hazard.

> **Coordinated fix opportunity (do NOT do silently):** `connected_devices` is `encryptionTier: "server_readable"` (verified `registry.json:115`) despite sealed bodies — the scanner-blind gap. Correcting it collides with the shared registry/driftcheck (Stream 5/7) and must be coordinated, not landed in this PR.

---

## Stream 4 — Hermes attachments (signalEnvelope on the attachment manifest)

| | |
|---|---|
| **Worktree** | `/private/tmp/burnbar-signal-hermes-attachments` |
| **Branch** | `signal/hermes-attachments` |
| **Forks from** | AGPL-base |
| **Gated by** | Stream 3 (envelope shape + capability negotiation) **and** Stream 1 (session API for real key derivation) |
| **Gates** | — |

**Owned file boundaries:**
```
functions/src/callables/hermesGateway.ts                                        (shared w/ Stream 3,7 — coordinate)
functions/src/hermesGateway.ts                                                  (shared — coordinate)
functions/src/__tests__/hermesGatewayAttachmentInit.test.ts
OpenBurnBarMobile/Services/FunctionsRepository.swift                            (shared w/ Stream 3)
OpenBurnBarMobile/Views/Hermes/HermesSettingsView.swift                         (shared w/ Stream 3,6)
OpenBurnBarMobile/Services/HermesGatewayRelayKeypair.swift                      (shared w/ Stream 3,6)
OpenBurnBarMobile/Services/HermesAttachmentLoader.swift
OpenBurnBarMobile/Services/HermesAttachmentWorkspace.swift
OpenBurnBarMobile/Features/Mercury/Stores/MediaAttachmentManifestStore.swift    (Mercury — NAME only, do NOT migrate)
OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayCrypto.swift    (shared — coordinate)
OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRatchetCrypto.swift  (shared — coordinate)
tools/hermes-platform-burnbar/adapter.py                                        (shared w/ Stream 2,3)
```

**Rule-0 avoid-list:** `functions/src/health.ts`, `functions/src/sourceMetadata.ts(+test)`; the bridge; all license manifests (`functions/package.json`, `OpenBurnBarCore/Package.swift`). **Note:** the core attachment files (`callables/hermesGateway.ts`, `FunctionsRepository.swift`, `HermesRelayCrypto.swift`, `adapter.py`) are **clean in the dirty tree** — no AGPL collision on the attachment logic itself, but heavy **cross-stream** sharing with Stream 3 (same files).

**First-PR scope:** **Signal-session-derived attachment key path behind a no-op capability flag, additive; every existing v2/v3 row keeps opening unchanged.**
1. Introduce optional `signalEnvelope` on `HermesGatewayAttachmentManifestDoc` (or reuse `ratchetEnvelope` gated by a **new algorithm marker** — never collide with `OpenBurnBar-HermesRatchet-v1`). Server adds shape-only `requireGatewaySignalEnvelope` that **never decrypts**; widen `sealed = relayEnvelope || ratchetEnvelope` to include it in `handleAttachmentInit`/`handleAttachmentFinalize`.
2. Producer `adapter.py:seal_attachment` v-next: when a Signal session exists AND flag on, derive the per-attachment `body_key` from the Signal session instead of `_wrap_content_key`. **Preserve the THREE-AAD invariant byte-for-byte** (`gatewayAttachmentBody/Manifest/Key`, bound to `{uid,clientId,attachmentId}`) so body↔manifest swap still fails the GCM tag.
3. Consumer `FunctionsRepository.swift:HermesGatewayAttachmentRecord`: add `isSignalSealed` branch in `unwrapBodyKey` that opens via the Signal session. Keep `openManifest` (destinationId equality) and `openBody` IDENTICAL. **Destination-binding moves from the TOFU relay pin to the Signal identity key — fail closed (return nil) when no verified Signal session exists.**
4. Flag defaults OFF; emit **only when both ends negotiate Signal capability** (mirror the v2→v3 emit guard).

**Tests / DoD:**
- attachment-init test: signalEnvelope stored opaque + plaintext fileName still rejected.
- Swift cross-slot-swap test: manifest ciphertext in the body slot **fails the AAD tag**.
- destination-mismatch test: `openManifest` still throws on `destinationId` mismatch.
- `byteCount` is **ciphertext length** — Signal framing overhead changes it; the declared `byteCount` must equal exact uploaded bytes or finalize rejects `attachment_size_mismatch`.
- No-downgrade: a new/old phone still opens via v2/v3; no in-flight `pending_upload` row bricks.
- Server stays **blind**: sealed `contentType` forced `application/octet-stream`; sha256 is ciphertext-integrity only.

> **Red herring named, not migrated:** `MediaAttachmentManifestStore` is iroh-P2P with a cloud **audit-only** doc, sealed with **CloudVault** (`sealText sealedFilename`), bytes never in cloud, no native reader — unaffected by a gateway Signal swap. **In scope to NAME, out of scope to MIGRATE.** Also confirm whether **Android consumes gateway attachments at all** before claiming three-platform parity (no Android gateway-attachment open path was found).

---

## Stream 5 — CloudVault / Cloud Pro end-to-end domains (Data & Privacy Control Center)

| | |
|---|---|
| **Worktree** | `/private/tmp/burnbar-signal-cloudvault` |
| **Branch** | `signal/cloudvault` |
| **Forks from** | AGPL-base |
| **Gated by** | Stream 1 (a **self-encryption** Signal mode — sender-key / seal-to-own-identity, NOT a 1:1 ratchet); Stream 7 (registry/driftcheck adjacency) |
| **Gates** | — (terminal domain stream) |

**Owned file boundaries (codegen + Swift sources + callables; NOT `package.json`):**
```
packages/data-domains/registry.json   codegen.mjs   driftcheck.mjs
packages/data-domains/gen/domains.ts   gen/DataDomains.swift   gen/DataDomains.kt   (codegen OUTPUTS — regen, never hand-edit)
OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift
OpenBurnBarMobile/Services/{MobileCloudVaultKeyAccess,MobileChatHistoryStore,CLIAgentChatReader,CLIAgentMissionDispatcher,RollbackService,ApprovalPolicyStore}.swift
OpenBurnBarMobile/Models/{DataVaultStore,BudgetRulesStore,ActivityStore,MobileTextExpansionStore}.swift
OpenBurnBarMobile/Features/Mercury/Stores/MediaAttachmentManifestStore.swift    (shared w/ Stream 4 — coordinate)
OpenBurnBarMobile/Views/Control/{DataVaultRecoveryView,PensieveMemorySearchView}.swift
functions/src/callables/{knowledgeMemory,knowledgeSync,knowledgeSearch,encryptedSearch,dataExport,dataDeletion,dataDomainUsage,auditLog,privacyBackfill}.ts
```
> **Shared single-source-of-truth alert:** `registry.json` + `firestore.rules` drive CI driftcheck and are **also** Stream 7's territory (`knowledgeSync.ts`, `dataExport.ts`, `privacyBackfill.ts`). Streams 5 and 7 **must coordinate** every registry/rules/knowledge-callable edit. `packages/data-domains/package.json` is AGPL-owned — Stream 5 edits **only** `registry.json` + `.mjs` + regenerated `gen/*`, never the manifest.

**Rule-0 avoid-list:** `packages/data-domains/package.json`; the bridge; `functions/src/health.ts`, `functions/src/sourceMetadata.ts`; `OpenBurnBarCore/Package.swift` (edit Swift **sources** only).

**First-PR scope:** **No-op Signal envelope SHAPE behind a dark flag, for the `pensieve` domain ONLY** (lowest traffic, gate `burnbar_pro_max`, already cleanly sealed-only, no Storage blobs, no recovery dependency).
1. Define `CloudVaultSignalEnvelope` alongside `CloudVaultSealedText/Payload` in `CloudVaultCrypto.swift` (additive type: `{signalCiphertextBase64, signalSessionId, envelopeVersion}`), plus Kotlin/TS mirrors.
2. Add `isSignalEnvelope()` recognizer next to `isSealedEnvelope` (`dataExport.ts:~320`) + `requireSealedText` acceptance in `shared.ts` so server validators treat the new shape as **opaque-and-exportable without producing it**.
3. Add a registry note + a fixture-pinned cross-language byte-parity test (mirror the HPKE v3 lane) round-tripping ONE Signal-sealed pensieve chunk through Stream 1's facade.
4. All write paths stay on `CloudVaultCrypto.sealPayload`; flag defaults OFF; production still seals with the AES-GCM vault key.

**Tests / DoD:** export/delete stay correct if a Signal-sealed doc ever appears; one pensieve chunk round-trips; zero production behavior change.

**Migration order (smallest blast radius first), to drive later PRs:**
`(0)` Stream 1 ships a callable bridge **+ defines a self-encryption Signal mode** (at-rest is same-user multi-device, **not** 1:1 ratchet — this is an architecture decision, not a drop-in). `(1)` **pensieve** (PR1 target). `(2)` `conversations_chat` per-collection (`cli_agent_mission_requests` → `mobile_assistant_chats`). `(3)` `session_logs` — hardest: large Storage blobs + the **deterministic keyed-HMAC search index** (admitted structural leak; **Signal does NOT fix searchability** — keep an honestly-tiered separate index). `(4)` `device_trust_keys`/escrow — riskiest; replace P-256 ECIES vault-key escrow with a Signal identity-key + prekey directory, dual-write during cutover (touches recovery — `DataVaultStore.setupRecoveryKey`).

> **Honesty caveats this stream must carry:** (a) there is **no Signal crypto in production to migrate to** — the bridge is a verified stub; (b) the prior leak suspects (`project_memory_snapshots`, `knowledge_repos`, knowledge chunks) were **remediated 2026-06-02** — the genuine residuals are the **deterministic HMAC search index** (by design, admitted in registry) and the **gateway legacy schema-1 plaintext READ fallback** (`hermesGateway.ts:1114/1144` — drain/expire it); (c) Signal forward secrecy **fights** both searchability and same-user multi-device re-reads.

---

## Stream 6 — Multi-device trust + UX (the blocker P1)

| | |
|---|---|
| **Worktree** | `/private/tmp/burnbar-signal-trust-ux` |
| **Branch** | `signal/trust-ux` |
| **Forks from** | AGPL-base |
| **Gated by** | **Nothing for PR1** (no crypto/bridge change). Later PR (real Signal Fingerprint) gated by Stream 1. |
| **Gates** | — (but sequenced after crypto streams so the eventual real fix re-roots on Signal identity) |

**Owned file boundaries:**
```
OpenBurnBarMobile/Views/Control/{DataVaultRecoveryView,DataVaultControlView}.swift
OpenBurnBarMobile/Views/iPadDevicesSettingsView.swift
OpenBurnBarMobile/Views/You/ConnectedDevicesRow.swift
OpenBurnBarMobile/Models/DevicesStore.swift
OpenBurnBarMobile/Models/Gateways/CloudGateways.swift
AgentLens/Views/Settings/DevicesAndSyncSettingsView.swift
OpenBurnBarMobile/Views/Hermes/HermesSettingsView.swift              (shared w/ Stream 3,4 — coordinate)
OpenBurnBarMobile/Services/HermesGatewayRelayKeypair.swift           (shared — reuse safetyCode formatter, do not refactor crypto)
OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/EscrowModels.swift
OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultDeviceKeypair.swift
AgentLens/Services/ComputerUse/EscrowRevocationWatcher.swift
OpenBurnBarMobile/Services/LiveCloudReader.swift
```

**Rule-0 avoid-list:** the bridge (consume `Fingerprint` only in the *later* PR, never edit the bridge); `docs/HERMES_GATEWAY_E2EE_REMEDIATION_PLAN.md` + `docs/runbooks/hermes-gateway-3features*` (AGPL-owned — coordinate, the safety-code MITM work overlaps); all license manifests (new test targets go via separate worktree, coordinate). **Do not edit `functions/src/callables/computerUseSecurity.ts` crypto in PR1** — PR1 is **client-side UX only, no callable change.**

**First-PR scope (closes the P1 trust inversion):** **Honest fingerprint/safety-number display + verification UX on the ESCROW device-trust approve flow, behind a no-op flag, no crypto change.**
- **Verified P1:** `approveEscrowDeviceTrust` (`computerUseSecurity.ts:155`) flips trust on `deviceId` + `approverDeviceId` + `trustState` **ONLY** — it **never reads or compares `publicKeyFingerprint`** (confirmed: lines 155-250 reference `trustState`, `approverDeviceId`, but not `publicKeyFingerprint`). The Mac `deviceRow` shows no fingerprint. A relay/swapped device gets **one-tap trust to the vault-key path with zero out-of-band comparison.** Meanwhile the *server_readable* Hermes path has the *strongest* UX (full safety code + change alert) and the *end_to_end* escrow/vault path has the *weakest* — an inversion.
1. Plumb the already-stored `publicKeyFingerprint` (accepted + stored by `registerEscrowDevice` at `computerUseSecurity.ts:112-137`, present on `EscrowDevice`) into the Mac approve UX (`DevicesAndSyncSettingsView.swift:deviceRow`) + iOS/iPad equivalents, rendered with the existing `HermesGatewayAgentKeyPinStore.safetyCode` formatter (sorted-key SHA-256 → 8 hex groups) so Mac and phone derive the **same** code.
2. Add a "Compare this code on the other device before approving" confirmation step gating the existing `deviceTrust.approve(...)` call — purely client-side.
3. Feature flag defaults OFF (current one-tap behavior in production).

**Tests / DoD:** Swift unit test asserting Mac-derived and phone-derived codes match for the same `publicKeyFingerprint` set; a snapshot of the confirm-before-approve gate. **Do not pretend the two device lists are one** — `devices` (`DevicesStore`, server_readable) vs `escrow_devices` (`device_trust_keys`, end_to_end) are separate collections with separate trust states.

> **Known gaps to document, not silently inherit:** escrow prekeys are **unsigned** (`EscrowPublicKey` has no signature field; only the Hermes ratchet path verifies via `verifySignedPreKey`); **revocation does NOT stop at-rest decryptable data** (`revokeEscrowDeviceTrust` flips state + revokes grants but never rotates the revoked device's Keychain key or re-wraps existing `escrow_envelopes`/`cloud_vault_key_wrappers`); **no escrow key-change alert** (`CloudVaultDeviceKeypair` hardcodes `keyVersion 1`, no rotate path; `DevicesStore` name+platform dedup *masks* a key change as a duplicate). The real fix (route escrow approve through libsignal `Fingerprint`/numeric safety number + add key rotation + re-wrap on revoke) is a **later, coordinated PR gated by Stream 1.**

---

## Stream 7 — Backend validators + dataExport + privacy scanner (CI hard gates)

| | |
|---|---|
| **Worktree** | `/private/tmp/burnbar-signal-backend-gates` |
| **Branch** | `signal/backend-gates` |
| **Forks from** | AGPL-base |
| **Gated by** | **Nothing** (no Signal/bridge dep). Start immediately. |
| **Gates** | Streams 4/5 lean on its seal-aware validators + driftcheck staying green |

**Owned file boundaries:**
```
scripts/privacy/scan-chat-cloud-plaintext.mjs   scrub-chat-cloud-plaintext.mjs   backfill-privacy-plaintext.mjs
functions/src/callables/dataExport.ts           functions/src/__tests__/dataExport.test.ts
functions/src/callables/encryptedSearch.ts      (commitEncryptedProjectMemorySnapshot)
functions/src/callables/knowledgeSync.ts        (connectKnowledgeRepo — the residual)
functions/src/callables/knowledgeMemory.ts
functions/src/callables/privacyBackfill.ts      functions/src/__tests__/privacyBackfill.test.ts
functions/scripts/test-firestore-rules.mjs      (the REAL emulator suite — NOT firestore-rules-tests/)
firestore.rules                                 (project_memory_snapshots / knowledge_repos / hermes_gateway_* blocks — shared w/ Stream 3,5)
```

**Rule-0 avoid-list:** `firestore-rules-tests/package.json(+lock)` (AGPL-owned **decoy** — its `npm test` covers none of these collections); `functions/src/health.ts`; `.github/workflows/fast-feedback.yml` (AGPL-owned — `.github/workflows/openburnbar-pr-harness.yml` is NOT in the avoid-list but coordinate). **Do NOT add tests to `firestore-rules-tests/` expecting them to gate these collections — they won't.**

**First-PR scope:** **Close the ONE real residual + the ONE coverage gap, both no-op-safe.**
- **(A) knowledge_repos `sourceSlug` residual (verified):** `connectKnowledgeRepo` (`knowledgeSync.ts:165` reads `sourceSlug = safeCloudDocumentID(request.data.sourceSlug, ...)`, `:177` stores `sourceSlug` verbatim). `safeCloudDocumentID` only **char-validates**, no hashing — so a near-cleartext repo/source slug is stored server-readable, **directly contradicting `firestore.rules` which BANS `sourceSlug` for client writes**. Replace the stored `sourceSlug` with an HMAC trapdoor (reuse the `repoMatchToken` pattern at `:61/:117`) OR drop it and key `knowledge_sync_manifests` by `repoMatchToken`; add a scanner `assertNotIncludes` that `connectKnowledgeRepo` no longer persists a cleartext slug. `dataExport` already drops it (not in `OPAQUE_EXPORT_COLUMNS`) so it does not exfiltrate, but it lingers in Firestore.
- **(B) knowledge_repos emulator coverage gap (verified):** `grep -c knowledge_repos functions/scripts/test-firestore-rules.mjs` = **0** — ZERO emulator coverage; only the static scanner string-asserts the rule. Add a live emulator negative test (client write of `repoFullName`/`sourcePath`/`sourceSlug` → `assertFails`) + positive test (`{repoMatchToken, sealedRepoFullName}` → succeeds). Both land **green immediately** (the rule already rejects).

**Tests / DoD:** scanner needle for the slug change; new emulator negative+positive tests pass on first run; CI hard gate `scripts/ci/verify-hermes-gateway-e2ee-remediation.sh` (invoked by `openburnbar-pr-harness.yml:535`) stays green.

> **Critical honesty correction — do NOT redo remediated work:** the prior "scanner + rules-tests are BLIND to Hermes Gateway / project_memory_snapshots / dataExport / knowledge_repos" claim is **FALSE against the current committed tree.** All four are covered and pass today: Hermes Gateway plaintext write is **impossible** (`gatewayPlaintextWriteAllowed()` returns false — `hermesGateway.ts:107`; `resolveGatewayWriteBody` throws `ciphertext_required` — `callables/hermesGateway.ts:385-388`; `legacyText` is dead-code read-fallback only); `project_memory_snapshots` is sealed-blob + opaque HMAC docID + strict allowlist; `dataExport` is default-deny seal-aware. **The only residual is knowledge_repos `sourceSlug` + its missing emulator test.** The scanner's brittleness (string-match on callable symbol names) is a maintenance follow-up, not a leak.

---

## Stream 8 — Proof harness + external review

| | |
|---|---|
| **Worktree** | `/private/tmp/burnbar-signal-proof-harness` |
| **Branch** | `signal/proof-harness` |
| **Forks from** | AGPL-base |
| **Gated by** | **Nothing for PR1** (re-verifies existing parity). Signal-KAT lane gated by Stream 1. |
| **Gates** | — (terminal — the external-review bundle is the swarm's capstone) |

**Owned file boundaries:**
```
OpenBurnBarCore/Tests/OpenBurnBarCoreTests/{BurnBarHpkeV3CrossPlatformVectorTests,HermesRelayHPKEv3VectorTests,HermesRelayCrossPlatformVectorTests,HermesRatchetCryptoTests,CloudVaultCryptoTests}.swift
OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/{BurnBarHpkeV3Vector,HermesGatewayWireVector,HermesRelayWireVector}.json
android/app/src/test/java/com/openburnbar/data/hermes/relay/{HermesRelayCryptoHpkeV3Test,HermesGatewayV2VectorTest,HermesRatchetCryptoTest}.kt
android/app/src/test/java/com/openburnbar/data/cloud/CloudVaultCryptoTest.kt
android/app/src/test/resources/hermes-relay/{HermesGatewayWireVectorV3,HermesGatewayWireVector}.json
crates/burnbar-remote/burnbar-remote-security/src/lib.rs
scripts/ci/crypto-proof-harness.mjs               (NEW)
.github/workflows/crypto-proof-harness.yml        (NEW — NOT fast-feedback.yml)
```

**Rule-0 avoid-list:** the bridge (consume only); `scripts/ci/verify-agpl-compliance.sh` (if a vendored Signal KAT is added, the SBOM gate is an AGPL handoff); `.github/workflows/fast-feedback.yml` (wire a NEW workflow file instead); `docs/HERMES_GATEWAY_E2EE_REMEDIATION_PLAN.md` (AGPL-owned — propose external-review additions via the owner); all license manifests (new test deps/Tamarin/ProVerif tooling → coordinate, never clobber).

**First-PR scope:** **In-tree, language-agnostic crypto-proof-harness SKELETON behind a no-op flag that on day one only RE-VERIFIES existing parity, then becomes the single Signal-lane plug-in point.**
1. `scripts/ci/crypto-proof-harness.mjs` loads every committed fixture (`BurnBarHpkeV3Vector.json`, `HermesGatewayWireVector.json`, `HermesRelayWireVector.json`) and asserts the **Core↔Android mirror copies are byte-identical** — re-implementing `assert_gateway_vector_mirrors` as a standalone, **Hermes-checkout-OPTIONAL** step that runs on a **fresh clone** — plus a structural KAT check (suite ids `kem=0x10/kdf=0x01/aead=0x02/mode=0x02`, `enc=65B`, `wrappedKey=48B`) read from the fixture.
2. A manifest JSON enumerating the **proof matrix** — for each `{language: Swift|Kotlin|Rust|Node} × {dimension: parity|liveE2E|legacyMigration|revokedDevice|signalProtocol}` a status `present|stub|missing` with the exact `file:test` ref — that the harness validates against reality and prints as an **honest coverage report**: `signalProtocol = missing` everywhere; `liveE2E = manual`; `legacyMigration = fixture-only downgrade negatives`; `revokedDevice = Rust session-grant only`.
3. Gate in NEW `.github/workflows/crypto-proof-harness.yml` running **report-only** (`continue-on-error`, flag `CRYPTO_PROOF_ENFORCE` unset).

**Tests / DoD:** green, fresh-clone-runnable, single-entry coverage gate; zero Rule-0 path touched; no external Hermes repo required. The Signal-protocol KAT lane and external-review bundle drop in **downstream of Stream 1.**

> **Honesty this stream must carry:** the "triangulation" is really **Python(external)→{Swift CryptoKit, Android JCE}** agreement, missing an independent third in-tree implementation — **external reviewers cannot regenerate the fixtures** (`generate_burnbar_hpke_v3_vectors.py`/`hpke_v3_reference.py`/`relay_e2ee.py` are NOT in this tree). The privacy scanner proves posture by **registry-tier + substring** checks, **not** by reading stored ciphertext. **Live ciphertext-readback is MANUAL** (Phase 7 on Alberto's physical iPad). **Revoked-device coverage exists ONLY for remote-control session grants** in Rust (`crates/burnbar-remote/burnbar-remote-security/src/lib.rs` — `DeviceTrustState::Revoked`, `AntiReplayWindow`, `TamperEvidentAuditLog`), **NOT** for E2EE message decryption — there is no forward-secrecy/post-compromise proof, which is exactly what a real ratchet would provide and what is absent. The "Rust" leg of the parity matrix **has no message-crypto implementation to test.**

---

## Global Definition of Done

A `signal/*` stream's PR is **Done** only when ALL hold:

1. **Worktree + branch discipline:** work landed from a separate worktree on `signal/<name>`, **forked from (or rebased onto) the committed AGPL-base commit**; every manifest in the AGPL avoid-list re-verified after any rebase (not auto-merged).
2. **Zero Rule-0 edits:** no change to any AGPL-owned path. The bridge (`packages/libsignal-bridge/`) is **consumed, never edited**; every license/NOTICE/THIRD_PARTY*/REUSE.toml/`packages/README.md`/`fast-feedback.yml` change forced by new Signal vendoring is filed as an **AGPL handoff ticket**, not committed by the stream.
3. **No-op in production:** the new path is behind a flag/capability that **defaults OFF**; no shipping client negotiates it; **production wire bytes are byte-identical** to pre-PR. No `end_to_end` registry domain switches its live envelope. Legacy v1/v2/v3 + CloudVault + custom-ratchet rows still open unchanged (the Stream 2 frozen-vector contract).
4. **Real crypto is real, or honestly absent:** any "Signal" code path that *can* run produces real, **round-tripped** ciphertext under test (no theater); where Signal crypto does not yet exist, the PR body **says so explicitly** and the proof-harness manifest marks it `missing`/`stub`.
5. **No downgrade, no MITM regression:** per-version algorithm-equality gates preserved; the trust root (TOFU pin + two-key safety code + `/runtime` immutability) is **extended, never forked**; AAD discipline byte-identical across Swift/Python/(Android/Rust); replay/ordering invariants preserved or explicitly re-derived from the ratchet.
6. **Cross-language parity shipped together:** any Swift envelope/version change ships with its Python (and Android/Rust where the path exists) counterpart **and** a frozen KAT fixture in the same PR — never Swift-only (the agent fail-closes non-supported versions: `adapter.py:1773`).
7. **Tests green on a fresh clone:** new unit/round-trip/negative/emulator tests pass; the relevant CI gate (`verify-hermes-gateway-e2ee-remediation.sh`, `crypto-proof-harness.yml`, `signal-protocol.yml`, or the firestore-rules emulator) is green; **no reliance on the external `$HERMES_AGENT_CHECKOUT`** for the stream's own gate.
8. **Honesty checklist in the PR body:** states what is proven vs. deferred; re-verifies (does not inherit) any "leak"/"remediated" claim against current code; for migration PRs, names the dual-decrypt/backfill/telemetry plan that keeps legacy rows openable per `third_party/libsignal/manifest.json` `migrationPolicy`.
9. **Registry/driftcheck honesty:** any tier change (e.g. correcting `connected_devices` from `server_readable` to reflect sealed bodies) is coordinated with the registry owner, regenerates `gen/{domains.ts,DataDomains.swift,DataDomains.kt}` via `codegen.mjs`, and passes `driftcheck.mjs` vs `firestore.rules`.
10. **Coordination receipts:** for any file shared across streams (`HermesRelayCrypto.swift`, `callables/hermesGateway.ts`, `FunctionsRepository.swift`, `HermesSettingsView.swift`, `registry.json`, `firestore.rules`, `adapter.py`), the PR notes which sibling streams touch the same file and confirms a merge order with them.

## Open Questions (external-reviewer surface)

1. AGPL-base commit identity: the bridge (packages/libsignal-bridge/) and third_party/ are UNTRACKED at HEAD 718990e0f. The orchestrator must get the AGPL agent to commit (a) the bridge, (b) third_party manifest, (c) all license-field manifest edits, (d) the LICENSE/NOTICE/THIRD_PARTY*/REUSE.toml/LICENSES/docs/legal footprint to a single named base commit. Until that lands, Streams 1/3/4/5/8 build only against in-tree crypto + the npm @signalapp/libsignal-client package directly. What is the target base SHA and ETA?
2. Self-encryption Signal mode for at-rest CloudVault domains: Signal Double Ratchet is a pairwise 1:1 session, but conversations_chat/session_logs/pensieve/device_trust_keys are SAME-USER multi-device self-encryption. Stream 1 must define a sender-key / seal-to-own-identity mode before Stream 5 can migrate anything. Is this in Stream 1's charter or a separate design task?
3. Ratchet coexistence decision (Stream 3/4): the bespoke OpenBurnBar-HermesRatchet-v1 already occupies the 'upgraded transport' slot and is mutually exclusive with relayEnvelope per write. Does official Signal REPLACE the custom ratchet, or become a third envelope family? Two ratchets is an audit hazard that must be resolved before Stream 3 PR2.
4. Four-language parity ownership: Node facade (Stream 1) is the only one scoped. Swift libsignal Swift Package, Android org.signal maven (custom non-Maven-Central repo build-artifacts.signal.org), and Rust crate each pull AGPL native binaries into shipped artifacts (App Store binary-size/notarization, Android 16KB-page alignment, supply-chain risk) and force AGPL legal-footprint updates. Who owns each language facade and the vendoring handoff?
5. External Hermes repo dependency: the canonical cross-language vector GENERATOR (generate_burnbar_hpke_v3_vectors.py, hpke_v3_reference.py, relay_e2ee.py) and ~211 pytest live in $HERMES_AGENT_CHECKOUT, NOT this repo. adapter.py imports gateway.crypto externally. Must the generator be in-sourced for external reviewers to reproduce fixtures, and who owns that?
6. connected_devices tier correction: registry.json:115 marks it server_readable despite sealed gateway bodies (the scanner-blind gap). Correcting it collides with the shared registry/driftcheck owned across Streams 5/7/3. Is the tier fix in scope for the Signal swarm, and which stream lands it?
7. Gateway legacy schema-1 plaintext READ fallback (hermesGateway.ts:1114/1144): writes are closed but un-migrated old docs can still be read as plaintext. Who owns the drain/expire/backfill of legacy schema-1 docs, and is it gated behind any of the eight streams or a separate backfill task?
8. Escrow revocation does not rotate keys or re-wrap at-rest data: revoked devices retain their Keychain key and can still decrypt existing escrow_envelopes/cloud_vault_key_wrappers. Stream 6 PR1 only adds fingerprint UX. Who owns the key-rotation + re-wrap-on-revoke fix (Stream 5 device_trust_keys migration or Stream 6 later PR)?
