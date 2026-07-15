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
| Remote MCP TypeScript | No | Pensieve content/slug/provenance opaque hashes | No | No | No |
| Local MCP Python | No | Rust plus named Python rollback during rollout | No | No | Rust plus named Python rollback during rollout |
| Hermes plugin Python | No | No | Rust plus named Python rollback for the ratchet prekey transcript/HKDF; relay crypto otherwise delegates to Hermes `gateway.crypto` | No | No |
| Tauri/Linux UI | Displays daemon-produced values | No separate implementation | No separate implementation | No separate implementation | No separate implementation |

Provider log parsers remain in `OpenBurnBarCore`. macOS, iOS, and the Linux
daemon use that single production Swift engine. Windows contains a deferred
`CAbiEngineProvider` and a macOS-authoring-host `swift run` parity helper, but
the Windows application does not yet ship a production parser engine. Android,
Cloud Functions, and the Tauri/Linux UI do not read local provider logs.
Provider parsers are therefore not duplicated and are not a shared-Rust
consolidation target; finishing the Windows consumer is a parity task, not a
five-language parser migration.

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
| Opaque project-memory, Pensieve, provenance, and subscription identifiers | Swift, Kotlin subscription, C# Pensieve, remote MCP TypeScript, and local MCP Python subsets | Rust owns only closed, purpose-specific HKDF/HMAC operations. The local Python consumer is wired behind `legacy|shadow|rust` with candidate-proof coverage; legacy deletion remains gated. |

### Required local MCP Python consumer

`tools/openburnbar-mcp/server.py` is a real CloudVault consumer, not a waiver or
an excluded platform. Its executable transforms now route through
`tools/openburnbar-mcp/domain_core_cloudvault.py`; the named rollback code lives
only in `cloudvault_legacy.py`. The production adapter covers the operations it
actually executes:

- project-memory opaque document IDs at `_cloud_vault_project_memory_doc_id`;
- CloudVault AAD v2 serialization and validation at
  `_cloud_vault_aad_context` / `_validate_cloud_vault_aad`;
- fixed-purpose keyed hashes for blob integrity, session body, and
  project-memory content at `_cloud_vault_hmac_hex`;
- encrypted-search token analysis/hashes and semantic analysis/hashes at
  `_cloud_token_hashes` / `_cloud_semantic_hashes`; and
- AES-GCM sealed-text and blob open/seal framing at
  `_open_cloud_sealed_text`, `_open_cloud_blob_envelope`, and
  `_seal_cloud_blob_envelope`.

The adapter uses the same `legacy|shadow|rust` authority semantics, verifies the
complete version/ABI/source/host/package identity, fails closed in Rust mode,
retains named legacy functions until the deletion gate, and runs canonical
CloudVault fixtures through the production package. Its exact source/deletion
ledger is `contracts/domain-core-python-consumer-manifest.json`.

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
| Local MCP Python | ABI 3 CloudVault/opaque/search exports in the converged core | Generated Python binding and host-native receipt, production `legacy\|shadow\|rust` adapter, canonical contracts, and candidate-proof job are wired; promotion and legacy deletion remain open |

“Merged” in this table means merged into the named feature branch, not `main`.
No CloudVault slice has completed security review, production promotion, stable
release observation, and legacy deletion.

## C2 Hermes operations

| Slice | Real owners | Contract/deletion boundary |
|---|---|---|
| Request/response/control/media AAD | Rust plus Swift/Kotlin during rollout | `tests/fixtures/domain-core/hermes/v1`; delete serializers after crypto promotion evidence |
| AES payload seal/open and v1/v2 key-wrap KDF/info | Rust plus Swift/Kotlin during rollout | Rust owns framing/KDF; CryptoKit/JCA retain P-256 ECDH and secure nonce generation |
| Authenticated HPKE v3 info | Rust plus Swift/Kotlin during rollout | Pinned sender authentication and platform private-key custody remain unchanged; no auth fallback |
| Ratchet KDF, envelope AAD, and payload AEAD | Rust plus Swift/Kotlin/Hermes Python during rollout | Platform code retains atomic state transitions, skipped-key maps, replay policy, P-256 ratchets, and persistence |

Functions validate schemas and proof-of-possession but do not decrypt relay
payloads, so they are not a native relay-crypto implementation. Hermes
[#1609](https://github.com/Imagine-That-Ai/BurnBar/pull/1609) is merged into a
feature branch, not `main`; rollout and deletion gates remain open.

### Hermes Python adapter audit

`tools/hermes-platform-burnbar/adapter.py` is not the local MCP and cannot be
silently covered by the MCP package. AES payload seal/open, v2/v3 content-key
wrap, and relay AAD namespace encoding delegate to the separately deployed
Hermes `gateway.crypto.relay_e2ee` module. P-256 private-key loading, ECDH,
Keychain custody, signatures, randomness, ratchet state transitions, replay
policy, and persistence are platform-owned.

The portable `_ratchet_prekey_shared_secret` transcript/HKDF transform is now
one composite Rust call. The plugin ships its own candidate-bound generated
binding, host-native library, source fingerprint, and digest receipt; it does
not borrow the local MCP artifact or evidence. Production selects
`legacy|shadow|rust`, Rust authority fails closed, and shadow emits only safe
operation/category/version diagnostics. The exact rollback deletion targets
are `tools/hermes-platform-burnbar/legacy/hermes_ratchet_legacy.py` and the
legacy branch in `domain_core_hermes.py`; they remain until the protected C2
promotion and stable-release rollback gates authorize the separate deletion.

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
| Python binding/host native library | `artifact-provenance/python.sha256` plus separate local-MCP and Hermes-plugin package receipts, host tuples, binding/native SHA-256 checks, and candidate-bundle native-load proofs |
| Browser and Node Wasm | `openburnbar-domain-core-source.sha256` inside each vendored package plus exact tree comparison |

`scripts/ci/domain-core-union-gate.py` validates all eight converged domains,
their required ABI symbols, the reviewed source fingerprint, and selected
artifact provenance. Regenerate every surface from the same source tree after
one atomic `--update-source-fingerprint`; never merge independently generated
artifact diamonds.

## Completion rule

A row leaves this ledger only after:

1. No operation is marked `REQUIRED_CONSUMER_PENDING`; Rust is authoritative in every real consumer and Rust mode fails closed.
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
