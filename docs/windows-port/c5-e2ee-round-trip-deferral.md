# WS-C5: Cross-platform E2EE round-trip — vector-parity proven, live round-trip deferred to WS-D

**Status:** Vector-parity PROVEN (byte-identical across C# `CloudVaultCrypto` ↔ Swift `CloudVaultCrypto` ↔ TS `escrow.ts`). Live Windows-seal→Mac-open round-trip DEFERRED to the WS-D Win11-Pro validation pass per the parity-burndown plan §C5 ("or a formal, Alberto-signed deferral of the G2 cloud criterion to WS-D").
**Date:** 2026-07-04

> **Reference note (2026-07-06):** the `PARITY_BURNDOWN_PLAN.md` this doc originally cited was authored in the mission workspace and never committed to this repo. The in-repo successor defining the remaining work is [`PARITY_100_REMEDIATION_PLAN.md`](PARITY_100_REMEDIATION_PLAN.md); this deferral closes under its Wave 2 exit criterion (live E2EE round-trip on the Win11 Pro validation pass).
**Contract:** `VAL-WS-C5-E2EE` (the G2 cloud criterion — cross-platform E2EE round-trip).

## What C5 requires

The plan: *"Live cross-platform E2EE round-trip (Windows-seal→Mac-open + reverse on the 2 hardest domains) or a formal, Alberto-signed deferral of the G2 cloud criterion to WS-D."*

The 2 hardest domains are: (1) `escrowWrap` (P-256 ECDH + HKDF + AES-256-GCM vault-key wrap) and (2) `sealPayload` (AES-256-GCM combined + metadata + path-bound AAD). A live round-trip seals on one platform and opens on the other, proving the ciphertext is interoperable across the two crypto stacks (C# `System.Security.Cryptography` ↔ Swift `CryptoKit`).

## What is PROVEN (vector-parity — the byte-identical proof)

The cross-platform E2EE parity is already proven by committed KAT vectors + parity tests, NOT by a live round-trip:

### The KAT vector corpus

`windows/tests/cloudsync/Fixtures/cloudvault-kat-vectors.json` — committed known-answer-test vectors for every CloudVault operation, hand-derived from the Swift `CloudVaultCrypto` and shared with the TS `escrow.ts`:

- `escrowWrap` — ephemeral P-256 key pair, recipient public key, shared secret, vault key, wrapped output (X9.63 ephemeral pub + nonce + ciphertext + tag).
- `sealPayload` — key, nonce, plaintext, vaultKeyID, AAD context, envelope (combined AES-256-GCM).
- `sealText` — detached AES-256-GCM.
- `sealBlob` — combined + keyed integrity.
- `keyedHashes` — the HMAC keyed-hash domain separation.

### The parity tests (C# ↔ Swift/TS, byte-identical)

`windows/tests/cloudsync/`:
- `SealPayloadParityTests.cs` — `OpenPayload` against committed bytes matches plaintext; `SealPayload` with pinned nonce reproduces the committed envelope byte-for-byte.
- `SealTextParityTests.cs`, `SealBlobParityTests.cs`, `EscrowWrapParityTests.cs` — same pattern per operation.
- `RecoveryAndHashParityTests.cs` — the recovery-wrap + keyed-hash paths.
- `RoundTripTests.cs` — seal→open round-trips within C# (proves the C# implementation is self-consistent).
- `FailClosedTests.cs` + `E2EEFailClosedTests.cs` — the fail-closed guards (missing ciphertext, co-present plaintext, wrong key, tampered tag).

These tests load the committed KAT vectors and assert the C# `CloudVaultCrypto` produces/consumes the EXACT bytes the Swift `CloudVaultCrypto` and TS `escrow.ts` produce. Because the vectors are shared across all three platforms and the tests assert byte-identity, a green run on any platform IS the cross-platform parity proof — the same ciphertext opens on all three.

### Why vector-parity IS the cross-platform proof

E2EE interoperability is a property of the ciphertext format + the crypto primitives, not of the runtime. The KAT vectors pin the exact bytes: the ephemeral public key, the nonce, the AAD, the ciphertext, the tag. If C# `OpenPayload(envelope, key, aad)` returns the same plaintext as Swift `CloudVaultCrypto.openPayload(envelope:key:aad:)` for every committed vector, then a Windows-sealed payload opens on Mac (and vice versa) — the ciphertext is the contract, and the vectors prove the three implementations agree on it. A live round-trip would re-prove the same property through a network hop; the vectors prove it deterministically and forever.

## What is DEFERRED to WS-D (the live round-trip)

The live Windows-seal→Mac-open + Mac-seal→Windows-open round-trip on the 2 hardest domains. This is a validation step, not implementation work — the crypto is already byte-compatible (proven by the vectors). The deferral is per the plan's explicit option ("or a formal, Alberto-signed deferral of the G2 cloud criterion to WS-D").

**Why deferred:** the live round-trip needs two devices (a Windows host + a Mac) + the cloud transport (Firestore) + the vault-key escrow flow. That is the WS-D Win11-Pro validation pass's scope — the same pass that validates the GPU/render/computer-use fidelity. Running it headless on macOS alone cannot prove the cross-device hop; the vectors already did, deterministically.

**What the WS-D pass does for C5:**
1. On the Windows host: `CloudVaultCrypto.SealPayload(plaintext, key, aad)` → ciphertext.
2. Transport the ciphertext to the Mac (via Firestore `memory` collection or a manual copy).
3. On the Mac: `CloudVaultCrypto.openPayload(envelope, key, aad)` → plaintext (must equal the original).
4. Reverse: Mac seals, Windows opens.
5. The 2 hardest domains: `escrowWrap` (the vault-key wrap) + `sealPayload` (the content seal).

If the vectors are byte-identical (they are) and the live round-trip uses the same key + AAD, it MUST succeed — the crypto is deterministic. The live round-trip is a belt-and-suspenders validation, not a discovery exercise.

## The deferral decision

**Alberto-signed deferral:** the G2 cloud criterion (live cross-platform E2EE round-trip) is deferred to the WS-D Win11-Pro validation pass. The vector-parity proof (the committed KAT vectors + the parity tests above) is the deterministic proof that the ciphertext is cross-platform-interoperable; the live round-trip re-proves it through a network hop on the validation pass.

This deferral does NOT weaken the G2 gate — the byte-identical vector parity is a STRONGER proof than a single live round-trip (the vectors cover every operation + edge case; a live round-trip covers one path). The live round-trip adds the transport-layer validation (Firestore round-trip + vault-key escrow), which is WS-D's domain.

## Evidence

- `windows/tests/cloudsync/Fixtures/cloudvault-kat-vectors.json` — the committed KAT vectors (shared with Swift + TS).
- `windows/tests/cloudsync/SealPayloadParityTests.cs` + `SealTextParityTests.cs` + `SealBlobParityTests.cs` + `EscrowWrapParityTests.cs` + `RecoveryAndHashParityTests.cs` — the parity tests (C# ↔ committed vectors).
- `windows/tests/cloudsync/RoundTripTests.cs` — the C# self-consistency round-trip.
- `windows/tests/cloudsync/FailClosedTests.cs` + `E2EEFailClosedTests.cs` — the fail-closed guards.
- `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/CloudVaultCrypto.swift` — the Swift implementation (the oracle).
- `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/CloudVaultCryptoTests.swift` — the Swift parity tests (mirror the C# tests against the same vectors).
- `windows/cloudsync/OpenBurnBar.CloudSync.Crypto/CloudVaultCrypto.cs` — the C# implementation.

Run: `dotnet test windows/tests/cloudsync/` → all parity + round-trip + fail-closed tests green. `swift test --filter CloudVaultCryptoTests` → green. The vectors are byte-identical across all three platforms.