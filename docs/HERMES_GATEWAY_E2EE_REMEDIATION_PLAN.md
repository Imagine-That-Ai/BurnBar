# Hermes Gateway E2EE — Consolidated Security Remediation Mega Plan

**Author:** Aggregation + adjudication pass (Opus 4.8, 1M ctx), 2026-06-03
**Inputs:** 7 independent model security reviews on the Desktop
(`claude-sonnet-4-6-thinking`, `gemini-3.1-pro-high`, `gemini-3.5-flash`,
`gpt-5-codex`, `Grok-4.3`, `grok-hermes-gateway-e2ee`, `Opus-4.8`).
**Target of the reviews:** the `hermes-agent` fork destined for Nous Research
upstream (`~/.hermes/hermes-agent`, branch `ajnunezg/burnbar-platform`, dirty
working tree = the reviewed v2 artifact) **plus** its cross-language
counterparts in this repo (`OpenBurnBarCore`, `OpenBurnBarMobile`, `android/`,
`functions/`).
**Status of this document:** every finding below was re-verified against the
actual source (file:line quoted). Contested findings were adjudicated by reading
code, not prose. This plan is the input artifact for an implementation workflow.

---

## 0. Executive verdict

**HOLD. Do not submit to Nous, and do not ship the mobile/functions side as
"E2EE", until the four P1s below are fixed.**

The cryptographic core is genuinely well-built: the v2 2-DH AuthEncap
(`ikm = ECDH(eph,R) ‖ ECDH(S,R)`, empty-salt HKDF, info binds all three pubkeys,
X9.63 throughout, prime-order P-256, fresh nonce, distinct v1/v2 domain prefixes)
is sound and independently verified by all 7 reviewers and re-checked here. The
gateway open path is correctly v2-only and fail-closed. Cross-language byte-exact
crypto interop (Swift emits → Python + Kotlin open, with forge-reject and
v1-downgrade-reject) is real.

But the whole construction hangs off trust roots and wire plumbing that are
currently broken or unsubmitted:

| # | P1 finding | One-line impact |
|---|---|---|
| **MP-1** | Pairing safety code hashes only the **agent** key, never the phone key | An untrusted relay substitutes the phone key at first pin; the human-verified code still matches → relay reads all agent→phone replies and forges all phone→agent events. Collapses Claims 1, 2, 6. |
| **MP-2** | Agent never sends the AAD-bound id (`messageId` **and** `attachmentId`) on `/messages` + `/attachments/init` | Server mints a different id; phone reconstructs the AAD from that id → **every sealed agent→phone reply AND attachment fails AEAD on the device today.** The agent→phone E2EE channel is non-functional. Shipping-broken. |
| **MP-3** | Replay cache records the relay-controlled event id **before** AEAD auth | Relay floods 4096 forged-id events to evict the LRU, then replays an old genuine sealed event → defeats the replay defense (Claim 3 partial). |
| **MP-4** | The v2 work exists **only in the dirty working tree** | The pushed PR2 branch is still v1. Whatever is submitted is not what was reviewed. Release-integrity blocker. |

After the P1s, there are P2 hardening items and P3 polish/test items, all
verified real, enumerated below.

> **⚠ This plan was revised after a Round-2 adversarial self-audit + an independent
> `/codex` pass (2026-06-03). Both passes ran in parallel and were reconciled
> against source. The original v1 of this plan was NOT safe to execute as written —
> it missed a P1 (sealed *messages* had the identical id-mismatch bug, not just
> attachments), under-spec'd the safety-code entropy, and proposed one unsafe
> version fix. See § 1.5 for the corrections; the MP entries below are the
> corrected versions.**

---

## 1.5 Round 2 — adversarial self-audit + independent /codex pass (corrections)

Two independent loophole hunts ran in parallel against v1 of this plan: a manual
self-audit and an OpenAI Codex (`gpt-5`-class, `model_reasoning_effort=high`,
~2.19M tokens, read-only) pass over both repos. They converged. **Verdict on
v1-as-written: NOT safe to execute.** Every correction below is verified against
source (file:line).

**New / re-scoped P1:**

