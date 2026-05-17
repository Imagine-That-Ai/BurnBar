# OpenBurnBar Computer Use — operator & engineer reference

**Status:** Phase 8 substrate landed · Phase 9–13 source-complete behind flags
**Master plan:** [`plans/2026-05-16-computer-use-master-plan.md`](../plans/2026-05-16-computer-use-master-plan.md)
**Substrate:** Layers on Mercury Media — see [`HERMES_MEDIA_TRANSPORT.md`](HERMES_MEDIA_TRANSPORT.md).

This document is the long-lived reference for what ships on the wire, what runs on each device, and how to operate the kill switches when something goes wrong. The master plan tells you why we built this; this document tells you what it does.

---

## 1. Surface map

| Path | Direction | Trust boundary | Phase |
|---|---|---|---|
| **A — Agent Watch** | Mac → iOS/Android | Read-only mirror + action overlay | 8 |
| **B — Browser CU** | Agent → Playwright Chromium | Sandboxed inside Chromium | 9 |
| **C — Mac System CU** | Agent → CGEvent + AX | Mac-wide, gated by Accessibility | 11 |
| **D — Phone control** | iOS/Android → Mac | Ed25519-signed intent envelopes | 12 |

Every path rides the existing iroh QUIC transport. No new ALPN. No WebRTC. No new encryption hop.

---

## 2. Wire types added

### 2.1 New `MediaStreamClass` constants

| Class | Direction | Discipline | Phase |
|---|---|---|---|
| `control.surface.frame` | Mac → phone | Reliable-ordered, per-GOP | 8 |
| `control.action.log` | Mac → phone | Reliable-ordered, JSON envelope | 8 |
| `control.input` | Phone → Mac | Reliable-ordered, JSON envelope | 12 |
| `control.approval` | Bidirectional | Reliable-ordered, JSON envelope | 12 |

`MediaStreamClass.Feature.computerUse` is the bucket all four roll up to for quota counters.

### 2.2 New `HermesRealtimeRelayFrameType` cases

```
control.classify              ← negotiation, first frame on a new bi-stream
control.action.log.entry      ← Mac → phone planned/executing/completed/failed
control.input.intent          ← Phone → Mac signed envelope
control.approval.request      ← Mac → phone approval ask
control.approval.response     ← Phone → Mac decision
control.denied                ← Mac → phone iroh accept-loop refusal
```

The carrier struct is `HermesRealtimeRelayControlPayload` — a sibling of the existing `HermesRealtimeRelayMediaPayload`. Encoders omit absent optionals so pre-Computer-Use traffic stays byte-identical.

### 2.3 `MediaFrame.Flags.hasCursorMetadata`

The cursor coords (i16 x, i16 y, both big-endian) live in 4 trailing bytes after the existing 18-byte header. Flag bit on the wire is **`0x08`** — `0x04` was already taken by `.muted`. Receivers that do not set the bit ignore the trailing 4 bytes, so the extension is backward-compatible.

The plan's draft labels this bit as `0x04`; it is `0x08` in code. Captured in the `DESIGN.md` Phase 8 decision-log entry too.

---

## 3. Trust modes

| Mode | Approval per action | Picker behavior |
|---|---|---|
| **Manual** | Yes, every action | Default. The reset target when Mac unlock / Remote Config kill fires. |
| **Step** | Burst (≤ 10 actions or 30 s) | "Approve next 10 actions like this" toggle on the approval sheet. |
| **Trusted** | Only when an action escapes an active scope rule. | Phone can downgrade to Step or Manual but cannot upgrade. |

Mode lives on `ComputerUseSessionDoc.trustMode`. Never sticky across sessions.

---

## 4. Scope rules

Rule shape (see `ComputerUseScopeRule`):

```
{
  effect: "allow" | "deny",
  origin: "built_in" | "user" | "imported",
  urlPrefix?:        string,     // case-insensitive prefix match
  bundleId?:         string,     // exact, or "com.apple.*" trailing wildcard
  windowTitleRegex?: string,     // unanchored, case-insensitive
  actionBudget?:     int,
  expiresAt?:        ISO8601
}
```

