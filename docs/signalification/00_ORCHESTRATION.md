# Signalification Swarm — Orchestration (authoritative)

> **Status:** Design + grounding complete (2026-06-04). Implementation NOT started.
> This document is the **source of truth**. It folds in an adversarial verification pass
> that post-dates the three detailed artifacts in this folder. **Where the detailed
> artifacts conflict with this file, this file wins.**

Detailed artifacts (read after this):
- [`SIGNAL_ENVELOPE_V1.md`](./SIGNAL_ENVELOPE_V1.md) — on-wire `signalEnvelope` format + key derivation (Stream 2)
- [`DOMAIN_SIGNALIFICATION_MAP.md`](./DOMAIN_SIGNALIFICATION_MAP.md) — every `end_to_end` registry domain → target treatment + migration wave (Stream 5)
- [`SWARM_RUNBOOK.md`](./SWARM_RUNBOOK.md) — full 8-stream runbook (detailed; superseded by the corrected order below)

Grounded by a 16-agent workflow (8 mappers → 3 authors → 5 adversarial verifiers) against the
live tree at `fix/hermes-gateway-e2ee-remediation-20260603` @ `718990e0f`.

---

## TL;DR

- **Goal:** move BurnBar's private Cloud Pro data onto the **official Signal `libsignal` (`@signalapp/libsignal-client@0.94.4`, AGPL-3.0-only)** crypto boundary, replacing the bespoke HPKE-Auth (P-256) key-wrap + AES-GCM CloudVault envelopes for *new* writes, with all legacy envelopes kept **read-only**.
- **Feasibility: CONFIRMED.** The at-rest primitive the plan needs is real in 0.94.4 (`PublicKey#seal` / `PrivateKey#open`, RFC 9180 HPKE single-shot to a long-term identity key). This is the *correct* primitive for "seal to my own devices at rest" — **not** a Double-Ratchet abuse. PQXDH (Kyber prekey) is mandatory; safety-numbers (`Fingerprint`) and `sealedSenderMultiRecipientEncrypt` both exist.
- **The plan is a serial critical path, not 8 parallel sprints.** Streams 3–5, 8 each depend on an interface that does not exist yet (the bridge crypto API and the `signalEnvelope` wire shape). Only **Streams 6 & 7 are independent and start first** (they fix verified P1 bugs with zero Signal dependency).
- **Two hard blockers to clear before any `signal/*` PR:** (1) the AGPL agent must **commit** its dirty tree (bridge + `third_party/` + ~27 manifests) to a named **base SHA**; (2) Stream 1 must own a **new** `packages/libsignal-protocol/`, never the AGPL-owned `packages/libsignal-bridge/`.
- **3 of the 4 "open leaks" are already CLOSED** on this branch. Don't redo them.
- **Do not ship "Signal-quality privacy" copy.** Residual server-side leakage (cosine-preserving vector graph, deterministic search trapdoors, routing metadata, no at-rest forward secrecy, TOFU trust root) makes the unqualified claim false.

---

## Adversarial verdicts (what the verification pass found)

| # | Claim checked | Verdict | Severity | What it means |
|---|---------------|---------|----------|---------------|
| 1 | libsignal 0.94.4 exposes a real at-rest seal primitive | **CONFIRMED real** | info | `PublicKey#seal`/`PrivateKey#open` (RFC 9180 HPKE). Identity key *is* a `PublicKey`/`PrivateKey`. Proceed. Cheap fix: add `PublicKey`/`PrivateKey` to the bridge's `REQUIRED_SIGNAL_PROTOCOL_SYMBOLS`. |
| 2 | Stream first-PR files collide with the AGPL footprint | **CONFIRMED collision** | **blocker** | Stream 1 mapped-ownership = `packages/libsignal-bridge/` + `third_party/` (100% AGPL). Stream 5 codegen writes `website/.../trust.generated.ts` (AGPL). Streams 2,3,4,6,7,8 are clean. |
| 3 | The 4 "open leaks" are reachable server-side today | **REFUTED (3 of 4)** | minor | Hermes Gateway, `project_memory_snapshots`, `dataExport` are **closed & gated**. Only `knowledge_repos` `sourceSlug` is a real (minor) residual. |
| 4 | Streams 3/4/5/8 can start day-one in parallel | **CONFIRMED too-early** | major | AGPL-base isn't a commit yet; bridge has no crypto; `signalEnvelope` is greenfield. Serialize per the critical path below. |
| 5 | "Signal-quality privacy" is an accurate claim | **CONFIRMED over-claim** | major | Designs are honest; *product copy* would not be. Cosine-preserving vector graph is the largest residual; Signal doesn't touch it. |

---

## Corrected critical path

