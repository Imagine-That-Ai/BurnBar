# Application / API / Data Validation Review (incl. Billing) — Opus 4.8 1M lane

## Input validation & injection surface
- **Callables:** typed Codable/`onCallProduction` decode; malformed payloads rejected pre-handler. Daemon RPC capped at 64KB, typed `BurnBarRPCMethod` enum (no dynamic dispatch).
- **Gateway envelopes:** size caps enforced — event 32KB, message 64KB, modelId ≤180 chars (no CRLF), destId no slash (`functions/src/hermesGatewayEnvelope.ts`).
- **No command injection found:** subprocess args are argv arrays (`CLIProcessStreamRunner.swift:184-188`, `FactoryDroidProviderExecutor.swift:67`); prompts written to 0600 temp files; the one login-shell use is for path discovery of a fixed catalog name, single-quote-escaped (OPUS-F-009 residual is dotfile-hijack only).
- **SSRF:** `functions/src/ssrfGuard.ts` blocks dotted-decimal private/metadata ranges; latent alt-encoding/DNS-rebinding gap (OPUS-F-007) — **unreachable today** (no user-supplied-URL fetch path; sole `fetch()` at `resilienceHelpers.ts:40` is gated, all targets hardcoded/env).

## Billing / entitlement integrity — server is sole authority (DEFENSIBLE)

| Threat | Mitigated | Evidence | Residual |
|---|---|---|---|
| Forged Apple JWS | yes | `appstore/verifier.ts:85-107` pins SHA-256 of 3 Apple roots, refuses start on mismatch; chain via `@apple/app-store-server-library`; OCSP `:278` | — |
| Replay (same JWS) | yes | `reconciler.ts:569-579` `shouldOverwrite` keyed to Apple `signedDateMs`; transactional read-compare-write `:171-183`; audit idempotent `create()` | `>=` allows idempotent re-apply (safe) |
| Cross-user replay | yes | server-minted `appAccountToken` → `entitlement_bindings/{token}`; `binding_mismatch` reject `reconciler.ts:399-409`; bindings server-only | legacy no-token S2S fallback (OPUS-F-019) |
| Downgrade revival | yes | downgrade + rewind guards `entitlements.ts:240-257,296-328`; **watermark-erase FIXED** `:202-207` | — |
| Stripe replay/reorder | yes | `constructEvent` sig verify `stripe.ts:561`; transactional `event.id` ledger + 10-min lease `:160-196`; rewind guard; same-second tie `entitlements.ts:311-327`; current-state re-fetch `stripe.ts:603-610` | — |
| Client self-grant | yes | `entitlements` `write: if false` `firestore.rules:3539-3559`; macOS/iOS clients read-only listeners | — |
| Quota inflation | mostly | allowance ledger `billing/allowances/**` server-only; `reserveCloudProAllowance` server-side | client-mirrored counters ≤1h window (OPUS-F-013) |

- **Audit redaction:** Apple audit drops nested `signedTransactionInfo`/`signedRenewalInfo`/`signedPayload` and replaces with SHA-256; raw JWS never persisted; `appAccountToken` logged first/last-4 only.
- **IAP provisioning tools** (`tools/app-store-connect/prepare-commercial-iaps.js`, `tools/google-play/prepare-commercial-iaps.mjs`, `scripts/commercial-launch-gate.mjs`): build-time admin CLIs reading creds from env / `firebase functions:secrets:access`; push prices/metadata to Apple/Google; write nothing to Firestore entitlements. Lower-risk.

## Routes / endpoints posture
- 150 callable/HTTP endpoints catalogued with authorization classification (see `authz-review.md`).
- Public/webhook `onRequest` endpoints (App Store S2S, Stripe webhook, `startCliLink`) authenticate by **signed payload / HMAC**, not App Check (cataloged `not-applicable-public`) — appropriate.
- Rate limits: per-credential + tokenless-loopback limits on the gateway proxy; `_rate_limits` docs server-only. Public-endpoint rate-limit inventory is a recommended hardening (not a finding this lane).

## File / data handling
- Firestore size limits: 1MB/80 keys general, escrow 50KB/20 keys (`firestore.rules:42-50`).
- Blob fetch ceilings exist (Rust `fetch_blob_with_expected_size`); the Swift bridge previously fell to post-download (06-14 M-010) — verify the regenerated UniFFI binding ships (deployment/build readback).
