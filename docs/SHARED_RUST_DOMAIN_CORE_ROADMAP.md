# Shared Rust Domain Core Roadmap

**Status:** active migration; no domain has completed production promotion and legacy deletion

**ADR:** [ADR 014](architecture/014-shared-rust-domain-core.md)

**Source inventory:** [Shared Rust Domain Inventory](SHARED_RUST_DOMAIN_INVENTORY.md)

**Promotion evidence:** [Candidate-bound V3 runbook](runbooks/shared-rust-promotion-evidence.md)

**Shadow sample contract:** [`domain-core-shadow-sample-v3.schema.json`](contracts/domain-core-shadow-sample-v3.schema.json)

**Quota contract:** [`tests/fixtures/domain-core/quota/v1/`](../tests/fixtures/domain-core/quota/v1/)

**CloudVault contract:** [`tests/fixtures/domain-core/cloudvault/v1/`](../tests/fixtures/domain-core/cloudvault/v1/)

**Hermes contract:** [`tests/fixtures/domain-core/hermes/v1/`](../tests/fixtures/domain-core/hermes/v1/)

The program consolidates pure business logic that is genuinely implemented in
more than one language. It does not rewrite every application or move
platform-owned I/O into Rust. Provider log parsing is specifically out of
scope: macOS, iOS, Linux, and Windows already consume the one Swift parser
engine, while Android and Cloud Functions do not read local provider logs.

## Invariants

- The Rust workspace owns pure transformations only. Platform adapters own I/O,
  persistence, credentials, process execution, UI, key handles, and release
  integration.
- The merged crate is the integration point. Work lands through short-lived,
  reviewable branches; there is no long-lived SharedRust branch.
- Contract fixtures precede implementation. Rust and every active consumer must
  emit the same normalized result before Rust can become authoritative.
- FFI calls are payload- or document-sized. No caller crosses the boundary once
  per log line, token, field, or byte block.
- Telemetry contains mismatch categories, counts, versions, and timing only. It
  never contains sensitive inputs, outputs, credentials, user identifiers, or
  stable payload hashes.
- Promotion proof is bound to one signed app commit and one expected loaded Rust
  version/ABI/source fingerprint. Optional V3 telemetry keeps server
  `receivedAt` for diagnostic ordering, but telemetry continuity and volume do
  not control promotion.
- Generated Swift, Kotlin, C#, native, and Wasm artifacts are one atomic release
  set. A consumer never mixes bindings or binaries generated from different
  domain-core source trees.

## Migration mode semantics

Each production adapter exposes a domain-specific
`OPENBURNBAR_DOMAIN_CORE_*_MODE` setting with these values:

| Mode | Authority | Failure behavior |
|---|---|---|
| `legacy` | Existing platform implementation only | Rust is not invoked. This is an explicit rollback state, not proof that migration is complete. |
| `shadow` | Existing platform implementation | Rust runs once against the same complete input. The adapter returns the legacy result and records only safe mismatch/failure categories. A Rust load, ABI, parse, or transform failure does not change the user-visible result because Rust is not authoritative in this mode. |
| `rust` | Shared Rust core only | Missing artifacts, ABI mismatch, invalid input, authentication failure, or Rust errors fail closed. The adapter must not silently invoke the legacy implementation. |

Missing or invalid configuration resolves to the documented legacy default
until a reviewed rollout changes that default. Selecting `rust` is an explicit
authority change and never enables automatic fallback. Shadow evidence is not
promotion; it is input to the promotion gate.

## Delivery waves