```
        ┌──────────────────────────────────────────────────────────────┐
        │ GATE 0: AGPL-base commit (AGPL agent)                          │
        │ commit bridge + third_party/ + ~27 manifests + legal footprint │
        │ to a NAMED base SHA. Until then, no signal/* branch may fork   │
        │ that touches a manifest or the bridge.                         │
        └───────────────┬──────────────────────────────────────────────┘
                        │
   start NOW (no Signal dep, verified P1 value) ──────────────┐
   ┌─────────────────┐   ┌─────────────────┐                  │
   │ Stream 6        │   │ Stream 7        │                  │ (land early,
   │ trust/safety UX │   │ backend gates   │                  │  independent)
   └─────────────────┘   └─────────────────┘                  │
                                                               │
        ┌──────────────────────────────────────────────────┐  │
        │ Stream 1: real seal/open + X3DH/PQXDH + Ratchet   │◄─┘ (after GATE 0)
        │ in NEW packages/libsignal-protocol/, flag OFF     │
        │ ‖ Stream 2: freeze legacy KAT vectors (parallel)  │
        └───────────────┬──────────────────────────────────┘
                        │ (bridge API + envelope shape defined)
        ┌───────────────▼──────────────────┐
        │ Stream 3 PR1a: v4 signalEnvelope  │
        │ SHAPE + validator + capability,   │
        │ NO crypto, flag OFF               │
        └───────────────┬──────────────────┘
                        │
        ┌───────────────▼──────────────────┐
        │ Stream 3 PR1b/PR2: real ciphertext│ (uses Stream 1 API)
        └───────────────┬──────────────────┘
                        │ (envelope shape MERGED)
        ┌───────────────▼──────────────────┐   ┌──────────────────────────┐
        │ Stream 4: attachments (reuse §5.3 │   │ Stream 5: CloudVault      │
        │ grammar; old HPKE rows still open)│   │ domains, wave-by-wave     │
        └───────────────────────────────────┘   │ (gated on Stream 1 at-rest│
                                                 │  self-encryption mode)    │
                                                 └──────────────────────────┘
        Stream 8: report-only day 1; becomes the proof harness that every lane plugs into.
```

**Start order:** `6, 7` (now) ‖ `2` → `1` → `3a` → `3b/2` → `4`, `5` → `8` (hardens throughout).

---

## Per-stream assignment (corrected)

All non-trivial code runs in a **separate git worktree** on a `signal/<name>` branch forked from the AGPL-base SHA (Streams 6/7 may fork from current `HEAD` since they touch only in-tree crypto). **No stream edits another stream's files or any AGPL path.**

| Stream | Branch | Owns (corrected) | First PR (flag OFF) | Gated by |
|--------|--------|------------------|---------------------|----------|
| **1 Core bridge** | `signal/core-bridge` | **NEW `packages/libsignal-protocol/`** (consumes `@openburnbar/libsignal-bridge` read-only) | TS facade over libsignal: in-memory stores, `generateIdentity/generatePreKeys` (incl. mandatory Kyber), `buildPreKeyBundle`, `establishSession`, `encrypt/decrypt`, `safetyNumber`; **real Alice↔Bob X3DH+Ratchet round-trip + skipped-key + replay-reject tests** | GATE 0 |
| **2 Protocol/vectors** | `signal/proto-vectors` | `OpenBurnBarCore/Tests/.../Fixtures/*` (legacy KAT) + this spec | Freeze the 5 legacy wire shapes (ratchet, HPKE v2/v3, realtime v1, CloudVault) as golden vectors = the "read-only fallback" contract | — (parallel w/ 1) |
| **3 Hermes text/ctrl** | `signal/hermes-textctrl` | `functions/src/hermesGateway.ts` + `callables/hermesGateway.ts` seal/open seam, Swift shape gates | **PR1a:** add `relayKeyVersion=4` shape + `requireGatewaySignalEnvelope` validator + `supportsSignalEnvelope` cap **default false** (NOT added to `PRODUCTION` versions). **PR1b/2:** real ciphertext via Stream 1 | 1 |
| **4 Hermes attach** | `signal/hermes-attach` | gateway attachment manifest/body seal-open paths | Optional `signalEnvelope` on `HermesGatewayAttachmentManifestDoc` + shape-only `requireGatewaySignalEnvelope`; old HPKE rows keep opening | 3 (shape **merged**) |
| **5 CloudVault domains** | `signal/cloudvault-domains` | `CloudVaultCrypto.swift` (+TS/Kotlin mirror), registry **additive** field, `end_to_end` call sites | `CloudVaultSignalEnvelope` type (additive) + `isSignalEnvelope()` recognizers (opaque-and-exportable) + registry **`sealingScheme`** field (absent==legacy, **non-websited**, zero-diff codegen) for **pensieve only**, dark flag | 1 (at-rest self-encryption mode) |
| **6 Trust/safety UX** | `signal/trust-ux` | `AgentLens/Views/Settings/DevicesAndSyncSettingsView.swift` + iOS/iPad device rows; escrow approve flow | Render the already-stored `publicKeyFingerprint` as a comparable safety code (reuse `HermesGatewayAgentKeyPinStore.safetyCode`) + "compare this code" gate on escrow approve | **none — start now** |
| **7 Backend gates** | `signal/backend-gates` | `functions/src/callables/knowledgeSync.ts`, `scripts/privacy/*`, `functions/scripts/test-firestore-rules.mjs` | (A) Stop persisting cleartext `sourceSlug` (HMAC it / key by `repoMatchToken`); (B) scanner `assertNotIncludes` for it; (C) add the missing `knowledge_repos` emulator test (currently zero) | **none — start now** |
| **8 Proof harness** | `signal/proof-harness` | NEW `scripts/ci/crypto-proof-harness.mjs`, NEW `.github/workflows/crypto-proof-harness.yml` | Skeleton that re-verifies existing fixture/mirror parity on a fresh clone (Hermes-checkout-optional); becomes the single plug-in point for the Signal lane | report-only day 1 |

