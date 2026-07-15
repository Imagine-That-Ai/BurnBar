# Shared Rust Domain Inventory

**Status:** active migration ledger; no row is complete

**Architecture:** [ADR 014](architecture/014-shared-rust-domain-core.md)

**Roadmap:** [Shared Rust Domain Core Roadmap](SHARED_RUST_DOMAIN_CORE_ROADMAP.md)

This ledger is the source-level proof of what is actually duplicated. A
platform is a migration consumer only when it executes the same pure operation;
shipping five applications does not imply five implementations of every
domain. “Rust plus platform” means a migration is staged or in shadow, not that
Rust is production-authoritative. Update this file when a source owner,
consumer, contract, deletion target, or rollout state changes.

## Platform reality

| Platform | Quota transforms | CloudVault portable logic | Hermes portable crypto | Pricing arithmetic | Encrypted search |
|---|---|---|---|---|---|
| Swift (macOS/iOS and Linux daemon) | Claude, Codex, Cursor, Anthropic | Yes | Yes | Yes | Yes |
| C# (Windows) | Claude, Codex, Cursor, Anthropic | AAD/AES/recovery/escrow subsets | No | No; injected calculator defaults to zero | No production owner |
| Kotlin (Android) | No local provider quota parsing | Yes | Yes | No canonical catalog calculator | Yes |
| Browser TypeScript (Console) | No | Yes, with non-extractable WebCrypto keys | No | No | Consumes encrypted search data; no duplicate native analyzer |
| Cloud Functions TypeScript | Separate Cursor dashboard mechanism only | Encrypted-record coordination only | Envelope validation/coordination only | Yes | Persistence/query coordination only |
| Tauri/Linux UI | Displays daemon-produced values | No separate implementation | No separate implementation | No separate implementation | No separate implementation |

Provider log parsers remain in `OpenBurnBarCore`. macOS, iOS, and Linux use that
single Swift engine, and Windows loads it through the existing Swift C ABI.
Android and Cloud Functions do not read local provider logs. Provider parsers
are therefore not duplicated and are not a shared-Rust consolidation target.

## Q1/Q2 quota operations

| Operation | Migration owners | Contract | Production callers | Legacy deletion target |
|---|---|---|---|---|
| Claude statusline JSON to buckets | Rust plus Swift/C# during rollout | `tests/fixtures/domain-core/quota/v1/claude-statusline-*` | Swift `ClaudeQuotaAdapter`; Windows `ClaudeStatuslinePayloadSource` | Swift `legacyBuckets`; C# `ParseLegacy`, window parser, and bucket builder |
| Codex `wham/usage` JSON to snapshot | Rust plus Swift/C# during rollout | `codex-usage-*` | Swift `CodexOAuthQuotaFetcher`; Windows `CodexUsageQuotaSource` | Swift `rateLimitBuckets` helpers and decoded transform; C# `CodexUsageQuotaParser` implementation |
| Cursor `usage-summary` JSON to snapshot | Rust plus Swift/C# during rollout | `cursor-usage-summary-*` | Swift `CursorQuotaAdapter`; Windows `CursorUsageQuotaSource` | Swift `buildExactSnapshot`; C# `CursorUsageQuotaParser` implementation |
| Anthropic rate-limit headers to snapshot | Rust plus Swift/C# during rollout | `anthropic-ratelimit-headers-*` | Swift `AnthropicCredentialProbe`/`ClaudeQuotaAdapter`; Windows `AnthropicRateLimitSource` | Swift header coercion/snapshot builder; C# `AnthropicRateLimitHeaderParser` implementation |

Quota FFI calls receive one complete response payload and a frozen time anchor
where relative resets exist. HTTP, credentials, files, and SQLite remain in the
platform acquisition layer. Rust mode must fail closed on artifact, ABI, or
transform failure; shadow mode returns the legacy result while collecting safe
comparison metadata.