| Wave | Domain | Real duplication | Exit condition |
|---|---|---|---|
| Q1 | Claude statusline quota | Swift + C# | Rust enforced on Apple/Windows; quota rollout gate passes; named legacy transforms deleted |
| Q2 | Codex, Cursor, Anthropic quota | Swift + C# | Four quota mechanisms use Rust as authority; quota rollout gate passes; named legacy transforms deleted |
| C1 | CloudVault primitives, encrypted search, and document envelopes | Swift + Kotlin + C# + browser TypeScript, with different subsets | KAT/cross-open/tamper/fuzz/security gates pass for each applicable consumer; duplicated portable crypto and transform copies deleted without exporting browser private keys |
| C2 | Hermes relay crypto and ratchet byte transforms | Swift + Kotlin | Existing wire vectors pass through Rust; P-256 custody and ratchet state mutation remain platform-owned; legacy byte transforms deleted after crypto promotion |
| P1 | Model pricing and cost arithmetic | Swift + Cloud Functions TypeScript | Checked nano-USD Rust/Wasm path enforced; parity and rollout evidence pass; duplicate calculators deleted |

CloudVault C1 is split by security boundary:

- **C1a:** deterministic AAD canonicalization, SHA-256, 32-byte vault-key IDs,
  and fixed-purpose HKDF/HMAC.
- **C1b:** AES-256-GCM detached/combined framing, strict UTF-8, canonical RFC
  4648 Base64, and payload-sized calls. Platforms still generate secure 12-byte
  nonces.
- **C1c:** recovery normalization/HKDF/verification, strict on-curve 65-byte
  X9.63 P-256 validation, escrow HKDF from caller-provided ECDH output, and exact
  public-key-plus-AES wire assembly. Private keys and ECDH remain in platform
  key stores or non-extractable WebCrypto handles.
- **C1d:** typed whole-document rewrap. Swift and Kotlin classify dynamic
  Firestore dictionaries into typed payload/text/blob envelopes and a complete
  top-level field-name set. Rust receives that typed request once per document,
  authenticates and transforms envelopes in deterministic order, and returns
  changed/skip/companion/metadata/preserved-member intents. Persistence,
  timestamps, orchestration, and secure nonce generation remain platform-owned.
- **Search:** complete v1 token analysis and ordered keyed hashes. Storage,
  query orchestration, and browser non-extractable key handles stay outside
  Rust.

Android selects `legacy`, legacy-authoritative `shadow`, or fail-closed `rust`
for C1d with `OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE`; missing or
unknown values keep legacy authoritative.

Android routes all four search operations through one UniFFI call per complete
text/query behind `OPENBURNBAR_CLOUDVAULT_SEARCH_MODE=legacy|shadow|rust`.
Missing, blank, or unknown values resolve to `legacy`, and shadow remains
legacy-authoritative. Before its first native search the adapter caches and
verifies UniFFI ABI 3; a mismatch is a fail-closed Rust error and a sanitized
shadow rejection, never an automatic Rust-to-legacy fallback.

Search exports are payload-sized and typed. `cloud_vault_search_analyze`
returns normalized tokens, exact-phrase tokens, and semantic feature names for
one text. `cloud_vault_search` accepts one typed operation plus the complete
text, 32-byte vault key, and signed limit, then returns ordered hashes. The core
rejects text above 1 MiB, more than 4,096 extracted tokens, and limits above
1,024; nonpositive limits return the contract-required empty array. Owned FFI
and Wasm key copies and derived search keys are zeroized before return. Android
additionally wipes its owned lowering copy of the vault key after every native
attempt. Kotlin `String` is immutable, so Android avoids making an extra mutable
plaintext copy and relies on the UniFFI/Rust-owned input zeroization. Shadow
diagnostics contain only a bounded mismatch/error category, core version, and
counter; Rust mode propagates validation or native-load failures without
evaluating the legacy implementation.

## ABI 3 and artifact provenance

The converged union is one breaking **UniFFI ABI 3** cut. C1d replaces the old
positional nonce array with `CloudVaultResealNonce { fieldName, nonce }`. Rust
validates exact field coverage, uniqueness, and 12-byte nonce length. A nonce
cannot be reassigned to a different lexicographically sorted field by accident.
Every consumer must require `domain_core_abi_version() == 3`; ABI 2 bindings or
binaries must not be paired with ABI 3 consumers.

Use this atomic process for every source change:

1. Change the Rust source and its fixtures, then review the complete exported
   union in `crates/openburnbar-domain-core/union-abi-manifest.json`.