---

## Rule 0 — collision guard (must-not-touch)

The AGPL agent's dirty tree is broad. **Add a CI gate:** any `signal/*` PR that diffs any of the
following **fails** a `no-rule0-edit` check:

- `packages/libsignal-bridge/**`, `third_party/**`
- any `package.json` / `package-lock.json` / `Package.swift` / `Cargo.toml` (license fields)
- `functions/src/health.ts`, `functions/src/sourceMetadata.ts(+test)`, `services/*/src/server.ts`, `services/*/src/sourceMetadata.ts(+test)`
- `website/**` (incl. generated `website/src/data/trust.generated.ts`)
- `LICENSE`, `NOTICE`, `REUSE.toml`, `THIRD_PARTY*.md`, `LICENSES/`, `docs/legal/`
- `docs/HERMES_GATEWAY_E2EE_REMEDIATION_PLAN.md`, `docs/runbooks/hermes-gateway-3features*`, and the other AGPL-touched docs
- `.github/workflows/fast-feedback.yml`

**Handoffs to the AGPL agent (cannot be done by a `signal/*` stream):**
1. Add `PublicKey`/`PrivateKey` to `REQUIRED_SIGNAL_PROTOCOL_SYMBOLS` in `packages/libsignal-bridge/src/index.ts` (so a future bump that drops the HPKE seal/open API fails the readiness check).
2. Set the license field on any **new** manifest a stream creates (e.g. `packages/libsignal-protocol/package.json`).
3. Vendor the **Swift Package / Android maven / Rust crate** libsignal bindings and update `LICENSE`/`NOTICE`/`THIRD_PARTY*`/source-offer accordingly.
4. Any regenerated `website/src/data/trust.generated.ts` write (route Stream 5 registry changes that touch a websited field through the AGPL agent).

---

## Honesty guard — product-copy gate (Verdict 5)

After Signalification, **these still leak server-side** (Signal wraps the *body key*, not these):

1. **Cosine-preserving cloaked vectors** (`PensieveVectorCloak.swift:23-29`) — orthonormal map preserves inner products exactly, so the server keeps the full k-NN / cluster geometry **within and across tenants** (cross-tenant cosine ≈ 0.77) and runs ANN over it. **Largest residual.** Demand a published threat model before any "semantic memory is private from us" copy.
2. **Deterministic keyed-HMAC search index** (`CloudVaultCrypto.swift:546-576`) — prefix + phrase trapdoors leak term recurrence/co-occurrence; integrity hashes confirm a guessed body.
3. **Routing/structural metadata** stays `server_readable` (provider/model/cost/token-counts/timing/integrity-hashes; message counts; chunk/byte counts).
4. **`connected_devices` tier mismatch** (`registry.json:115` = `server_readable` while bodies are sealed) → the privacy scanner keys off the tier and is **structurally blind** to the gateway. Correct the tier before relying on scanner coverage or "gateway never readable" copy.
5. **`knowledge_repos` `sourceSlug`** residual (Stream 7).
6. **At-rest has NO forward secrecy by design** — identity-key compromise exposes all not-yet-re-wrapped docs; revocation flips trust state but does **not** rotate keys or re-wrap.
7. **Trust root is TOFU + manual safety-number** — escrow approval never compares fingerprints (`computerUseSecurity.ts:155`), escrow prekeys are unsigned, no key transparency → first-pin MITM window.

**Only accurate near-term claim** (per `docs/HERMES_GATEWAY_E2EE_REMEDIATION_PLAN.md:85/443/659`): paired *traffic* is sealed and ratchets when both peers publish material. "Signal-quality privacy" overall is an over-claim until at-rest FS, re-wrap-on-revoke, fingerprint comparison, and the vector/index residuals are addressed.

---

## Definition of Done (global)

BurnBar may claim Signal-backed Cloud Pro privacy only when:
- every private Cloud Pro **write** uses a `signalEnvelope` or an approved legacy read-only fallback;
- replay / tamper / downgrade **fail closed** (proven by cross-language KAT + negative tests);
- safety-number changes are **user-visible** and escrow approval **compares fingerprints**;
- revoked devices stop receiving future-decryptable data (**re-wrap-on-revoke job shipped**);
- the privacy scanner + firestore-rules tests + a **stored-ciphertext** readback prove no plaintext private write (CI hard gate);
- physical iOS + Android + macOS devices prove the flows live;
- the residual-leak threat model (vectors, search index, metadata) is published and product copy matches it;
- an external crypto reviewer signs off on the proof package.
