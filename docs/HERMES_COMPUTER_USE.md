# OpenBurnBar Computer Use — operator & engineer reference

**Status:** Phase 8 substrate landed · Phase 9–13 source mostly landed behind flags · launch gates still open
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
control.clipboard.request     ← iOS/iPadOS/Android → Mac signed text clipboard request
control.clipboard.response    ← Mac → iOS/iPadOS/Android text clipboard result
control.approval.request      ← Mac → phone approval ask
control.approval.response     ← Phone → Mac decision
control.agent_grant.request   ← iOS/iPadOS/Android → Mac signed agent capability grant
control.agent_grant.receipt   ← Mac → iOS/iPadOS/Android grant/revoke acknowledgement
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
| Head marker | `head.json` | `{index, hashHex, updatedAt, sessionId, schemaVersion}` (live; updated per append) |
| Signed head (WS3) | `signed_head.json` | Ed25519 over `{sessionId, lastEntryIndex, headHashHex, closedAt}` — written at close/panic/export |
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

Pass `expectedHeadHashHex` from `head.json` or `signed_head.json` when invoking the validator — otherwise a tampered last entry passes the parent-chain walk.

**Offline verifier (WS3):** `openburnbar-cli audit-verify <session-directory> [--max-entry-index P] [--skip-opentimestamps]` runs `ComputerUseAuditVerifier` — chain walk, signed-head signature check, optional `ots verify`, and completeness given panic index **P**. See [`docs/runbooks/computer-use-audit-disputes.md`](runbooks/computer-use-audit-disputes.md).

### 5.2 Export format

`ComputerUseAuditExportWriter` exports Phase 13 audit bundles as a real `.tar.gz`:

- POSIX ustar entries for `manifest.json`, `chain.jsonl`, optional `head.json`, optional `signed_head.json`, and optional `screenshots/*.png`.
- `ComputerUseAuditExportRequest.anchorOpenTimestamps` mints `chain.jsonl.ots` before packaging when enabled.
- Gzip compression via zlib.
- Detached JSON signature sidecar at `{archive}.sig.json`.
- Signature algorithm today: `ed25519`, signed by an OpenBurnBar trusted-device export key stored in the local Keychain as `WhenUnlockedThisDeviceOnly`.
- Signature sidecars include `signerKind`, `trustRoot`, `publicKeyBase64`, and `publicKeySHA256Hex`; verification rejects a sidecar whose public-key hash no longer matches the included public key.
- After a Mac export succeeds, the Settings flow publishes the signer public key under
  `users/{uid}/escrow_devices/{deviceId}/computer_use_audit_export_signers/{publicKeySHA256Hex}`.
  Firestore rules require the parent escrow device to be trusted macOS, reject secret-looking fields, disable delete, and allow signer-level revocation by changing `status` to `revoked`.
- `ComputerUseAuditExportWriter.verify(..., signatureTrust: .trustedDeviceReadback(record))`
  verifies the sidecar signature and then rejects missing, revoked, or mismatched server readback records.

The original master-plan wording asked for an Apple/iCloud device-certificate signing identity. Implementation audit found no such app-facing trust root in this repo, so the production identity is now the OpenBurnBar trusted-device Keychain signer plus Firestore trusted-device readback/revocation.

### 5.3 OpenTimestamps validation

`validateOpenTimestampsProof` is the server-side Phase 13 cross-check:

- Callable Cloud Function exported from `functions/src/computerUseOpenTimestamps.ts`.
- Requires Firebase Auth + App Check and enforces `request.auth.uid == uid`.
- Checks `users/{uid}/computer_use_sessions/{sessionId}.auditHeadHashHex` against the submitted head hash before attempting proof validation.
- Accepts the `.ots` proof bytes as base64 and optional `chain.jsonl` bytes as base64.
- Calls `OPENBURNBAR_OTS_VERIFY_URL` first when configured. This should point to the Dockerized verifier in `tools/opentimestamps-verifier-service/`, which packages the official `opentimestamps-client` CLI.
- Falls back to `OPENBURNBAR_OTS_VERIFY_BIN` or `ots` when a local verifier binary is available in the runtime.
- Returns `ots_verifier_unavailable` instead of marking a proof verified when the official verifier is not installed.
- Returns `ots_verify_failed` for pending, malformed, or not-yet-Bitcoin-confirmed proofs. A fresh proof may legitimately remain pending until it is upgraded with a Bitcoin attestation.

This means server-side validation is wired, and production Bitcoin-header proof now has a deployable verifier-service path. The remaining rollout proof is operational: deploy that service, set `OPENBURNBAR_OTS_VERIFY_URL`, and record 10/10 upgraded `.ots` proofs verifying against Bitcoin headers.

The Mac Settings surface keeps notarization behind Computer Use → Audit
operations → Advanced. The Notarize button remains disabled until the user
explicitly opts in for that session.

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