2. Run `python3 scripts/ci/domain-core-union-gate.py --update-source-fingerprint`
   once to atomically replace the manifest's source SHA-256 for the reviewed
   source tree.
3. From that exact tree, regenerate the Swift XCFramework, Android AAR/Kotlin
   binding, C# binding, and both browser/Node Wasm packages. Do not regenerate
   consumers from independent feature branches.
4. Commit the generated set together. Source fingerprints live in
   `crates/openburnbar-domain-core/artifact-provenance/{swift,kotlin,csharp}.sha256`
   and are embedded in the XCFramework, AAR, and both Wasm packages.
   The canonical Android NDK version lives in
   `config/domain-core-android-ndk-version.txt`; the AAR also embeds the exact
   Rust and NDK versions used to build its native libraries.
5. Run `python3 scripts/ci/domain-core-union-gate.py --check-abi` and the normal
   gate. CI also rebuilds/compares the generated surfaces and rejects missing,
   stale, mixed-source, or undeclared exports.

The source fingerprint proves source identity, not merely artifact presence.
Checksums, SBOMs, native load tests, and AGPL source completeness remain
separate release requirements.

Swift production search routing is controlled independently by
`OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE`, with `legacy` as the default,
`shadow` as a legacy-authoritative exact ordered comparison, and `rust` as the
fail-closed native authority. Native unavailability, ABI mismatch, invalid
input, or a UniFFI error never invokes legacy code in `rust` mode. Diagnostics
contain only the operation, mismatch/error category, and core version; search
text, hashes, and key material are never logged.

## Rollout and deletion gates

Quota promotion requires all of the following:

1. Complete deterministic fixtures, property/fuzz tests, and native/Wasm binding
   load tests for every required consumer in
   [`config/domain-core-promotion-policy.json`](../config/domain-core-promotion-policy.json).
2. One exact candidate commit and Rust version/ABI/source tuple, proven by the
   artifacts actually loaded by Swift, Kotlin, C#, browser Wasm, and Node Wasm.
3. A successful `push` run of `.github/workflows/domain-core.yml` on `main` with
   every exact policy job and all 38 real `(domain, slice, consumer)` coverage
   cells. Failed, skipped, missing, duplicate, extra, PR, dispatch, mixed-run, or
   mixed-candidate evidence fails closed.
4. The paired complete-payload FFI benchmark no more than **5 percent** slower
   than the direct Rust baseline in the same CI job and attempt.
5. A real rollback drill that resolves the signed public artifact and exercises
   its `legacy` routing, followed by a protected provenance attestation from
   `.github/workflows/domain-core-promotion-proof.yml`. The signer independently
   queries GitHub, downloads the exact run bundle, and revalidates it with the
   trusted `main` policy and evaluator. The unsigned bundle and uploaded
   verification receipt are not authority by themselves.
6. One stable signed release observed with Rust authoritative and the explicit
   legacy rollback mode still available.

Shadow telemetry is optional diagnostic input. V3 preserves exact candidate and
loaded-module identity and can reveal mismatches in real deployments, but no
duration, daily continuity, account count, or sample count is a promotion gate.
V1/V2 remain drain-only and no telemetry report may substitute for the protected
deterministic attestation.

Only after all six gates pass may a separate deletion PR remove the legacy
quota implementations and rollback setting. Its proof must retain the exact
attested candidate/core tuple, then pass named source-absence and Rust-only
compile gates. A mismatch, artifact/ABI/source failure, rollback, new candidate
commit, or performance regression before deletion rolls the affected consumer
explicitly back to `legacy`, preserves the diagnostic evidence, fixes the cause,
and requires a new exact candidate attestation.

Crypto promotion additionally requires deterministic KATs, bidirectional
cross-open coverage for every supported envelope version and consumer,
wrong-key/AAD/tamper rejection, boundary fuzzing, and an independent security
review with all release-blocking findings resolved. Authentication failures in
`rust` mode are fail-closed and never trigger legacy decryption. Legacy crypto
is deleted only after those gates, consumer-specific rollout evidence, and one
stable Rust-authoritative release.

