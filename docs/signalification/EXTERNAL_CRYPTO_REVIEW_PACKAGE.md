# OpenBurnBar Signalification - External Crypto Review Package

Date: 2026-06-05
Status: package prepared, external review not yet performed
Scope: Signal envelope v1, CloudVault at-rest envelopes, Hermes transport envelope readiness, binding-to-AAD parity, and activation gates

This package is for an external reviewer to attack the Signalification work before any production activation. It is not a sign-off. It is the review index and evidence map.

## Review Objective

Determine whether OpenBurnBar's Signal-inspired envelope work is safe to activate, with special attention to:

- path-bound AAD and relocation resistance
- cross-language AAD byte parity
- native Swift and Android libsignal open/seal behavior
- transport-mode identity binding and replay resistance
- key-bound trust display and enforcement
- residual metadata/search leaks that the crypto does not hide
- rollback and activation gates

## Primary Documents

| Artifact | Purpose |
| --- | --- |
| `docs/signalification/SIGNAL_ENVELOPE_V1.md` | Envelope schema, AAD grammar, at-rest and transport mode specification |
| `docs/signalification/DOMAIN_SIGNALIFICATION_MAP.md` | Domain-by-domain migration map and residual privacy boundaries |
| `docs/signalification/00_ORCHESTRATION.md` | Over-claim guard, sequencing, and activation discipline |
| `docs/signalification/COMPUTER_USE_AGENT_HANDOFF.md` | Productionization plan, phases A-F, device E2E and activation gates |
| `docs/signalification/SKEPTICAL_ADVERSARIAL_REVIEW_HANDOFF.md` | Hostile review handoff and confirmed findings |
| `.agent/runs/sotasignal-full-ship-20260605/evidence/adversarial-3waves.json` | 3-wave adversarial review output |

## Code Surfaces To Review

| Surface | Files |
| --- | --- |
| Canonical TS contract | `packages/signal-envelope-contracts/src/index.ts` |
| Node libsignal proof facade | `packages/libsignal-protocol/src/index.ts` |
| Swift AAD canonicalizer | `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/SignalEnvelopeAAD.swift` |
| Swift at-rest sealer/opener | `OpenBurnBarCore/Sources/OpenBurnBarSignalCore/SignalAtRestSealer.swift` |
| Android AAD/libsignal helpers | `android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCryptoSupport.kt` |
| Android at-rest sealer/opener | `android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt` |
| Mobile at-rest producer/consumer helper | `OpenBurnBarMobile/Services/MobileCloudVaultSignalPayloads.swift` |
| Firestore direct-write rules | `firestore.rules` |
| Admin SDK validator | `functions/src/signalAtRestWrite.ts` |
| Data export sanitizer | `functions/src/callables/dataExport.ts`, `packages/signal-envelope-contracts/src/index.ts` |
| Activation defaults | `functions/src/hermesGateway.ts`, `functions/src/callables/computerUseSecurity.ts`, `packages/data-domains/registry.json` |

## Required Review Commands

Run from the repository root unless noted.

```bash
# Signal proof harness wired into fast-feedback
ruby -e 'require "yaml"; YAML.load_file(ARGV[0]); puts "yaml ok"' .github/workflows/fast-feedback.yml
npm test --prefix packages/libsignal-bridge
node scripts/ci/crypto-proof-harness.mjs

# Contract and Node libsignal
( cd packages/signal-envelope-contracts && npm test )
( cd packages/libsignal-protocol && npm test )

# Server and rules
( cd functions && npx tsc --noEmit )
( cd functions && npm run test:firestore-rules )
( cd functions && npx vitest run src/__tests__/signalAtRestWrite.test.ts )

# Swift native crypto
swift test --package-path OpenBurnBarCore --filter SignalEnvelopeAADTests
swift test --package-path OpenBurnBarCore --filter SignalAtRestSealerTests

# Android native crypto
( cd android && ANDROID_HOME=$HOME/Library/Android/sdk ./gradlew :app:testDebugUnitTest --tests com.openburnbar.data.cloud.CloudVaultCryptoTest --no-daemon )
( cd android && ANDROID_HOME=$HOME/Library/Android/sdk ./gradlew :app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.openburnbar.data.cloud.CloudVaultCryptoSignalInstrumentedTest --no-daemon )

# Drift and honesty gates
bash scripts/ci/verify-signal-activation-parity.sh
bash scripts/ci/verify-signal-honesty-copy.sh
bash scripts/ci/verify-signal-rule0.sh
RUN_TESTS=false bash scripts/ops/signal-rollback-drill.sh
```