For `HermesRealtimeRelayInputIntent`, the signed `intentHashBlake3` covers the action fields and excludes the `authority` envelope. The phone signs before attaching the final envelope; the Mac verifier recomputes the same authority-free hash before checking the Ed25519 signature. The pure signer/verifier lives in `OpenBurnBarComputerUseCore.ComputerUsePhoneControlSigner` so iOS issuer and Mac validator share canonical signing semantics and the test target can prove sig + counter + freshness + intent-hash semantics from a single fixture. Android mirrors the same contract in `PhoneControlSigner.kt` with Tink Ed25519: sorted authority-free JSON, SHA-256 hex in the `intentHashBlake3` field, `UTF8(hash) || u64BE(counter) || i64BE(timestampMs)`, replay/freshness/tamper checks, and Swift Date reference-second conversion for the Mac-bound `timestamp` JSON field. `PhoneControlSender.kt` then wraps the signed authority in the Android relay model as a `control.input.intent` frame with `control.streamClass = "control.input"` and `control.inputIntent.authority` attached. Android publishes the verifier root with `PhoneControlAuthorityPublisher.kt` under `iroh_pairing/{connectionId}/controllers/{peerNodeId}`; `PhoneControlSigningKeyStore` keeps the Ed25519 seed wrapped by Android Keystore AES-GCM. iOS and Android both register the current phone under `escrow_devices/{deviceId}` and expose a mirror Trust action; Firestore rejects the controller authority document until that device is `trusted`, the pairing document exists, and the account has the hosted Computer Use entitlement.

Agent capability grants reuse the same authority envelope and signing payload,
but the authority-free hash is computed over `AgentCapabilityGrantRequest`.
iOS/iPadOS and Android first register the current device if needed, require the
matching `escrow_devices/{deviceId}` record to be explicitly `trusted`, and
then require platform local authentication before issuing Desktop, All, or YOLO
grants. iOS/iPadOS use LocalAuthentication; Android uses AndroidX
BiometricPrompt from `FragmentActivity` and treats failed face/fingerprint
attempts as retryable until the system reports success, cancellation, or a
terminal error. Low and Workspace do not require biometric unlock, but still
require a signed-in user, a paired Mac, the hosted Computer Use entitlement, and
a trusted controller identity.

### 6.1 Replay rejection contract

`counter` is strictly monotonic per peer. The Mac receiver persists `lastSeenCounter[peerNodeId]` and rejects any envelope whose counter is `<= lastSeen`. On pairing rotation the counter resets — same flow as the iroh-blobs ticket exchange.

### 6.2 Mercury remote clipboard

Mercury mirror exposes two explicit text-only clipboard actions next to the
keyboard controls: **Paste to Mac** and **Grab from Mac**. There is no
background sync, polling, image transfer, rich text, file transfer, Firestore
clipboard queue, analytics payload, or visible phone text field.

The wire types are `control.clipboard.request` and
`control.clipboard.response`. Requests reuse the Phase 12 Ed25519 authority
envelope, the same freshness window, and the same per-controller monotonic
counter namespace as `control.input.intent`; the signed hash covers the
authority-free `HermesRealtimeRelayClipboardRequest`, so tampering with
`action`, `contentType`, `text`, `maxBytes`, or `clientIntentId` invalidates
the signature. Swift and Android keep the canonical signing logic beside their
existing phone-control signer implementations.

V1 accepts only `text/plain`. Phones read their local clipboard only inside the
user's **Paste to Mac** tap handler, reject empty text locally, and reject
outbound UTF-8 payloads over 65536 bytes before signing. **Grab from Mac** sends
no phone clipboard data; the phone writes its clipboard only after a matching
accepted response for the pending request ID.

On the Mac, `RemoteClipboardController` treats clipboard actions as direct
phone-control actions. The request must pass authority validation, trusted
controller identity, active Mercury session matching the manifest phone node,
Computer Use entitlement, Remote Config kill-switch, Accessibility permission,
scope rules, deny-region checks, secure-focus/loginwindow/SecurityAgent/screen
sleep checks, and the request's `maxBytes` limit. `Paste to Mac` writes
`NSPasteboard.general` and dispatches Command-V; `Grab from Mac` reads
`NSPasteboard.general.string` and returns text only when it is non-empty and
within the caller's byte limit.

Remote Unlock password paste is not this clipboard lane. Locked-screen password
entry uses `remote_unlock.credential`, a sealed credential envelope with no
plaintext field, no Mac pasteboard write, no `Grab from Mac`, and no agent
visibility. See [`REMOTE_UNLOCK.md`](REMOTE_UNLOCK.md).

Audit entries use `clipboard.paste_to_mac` and `clipboard.grab_from_mac`
descriptor kinds. They record the action, byte count, status, and session
context, but never store clipboard text in the audit chain, action-log stream,
analytics, Firestore, or relay logs.

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

### 9.1 Agent chat grants

Hermes, OpenClaw, Pi, Codex, and Claude do not get desktop authority merely
because their chat is running on the Mac. OpenBurnBar now treats desktop access
as an explicit, revocable `AgentCapabilityGrant` issued from the chat UI.

Grant shape:

- Scoped to one chat thread, one runtime (`hermes`, `openclaw`, `pi`, `codex`,
  or `claude`), and one expiration window.