## Current landing state

Snapshot: **2026-07-14**. PR and branch status records implementation ancestry
only. A merged crate, collector, or evidence contract is not production
promotion, does not prove a protected deterministic attestation, and does not
authorize legacy deletion.

- Quota: pilot [#1590](https://github.com/Imagine-That-Ai/BurnBar/pull/1590),
  Q2 [#1591](https://github.com/Imagine-That-Ai/BurnBar/pull/1591), and consumer
  wiring [#1592](https://github.com/Imagine-That-Ai/BurnBar/pull/1592) are in the
  implementation ancestry. The shared collector foundation
  [#1722](https://github.com/Imagine-That-Ai/BurnBar/pull/1722) is merged into
  `main`; that does not certify the protected deterministic candidate proof.
- CloudVault and pricing: foundation
  [#1594](https://github.com/Imagine-That-Ai/BurnBar/pull/1594), AES
  [#1602](https://github.com/Imagine-That-Ai/BurnBar/pull/1602), C1c core
  [#1615](https://github.com/Imagine-That-Ai/BurnBar/pull/1615), Windows C1c
  [#1616](https://github.com/Imagine-That-Ai/BurnBar/pull/1616), Console C1c
  [#1617](https://github.com/Imagine-That-Ai/BurnBar/pull/1617), and typed
  document rewrap [#1636](https://github.com/Imagine-That-Ai/BurnBar/pull/1636)
  are merged into the feature stack. Pricing
  [#1629](https://github.com/Imagine-That-Ai/BurnBar/pull/1629) and search
  [#1632](https://github.com/Imagine-That-Ai/BurnBar/pull/1632) are closed as
  superseded after their heads were incorporated into downstream convergence and
  consumer branches.
- Hermes [#1609](https://github.com/Imagine-That-Ai/BurnBar/pull/1609) and the
  promotion gate [#1612](https://github.com/Imagine-That-Ai/BurnBar/pull/1612)
  are merged into feature branches. Convergence
  [#1647](https://github.com/Imagine-That-Ai/BurnBar/pull/1647), crypto
  hardening [#1721](https://github.com/Imagine-That-Ai/BurnBar/pull/1721), rollout
  authority [#1729](https://github.com/Imagine-That-Ai/BurnBar/pull/1729), and
  remaining Swift/Kotlin consumer work are still under review or pending.
- Candidate-bound V3 ingress, enrollment, export, and evaluation remain useful
  diagnostic surfaces. They must not be cited as promotion authority regardless
  of sample volume or collection duration.
- Signed candidate receipts are being bound across Apple, Android, Windows,
  Console, and Functions to one clean checkout and one verified Rust
  version/ABI/source tuple. This release-integrity work prevents mixed or
  relabeled diagnostics, but does not authorize a mode promotion.
- No shared-Rust domain is complete under the inventory's completion rule. No
  legacy implementation should be deleted from this status snapshot.

## Required CI

- `cargo fmt --check`, Clippy with warnings denied, Rust unit/property tests,
  `cargo deny`, and bounded fuzz smoke for quota-transform and crypto surfaces.
- `domain-core-union-gate.py` ABI, export, source-fingerprint, and provenance
  checks across all eight union domains.
- Generated binding drift checks against the pinned UniFFI toolchain for Swift,
  Kotlin, and C#; exact deterministic tree comparison for browser and Node Wasm.
- Apple XCFramework, four-ABI Android AAR with 16 KiB page compatibility,
  Windows x64/ARM64 DLL, and applicable Linux library load tests.
- Focused platform fixture/consumer tests plus release checks for checksums,
  SBOM, provenance, and AGPL source completeness.
- Exact-run proof fragments, the real signed-legacy rollback drill, and a final
  unsigned candidate bundle on `main`; only the trusted-main revalidation and
  provenance attestation behind the protected `domain-core-promotion`
  environment authorizes promotion.
