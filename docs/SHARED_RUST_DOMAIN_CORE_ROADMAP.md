# Shared Rust Domain Core Roadmap

**Status:** active migration; no domain has completed production promotion and legacy deletion

**ADR:** [ADR 014](architecture/014-shared-rust-domain-core.md)

**Source inventory:** [Shared Rust Domain Inventory](SHARED_RUST_DOMAIN_INVENTORY.md)

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

1. Complete fixture corpus and native binding load tests on Apple and Windows.
2. At least **14 consecutive days per required consumer** in an internal or beta
   channel and **10,000 aggregate shadow parses** across the required consumers.
3. Zero unexplained mismatches. Explained categories require a linked issue and
   named review; explanation never removes the raw count from evidence.
4. Rust p95 latency no more than **5 percent** above the legacy p95, using the
   same shadow samples.
5. A passing fail-closed quantitative report from the existing promotion
   evidence evaluator delivered by [PR #1612](https://github.com/Imagine-That-Ai/BurnBar/pull/1612).
   Use `node scripts/ci/evaluate-domain-core-promotion.mjs --evidence <bundle>
   --output <report>` after that merged feature-stack commit is in the landing
   ancestry, and follow `docs/runbooks/shared-rust-promotion-evidence.md` from
   that commit. Do not add a second evaluator or hand-edit evidence.
6. One stable release observed with Rust authoritative and the explicit legacy
   rollback mode still available.

Only after all six gates pass may a separate deletion PR remove the legacy
quota implementations and rollback setting. A mismatch, artifact/ABI failure,
or latency regression before deletion rolls the affected consumer explicitly
back to `legacy`, preserves evidence, and restarts the applicable shadow window
after the cause is fixed.

Crypto promotion additionally requires deterministic KATs, bidirectional
cross-open coverage for every supported envelope version and consumer,
wrong-key/AAD/tamper rejection, boundary fuzzing, and an independent security
review with all release-blocking findings resolved. Authentication failures in
`rust` mode are fail-closed and never trigger legacy decryption. Legacy crypto
is deleted only after those gates, consumer-specific rollout evidence, and one
stable Rust-authoritative release.

## Current landing state

Snapshot: **2026-07-13**. “Merged” below means merged into a feature branch,
not into `main`, and does not mean production promotion.

- Quota: pilot [#1590](https://github.com/Imagine-That-Ai/BurnBar/pull/1590),
  Q2 [#1591](https://github.com/Imagine-That-Ai/BurnBar/pull/1591), and consumer
  wiring [#1592](https://github.com/Imagine-That-Ai/BurnBar/pull/1592) are merged.
  The 14-day/10,000-sample window has not been certified.
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
  evidence collection [#1722](https://github.com/Imagine-That-Ai/BurnBar/pull/1722),
  and remaining Swift/Kotlin consumer PRs remain open or pending.
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
