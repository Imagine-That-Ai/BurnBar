# Complete Signal migration Streams 3-8 + adversarial audits

Goal ID: `signalification-phases-3to8-20260604`
Started: 2026-06-05T03:31:55Z
Parent goal: none
Mode: full
Ledger path: `.agent/runs/signalification-phases-3to8-20260604/`

## Objective

Implement remaining Signal-Protocol migration phases (bindingToAAD prereq, Stream 6 enablement, Streams 3/4/5/8) flag-OFF/additive with tests + cross-language parity, then run intense adversarial audits

## Goal Mode Coupling

When creating or updating the matching `/goal`, include this ledger pointer in the goal objective:

`Maintain the agent-owned ledger at /Users/albertonunez/Documents/Windsurf/BurnBar/.agent/runs/signalification-phases-3to8-20260604/ and keep implementation-notes.html current at checkpoints, before compaction, and before final handoff.`

## Context

Wave-1 (Streams 1/6-UX/7) + envelope contracts + AGPL relicense already LANDED on `main` @ `6fa0c9ab9`. This goal does the remaining migration phases, all **flag-OFF / additive** (no production behavior change), with tests + cross-language parity, then intense adversarial audits. Authoritative plan: `docs/signalification/`.

## Finishing Criteria

- [todo] **P0 — bindingToAAD canonicalizer**: single `bindingToAAD()` in `packages/signal-envelope-contracts` (legacy pipe grammar per SIGNAL_ENVELOPE_V1 §5.4) + consumed by `libsignal-protocol`; Swift/Kotlin equivalents; cross-language byte-parity test. Validation: contracts+libsignal-protocol tests green.
- [todo] **Stream 6 enablement**: safety code bound to the key actually used (not server-stored string) + server-side fingerprint enforcement in `approveEscrowDeviceTrust`; flag still default OFF; tests.
- [todo] **Stream 3 — gateway text/control**: accept v4 `signalEnvelope` (transport) shape + `requireGatewaySignalEnvelope` validator + capability default OFF (not in PRODUCTION versions); real ciphertext path via libsignal-protocol; functions tsc + vitest green.
- [todo] **Stream 4 — attachments**: optional `signalEnvelope` on attachment manifest/body via Signal-session keys; old HPKE rows still open; shape-only validator; tests.
- [todo] **Stream 5 — CloudVault domains**: `CloudVaultSignalEnvelope` type + registry additive `sealingScheme` (pensieve first, non-websited, zero-diff codegen) + recognizers consume the contract; data-domains + functions tests + drift green.
- [todo] **Stream 8 — proof harness**: `SignalEnvelopeV1Vector.json` KAT + TS/Swift opener parity + `scripts/ci/crypto-proof-harness.mjs` skeleton; harness green.
- [todo] **Full validation**: functions tsc + full vitest, contracts + libsignal-protocol tests, data-domains tests, schema drift, OpenBurnBarCore swift build/tests where feasible. No production behavior change (flags OFF) verified.
- [todo] **Intense adversarial audits**: multi-agent adversarial review of all new crypto — fail-closed, downgrade/version, replay, AAD/binding cross-language byte-parity, no E2EE weakening, no "Signal-quality" over-claim. Findings triaged + fixed or logged with evidence.
- [todo] **Real Swift libsignal integration**: vendor `LibSignalClient` (libsignal v0.94.4, local `swift/` path; build_ffi via cargo+protoc — confirmed buildable in-agent) + Swift sealer (`PublicKey.seal`/session) + round-trip tests + **on-device iPhone E2E** (attached device `00008150-00180C661EF0401C`).
- [todo] **Real Kotlin/Android libsignal integration**: `org.signal:libsignal-client` + Kotlin sealer + JVM round-trip + **on-device Android E2E** (attached device `R3CXB0CNS0J`; SDK being installed).
- [todo] **Cross-language KAT** `SignalEnvelopeV1Vector.json` opened byte-identically by Node + Swift + Kotlin.
- [todo] **Wire real ciphertext** through client paths (Swift FunctionsRepository, Android repo, Mac); activation proven on real devices (full-SOTA, no stubs/workarounds). External crypto-review remains a human sign-off.
- [todo] Keep `implementation-notes.html` current (Resume Here + progressEvents) at every phase checkpoint; link bulky proof under `evidence/`.

## Escape Hatch

Pause, ask the user, or mark a scoped item `[blocked]` / `[incomplete]` if:
- validation contradicts the goal
- the goal requires a scope change
- the agent is looping without measurable progress
- the next step risks deleting or rewriting durable memory
- the PRD and actual repo disagree
- the ledger itself contaminates validation

