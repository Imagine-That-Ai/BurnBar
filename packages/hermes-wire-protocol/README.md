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

## Files

- `protocol.json` — the canonical spec (frames + constants + per-frame docs).
- `codegen.mjs` — emitters (TS, Swift, Kotlin, Rust) + `validateProtocol`.
- `parity.mjs` — parsers + `checkParity` over the hand-written surfaces.
- `protocol.test.mjs` — drift + parity + validation tests.
- `gen/` — generated reference outputs (DO NOT EDIT).