- Never sticky across backend switches, new threads, or history-thread opens.
- Revocation is live: the in-process broker re-checks the active grant before
  every tool call and denies calls after the user turns access off.
- Capabilities are split instead of using an all-or-nothing "desktop" bit:
  Browser, screenshot, Accessibility inspect, Mac input, workspace read,
  workspace write, and shell.
- The UI starts with plain-language presets: **Off** (no tools), **Low**
  (workspace read-only), **Workspace** (workspace read/write, the default),
  **Desktop** (browser, screenshot, Accessibility inspect, workspace read/write),
  **All** (every capability in Manual mode), and **YOLO** (every capability in
  Trusted mode). A "Fine tune" section exposes the individual toggles for users
  who want an exact custom grant.
- Accessibility inspect, Mac input, shell, All, and YOLO carry inline risk copy
  because they can expose visible app text, type/click in apps, or run
  high-trust local commands.
- Workspace file tools reject absolute paths, `..` escapes, and symlink escapes.
  The local shell runner executes from the workspace with bounded output and a
  macOS sandbox that denies writes outside the workspace; shell remains a
  high-trust capability because commands can still read local files.
- Trust mode remains per session (`Manual`, `Step`, `Trusted`) and feeds the
  same Computer Use coordinator, scope rules, approvals, audit chain, budgets,
  and panic-halt paths described above.

Mobile surfaces:

- iPhone and iPad expose **Agent permissions** in Hermes, Pi, and CLI-agent
  chat menus.
- Android exposes the same Security control in Hermes, Pi, and CLI-agent chat
  headers.
- Grant delivery is live-first: if the paired Mac control stream is active,
  the phone sends `control.agent_grant.request` over iroh and waits for
  `control.agent_grant.receipt`.
- If the live stream is unavailable, the phone queues the signed grant under
  `users/{uid}/agent_capability_grant_requests/{requestId}`. The Mac queue
  listener validates the trusted-device authority, applies the grant, and writes
  the receipt back to the same document.
- Firestore rules keep queued grant documents metadata-only. They reject prompt
  text, message bodies, screenshots, ciphertext blobs, and other payload fields
  so the queue cannot become a data exfiltration channel.
- Mobile applies an optimistic local receipt while the request is in flight, so
  the next Hermes/Pi/Codex/Claude/Droid/Forge/Antigravity send can route to the
  Mac desktop executor immediately. The Mac receipt is still the source of
  truth and can revoke or downgrade the optimistic state.

Runtime behavior:

| Agent backend | Grant delivery | Execution path |
|---|---|---|
| Hermes / OpenClaw / Pi | OpenAI-compatible `tools` descriptors from `AgentDesktopToolDefinitions` | `AgentToolBroker` routes browser calls to the daemon Browser CU session, Mac input/inspect calls to the app-owned System CU coordinator, and workspace/shell calls through a workspace-confined local broker. Mobile sends route through the Mac agent-relay mission path when a grant is active. |
| Codex | CLI-native sandbox arguments | Read grants map to `--sandbox read-only`; write/shell grants map to `--sandbox workspace-write`; YOLO maps to Codex's explicit dangerous sandbox bypass flag. |
| Claude | CLI-native permission arguments | Workspace tools map to `--allowedTools`; write grants enable `--permission-mode acceptEdits`; YOLO maps to Claude's explicit dangerous permission bypass flag. |
| Droid | CLI-native autonomy arguments | Droid runs through `droid exec --output-format json` in the selected workspace. Write grants map to `--auto low --disabled-tools execute-cli`; shell grants map to `--auto medium`. OpenBurnBar does not pass Droid's unsafe permission bypass. |
| Forge | Prompt-level safety constraints | Forge runs with `--prompt` and optional `--agent forge/muse/sage`. OpenBurnBar appends read-only, no-edit, and no-shell constraints unless the thread grant explicitly includes those capabilities. |
| Antigravity | CLI-native sandbox arguments | Antigravity runs through `agy --print` in the selected workspace. Normal grants keep `--sandbox`; YOLO/full trust maps to `--dangerously-skip-permissions`, which is only passed after the user selects that capability. |

The broker intentionally does not mutate global agent config, MCP config, or
provider account settings. Grants are session-local app authority, which keeps
Hermes and other agents honest: without a grant, they should say they cannot use
desktop tools; with a grant, the prompt and tool envelope tell them exactly what
was enabled.

Desktop export behavior is intentionally explicit. `desktop_export_file` copies
a workspace file to `~/Desktop/OpenBurnBar Agent Drops/{threadId}/` and never
lets the model choose an arbitrary absolute Desktop path. `shell_run_unrestricted`
requires the YOLO or Trusted all-capability preset and remains blocked by the
session-level panic halt and remote kill switch.

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
- **`hosted_computer_use_sync`:** the Computer Use entitlement that gates Browser + System + PhoneControl. Current product ID `com.openburnbar.computerUse.monthly`; legacy ID `com.openburnbar.hostedComputerUseSync.monthly`.
- **`computer_use_kill_switch`:** Remote Config flag that suspends all new sessions and ends existing ones within 60 s.