Rules are conjunctive (URL prefix AND bundle id AND window title regex). The rule set is evaluated as a disjunction with **deny precedence**: any matching deny rule beats any matching allow rule.

Built-in deny defaults live in `ComputerUseDenyRegistry.builtInRules`. Cannot be removed by the editor. The editor's "overlapsBuiltInDeny" check refuses a user-defined allow rule that would unmask a built-in deny.

---

## 5. Audit chain

| Layer | Lives at | Format |
|---|---|---|
| Session manifest | `~/Library/Application Support/com.openburnbar.AgentLens/computer-use-audit/{sessionId}/manifest.json` | Canonical JSON |
| Chain entries | `chain.jsonl` | One canonical-JSON entry per line, parent-hash linked |
| Head marker | `head.json` | `{index, hashHex, updatedAt, sessionId, schemaVersion}` |
| Screenshots | `screenshots/{entryIndex}_{before|after}.png` | PNG by content hash reference |

**Hash function:** SHA-256 (`ComputerUseAuditHasher.Algorithm.sha256`). The wire field names retain "Blake3" because the long-term intent is to swap to BLAKE3 once `iroh-blobs` exposes a Swift binding; the on-disk format is hash-agnostic — the validator re-hashes with whatever algorithm `ComputerUseAuditHasher.current` reports. The chain format never changes when the algorithm does.

### 5.1 Tamper detection

The walker `ComputerUseAuditChain.validate(at:sessionManifestHashHex:expectedHeadHashHex:)` returns `ValidationResult` with one of five failure reasons:

| Reason | When |
|---|---|
| `parent_hash_mismatch` | Some entry's `parentEntryHashHex` does not match the predecessor's re-hash |
| `unexpected_entry_index` | The `entryIndex` field jumps or repeats |
| `decode_failure` | A line is not valid JSON or fails Codable decode |
| `unsupported_schema` | `schemaVersion` field higher than `ComputerUseAuditEntry.schemaVersion` |
| `head_hash_mismatch` | Recomputed terminal head differs from `expectedHeadHashHex` (catches terminal-entry tamper) |

Always pass `expectedHeadHashHex` from `head.json` when invoking the validator — otherwise a tampered last entry passes the parent-chain walk.

---

## 6. Phone-control authority envelope

Phase 12. Wire shape (`PhoneControlAuthority`):

```
peerNodeId       (base32 iroh NodeId)
counter          (u64, monotonic per peer, persisted in UserDefaults)
timestamp        (ms-since-epoch, ± 5 s freshness window)
intentHashBlake3 (hex SHA-256 of canonical-JSON intent)
signatureEd25519 (base64 Ed25519 over UTF8(intentHash) ‖ u64BE(counter) ‖ i64BE(timestampMs))
```

The pure signer/verifier lives in `OpenBurnBarComputerUseCore.ComputerUsePhoneControlSigner` so both platforms (iOS issuer, Mac validator) share canonical signing semantics and the test target can prove sig + counter + freshness + intent-hash semantics from a single fixture.

### 6.1 Replay rejection contract

`counter` is strictly monotonic per peer. The Mac receiver persists `lastSeenCounter[peerNodeId]` and rejects any envelope whose counter is `<= lastSeen`. On pairing rotation the counter resets — same flow as the iroh-blobs ticket exchange.

---

## 7. Capabilities + budgets

`ComputerUseCapabilityGate` consults six knobs, in order:

1. `computer_use_kill_switch` from Remote Config (most severe)
2. `hosted_computer_use_sync` entitlement (Browser / System / PhoneControl flags)
3. Active Accessibility permission (Path C and D only)
4. Concurrent-session flag (max 1)
5. Hard cap → soft cap → daily caps → daily spend ceiling → per-session cap
6. Scope outcome (deny precedence)

Default envelopes:

| Level | Actions / run | Actions / day | Sessions / day | $ ceiling / user / day |
|---|---|---|---|---|
| `normal` | 50 | 200 | 4 | $5.00 |
| `soft_cap` | 25 | 100 | 2 | $2.50 |
| `hard_cap` | 0 | 0 | 0 | $0.00 |

Soft cap engages at projected month-end ≥ $1500; hard cap at ≥ $2500. Projector is `ComputerUseBudgetProjector.projectMonthEnd(monthToDateUSD:daysElapsed:daysInMonth:)`.

---

## 8. Kill switches (three independent paths)

| Source | Latency budget | Lives at |
|---|---|---|
| `⌃⌥⌘.` global hotkey | ≤ 100 ms hotkey → driver kill | `ComputerUsePanicHaltCoordinator.installHotkey` |
| Phone three-finger long-press | ≤ 200 ms phone tap → driver kill | `PhoneControlIntent.panic` |
| Mac auth gate (`loginwindow`, `SecurityAgent`, screen sleep) | ≤ 100 ms NSWorkspace notify → driver kill | `ComputerUsePanicHaltCoordinator.installAuthGateListeners` |
| Remote Config `computer_use_kill_switch=true` | ≤ 60 s cache TTL | `ComputerUsePanicHaltCoordinator.remoteConfigKillSwitchFired` |

All four converge on `ComputerUseRunCoordinator.panicHalt(sessionId:, source:)`.

---

## 9. Tool kinds

13 new `BurnBarToolKind` cases (see `BurnBarToolContracts.swift`):

| Kind | Path | Notes |
|---|---|---|
| `browser_click` | B | Selector or `(positionX, positionY)` fallback |
| `browser_fill` | B | Selector + text |
| `browser_goto` | B | URL with `domcontentloaded` wait |
| `browser_key` | B | Key combo (optional modifiers) |
| `browser_select` | B | Selector + option value |
| `browser_screenshot` | B | Returns base64 PNG |
| `browser_extract` | B | Selector text content or full page |
| `mac_input_click` | C | Display coords, button 0/1/2 |
| `mac_input_type` | C | Unicode-string typing |
| `mac_input_key` | C | Virtual-key dispatch |
| `mac_input_shortcut` | C | Modifier + key |
| `mac_input_drag_drop` | C | Start + end coords |
| `mac_inspect_accessibility` | C (read-only) | AX role/title/value at point |

Available via `BurnBarToolKind.computerUseToolKinds` for daemon dispatch routing.

---

## 10. Operations runbook quick-links

- Quota disputes → [`runbooks/computer-use-quota.md`](runbooks/computer-use-quota.md)
- Soft / hard cap engaged → [`runbooks/computer-use-budget.md`](runbooks/computer-use-budget.md)
- Phase rollout log → [`runbooks/computer-use-rollout-status.md`](runbooks/computer-use-rollout-status.md)
- App Store / direct-download distribution → [`runbooks/computer-use-app-store.md`](runbooks/computer-use-app-store.md)
- Audit chain dispute → [`runbooks/computer-use-audit-disputes.md`](runbooks/computer-use-audit-disputes.md)
- Device-matrix soak results → [`runbooks/computer-use-device-matrix/`](runbooks/computer-use-device-matrix/)

---

## 11. Glossary

- **Path A / B / C / D:** the four surfaces above.
- **Trust mode:** Manual / Step / Trusted.
- **Scope rule:** allow/deny predicate matched against URL + bundleId + windowTitle.
- **Deny region:** built-in or AX-derived UI region where actions are refused without a prompt.
- **Audit chain:** content-addressed JSONL whose entries form a parent-hash linked list.
- **Authority envelope:** Ed25519-signed `PhoneControlAuthority` carrying intent hash + counter + timestamp.
- **Panic halt:** instant cross-path session termination.
- **`hosted_computer_use_sync`:** the $14.99/mo entitlement that gates Browser + System + PhoneControl.
- **`computer_use_kill_switch`:** Remote Config flag that suspends all new sessions and ends existing ones within 60 s.