- **MP-2 was half-right and is now the headline.** The id-round-trip bug the plan
  caught for *attachments* exists **identically for ordinary sealed messages** —
  the primary agent→phone reply channel. `seal_message` bakes
  `message_id = secrets.token_hex(16)` into the AAD and returns it only inside the
  envelope (`adapter.py:586,591,603`); `_post_message` never sets top-level
  `body["messageId"]` (`adapter.py:422-434`); the server mints a fresh id via
  `safeIdentifier(body.messageId,"msg")` (`hermesGateway.ts:691`); the phone
  rebuilds the AAD from the stored id (`FunctionsRepository.swift:768,774`) →
  **AEAD fails → every sealed reply is undecryptable today.** The server comment
  at `hermesGateway.ts:713-721` *documents the intended contract* ("the server must
  echo the client's id byte-for-byte") — the agent simply never holds up its end.
  Same for attachments (`adapter.py:285-296`). **The entire agent→phone E2EE
  channel is non-functional in production, not just attachments.** I verified the
  reverse direction is fine: phone→agent **events** require the phone to send
  `eventId` (`hermesGateway.ts:309,1646`), which it does consistently with its
  seal, so that channel works — the bug is specific to the agent→phone write path.
  → MP-2 is now "AAD-bound id round-trip for messages AND attachments."

**New P2s the plan missed:**

- **MP-27 — phone never decodes the sealed `{"text":...}` JSON.** The agent seals
  JSON (`adapter.py:588`); Swift renders the decrypted bytes as a raw string
  (`FunctionsRepository.swift:776`), so once MP-2 is fixed, replies would display
  `{"text":"hi"}` literally, and approval-detail payloads can't carry a structured
  `actionId`. Masked today because MP-2 stops decryption entirely. Fix: define +
  decode a sealed payload schema `{text, actionId?, kind?}` on Swift + Kotlin;
  reject malformed.
- **MP-28 — server write path accepts v1 envelopes.** Supported versions are
  `[1,2]` (`hermesGateway.ts:67`); `requireGatewayRelayEnvelope` accepts any
  supported version (`hermesGateway.ts:490`); relay-capable events require *an*
  envelope, not v2 specifically (`hermesGateway.ts:1615`). The agent + phone fail
  closed on non-v2, but the server still lets unreadable schema-1 gateway docs be
  written. Fix: new gateway writes must require `relayEnvelope.relayKeyVersion===2`;
  keep v1 only as a legacy read sanitizer.

**Corrected entries:**

- **MP-1 (strengthen) — the two-key safety code must also be wider than 64 bits.**
  Sorting both raw keys is correct for role-independent comparison, but the
  displayed code truncates SHA-256 to **8 bytes / 64 bits** (`adapter.py:132`
  `range(0,8,2)`; `HermesGatewayRelayKeypair.swift:309` `stride(0,8,2)`). A relay
  that sees both honest keys at pairing can grind a substitute keypair (whose priv
  it holds) to collide the displayed code in ~2^64 — below a "Signal-style"
  fingerprint. Fix: feed both keys **and** display ≥128 bits (full
  fingerprint/QR path + grouped fallback); domain-separate with role labels /
  transcript. Also migrate the phone's cached pinned-safety-code store.
- **MP-6 (downgrade P1→P2, re-scope).** The server **already** ignores the
  client-supplied `summary` and derives a coarse label by design
  (`hermesGateway.ts:1087-1095`). So the server half is done. Residual leak: the
  agent still redundantly sends `summary` in the plaintext `/approvals` body
  (`adapter.py:1271`) which the untrusted relay sees in transit → drop that field
  agent-side (one line). **But** the higher-impact half is *informed approval*: the
  sealed follow-up is a plain `{"text"}` message with no `actionId`
  (`adapter.py:588`), and the approval card renders only server `toolName`/`summary`
  (`HermesSettingsView.swift:969`), so with multiple pending approvals the phone
  cannot bind the private detail to the right gate — a user could approve the wrong
  action. Fix: carry `actionId` in the sealed detail (needs MP-27 schema); phone
  joins detail→card; disable Approve until a matching sealed detail is opened (or
  show "details unavailable" → deny by default).
- **MP-3 (refine).** Safe today only because event polling is serial
  (`adapter.py:1091`). Spec precisely: parse top-level `raw.id`, reject a missing id
  for sealed events, decrypt with that id as AAD, then **atomically record the same
  id immediately after a successful open and before `handle_message`** — not after.
  Add a lock if any concurrent/SSE delivery path is ever introduced.
- **MP-10 (correct the fix).** Strike the "stamp top-level gateway envelopes as 2"
  option — public-key version (`keyVersion=1`) and envelope wrap version
  (`gatewayRelayKeyVersion=2`) are *different concepts* (`HermesRelayCrypto.swift:65`);
  stamping top-level as 2 bakes in a semantic lie. Correct fix: **remove/deprecate**
  top-level `relayKeyVersion` on sealed message/attachment writes, or rename
  (`relayPublicKeyVersion` for advertised keys vs `relayEnvelope.relayKeyVersion`
  for wraps).

**Confirmed sound (both passes):** MP-2's attachment server side is already built
to adopt the agent's `token_hex` id with create-if-absent / 409 anti-clobber
(`hermesGateway.ts:932` + comment ~962); MP-1 sorting is the right primitive; MP-3
has no live concurrency window under the current serial poll loop; the v2 crypto
core and PASS list (§2) survived re-scrutiny.

---

## 1. Why aggregate 7 models — the adjudications that matter

The point of pooling 7 reviews is to catch what any single reviewer missed and
to kill false positives. Three adjudications drove the verdict:

1. **Cache-flush replay (MP-3) — Gemini 3.1 Pro was right; Opus/Sonnet/Grok were
   wrong.** Four reviewers asserted "replay holds" because the event id is
   AAD-bound (can't be mutated without breaking the tag) and idless events aren't
   deduped. They missed the *ordering*: `_handle_burnbar_event` records the id
   into the bounded LRU **before** decryption (`adapter.py:1103` → `1112/1132`),
   so 4096 forged events with garbage ciphertext still poison/evict the cache
   even though they all fail AEAD. **Verified real.**

2. **Attachment AAD (MP-2) — grok-e2ee was right; Claude Sonnet was wrong.**
   Sonnet declared "the contract is enforced … the wire vector confirms the Swift
   side produces the matching AAD" — but that conclusion rested on the vector and
   on comments, not the production init path. Reading the three real files
   (`adapter.py:285-296` sends no `attachmentId`; `hermesGateway.ts:932` mints
   `att_<random>`; `FunctionsRepository.swift:856-858` opens with the server id)
   proves the production path is **broken end-to-end**. The cross-language vector
   masks it because it unwraps with the envelope id, not the server id.

3. **KCI severity — downgrade, don't over-engineer.** Gemini 3.5 framed KCI as P2
   and suggested migrating to X3DH / double-ratchet. Five reviewers correctly
   note KCI is an *inherent, documented* property of any 2-DH AuthEncap (HPKE
   AuthEncap has the same bound) and not exploitable under the relay-only threat
   model. **The SOTA-appropriate fix is to document the boundary (MP-16) and move
   the recipient key to OS keychain storage — not to bolt on a ratchet v1
   doesn't need.** Rejecting that suggestion is part of the plan.

### Cross-model agreement matrix (verified findings only)

| ID | Finding | Sonnet | G-3.1Pro | G-3.5 | GPT-5 | Grok-4.3 | grok-e2ee | Opus | Verdict |
|----|---------|:--:|:--:|:--:|:--:|:--:|:--:|:--:|:--:|
| MP-1 | Safety code single-key MITM | — | — | P1 | P1 | P1 | P1 | P1 | **REAL P1** |
| MP-2 | Attachment id AAD mismatch | (denied) | — | — | — | — | P1 | (slot ok) | **REAL P1** |
| MP-3 | Cache-flush replay | (P2 idless) | **P1** | — | P2 | P2 | P2 | (held) | **REAL P1** |
| MP-4 | PR2 ≠ reviewed v2 artifact | — | — | — | P1 | — | — | — | **REAL P1** |
| MP-5 | Plaintext downgrade at pairing | — | — | — | — | — | — | P2 | **REAL P2** |
| MP-6 | Approval summary leaks plaintext | — | — | — | P1 | — | — | — | **REAL P1** |
| MP-7 | Idless-event replay | P2 | (in MP-3) | — | P2 | P2 | P2 | (held) | **REAL P2** |
| MP-8 | Sealed event trusts relay sender id | — | — | — | P1 | — | — | — | **REAL P2** |
| MP-9 | uid/clientId AAD mutation | — | — | — | P2 | — | — | P3 | **REAL P2** |
| MP-10 | top-level vs envelope version | — | — | — | P2 | — | P2 | — | **REAL P2** |
| MP-11 | model_switch slash injection | P3 | — | — | P2 | — | P3 | P3 | **REAL P2** |
| MP-12 | Attachment metadata server-readable | — | — | — | P2 | — | — | — | **REAL P2** |
| MP-13 | AAD delimiter collision | — | — | — | P2 | — | — | — | **REAL P2** |
| MP-14 | Corrupt privkey mints new identity | — | — | — | — | — | P2 | — | **REAL P2** |
| MP-15 | `cryptography` optional dep | — | — | — | — | — | P2 | — | **REAL P2** |
| MP-16 | KCI / threat model undocumented | P2 | — | P2 | — | P2 | P2 | P3 | **REAL P2** |
| MP-17 | Shared-core changes bundled | P2 | — | — | P3 | P2 | — | P3 | **REAL P2** |
| MP-18 | Vector manifest `name` vs `fileName` | — | — | — | — | — | P2 | P3 | **REAL P3** |
| MP-19 | Stale substituted-sender test | P3 | — | — | P3 | P3 | P2 | P3 | **REAL P3** |
| MP-20 | `base64.binascii.Error` fragility | — | P3 | — | — | — | — | — | **REAL P3** |
| MP-21 | Ignored `_pin_peer_public_key` return | — | — | P3 | — | P2 | — | — | **REAL P3** |
| MP-22 | Safety-code silent base64 fallback | P3 | — | — | — | — | — | — | **REAL P3** |
| MP-23 | No adapter-level v1-rejection test | — | — | — | — | — | P2 | — | **REAL P3** |
| MP-24 | README test cmd omits v2 suite | — | — | — | P3 | — | — | — | **REAL P3** |
| MP-25 | `RELAY_CRYPTO_AVAILABLE` broad except | — | — | — | — | — | P3 | — | **REAL P3** |
| MP-26 | Hardcoded `api.burnbar.ai` default | — | — | — | — | — | — | P3 | Awareness only |

---

## 2. Confirmed PASS — do not touch (verified sound)

These were probed by multiple reviewers and re-verified here; changing them adds
risk with no benefit:

- v2 2-DH AKEM soundness: `dh1‖dh2` order (not XOR), ephemeral leg first, empty
  32-zero-byte salt (== Swift `Data()`), info binds `enc‖recipientPub‖senderPub`,
  X9.63 uncompressed everywhere, P-256 prime-order (no small-subgroup), fresh
  `os.urandom(12)` nonce per seal. (`relay_e2ee.py:120-160`, `535/623`.)
- v1↔v2 domain separation: `-KeyWrap-v1|` vs `-KeyWrap-v2|`; v1-open-of-v2 →
  `InvalidTag`. (`relay_e2ee.py:117/127`.)
- Gateway open path is v2-only + fail-closed; binds the **pinned** key, never the
  wire `senderPublicKey`. (`adapter.py:770-777`.)
- No reachable v1 unwrap on the gateway open path; no `except: pass` swallowing a
  security error into a plaintext path.
- No RCE/eval/subprocess sink from opened text or `modelId`.
- TOFU pin-jacking from runtime relay state is blocked (`allow_new_pin=False`
  everywhere except pairing — which is exactly the MP-1 hole).
- Cross-language **crypto-byte** interop is genuine (Swift emits the vector;
  Python + Kotlin open the byte-identical bytes incl. forge/downgrade reject).
- PR1 is genuinely crypto-free; no committed secrets (vector keys are
  deterministic test scalars).

---

## 3. Architectural spine (read before implementing)

The hard part is **not** any single fix — it is that this system is one wire
contract spread across **two repos and five language surfaces**, and several
fixes change that contract simultaneously:

```
            ┌─────────────────────── hermes-agent (Nous fork) ───────────────────────┐
   Python   │  gateway/crypto/relay_e2ee.py     plugins/platforms/burnbar/adapter.py   │
            └──────────────────────────────────────────────────────────────────────-─┘
                          ▲  byte-identical mirror  ▲
            ┌──────────────────────────── BurnBar repo ──────────────────────────────┐
   Python   │  tools/hermes-platform-burnbar/adapter.py   (IDENTICAL — must stay synced) │
   Swift    │  OpenBurnBarCore/.../SharedModels/HermesRelayCrypto.swift                  │
   Swift    │  OpenBurnBarMobile/Services/{FunctionsRepository,HermesGatewayRelayKeypair}│
   Swift    │  OpenBurnBarMobile/Views/Hermes/HermesSettingsView.swift                   │
   Kotlin   │  android/.../data/hermes/relay/HermesRelayCrypto{,Ec,Support}.kt           │
   TS       │  functions/src/{callables/,}hermesGateway.ts                              │
   Vectors  │  OpenBurnBarCore/Tests/.../Fixtures/HermesGatewayWireVector.json           │
            │  android/app/src/test/resources/hermes-relay/HermesGatewayWireVector.json  │
            │  hermes-agent/tests/gateway/fixtures/HermesGatewayWireVector.json          │
            └──────────────────────────────────────────────────────────────────────-─┘
```

**Two invariants the workflow must honor:**

1. **Adapter parity.** `~/.hermes/hermes-agent/plugins/platforms/burnbar/adapter.py`
   and `BurnBar/tools/hermes-platform-burnbar/adapter.py` are byte-identical
   (1743 lines). Every adapter edit lands in **both**, verified with `diff -q`.
   (Recommend a CI check or a one-line sync step in the workflow.)

2. **Vector is the lockstep gate.** Any change to AAD inputs, manifest schema,
   version fields, or the attachment id contract means the Swift emitter
   regenerates `HermesGatewayWireVector.json`, the bytes are copied to all three
   fixture locations (sha256-identical), and the Python + Kotlin + Swift suites
   re-open them. MP-1, MP-2, MP-10, MP-18 all touch the contract → they must land
   in one coordinated phase, not piecemeal.

---

## 4. The remediation findings (verified, with fix specs)

> Line numbers are against the current dirty working tree. `adapter.py` lines
> apply to **both** copies. Severity is the adjudicated value.

### P1 — blocks submission

#### MP-1 — Two-key pairing safety code (Signal-style fingerprint)
> **Round-2 correction (see § 1.5): also widen the displayed code from 64 bits to
> ≥128 bits.** Feeding both keys is necessary but not sufficient — the current
> 8-byte truncation (`adapter.py:132`, `HermesGatewayRelayKeypair.swift:309`) lets a
> key-substituting relay grind a ~2^64 collision on the displayed code. Add a
> fingerprint/QR path + migrate the phone's cached pinned-code store.
- **Evidence:** `_relay_safety_code(public_key_b64)` hashes one key
  (`adapter.py:115-132`); `interactive_setup` feeds only the agent key
  (`adapter.py:1703`) while pinning the phone key straight from the
  relay-controlled poll response (`adapter.py:1683-1695`). Swift mirror is
  single-key (`HermesGatewayRelayKeypair.swift:304-314`,
  `HermesSettingsView.swift:2261-2268`). Android has **no** safety-code UI.
- **Fix:**
  1. Define a canonical two-key code: `SHA-256( sorted([agentPubRaw, phonePubRaw]) )`,
     first 8 bytes → four uppercase hex groups (keep the existing rendering).
     Sorting by raw bytes makes both ends compute the identical code without
     agreeing on roles.
  2. Python: `_relay_safety_code(agent_pub_b64, phone_pub_b64)`; call it with
     both keys at `adapter.py:1703`. Do **not** persist
     `BURNBAR_RELAY_PEER_PUBLIC_KEY` / set `BURNBAR_RELAY_E2E=1` until the user
     confirms the two-key code (add a confirm gate, or at minimum print both the
     agent-only and the combined code and instruct comparison of the combined
     one).
  3. Swift: `safetyCode(agentKey:phoneKey:)`; update `agentSafetyCode(...)` to
     feed both the pinned agent key and the device's own relay public key.
  4. Android: add the safety-code derivation + a pairing screen that displays it
     (currently absent — this is net-new UX, not just a port).
  5. Tests: cross-language unit test that swapping **either** key changes the
     code; a pairing test that a substituted phone key produces a *different*
     code on the agent than on the phone.
- **SOTA note:** this is exactly Signal's safety-number model (hash of both
  identity keys). Primary fix. Defense-in-depth follow-up (not v1-blocking):
  have the phone MAC its relay pubkey under the user's authenticated session so
  the agent can verify it without human comparison.

#### MP-2 — AAD-bound id round-trip for MESSAGES **and** attachments (agent→phone E2EE is broken today)
> **Round-2 correction (see § 1.5): this is not attachment-only.** The identical
> bug hits sealed *messages* — `_post_message` omits top-level `body["messageId"]`
> (`adapter.py:422-434`) the same way `_init_attachment` omits `attachmentId`. Fix
> BOTH: agent sets `body["messageId"]=envelope["messageId"]` and
> `body["attachmentId"]=relay_envelope["attachmentId"]`. Both servers already adopt
> (`safeIdentifier` for messages `hermesGateway.ts:691`; `adoptedGatewayDocId` for
> attachments `:932`) with create-if-absent/409. Agent retry must regenerate the id
> or treat 409 as already-initialized. Add round-trip mismatch tests for messages
> AND attachments. Pairs with MP-27 (phone must then decode the `{"text"}` JSON).
- **Evidence:** agent seals body/manifest/key AADs with
  `attachment_id = secrets.token_hex(16)` (`adapter.py:615-644`) but
  `_init_attachment` omits it from the POST body (`adapter.py:285-296`); server
  `adoptedGatewayDocId(body.attachmentId, …)` therefore mints `att_<random>`
  (`functions/src/callables/hermesGateway.ts:932`); phone resolves the record id
  from the stored doc (`FunctionsRepository.swift:856-858`) and builds all three
  AADs from it (`:908/:924/:945`) → AAD mismatch → AEAD fail.
- **Fix:**
  1. Agent: in `_init_attachment`, when `relay_envelope is not None`, set
     `body["attachmentId"] = relay_envelope["attachmentId"]`. Generate the id in
     server-adoptable form (`att_` + 16 hex) so it is unambiguous; the server
     regex `[A-Za-z0-9_.:-]+` (≤160) already accepts it.
  2. Confirm server adoption is unconditional when a valid id is supplied (it is
     — `adoptedGatewayDocId`) and that the manifest doc stores `id: attachmentId`
     (it does — `hermesGateway.ts:945`).
  3. Test (the one that would have caught this): an integration test where
     `/attachments/init` mock returns a **different** id than the envelope's
     unless `body.attachmentId` is set — must AEAD-fail when mismatched and
     succeed when the round-trip is wired. Align with the new
     `functions/src/__tests__/hermesGatewayAttachmentInit.test.ts`
     (`attachmentId: "att_happy_path_0001"`).

#### MP-3 (+MP-7) — Record event id only after authenticated decrypt; reject idless E2E events
> **Round-2 refinement (see § 1.5):** record the id *immediately after* a successful
> open and *before* `handle_message` (not after), atomically. Safe today only
> because the poll loop is serial (`adapter.py:1091`); add a lock if any
> concurrent/SSE delivery is introduced.
- **Evidence:** `_handle_burnbar_event` (`adapter.py:1103`) calls
  `_event_already_seen` (which records, `:983`) **before** `open_event` /
  `open_model_switch` (`:1112/:1132`). Idless events are never deduped
  (`:975-976`).
- **Fix:** split `_event_already_seen` into `_is_event_seen(id)` (read-only,
  before decrypt) and `_record_event(id)` (called only **after** a successful
  authenticated open). On an E2E-paired link, refuse events whose
  authenticated/sealed id is empty (or synthesize a dedup key from
  `sha256(uid, clientId, wrappedKey, payloadCiphertext)`). Tests: a flood of
  forged-id frames that all AEAD-fail must **not** evict a legitimate id; a
  replayed genuine event must be dropped after restart only if persisted (see
  optional persistence below).
- **Optional (P2 within this fix):** persist a bounded seen-id store per
  `(uid, clientId)` so replay survives a gateway restart.

#### MP-4 — Land the v2 artifact on the real PR branches and re-verify clean
- **Evidence:** `git grep KeyWrap-v2 ajnunezg/burnbar-gateway-e2ee` → empty; v2
  is only in the uncommitted working tree on `ajnunezg/burnbar-platform`.
- **Fix:** commit the v2 crypto + adapter + `test_relay_e2ee_v2.py` + the v2
  `HermesGatewayWireVector.json` (and every fix from this plan) onto
  `ajnunezg/burnbar-gateway-e2ee`; drop unrelated untracked files (`.serena/`,
  `assets/user_ascii_apple.txt`); from a **clean checkout** run the canonical
  command and byte-verify the fixture. This is the **last** phase (after all
  code fixes), not the first.

#### MP-6 — Stop leaking approval free-text + bind approval detail (re-scoped P1→P2)
> **Round-2 correction (see § 1.5):** the server ALREADY ignores the client
> `summary` and derives a coarse label (`hermesGateway.ts:1087-1095`) — no functions
> change needed. Residual leak = agent redundantly sends `summary` in the
> `/approvals` body (`adapter.py:1271`); drop it (one line). Higher-impact half:
> the sealed follow-up carries no `actionId` (`adapter.py:588`), so the phone can't
> bind the private detail to the right approval gate (informed-consent risk). Carry
> `actionId` in the sealed detail (needs MP-27) and have the phone join it; disable
> Approve until a matching sealed detail opens.
- **Evidence:** `_arm_approval` posts `{"actionId", "summary", "toolName"}` to
  `/approvals` in plaintext (`adapter.py:1271`), where `summary` is the
  slash-confirm message (can contain command text, file paths, tool args). README
  claims the approval channel is control-plane only.
- **Fix:** `/approvals` carries only opaque `actionId`, `destinationId`, expiry,
  and a coarse local category enum — **no free text**. Route all human-readable
  detail through the already-sealed `_post_confirm_followup` card
  (`adapter.py:1263`). Update `functions/.../hermesGateway.ts` approval handler +
  README. Test: a supervised E2E slash-confirm POST to `/approvals` contains no
  command/summary text.

### P2 — hardening (fix before upstream)

| ID | Fix summary | Anchor |
|----|-------------|--------|
| **MP-5** | Once the agent has a relay identity, **require** E2E; refuse the silent plaintext-legacy fallback unless `BURNBAR_ALLOW_PLAINTEXT=1`. Don't let the untrusted relay choose whether encryption happens. | `adapter.py:1692/1707` |
| **MP-8** | On an E2E event, take sender identity (`senderId`/`senderDisplayName`) from the **sealed payload**, not top-level relay metadata. Today `senderId` is always relay-controlled (`:1151`) and `senderDisplayName` falls back to it (`:1141`). Benign while `BURNBAR_ALLOW_ALL_USERS=true` (default `:1712`), but a spoofable access key once `BURNBAR_ALLOWED_USERS` is set. Bind sender identity into the ciphertext; test that raw-metadata substitution is ignored for authz. | `adapter.py:1141/1151` |
| **MP-9** | Pin `uid`/`clientId` from the authenticated pairing grant; treat runtime `/state`,`/events`,`/destinations` values as confirm-only (warn on change). Today they're overwritten unconditionally (`:1018-1023`) and feed every AAD → relay can silently DoS the link by rotating them. | `adapter.py:1018-1023` |
| **MP-10** | Disambiguate versions. **Round-2 correction:** do NOT "stamp top-level as 2" (public-key version ≠ envelope wrap version — `HermesRelayCrypto.swift:65`; stamping would lie). Instead **remove/deprecate** top-level `relayKeyVersion` on sealed message/attachment writes, or rename (`relayPublicKeyVersion` for advertised keys vs `relayEnvelope.relayKeyVersion` for wraps). Phone reads envelope-first + requires v2 (`FunctionsRepository.swift:607-611,759`), so this is integrator hygiene, not a live phone bug. Add a full-JSON cross-language test. | `adapter.py:294/434/601` |
| **MP-27** | **(Round-2, missed)** Phone renders the decrypted sealed body as a raw string (`FunctionsRepository.swift:776`) instead of parsing the agent's `{"text":...}` JSON (`adapter.py:588`). Masked today by MP-2. Define + decode a sealed payload schema `{text, actionId?, kind?}` on Swift + Kotlin; reject malformed. Required for readable replies and for MP-6 approval correlation. | `FunctionsRepository.swift:776` |
| **MP-28** | **(Round-2, missed)** Server write path accepts v1 envelopes: supported=`[1,2]` (`hermesGateway.ts:67`), `requireGatewayRelayEnvelope` accepts any supported (`:490`), relay-capable events require an envelope but not v2 (`:1615`). Agent+phone fail closed on non-v2, but the server still lets unreadable schema-1 docs be written. Require `relayEnvelope.relayKeyVersion===2` for new gateway writes; keep v1 only as a legacy read sanitizer. | `hermesGateway.ts:67/490/1615` |
| **MP-11** | Replace `text = f"/model {model_id}"` (`:1124`) with a structured model-switch call (`model_id` as data, `is_global=False`, explicit provider only from a separate validated field). Reject whitespace/control chars; validate against the advertised catalog; bound length. Closes the `--provider`/`--global` flag-injection surface. | `adapter.py:1120-1124` |
| **MP-12** | Move `contentType` and original `byteCount` into the sealed manifest. If the upload infra needs a length, send `ciphertextByteCount` and document it as visible metadata. Today both are plaintext on `/attachments/init` (`:287-288`). | `adapter.py:285-295` |
| **MP-13** | AAD is `prefix + "|" + "|".join(parts)` with no escaping (`relay_e2ee.py:130`). Validate every AAD part rejects `|` and control chars (ids are token_hex / Firebase ids today, so low live risk), or move to a length-prefixed/CBOR canonical AAD in a future v3. Add delimiter-rejection tests. | `relay_e2ee.py:130` |
| **MP-14** | When `BURNBAR_RELAY_PRIVATE_KEY` is present but invalid, **fail closed** with an explicit "re-pair required" instead of silently minting a new identity (`relay_e2ee.py:350-356`) — silent rotation makes all prior sealed inbound undecryptable and looks like a relay attack. | `relay_e2ee.py:350-356` |
| **MP-15** | `cryptography` is an optional extra (`pyproject.toml:106`). When `BURNBAR_RELAY_E2E=1` and the import failed (`RELAY_CRYPTO_AVAILABLE=False`, `adapter.py:43-45`), warn loudly in `check_requirements`/setup and document `pip install -e '.[gateway-e2ee]'`. Ensure the send path fails closed (refuses), never plaintext. | `pyproject.toml:106`, `adapter.py:43-45` |
| **MP-16** | Add a **Security considerations** section to `relay_e2ee.py` module docstring (mirror in Swift/Kotlin + README): goals (confidentiality + sender auth under pinned statics; ephemeral FS on the `dh1` leg), explicit **non-goals** (KCI on recipient-key compromise; no PFS for the static leg; replay relies on AAD + event id + the MP-3 fix), empty-salt rationale, and that the sender-auth property requires the caller to pin the peer static (rooted in MP-1's safety code). **Do not migrate to a ratchet — document the bound.** Consider OS-keychain storage for the recipient key (ties to MP-14). | `relay_e2ee.py` docstring |
| **MP-17** | Disentangle shared-core changes from the BurnBar PR: extract `gateway/platforms/api_server.py` (`_upstream_model_descriptors`/model proxy, streaming finish/error fields) and the `tools/send_message_tool.py` media-routing change into a preceding generic PR, or gate them behind the BurnBar platform / a feature flag. Add tests proving existing media platforms (telegram/discord/matrix) still deliver natively. Call it out in the PR description regardless. | `api_server.py`, `tools/send_message_tool.py` |

### P3 — polish & test fidelity (do alongside the relevant phase)

| ID | Fix summary | Anchor |
|----|-------------|--------|
| **MP-18** | Regenerate the wire vector with the production manifest field `fileName` (vector + emitter currently use `name`; iOS/Android decode `fileName`). Add a test that parses the **decrypted** manifest through the production decoder (`HermesGatewayAttachmentManifest`) — the current test only byte-compares, so it never catches a schema drift. **Schedule in Phase 1** since the vector is regenerated there anyway. | `HermesGatewayWireVector.json:13` (×3), `HermesRelayCrossPlatformVectorTests.swift:255`, `FunctionsRepository.swift:982-997` |
| **MP-19** | Rewrite `test_event_with_substituted_sender_key_does_not_rotate_pin`: build a real **v2** wrap (`sender_private=phone`, `relayKeyVersion=2`), tamper only the wire `senderPublicKey`, assert content opens via the **pinned** key, the pin is unchanged, and a warning is logged. Today it builds a v1 wrap and its comment ("Event opens") is false — it's dropped at the version gate. (6/7 consensus.) | `test_burnbar_plugin.py:702-729` |
| **MP-20** | `import binascii`; catch `(ValueError, binascii.Error)`; drop the `# type: ignore[attr-defined]`. `base64.binascii.Error` relies on an undocumented re-export (the type-checker already flags it). | `relay_e2ee.py:409/459/510/592` |
| **MP-21** | Decide + enforce the post-open pin-guard policy: the return value of `_pin_peer_public_key` is ignored (`adapter.py:782-786`). Either hard-drop on mismatch (return None / raise) or keep accept-but-warn and **document** that the wire `senderPublicKey` is advisory (crypto already authenticated via the pinned key). Covered by the MP-19 test. | `adapter.py:782-786` |
| **MP-22** | `_relay_safety_code` silently falls back to hashing the raw base64 *string* on invalid input (`adapter.py:129-130`); Swift does the same (`HermesGatewayRelayKeypair.swift:308`). Return empty / raise instead so a corrupt key can't yield a plausible-looking code. (Fold into MP-1's rewrite.) | `adapter.py:129-130` |
| **MP-23** | Add `test_refuses_v1_wrapped_event_on_e2e_link`: a v1 wrap + omitted `relayKeyVersion` on an E2E link → `received == []`. Guards against regressing the v2 gate (library still exposes v1). | `test_burnbar_plugin.py` (new) |
| **MP-24** | Put `tests/gateway/test_relay_e2ee_v2.py` in the README test command; ensure all v2 negative tests pass `sender_public_base64`. | `README.md`, `test_relay_e2ee.py` |
| **MP-25** | Narrow `RELAY_CRYPTO_AVAILABLE`'s guard from `except Exception` to `except ImportError` so a real crypto bug isn't masked as "crypto unavailable" → plaintext path. | `adapter.py:44` |
| **MP-26** | No change. Hardcoded `https://api.burnbar.ai/...` default is overridable via `BURNBAR_API_BASE_URL` and consistent with other vendor plugins. Mention in the PR description. | `adapter.py:53` |

---

## 5. Workflow implementation plan (phased, gated)

Designed for a deterministic multi-agent workflow. Each phase ends with a **gate**
that must be green before the next begins. Cross-language fixes fan out per
language surface but **converge on the shared wire vector**.

### Phase 0 — Baseline & branch hygiene (serial)  *(satisfies MP-4 setup)*
1. Snapshot current green baseline:
   `cd ~/.hermes/hermes-agent && venv/bin/python -m pytest tests/gateway/test_relay_e2ee.py tests/gateway/test_relay_e2ee_v2.py tests/gateway/test_burnbar_plugin.py -q` (expect `99 passed`).
2. Run the BurnBar-side suites to record their baseline (Swift `OpenBurnBarCoreTests` Hermes vectors, Android `HermesGatewayV2VectorTest`, `functions` jest incl. the new `hermesGatewayAttachmentInit.test.ts`).
3. Confirm the two adapter copies are identical (`diff -q`). **Gate:** all baselines green + diff clean.

### Phase 1 — P1 wire-contract & crypto fixes (one coordinated phase — the contract moves)
Fan out, then converge on the vector:
- **1a (Python):** MP-2 **both halves** (`body["messageId"]` in `_post_message` + `body["attachmentId"]` in `_init_attachment`, with retry idempotency/409 handling), MP-3+MP-7 (record-after-auth, atomic, idless reject), MP-1 Python half (two-key code, **≥128-bit**, confirm gate), MP-6 (drop `summary` from `/approvals` body; add `actionId` to sealed follow-up), MP-22.
- **1b (Swift):** MP-1 Swift half (`safetyCode(agentKey:phoneKey:)` widened, `agentSafetyCode`, pin-store migration), MP-27 (decode sealed `{text, actionId?, kind?}` schema), MP-6 phone (join sealed detail→approval by `actionId`), MP-18 emitter change.
- **1c (Android):** MP-1 Android (net-new safety-code derivation + pairing display, ≥128-bit), MP-27 (Kotlin sealed-payload decode).
- **1d (functions):** MP-28 (require `relayEnvelope.relayKeyVersion===2` on new gateway writes); confirm MP-2 server adoption for messages (`safeIdentifier`) AND attachments (`adoptedGatewayDocId`); MP-6 server already done (verify).
- **1e (converge):** regenerate `HermesGatewayWireVector.json` from the Swift emitter with `fileName` manifest (MP-18) and the sealed-message schema (MP-27); copy byte-identical to all three fixture locations; sync both adapter copies (`diff -q`).
- **Gate:** Python 99+new green; Swift/Kotlin/functions suites green; vector sha256-identical across all three; **message AND attachment round-trip mismatch tests** pass; MP-1 two-key/≥128-bit tests pass; MP-6 no-leak + approval-correlation tests pass; MP-28 v1-write-rejection test passes.

### Phase 2 — P2 hardening (parallel, mostly Python adapter + functions)
MP-5, MP-8, MP-9, MP-10, MP-11, MP-12, MP-13, MP-14, MP-15, MP-16, MP-17.
- MP-10/MP-12 touch the contract again → regenerate + re-pin the vector and rerun all three suites at the end of this phase.
- MP-17 is a branch/PR-structure task (extract or flag the shared-core diffs).
- **Gate:** all suites green; vector re-pinned; `diff -q` clean; new tests for MP-8 (authz ignores raw metadata), MP-9 (runtime can't change AAD context), MP-13 (delimiter rejection), MP-10 (full-JSON cross-language).

### Phase 3 — P3 polish & test fidelity (parallel)
MP-19, MP-20, MP-21, MP-23, MP-24, MP-25, MP-26 (doc only). **Gate:** suites green; the rewritten MP-19 test genuinely opens a v2 frame and asserts the pinned-key behavior.

### Phase 4 — Submission integrity & adversarial re-review (serial)  *(satisfies MP-4)*
1. Commit everything onto `ajnunezg/burnbar-gateway-e2ee` (+ `pr1` as appropriate); drop unrelated untracked files.
2. From a **clean checkout**, run the canonical pytest command; byte-verify the fixture; `git diff --check` both branch ranges.
3. Re-run a focused adversarial security pass against the diff (the same surfaces: pairing MITM, replay, attachment AAD, fail-closed, downgrade) to confirm each P1/P2 is actually closed — not just edited.
4. **Gate / Definition of Done** (below).

---

## 6. Definition of Done (the bar)

- [ ] All four P1s (MP-1, MP-2, MP-3, MP-6) closed with a test that **fails before
      the fix and passes after**.
- [ ] Every P2 closed or explicitly justified in writing.
- [ ] Safety code is a function of **both** keys on Mac, iOS, **and** Android;
      swapping either key changes the displayed code (test-proven).
- [ ] A sealed **message** AND a sealed **attachment** each round-trip
      Mac→Cloud→phone in an integration test where the server id would differ from
      the agent's AAD id unless the agent sends it (MP-2, both halves), and the
      phone parses the `{"text":...}` payload to readable text (MP-27).
- [ ] New gateway writes are rejected by the server unless
      `relayEnvelope.relayKeyVersion===2` (MP-28).
- [ ] The displayed safety code is ≥128 bits and binds both keys (MP-1).
- [ ] A 4096-forged-id flood does not evict a legitimate event id (MP-3).
- [ ] `/approvals` body proven to carry no free text (MP-6).
- [ ] Wire vector is sha256-identical across hermes-agent / OpenBurnBarCore /
      android fixtures, uses the production `fileName` manifest, and is opened by
      all three languages incl. forge-reject + v1-downgrade-reject.
- [ ] Both adapter copies byte-identical (`diff -q`), enforced by a check.
- [ ] `relay_e2ee.py` documents goals/non-goals/KCI (MP-16).
- [ ] Canonical pytest passes from a **clean checkout** of the PR branch (MP-4);
      Swift/Kotlin/functions suites green.
- [ ] PR description calls out the shared-core changes (MP-17) and the vendor
      default (MP-26).

---

## 7. SOTA scorecard (current reviewed artifact, pre-remediation)

| Dimension | Score /10 | Rationale |
|---|---|---|
| Crypto construction quality | **9** | Sound 2-DH AuthEncap, correct domain separation, genuine cross-language byte-exact interop. Loses a point only for custom-vs-library framing (documentable). |
| Engineering / fail-closed rigor | **7** | Open path is genuinely fail-closed and v2-only; let down by the replay ordering bug (MP-3) and the silent identity-rotation (MP-14). |
| Trust model / threat resistance | **3** | The flagship claims (confidentiality + unforgeability) currently rest on a first pin an untrusted relay can substitute (MP-1). This is the gap between "looks E2EE" and "is E2EE." |
| Product correctness (does it work) | **2** | **Round-2: the entire agent→phone E2EE channel is broken today** — sealed replies AND attachments are undecryptable on device (MP-2, both halves), and even if they decrypted the phone wouldn't parse the JSON (MP-27). Plaintext-downgrade at pairing is relay-electable (MP-5). |
| Test meaningfulness | **6** | Crypto vector + forge tests are excellent; but the headline tests mask MP-2 and MP-3, and one test's comment is false (MP-19). |
| Release readiness | **2** | The reviewed v2 work isn't on the PR branch (MP-4). |

**Post-remediation target:** trust model 8–9, product correctness 9,
release readiness 9 — at which point this is a legitimately submit-worthy,
Signal-grade-rooted E2EE relay integration.

---

## 8. Final recommendation

**HOLD now; clear to submit after Phase 4.** The cryptographic engine is strong
enough to build on — the work is to fix the trust root (MP-1), make the product
actually function (MP-2, MP-3, MP-6), harden the relay-adversarial edges
(MP-5/8/9/10/11/12/13/14), document the boundary honestly (MP-16), and ship the
artifact that was actually reviewed (MP-4). None of these require re-architecting
the crypto; all are within reach in a single coordinated workflow run.
