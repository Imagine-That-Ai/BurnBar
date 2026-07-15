# ADR 014: Shared Rust Domain Core

## Status

Accepted; implementation and consumer rollout are in progress. Acceptance of
this architecture does not imply that any migration has passed its production
promotion or legacy-deletion gates.

## Context

OpenBurnBar has several behavior-identical pure domains implemented separately
for native and web platforms:

- quota response transforms in Swift and C#;
- CloudVault portable crypto and envelope logic across Swift, Kotlin, C#, and
  browser TypeScript, with different subsets per platform;
- Hermes portable crypto transforms in Swift and Kotlin;
- checked model-pricing arithmetic in Swift and Cloud Functions TypeScript; and
- encrypted-search analysis in Swift and Kotlin.

Whole-document CloudVault rewrap is also duplicated in Swift and Kotlin, but
its input begins as a dynamic Firestore dictionary. That dynamic representation
is not a suitable cross-language core contract.

Provider log parsing is not currently duplicated. The production parsers live
in `OpenBurnBarCore`; macOS, iOS, and Linux use that Swift engine, Windows loads
it through the existing Swift C ABI, and Android and Cloud Functions do not
parse local provider logs. Rewriting those parsers in Rust would replace one
implementation rather than consolidate several.

Golden fixtures detect drift after the fact but do not remove repeated
implementation cost. Independently generated native and Wasm artifacts can also
form an artifact diamond: bindings compile while pointing at a binary generated
from a different source or ABI.

## Decision

OpenBurnBar owns pure, duplicated business logic in
`crates/openburnbar-domain-core`. The workspace contains one dependency-light
Rust library, an explicit UniFFI adapter, and a Wasm adapter only for operations
that real TypeScript consumers execute. Transport, persistence, network
acquisition, authentication, secret storage, UI, operating-system integration,
platform key handles, and rollout control stay with their existing owners.

Every migration is contract-first. Existing implementations consume the same
language-neutral fixtures before Rust is introduced. Production adapters expose
three explicit states:

- `legacy` invokes only the existing implementation and is the rollback state;
- `shadow` returns the legacy result while invoking Rust once against the same
  complete input and recording secret-free mismatch/failure categories; and
- `rust` makes Rust authoritative and fails closed on artifact load, ABI,
  validation, parsing, authentication, or transform failure.

Shadow's legacy result is not an automatic fallback: legacy is deliberately the
authority in that mode. Once `rust` is selected, an adapter must not silently
invoke legacy code. Missing or invalid configuration keeps the documented
legacy default until a reviewed rollout changes it.

The crate on `main` is the integration point. Work proceeds through short-lived,
independently reviewable branches; there is no long-lived SharedRust branch.
Legacy implementations remain only for comparison and explicit rollback until
the evidence, stable-release, and deletion gates in the
[roadmap](../SHARED_RUST_DOMAIN_CORE_ROADMAP.md) are satisfied.

## Boundary decisions

### Rollout control ownership

Swift rollout profiles, native-availability identity, secret-free comparison
records, and the generic legacy-authoritative shadow selector live in the
Foundation-only `OpenBurnBarDomainCoreRuntime` target. `OpenBurnBarKernel`
depends on and re-exports this leaf, while domain adapters keep their
domain-specific inputs, equivalence rules, and fail-closed errors. This prevents
rollout safety machinery from regrowing the model/crypto kernel and gives the
Apple targets one typed authority contract without moving UI, persistence, or
artifact loading into the Rust crate.

### Payload-sized calls

Native and Wasm calls operate on a complete response, payload, document,
text/query, or event. Callers do not cross the boundary once per log line,
token, field, or block. The platform acquisition layer retains HTTP, file,
credential, database, and clock ownership.

### CloudVault key custody

