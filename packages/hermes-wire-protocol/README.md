# Hermes/iroh wire protocol — single source of truth

This package is the **canonical definition** of the Hermes/iroh realtime wire
protocol: the frame-type set and the on-the-wire constants (ALPN, frame-size
cap, length-prefix framing, protocol version, capabilities, role headers).

Before this package, the protocol was hand-mirrored across **four languages**
with no shared source, and had already drifted. Now it is defined **once** in
[`protocol.json`](./protocol.json) and enforced across every language by CI.

## Why this exists

The frame protocol is the single most load-bearing cross-platform contract in
the product: iOS, Android, and macOS all encode/decode it, and a silent
interop break (a renamed wire string, a changed ALPN, a different frame cap)
ships green to all three apps and breaks core connectivity with no signal.

## The model

```
                         protocol.json   ← edit HERE
                              │
            ┌─────────────────┼───────────────────────────┐
            │ node codegen.mjs (generated, drift-gated)    │ node parity.mjs
            ▼                                              ▼ (hand-written, parity-gated)
  services/.../generated/wireProtocol.ts   OpenBurnBarCore  HermesRealtimeRelayTypes.swift
      (CONSUMED by the relay's protocol.ts)  android        HermesRealtimeRelayFrame.kt
  gen/HermesWireProtocol.swift (reference)   relay          protocol.ts (FRAME_TYPES)
  gen/HermesWireProtocol.kt    (reference)   crates         openburnbar-iroh constants
  gen/wire_protocol.rs         (reference)   OpenBurnBarCore IrohRelayProtocol.swift
                                             android        IrohRelayProtocol.kt
```

- **TypeScript is generated and consumed.** The Cloud Run relay's `protocol.ts`
  imports `RELAY_ACCEPTED_FRAME_TYPES` + constants from the generated module, so
  the relay set can never silently fall behind the apps.
- **Swift / Kotlin / Rust stay hand-written** (they carry rich inline protocol
  docs) and are **locked to canon by the parity gate** — `parity.mjs` parses the
  real source and fails CI on any drift. `gen/` holds a generated reference of
  each, and the path to fully generate-and-consume them later is open.

## The 9-vs-41 split is intentional

All **41** frame types are peer-to-peer over **iroh** (Swift + Kotlin enums
carry the full set). Only the **9** `relayAccepted` frames — the chat
request/response multiplexing frames — are validated and routed by the legacy
Cloud Run WebSocket relay; the other 32 (media, control, signal, remote-unlock,
system-permission) never reach the relay. `protocol.json` records `relayAccepted`
per frame, so the relay's accepted set is **derived**, not hand-maintained.

## Adding or changing a frame type

1. Edit [`protocol.json`](./protocol.json) (add a frame, change a wire string,
   flip `relayAccepted`, …).
2. `node codegen.mjs` — regenerates the consumed TS + the reference files.
3. Update the hand-written Swift / Kotlin enums (and the iroh constants if you
   changed one) to match — `node parity.mjs` tells you exactly what's out of sync.
4. `node --test` — runs the drift gate + parity gate + validation.

CI runs the same checks in `fast-feedback.yml`'s `schema-drift` gate, so drift
in any language fails the PR.

## Commands

| Command | What it does |
|---|---|
| `npm run codegen` | Regenerate all outputs from `protocol.json`. |
| `npm run parity` | Verify every hand-written language surface matches canon. |
| `npm test` | Drift gate + parity gate + validation + parser tests. |

## Payload message types — generated-and-consumed (the second source of truth)

`protocol.json` owns the frame/transport layer. The **rich relay payload types**
(~60 Codable structs/enums — control, remote-unlock, system-permission, media,
mirror, streaming, envelope) used to be hand-mirrored across Swift / Kotlin / Rust
and were only *parity-checked* for drift. They are now defined ONCE in
[`relay-message-types.json`](./relay-message-types.json) and **generated and
consumed**: `OpenBurnBarCore` compiles the emitted Swift directly (the 2590-line
hand-written `HermesRealtimeRelayTypes.swift` was retired). Drift is now
structurally impossible for these types, not merely detected.

Three wire concerns are first-class in the schema, each **per-field** (never a
global default — a global date setting would silently flip ~10 synthesized structs
between a JSON number and an ISO string):

- **date regimes** — `iso` (ISO-8601 ms via `HermesRealtimeRelayDateCodec`),
  `numeric` (Swift-synthesized JSON number), `numericEncodeIsoDecode` (tolerate an
  ISO string on decode, re-emit a number).
- **multi-key aliases** — one field, several wire keys (e.g. the legacy Android
  `displayName` ⇄ `deviceDisplayName`), with a decode fallback literal.
- **forward-compat defaults** — `decodeDefault` (decode-only `?? …`) distinct from
  the memberwise-init default, and `containsGuard` optional dates.

Three-tier model: most types are **generated** (data + Codable); the
parity-gated **frame/protocol layer** stays hand-written in
`HermesRealtimeRelayFrameType.swift`; irreducible **behavior** (computed members,
factories, the shared `DateCodec`) is hand-written in
`HermesRealtimeRelayTypes+Behavior.swift`. **Rust is intentionally absent** — the
iroh transport carries frames as opaque bytes and has no payload types.

Edit `relay-message-types.json`, run `node codegen.mjs`, and the Swift files under
`OpenBurnBarCore/.../SharedModels/Generated/` regenerate; the drift gate
(`node --test`) fails CI if they are stale. The migration provenance (the
extractor + round-trip prover that derived the schema byte-faithfully from the
original) lives in `migrate/`.

> **Kotlin / Android:** the schema is language-agnostic and the Kotlin emitter is
> a designed next step (kotlinx.serialization with the three date regimes + alias
> support). It needs an Android/Gradle environment to verify the byte-identical
> round-trip against the Android iroh-relay module, so it is intentionally not
> landed here — the schema makes it "add an emitter," not "re-derive the types."

## Files

- `protocol.json` — the canonical spec (frames + constants + per-frame docs).
- `relay-message-types.json` — the canonical spec for the rich payload message types.
- `codegen.mjs` — emitters (TS, Swift, Kotlin, Rust frames) + Swift payload types + validation.
- `relay-types.mjs` — payload-type schema loader, validator, and Swift emitter.
- `parity.mjs` — parsers + `checkParity` over the hand-written frame surfaces.
- `protocol.test.mjs` — drift + parity + validation + payload-schema-integrity tests.
- `migrate/` — one-time migration provenance (Swift→schema extractor + round-trip prover).
- `gen/` — generated reference outputs for the frame layer (DO NOT EDIT).
