# Shared Rust Domain Inventory

**Status:** active migration ledger  
**Architecture:** [ADR 014](architecture/014-shared-rust-domain-core.md)  
**Roadmap:** [Shared Rust Domain Core Roadmap](SHARED_RUST_DOMAIN_CORE_ROADMAP.md)

This ledger is the source-level proof of what is actually duplicated. A
platform is a migration consumer only when it executes the same pure operation;
shipping five applications does not imply five implementations of every
domain. Update this file when a source owner, consumer, contract, or deletion
target changes.

## Platform reality

| Platform | Quota transforms | CloudVault crypto | Hermes crypto | Pricing authority |
|---|---|---|---|---|
| Swift (macOS/iOS and Linux daemon) | Claude, Codex, Cursor, Anthropic | Yes | Yes | Yes |
| C# (Windows) | Claude, Codex, Cursor, Anthropic | Partial | No | No; injected calculator defaults to zero |
| Kotlin (Android) | No local provider quota parsing | Yes | Yes | No canonical catalog calculator |
| Browser TypeScript (Console) | No | Yes, with non-extractable WebCrypto keys | No | No |
| Cloud Functions TypeScript | Separate Cursor dashboard mechanism only | Zero-knowledge coordination only | Envelope validation/coordination only | Yes |
| Tauri/Linux UI | Displays daemon-produced values | No | No | No |

Provider log parsers remain in `OpenBurnBarCore`: Windows and Linux already use
that single Swift engine, while Android and Functions do not read local provider
logs. They are not a consolidation target.

## Q1/Q2 quota operations

| Operation | Current owners | Contract | Production callers | Legacy deletion target |
|---|---|---|---|---|
| Claude statusline JSON to buckets | Rust plus Swift/C# during rollout | `tests/fixtures/domain-core/quota/v1/claude-statusline-*` | `ClaudeQuotaAdapter`; Windows `ClaudeStatuslinePayloadSource` | Swift `legacyBuckets`; C# `ParseLegacy`, window parser, and bucket builder |
| Codex `wham/usage` JSON to snapshot | Rust plus Swift/C# during rollout | `codex-usage-*` | Swift `CodexOAuthQuotaFetcher`; Windows `CodexUsageQuotaSource` | Swift `rateLimitBuckets` helpers and decoded transform; C# `CodexUsageQuotaParser` implementation |
| Cursor `usage-summary` JSON to snapshot | Rust plus Swift/C# during rollout | `cursor-usage-summary-*` | Swift `CursorQuotaAdapter`; Windows `CursorUsageQuotaSource` | Swift `buildExactSnapshot`; C# `CursorUsageQuotaParser` implementation |
| Anthropic rate-limit headers to snapshot | Rust plus Swift/C# during rollout | `anthropic-ratelimit-headers-*` | Swift `AnthropicCredentialProbe`/`ClaudeQuotaAdapter`; Windows `AnthropicRateLimitSource` | Swift header coercion/snapshot builder; C# `AnthropicRateLimitHeaderParser` implementation |

Quota FFI calls receive one complete response payload and a frozen time anchor
where relative resets exist. HTTP, credentials, files, and SQLite remain in the
platform acquisition layer.

## C1 CloudVault operations

| Slice | Current source owners | Canonicalization/deletion boundary |
|---|---|---|
| AAD v1/v2 serialization and envelope validation | `CloudVaultCrypto.swift`; Android `CloudVaultCrypto*.kt`; Windows `OpenBurnBar.CloudSync.Crypto`; `apps/console/lib/escrow.ts` | Unify Windows KATs and Console interop vectors first; delete platform serializers after all consumers read the shared contract |
| SHA-256, HMAC, HKDF, vault-key IDs and blob hashes | Same four owners, with unequal subsets | Move deterministic byte transforms first; browser may call WASM because no key handle is required |
| AES-256-GCM text/blob/payload seal/open | Same four owners | Require bidirectional cross-open plus wrong-key/AAD/tamper rejection; never fall back after authentication failure |
| Recovery-key wrap and P-256 escrow wrap | Swift/Kotlin/C#/Console subsets | Preserve platform key custody; migrate portable byte/key-material operations only after KAT coverage is shared |
| Search tokens and semantic hashes | Swift/Kotlin, with Console consumers | Migrate after primitives; keep persistence and query orchestration outside Rust |
| Whole-document envelope rewrap | Rust core plus Swift/Kotlin legacy implementations pending consumer rollout | Canonical contract: `tests/fixtures/domain-core/cloudvault/v1/cloudvault-document-rewrap-contract.json`. Rust receives typed envelopes once per document and returns changed/skip/companion/metadata/preserved-member intents; keep Firestore maps, persistence, timestamps, rotation orchestration, and random policy outside Rust |

The Console stores non-extractable `CryptoKey` values in IndexedDB. Rust/WASM
must not require exporting those keys. WebCrypto operations using such handles
remain behind a narrow browser adapter unless a reviewed callback/handle design
preserves non-extractability.

## C2 Hermes operations

| Slice | Current owners | Contract/deletion boundary |
|---|---|---|
| Request/response/control/media AAD | Rust plus Swift/Kotlin during rollout | `tests/fixtures/domain-core/hermes/v1`; delete serializers after rollout evidence |
| AES payload seal/open and v1/v2 key-wrap KDF/info | Rust plus Swift/Kotlin during rollout | Rust owns framing/KDF; CryptoKit/JCA retain P-256 ECDH and secure nonce generation |
| Authenticated HPKE v3 info | Rust plus Swift/Kotlin during rollout | Pinned sender authentication and platform private-key custody remain unchanged; no auth fallback |
| Ratchet KDF, envelope AAD, and payload AEAD | Rust plus Swift/Kotlin during rollout | Platform code retains atomic state transitions, skipped-key maps, replay policy, P-256 ratchets, and persistence |

Functions validate schemas and proof-of-possession but do not decrypt relay
payloads, so they are not a native relay-crypto implementation.

## P1 pricing operations

| Operation | Current owners | Contract/deletion boundary |
|---|---|---|
| Catalog rate lookup and token-cost arithmetic | Swift `OpenBurnBarCatalog`/`ModelPricing`; Functions pricing and rollups | Define integer token/rate inputs and nano-USD rounding/overflow fixtures before Rust implementation |
| Historical provider-era pricing | Functions Kimi rollups and current catalog | Keep era selection explicit; historical recomputation must not silently use current catalog rates |
| Runtime consumers | Swift native and Functions TypeScript | Swift links native core; Functions loads reviewed WASM; remove Double/TS arithmetic only after both fixture suites pass |

## Completion rule

A row leaves this ledger only after its Rust implementation is authoritative in
every real consumer, packaged artifacts load on supported architectures, rollout
evidence satisfies the roadmap, and source/compile gates prove the named legacy
targets are absent. Adding an export or a shadow adapter alone is not completion.