Rust owns deterministic AAD/hashing/KDF, authenticated AES framing, recovery
normalization/wrap, public-point validation, portable escrow framing, typed
document transform, and encrypted-search analysis. CryptoKit, Android
Keystore/JCA, Windows CNG, and WebCrypto retain P-256 private keys, ECDH, secure
random generation, and non-extractable key handles. No FFI or Wasm API accepts a
private scalar, private-key encoding, or exported browser `CryptoKey` merely to
centralize an operation.

### CloudVault encrypted search

Rust owns the complete v1 analysis and hash operation: Unicode tokenization,
stopwords, index/query prefixes, phrase terms, semantic features, and ordered
keyed hashes. UniFFI and Wasm each take one complete text/query rather than
crossing the boundary per token. Inputs fail closed over 1 MiB of UTF-8, 4,096
extracted tokens, or a positive requested limit over 1,024. Nonpositive limits
remain a successful empty result because that is part of the versioned legacy
contract. Platform search services and Firestore I/O remain outside Rust.

Android and Swift each select `legacy`, legacy-authoritative `shadow`, or
fail-closed `rust` with `OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE`. Each
public token/index/query/semantic API crosses UniFFI once with the complete text
or query. The Android adapter wipes its owned key copy after every native
attempt. Both adapters require ABI 3 and emit only bounded
category/version/count diagnostics; callers, key custody, persistence, and
Firestore mapping do not cross the boundary.

### Typed CloudVault document rewrap

Swift and Kotlin, not Rust, classify collection-specific dynamic Firestore maps.
The adapter constructs a complete top-level field-name set and typed
sealed-payload, sealed-text, and blob envelopes. It also supplies old/new key
material, the expected new vault-key ID, and a named reseal nonce plan. Rust
receives that typed request once per document and owns bounded validation, exact
authentication, deterministic ordering, reseal, and typed
changed/skip/companion/metadata/preserved-member intents.

The adapter applies those intents to the original dictionary. Firestore map
typing, persistence, timestamps, rotation orchestration, randomness, retry
policy, and platform key handles remain outside Rust. An already-new envelope is
authenticated under the new key before it can be reported as skipped; malformed
or tampered skip candidates fail closed.

### ABI 3 named nonce contract

The converged union is a breaking UniFFI ABI 3 release. Document rewrap uses
`CloudVaultResealNonce { fieldName, nonce }`, replacing the ABI 2 positional
nonce array. This binds each caller-generated 12-byte nonce to the envelope it
may reseal and lets Rust reject missing, duplicate, extra, or mis-sized entries.
Swift, Kotlin, and C# consumers require `domain_core_abi_version() == 3`; no ABI
2 binding or library is compatible with the converged consumer set.

### Artifact provenance

`crates/openburnbar-domain-core/union-abi-manifest.json` is the reviewed export
and source-root manifest for the complete union. After a source change, the
source fingerprint is atomically updated once with
`scripts/ci/domain-core-union-gate.py --update-source-fingerprint`. Swift,
Kotlin/AAR, C#, browser Wasm, and Node Wasm are then regenerated from that exact
tree and committed as one set.

Generated-source fingerprints are recorded centrally under
`crates/openburnbar-domain-core/artifact-provenance/` and embedded in the
XCFramework, AAR, and both Wasm packages. Android's canonical NDK version is
stored in `config/domain-core-android-ndk-version.txt`, and the AAR additionally
embeds its exact Rust and NDK versions. The union gate checks required exports
for all converged domains, source identity, and selected artifact provenance;
language-specific drift jobs rebuild and compare generated output. A PR may not
independently merge one regenerated artifact if doing so creates mixed-source
bindings or binaries.

Every loaded native or Wasm module also exposes its own immutable identity:
domain-core version, ABI version, and the reviewed lowercase SHA-256 source
fingerprint. Promotion evidence must read this tuple from the loaded module and
compare it with the candidate's signed build metadata. A package sidecar alone
does not prove which library the process loaded, and a version string alone does
not distinguish two source revisions built with the same semantic version.

