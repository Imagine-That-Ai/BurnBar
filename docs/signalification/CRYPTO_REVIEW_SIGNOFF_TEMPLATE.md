# SOTASIGNAL External Crypto Review Sign-Off Template

**Purpose:** record an independent cryptographic/security review before Phase-E activation. This is not for the implementation agent to self-sign.

## Reviewer

- Name:
- Organization / affiliation:
- Contact:
- Date:
- Review artifact path in `~/Desktop/Signal Audit/`:
- Reviewed commit SHA:

## Scope Reviewed

Check every item actually reviewed:

- [ ] `docs/signalification/SIGNAL_ENVELOPE_V1.md`
- [ ] `packages/signal-envelope-contracts/src/index.ts`
- [ ] `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/SignalEnvelopeAAD.swift`
- [ ] `OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalAtRestSealer.swift`
- [ ] `android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCryptoSupport.kt`
- [ ] `android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt`
- [ ] `functions/src/signalAtRestWrite.ts`
- [ ] `firestore.rules`
- [ ] `scripts/ci/crypto-proof-harness.mjs`
- [ ] activation / rollback scripts and docs

## Required Attack Results

- [ ] Relocation across `uid`, `collection`, `docId`, `field`, `scope`, and `mode` fails closed in TS/rules/Swift/Android.
- [ ] AAD byte grammar is unambiguous, NFC-normalized, and rejects `|`, CR, LF, and combining-mark injection.
- [ ] At-rest HPKE identity-key use is acceptable for the stated no-forward-secrecy boundary.
- [ ] Transport v4 downgrade/replay/mode-confusion risks are either closed or listed as blockers.
- [ ] Export redaction fails closed for malformed signal-shaped values.
- [ ] Trust display/key-binding limitations are understood.
- [ ] Metadata/search/vector residual leaks are accurately described in user-facing copy and threat docs.
- [ ] Rollback and activation gates fail closed.

## Findings

| Severity | Finding | File:line | Required fix | Status |
| --- | --- | --- | --- | --- |
| blocker/major/minor/nit |  |  |  | open/fixed/accepted |

## Sign-Off Decision

Choose exactly one:

- [ ] **Approved for Phase-E canary**: no open blocker/major findings remain.
- [ ] **Approved with owner-accepted risk**: open findings listed above are accepted by Alberto for canary only.
- [ ] **Not approved**: Phase-E activation must not proceed.

Reviewer signature / typed approval:

Owner risk acceptance, if any:
