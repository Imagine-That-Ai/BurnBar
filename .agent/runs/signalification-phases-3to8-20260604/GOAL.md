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

## Status at handoff (2026-06-05, landed on main @ 9cc095ff4)

**[done] — landed flag-OFF on `main`, adversarially audited (43 agents: SAFE, 0 land-blockers), all tests green:**
- P0 `bindingToAAD` cross-language canonicalizer (TS+Swift byte-parity fixture, NFC-normalized, pipe/CRLF fail-closed).
- Stream 6 enablement CODE: key-bound safety-code verifier + server-side `approveEscrowDeviceTrust` enforcement (shadow mode, flag OFF) + P-256 on-curve validation.
- Stream 3 gateway v4 `signalEnvelope` shape + validator + capability (PRODUCTION set empty = fail-closed).
- Stream 5 `CloudVaultSignalEnvelope` type + registry additive `sealingScheme` (non-websited) + dataExport recognizer.
- Stream 8 (crypto proof): **real libsignal 0.94.4 proven in Node + Swift + Kotlin**, and a **cross-language KAT** (Node-sealed HPKE opens byte-correct in Swift AND Kotlin via identical `bindingToAAD`; tamper fails closed). Evidence in `evidence/`.
- Intense adversarial audit + its cheap confirmed fixes applied.

**[incomplete] — feasibility PROVEN (crypto works on all 3 languages + interop KAT; toolchain ready: Xcode+sim+device, Android SDK+device, adb), NOT completed this session (large multi-step productionization, no stubs/workarounds taken):**
- Vendor libsignal into the iOS/Android/Mac APP build graphs (Swift Package local-path + `build_ffi`; Android `org.signal:libsignal-client` from Signal maven). Proven buildable in-agent in isolation; not yet wired into the app targets.
  - reason: forces cargo/native-lib builds into every app/CI build; large XcodeGen/Gradle integration; deliberate to keep flag-OFF landing clean.
- Wire real ciphertext through production client paths (Swift `FunctionsRepository`, Android repo, Mac) + Stream 6 UI key-bound display (audit MAJOR: verifier built+tested but unwired) + transport AAD binding (audit minor).
- On-device E2E on the attached iPhone (`00008150-…`) + Android (`R3CXB0CNS0J`): crypto proven on host/JVM with the same libsignal; on-device app runs not executed.
- Flag activation (add 4 to `HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS`; flip escrow + Stream 6 flags) — gated on the above + external crypto review.
- External crypto-review sign-off (human).

## Escape Hatch

Pause, ask the user, or mark a scoped item `[blocked]` / `[incomplete]` if:
- validation contradicts the goal
- the goal requires a scope change
- the agent is looping without measurable progress
- the next step risks deleting or rewriting durable memory
- the PRD and actual repo disagree
- the ledger itself contaminates validation

