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

Signed builds derive that expected identity once from a clean, exact Git
checkout. The build receipt contains the candidate commit plus the manifest's
core version, ABI version, and source fingerprint; the resolver independently
checks those values against Cargo, the Rust ABI constant, and the complete
fingerprinted source roots. Apple plist metadata, Android BuildConfig/AAB
receipt, Windows assembly metadata/publish receipt, Console static values, and
the compiled Functions module all receive the same tuple. Release verification
binds the built runtime surface back to the authorized checkout. Runtime
environment variables are never signed authority, and an expected commit
argument may assert equality but may not rename the checkout.

### Promotion proof and diagnostic telemetry

Promotion authority is deterministic and candidate-bound. The `main` push
workflow runs the exact job, suite, artifact, coverage, benchmark, and rollback
contract in `config/domain-core-promotion-policy.json`. Each job emits a fragment
bound to the same GitHub run ID, attempt, commit, core version, ABI, and source
fingerprint. The final job rejects failed, skipped, missing, duplicate, extra,
mixed-run, or mixed-candidate fragments and creates an unsigned bundle. That
bundle states only `eligible_for_attestation`; it cannot authorize promotion.

The protected promotion workflow is the authority boundary. It checks out the
evaluator and policy from trusted `main`, requires the candidate to be reachable
from `main`, queries GitHub for the exact successful `push` run, downloads that
run's immutable bundle, independently validates the API run/jobs and candidate
checkout, and then uses GitHub's provenance attester. A dispatch or PR run,
user-supplied job JSON, a hand-authored bundle, or the uploaded verification
receipt cannot authorize promotion. The receipt records what was checked but is
not itself signed authority.

The `domain-core-promotion` GitHub environment is part of the trust boundary,
not a decorative YAML name. It must have a required reviewer and an allowlist
containing only the `main` branch. The signer checks those live controls before
attesting. As verified on 2026-07-14, the environment requires reviewer
`Ajnunezg` and permits only `main`; operators must preserve and re-verify those
settings.

Client durability is candidate-scoped. Apple, Android, Windows, and Console
derive their active queue namespace from the complete expected candidate tuple
and never read, upload, translate, or relabel a prior candidate's queue as new
evidence. Functions comparisons are a trusted server-side exception to client
claims only: the production process must hold an immutable signed compiled
receipt, record the identity independently observed from the loaded Wasm
module, and pass the same V3 parser before it may persist evidence. Only an
identical loaded tuple can produce a promotable success; a different readable
tuple is retained as `loaded_identity_mismatch`, and an unreadable tuple as
`native_unavailable`. Unsigned, local, test, or incomplete processes emit no
production evidence.

Candidate-bound V3 shadow samples remain optional diagnostic telemetry. Each
signed enrollment binds one internal/beta channel and consumer allowlist to one
exact app commit and expected loaded Rust tuple. The server validates those
claims and retains loaded identity mismatch, native-unavailable, native-error,
and result mismatch categories for diagnosis. No observation duration, daily
continuity, user count, or sample count is required for promotion. V1 and V2 are
accepted only so durable spools can drain idempotently and remain
non-promotable. The exact operator procedure is the
[Shared Rust Promotion Evidence runbook](../runbooks/shared-rust-promotion-evidence.md).

Crypto migrations additionally require deterministic KATs, bidirectional
cross-open, wrong-key/AAD/tamper rejection, boundary fuzzing, and independent
security review. Every domain still requires one stable Rust-authoritative
release with the explicit rollback path intact before legacy deletion.

## Landing and rollback

The source union and every generated artifact land coherently before consumers
are retargeted to ABI 3. Consumer changes then move through `legacy`, `shadow`,
and reviewed `rust` promotion. Merging a consumer into a feature branch is not
production promotion.

Before legacy deletion, rollback is an explicit configuration change from
`rust` to `legacy`; it is never an implicit exception handler. A mismatch,
latency regression, ABI/provenance failure, or unresolved security finding
    blocks promotion. After a rollback, retain the evidence, fix the cause, and
    produce a new exact candidate attestation. Legacy code is removed only in a
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