### Promotion evidence

Candidate-bound V3 is the only evidence schema that may authorize a
`shadow`-to-`rust` promotion or later legacy deletion. Each signed enrollment
binds one internal/beta channel and consumer allowlist to one exact app commit
and expected loaded Rust tuple: canonical version, uint32 ABI, and reviewed
source SHA-256. The server verifies all six claims, validates the declared
operation/domain/slice identity, and stamps `receivedAt`. Client `observedAt`
never controls a promotion window.

The exporter selects one exact candidate/core tuple over a half-open server
receipt interval and records sample counts for every UTC day and real
slice/consumer coverage cell. The evaluator requires one common observation
window, at least 14 consecutive days, 10,000 aggregate internal/beta samples,
zero unexplained mismatches, and at most five percent p95 regression. A loaded
tuple different from the signed expected tuple is retained as
`loaded_identity_mismatch` and is a hard blocker that cannot be explained away.
Native-unavailable and native-error comparisons are also hard blockers.

V1 and V2 remain accepted only so durable spools can drain idempotently. The
server marks them non-promotable, they are never translated into V3, and the
evaluator returns `evidence_schema_v3_required`. Operator-supplied revision
labels cannot substitute for the candidate commit stored in each V3 sample
accepted by the server. The exact operator procedure is the
[Shared Rust Promotion Evidence runbook](../runbooks/shared-rust-promotion-evidence.md),
and the client contract is
[`domain-core-shadow-sample-v3.schema.json`](../contracts/domain-core-shadow-sample-v3.schema.json).

The quantitative evaluator originally delivered in
[#1612](https://github.com/Imagine-That-Ai/BurnBar/pull/1612) remains the single
fail-closed evaluation authority, now upgraded for all inventoried domains and
candidate-bound V3. No second evaluator, policy override, relabeled cohort, or
synthetic passing evidence is accepted.

A passing quantitative result is necessary but insufficient. Native artifact
loads, fixtures, one stable Rust-authoritative release, and the separate legacy
deletion proof remain required. Crypto migrations additionally require KATs,
bidirectional cross-open, wrong-key/AAD/tamper rejection, boundary fuzzing, and
independent security review.

## Landing and rollback

The source union and every generated artifact land coherently before consumers
are retargeted to ABI 3. Consumer changes then move through `legacy`, `shadow`,
and reviewed `rust` promotion. Merging a consumer into a feature branch is not
production promotion.

Before legacy deletion, rollback is an explicit configuration change from
`rust` to `legacy`; it is never an implicit exception handler. A mismatch,
latency regression, ABI/provenance failure, or unresolved security finding
blocks promotion. After a rollback, retain the evidence, fix the cause, and
restart the applicable evidence window. Legacy code is removed only in a
separate reviewed change after one stable Rust-authoritative release, and
source/compile gates must prove the named legacy implementations and selector
are absent.

Android owns strict Firestore-map lowering and applies only typed Rust update
intents. `OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_REWRAP_MODE` controls its dedicated
`legacy`, legacy-authoritative `shadow`, and fail-closed `rust` lanes. Shadow
uses the same caller-generated, field-addressed nonce plan for both engines so
ciphertext can be compared directly; diagnostics contain only operation,
category, core version, and count.

## Consequences

- The shared crate removes real duplication without forcing UI, persistence,
  networking, or key custody through FFI.
- Swift, Kotlin, and C# use generated UniFFI bindings. Tauri may link the pure
  crate directly only for a domain it actually executes. Cloud Functions use
  the reviewed Wasm adapter only for applicable pricing operations.
- Browser private keys remain non-extractable WebCrypto handles.
- Existing iroh, remote, media, and libsignal crates remain separate ownership
  boundaries.
- A domain moves only when at least two implementations exist or a measured
  runtime constraint justifies replacing the current authority.
- Provider log parsers remain in the shared Swift engine unless the duplication
  inventory materially changes.
