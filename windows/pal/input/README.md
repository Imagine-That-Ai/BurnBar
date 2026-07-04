# `windows/pal/input/` — ViGEm virtual-HID input path (portable core, W5 / R17)

The **platform-independent** half of the computer-use input path — the non-bypassable-action
route from the master plan **§9.5 / R17**. Plain `net8.0`, zero P/Invoke, zero OS calls: it
compiles and is fully unit-tested on the macOS authoring host (`windows/tests/input`), then
the Windows adapter ([`../input-windows/`](../input-windows/)) plugs the ViGEmBus + SendInput
sinks in behind `IVirtualHidInputSink`.

## Why a virtual-HID route at all (R17)

On macOS every synthesized action goes through `CGEvent`, gated uniformly by the OS. On
Windows, **`SendInput` is bypassable** by any same-integrity process, so a capability-token
gate in front of `SendInput` is only **advisory**. Actions that *commit* input into the system
must therefore route through the **ViGEmBus virtual-HID device**, where the gate is enforced
**structurally**: the sink is unreachable except through the gate.

## What lives here

| Piece | File | Role |
|-------|------|------|
| Advisory-vs-non-bypassable **classification** | `InputAction.cs` | maps each action kind → route (`Advisory` = SendInput, `NonBypassable` = ViGEm) + the canonical macOS audit-kind string |
| **Capability token** model + canonical bytes | `CapabilityToken.cs`, `CapabilityTokenCanonicalizer.cs` | ported 1:1 from `OpenBurnBarComputerUseCore`; canonical signable bytes are **byte-parity** with the macOS signer |
| Ed25519 **signature** seam + impl | `CapabilityTokenSignature.cs` | pure-managed Ed25519 (BouncyCastle) — the same primitive as macOS CryptoKit `Curve25519.Signing` over the same bytes |
| Single-use **nonce** ledger | `CapabilityTokenNonceStore.cs` | replay rejection, keyed by domain+nonce |
| Token **verifier** state machine | `CapabilityTokenVerifier.cs` | present → domain → TTL → signature → issuer-trust → scope/attestation/escrow binding → action∈allowed → budget → nonce-unseen → consume |
| Triple **kill switch** | `InputKillSwitch.cs` | RC halt / signed local channel / watchdog heartbeat, **fail-closed-on-RC-error** (R17) |
| **Gate-before-dispatch** decision | `VirtualHidInputGate.cs` | the heart: kill-switch → classify → non-bypassable requires a valid token (token-absent = reject) → advisory logs |
| **Audit** record + sink | `InputAudit.cs` | every decision is logged; record is Ed25519-audit-chain-ready |
| **Sink** seam | `VirtualHidInputSink.cs` | the platform edge the two Windows sinks implement |
| **Dispatcher** | `VirtualHidInputDispatcher.cs` | gate → audit-BEFORE-dispatch (fail-closed audit) → route to the sink; the only path to the device |

## Security invariants (preserved verbatim, master plan §9.5 / R17)

- **Non-bypassable actions require a valid capability token** before any report reaches the
  virtual-HID sink; a token-absent non-bypassable request **fails closed** (rejected, never a
  silent SendInput fallback).
- **Capability-token verification**: Ed25519 signature + TTL + single-use nonce + action ∈
  allowed + budget + scope/attestation/escrow binding, harshest-failure-wins.
- **Triple kill switch** with **fail-closed-on-RC-error**; a throwing kill-switch source is
  treated as engaged.
- **Audit before dispatch**: a durable audit record is appended before the action executes; a
  failing audit sink blocks dispatch (fail-closed audit).

Source files here are ratcheted by the per-tree budget under the `pal` area.
