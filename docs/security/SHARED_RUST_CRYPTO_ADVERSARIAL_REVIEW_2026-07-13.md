# Shared Rust Crypto Boundary Review

**Date:** 2026-07-13

**Scope:** Shared Rust CloudVault and Hermes deterministic crypto boundaries,
their Swift/Kotlin/C#/Wasm adapters, malformed-input behavior, migration
authority, generated bindings, and artifact provenance.

**Claim boundary:** This is a repository-level adversarial implementation
review, not a formal cryptographic audit or proof of protocol security. It does
not certify platform random-number generators, private-key custody, production
nonce uniqueness, or rollout evidence.

## Review method

- Traced raw-key, nonce, AAD, ciphertext, recovery, escrow, and HKDF values from
  platform adapters through UniFFI/Wasm into the Rust primitives.
- Exercised canonical KATs, wrong key/AAD, tag and ciphertext tampering, invalid
  nonce/key lengths, off-curve P-256 points, recovery failures, bounded fuzz
  cases, and native artifact loading.
- Checked migration behavior separately from primitive behavior: shadow remains
  legacy-authoritative, while explicit Rust mode never invokes legacy after a
  native, validation, or authentication failure.
- Rebuilt the generated surfaces from one final source fingerprint and checked
  the union ABI and per-artifact provenance.

## Validation evidence

- `cargo fmt --check`
- `cargo clippy --workspace --all-targets -- -D warnings`
- `cargo test --workspace --all-targets`: 50 core, 2 FFI, and 6 fuzz-smoke
  tests passed; the release-only performance smoke remained intentionally
  ignored.
- `swift test --package-path OpenBurnBarCore --filter
  'HermesDomainCoreAdapterBoundaryTests|CloudVaultDomainCoreAdapterTests'`: 14
  tests passed.
- `./gradlew :app:testDebugUnitTest --no-daemon --rerun-tasks` filtered to the
  CloudVault and Hermes domain-core adapter suites: passed after forced Kotlin
  and unit-test recompilation.
- `./scripts/build-domain-core-wasm.sh --check`: browser and Node packages were
  API-, behavior-, and byte-equivalent to a clean rebuild.
- `./scripts/build-domain-core-android-aar.sh --check-source` and
  `--check-artifact`: all four Android ABIs were 16 KB compatible and the AAR
  rebuilt byte-identically.
- `scripts/windows-port/check-csharp-binding-drift.sh domain-core`: the
  committed C# binding matched the pinned generator.
- `domain-core-union-gate.py --check-abi --check-provenance ...`: Swift,
  Kotlin, C#, browser Wasm, Node Wasm, XCFramework, and AAR surfaces all matched
  source fingerprint
  `05edb4d0507da2172ba1d6a212cf549d1a47b361caeca2262dffa57c534144d2`.

## Resolved findings

### R1. Swift shadow execution violated the authority contract

The Swift CloudVault and Hermes selectors evaluated Rust before the legacy
authority. A slow or failing native path could therefore affect an operation
whose documented result and failure were owned by legacy code. Shadow now
evaluates legacy exactly once and first. If legacy throws, Rust is not invoked;
if Rust fails, the exact legacy value is returned. Rust mode remains fail-closed.

### R2. Negative Android schema versions crossed UniFFI as large unsigned values

Kotlin used `schemaVersion.toUInt()`. A value such as `-1` became
`4294967295`, which satisfied Rust's `schema_version >= 2` check and produced a
non-contract AAD string. The adapter now rejects values below 2 before lowering.
The Wasm boundary independently rejects negative, fractional, non-finite, and
out-of-range JavaScript numbers.

### R3. HKDF length lowering was not misuse-resistant at platform boundaries

Swift and Kotlin accepted signed integers and converted them to unsigned FFI
values. Both adapters now enforce the RFC 5869 SHA-256 range of 1 through 8160
bytes before crossing FFI. Rust retains the same independent bound.

### R4. Owned Wasm plaintext/search/key copies outlived the operation

Wasm rewrap keys and search text now cross as owned values and are zeroized on
success and error paths. This reduces residue inside Wasm linear memory. It
cannot erase the caller-owned JavaScript `String` or `Uint8Array`; consumers
must continue to avoid unnecessary copies and must not treat Wasm zeroization as
browser-process memory erasure.

### R5. Search limit lowering used an unchecked integer cast

The search core now uses a checked signed-to-`usize` conversion after its
nonpositive and upper-bound checks. This preserves current 32/64-bit behavior
and makes the allocation boundary explicit.

## Preserved invariants

- AES-256-GCM authentication failure never triggers legacy decryption in Rust
  mode.
- Keys are exactly 32 bytes; nonces are exactly 12 bytes; Hermes and CloudVault
  AAD inputs remain bounded and domain-separated.
- P-256 escrow accepts only exact, uncompressed, on-curve 65-byte X9.63 points.
- Platform code retains secure nonce generation, ECDH, private-key handles,
  state mutation, persistence, and replay policy.
- Browser non-extractable `CryptoKey` values do not cross into Rust/Wasm.
- Diagnostics contain operation/category metadata only, never plaintext, keys,
  ciphertext, recovery material, or stable payload hashes.

## Remaining promotion gates

This review resolves the code findings above. CloudVault/Hermes promotion still
requires the roadmap's bidirectional consumer cross-open matrix, retained
shadow evidence, supported-architecture artifact loading, one stable
Rust-authoritative release, and a separate legacy-deletion change. A future
protocol or primitive change should receive an independent specialist review;
this document must not be used as blanket approval for later crypto changes.

## Residual risks

- Rust zeroizes the owned buffers it receives, but cannot guarantee erasure of
  caller-owned Swift `Data`, Kotlin `ByteArray`, C# arrays, JavaScript strings,
  or `Uint8Array` values and their runtime-created copies.
- UniFFI-generated record lowering owns intermediate platform allocations.
  Exported search results necessarily expose plaintext tokens to consumers, and
  those generated intermediate copies are not formally wipe-proven.
- P-256 private keys and ECDH operations remain platform-owned. Their call sites
  were source-reviewed here, but platform key custody was not penetration
  tested.
- Nonce uniqueness is caller-owned across operations. The core validates nonce
  length and a rewrap request's per-document uniqueness, but cannot enforce
  global uniqueness across devices or time.
- This was an internal engineering source review. It is not independent human
  or external security approval, and it provides no production rollout or
  deployed-configuration evidence.