Current status: [#1590](https://github.com/Imagine-That-Ai/BurnBar/pull/1590)
and [#1591](https://github.com/Imagine-That-Ai/BurnBar/pull/1591) remain open;
consumer wiring [#1592](https://github.com/Imagine-That-Ai/BurnBar/pull/1592)
is merged into the feature stack. Neither the quantitative promotion gate nor
the stable-release gate has been satisfied.

## C1 CloudVault operations

| Slice | Real owners | Rust boundary and deletion condition |
|---|---|---|
| AAD v1/v2 serialization and envelope validation | Swift, Kotlin, C#, Console | Rust owns deterministic bytes. Delete serializers only after every applicable consumer uses the shared contract and crypto gates pass. |
| SHA-256, HMAC, HKDF, vault-key IDs, and blob hashes | Same four owners, with unequal subsets | Rust/Wasm may own deterministic byte transforms because no private key handle is required. |
| AES-256-GCM text/blob/payload seal/open | Swift, Kotlin, C#, Console | Rust owns framing/authentication where raw key bytes already cross the adapter. Require cross-open and wrong-key/AAD/tamper rejection; never fall back after auth failure. |
| Recovery-key wrap and P-256 escrow wrap | Swift, Kotlin, C#, Console subsets | Rust owns portable normalization/KDF/framing. Platform key stores retain private-key custody and ECDH; no private scalar or browser `CryptoKey` export crosses the boundary. |
| Whole-document envelope rewrap | Swift and Kotlin implementations; Rust transform staged | Swift/Kotlin classify dynamic Firestore maps into typed envelopes, then call Rust once per document. Rust owns bounded validation, authentication, deterministic transform, and update intents. Delete platform transform logic only after ABI 3 consumers and crypto promotion gates pass. |
| Search tokens and semantic hashes | Swift and Kotlin | Rust owns complete analysis and ordered keyed hashes once per text/query. Persistence and query orchestration remain platform-owned. Delete analyzers only after both consumers pass shadow/promotion gates. |

### Typed document-envelope boundary

Rust does **not** receive or classify an arbitrary Firestore dictionary. Swift
and Kotlin adapters recognize the collection-specific dynamic map shape and
construct:

- the complete top-level field-name set;
- typed sealed-payload, sealed-text, and blob envelopes;
- the old/new vault key material and expected new vault-key ID; and
- a named nonce plan of `CloudVaultResealNonce { fieldName, nonce }` records.

Rust validates exact field and nonce-plan coverage, authenticates existing
envelopes, reseals eligible envelopes in deterministic field order, and returns
typed changed/skip/companion/metadata/preserved-member intents. The adapter
applies those intents to the original document. Firestore typing, persistence,
timestamps, rotation orchestration, random generation, and retry policy remain
outside Rust.

`CloudVaultResealNonce` is part of the breaking UniFFI ABI 3 union. The old
positional nonce array is not ABI-compatible and must not survive in generated
bindings or consumers after the atomic ABI 3 artifact cut.

The Console stores non-extractable `CryptoKey` values in IndexedDB. Rust/Wasm
must not require exporting those keys. WebCrypto operations using such handles
remain behind a narrow browser adapter unless a reviewed callback/handle design
preserves non-extractability.

Current status snapshot (2026-07-13):

| Slice | Core/contract PR | Consumer PRs |
|---|---|---|
| C1a foundation | [#1594](https://github.com/Imagine-That-Ai/BurnBar/pull/1594) open | Console [#1597](https://github.com/Imagine-That-Ai/BurnBar/pull/1597), C# [#1598](https://github.com/Imagine-That-Ai/BurnBar/pull/1598), Swift [#1599](https://github.com/Imagine-That-Ai/BurnBar/pull/1599), and Kotlin [#1601](https://github.com/Imagine-That-Ai/BurnBar/pull/1601) open |
| C1b AES | [#1602](https://github.com/Imagine-That-Ai/BurnBar/pull/1602) open | C# [#1604](https://github.com/Imagine-That-Ai/BurnBar/pull/1604), Console [#1607](https://github.com/Imagine-That-Ai/BurnBar/pull/1607), and Swift [#1608](https://github.com/Imagine-That-Ai/BurnBar/pull/1608) open; Kotlin [#1611](https://github.com/Imagine-That-Ai/BurnBar/pull/1611) merged into the AES feature branch |
| C1c recovery/escrow | [#1615](https://github.com/Imagine-That-Ai/BurnBar/pull/1615) merged into the AES feature branch | C# [#1616](https://github.com/Imagine-That-Ai/BurnBar/pull/1616) and Console [#1617](https://github.com/Imagine-That-Ai/BurnBar/pull/1617) merged into the C1c feature branch; Kotlin [#1623](https://github.com/Imagine-That-Ai/BurnBar/pull/1623) and Swift [#1634](https://github.com/Imagine-That-Ai/BurnBar/pull/1634) open |
| C1d document rewrap | [#1636](https://github.com/Imagine-That-Ai/BurnBar/pull/1636) open/converging into ABI 3 | Swift and Kotlin ABI 3 consumer changes are not yet landed |
| Encrypted search | Contract [#1620](https://github.com/Imagine-That-Ai/BurnBar/pull/1620) merged into a feature branch; core [#1632](https://github.com/Imagine-That-Ai/BurnBar/pull/1632) open | Kotlin [#1635](https://github.com/Imagine-That-Ai/BurnBar/pull/1635) and Swift [#1640](https://github.com/Imagine-That-Ai/BurnBar/pull/1640) open |

“Merged” in this table means merged into the named feature branch, not `main`.
No CloudVault slice has completed security review, protected deterministic
promotion, an exact-candidate stable release with retained signed rollback, and
legacy deletion.

## C2 Hermes operations

| Slice | Real owners | Contract/deletion boundary |
|---|---|---|
| Request/response/control/media AAD | Rust plus Swift/Kotlin during rollout | `tests/fixtures/domain-core/hermes/v1`; delete serializers after crypto promotion evidence |
| AES payload seal/open and v1/v2 key-wrap KDF/info | Rust plus Swift/Kotlin during rollout | Rust owns framing/KDF; CryptoKit/JCA retain P-256 ECDH and secure nonce generation |
| Authenticated HPKE v3 info | Rust plus Swift/Kotlin during rollout | Pinned sender authentication and platform private-key custody remain unchanged; no auth fallback |
| Ratchet KDF, envelope AAD, and payload AEAD | Rust plus Swift/Kotlin during rollout | Platform code retains atomic state transitions, skipped-key maps, replay policy, P-256 ratchets, and persistence |

Functions validate schemas and proof-of-possession but do not decrypt relay
payloads, so they are not a native relay-crypto implementation. Hermes
[#1609](https://github.com/Imagine-That-Ai/BurnBar/pull/1609) is merged into a
feature branch, not `main`; rollout and deletion gates remain open.

## P1 pricing operations

| Operation | Real owners | Contract/deletion boundary |
|---|---|---|
| Catalog rate lookup | Swift `OpenBurnBarCatalog` only | Not duplicated: catalog loading and provider matching stay in Swift; Rust receives selected rates. |
| Token-cost arithmetic and cache-write fallback | Rust plus Swift/Functions during rollout | `tests/fixtures/domain-core/pricing/v2/pricing-kat.json`; checked nano-USD arithmetic becomes authoritative before deleting `ModelPricing.cost` and `legacyTokenCost`. |
| Historical provider-era pricing | Rust plus Functions during rollout | Kimi `chatcmpl-` recognition, `kimi-for-coding` alias, era rates, cache subtraction, and total/cost are one event-sized call. |
| Runtime consumers | Swift native and Functions TypeScript | `OPENBURNBAR_DOMAIN_CORE_PRICING_MODE=legacy\|shadow\|rust`; Functions lazily loads checked-in Wasm from its deployable vendor package. |

Functions alone rounds final rollup totals to six decimals. That aggregation
presentation rule has no Swift peer and remains outside P1. P1 returns checked
integer nano-USD and converts to the existing USD number only inside each
platform adapter. Stored schemas remain unchanged. Pricing
[#1629](https://github.com/Imagine-That-Ai/BurnBar/pull/1629) is open and has
not completed rollout or deletion gates.

## Artifact ownership

The generated surfaces are a single source-coherent set:

| Surface | Provenance proof |
|---|---|
| Swift binding/XCFramework | `artifact-provenance/swift.sha256` plus fingerprint embedded at the XCFramework root |
| Kotlin binding/four-ABI AAR | `artifact-provenance/kotlin.sha256` plus source and Rust/NDK toolchain provenance under `META-INF/` inside the AAR |
| C# binding/native DLL | `artifact-provenance/csharp.sha256` plus generated binding drift/native load checks |
| Browser and Node Wasm | `openburnbar-domain-core-source.sha256` inside each vendored package plus exact tree comparison |

`scripts/ci/domain-core-union-gate.py` validates all eight converged domains,
their required ABI symbols, the reviewed source fingerprint, and selected
artifact provenance. Regenerate every surface from the same source tree after
one atomic `--update-source-fingerprint`; never merge independently generated
artifact diamonds.

## Completion rule

A row leaves this ledger only after:

1. Rust is authoritative in every real consumer and Rust mode fails closed.
2. Packaged artifacts load on every supported architecture and provenance proves
   they came from the same reviewed source tree.
3. Fixture, quantitative rollout, performance, and applicable crypto security
   gates in the roadmap pass with retained evidence.
4. One stable Rust-authoritative release has been observed with the explicit
   legacy rollback mode still available.
5. A separate deletion change removes the named legacy implementations and
   source/compile gates prove they cannot be selected or linked.

Adding an export, generating a binding, merging into a feature branch, or
running shadow mode alone is not completion.