## Known Current Status

Proven in the current dirty tree:

- `bindingToAAD` byte parity fixture is pinned and the Swift fixture copy is byte-identical.
- Swift AAD reserved-character validation uses unicode scalar checks, not grapheme-cluster checks.
- Swift and Android high-level at-rest openers require caller-derived `expectedBinding` and derive AEAD AAD from `expectedBinding`, not from `envelope.binding`.
- Firestore rules accept optional `signalEnvelope` only on explicitly wired owner-direct collections and bind it to the document path.
- Admin validator deep-validates wraps and path-binding, but is not yet wired into a production writer.
- Fast-feedback now runs the Signal crypto proof harness in addition to the legacy libsignal bridge package proof.
- Apple FFI packaging rebuild, iOS Simulator build, macOS app build, physical iPhone test suite, Android debug build/install, Signal Maven source probe, and Android physical Signal instrumented KAT all pass. Evidence: `.agent/runs/sotasignal-full-ship-20260605/evidence/device-packaging/physical-device-packaging-status.md`.
- Activation remains flag-off.

Not proven or not complete:

- No external cryptographer has reviewed or signed this off.
- No legal/AGPL/MAS sign-off has been recorded for vendored libsignal.
- Live production-domain physical-device E2E is not complete because producers remain flag-off and the paired iPad was unavailable during the local proof run.
- Production domain writers are not all switched to real Signal ciphertext.
- Transport v4 production identity binding and full client producer paths still need final review before activation.
- Live rollback drill has not been run against production Remote Config/deploy machinery.

## Threat Model Boundary

Do not describe the system as zero-knowledge or as hiding all metadata.

Protected when the Signal envelope path is active and validated:

- sealed payload contents
- recipient-bound content-key wraps
- path-bound at-rest relocation resistance
- tamper failure for payload ciphertext and wrapped keys

Still visible or potentially inferable:

- routing metadata
- timing and access patterns
- deterministic search/index recurrence and co-occurrence
- cloaked vector graph structure
- at-rest mode does not provide forward secrecy for already-wrapped historical payloads

## Reviewer Attack Checklist

1. Try to relocate an at-rest envelope across uid, collection, docId, field, scope, and mode in TS, rules, Swift, and Android.
2. Try AAD injection with `|`, CR, LF, decomposed Unicode, and pipe-plus-combining-mark inputs.
3. Try transport-vs-at-rest mode confusion, including `relayKeyVersion` on at-rest and missing version on transport.
4. Try polluted envelopes with extra plaintext keys and verify export redaction fails closed.
5. Try malformed or off-curve public keys in escrow/device trust flows.
6. Try to activate v4 by changing only one lever and verify activation-parity catches it.
7. Try to introduce a user-facing over-claim and verify the honesty gate catches it.
8. Try to bypass Rule-0 with vendored libsignal, `.gitmodules`, generated trust copy, legal files, or license metadata.

## Sign-off Requirements Before Production Activation

Production activation may proceed only after all of the following are true:

1. External crypto reviewer signs off or all blocking findings are fixed and re-reviewed.
2. Legal/AGPL/MAS owner signs off on vendoring and distribution obligations.
3. Physical iPhone, iPad, Android, and Mac E2E evidence is captured.
4. Production writer paths use real Signal ciphertext and preserve legacy fallback.
5. Admin validator is called at every Admin SDK Signal-envelope write site.
6. Activation flags are flipped only in the documented Phase E order.
7. A live timed rollback drill proves the system can disable new v4 writes without deleting existing ciphertext.
