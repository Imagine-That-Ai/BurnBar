# BurnBar Relay HPKE v3 Migration Plan

## Goal

Replace the bespoke v2 authenticated relay key wrap with a standards-shaped
RFC 9180 HPKE Auth mode v3 key wrap while keeping the existing v2 gateway
stable during migration.

## Success Criteria

- Python, Swift, and Kotlin use one documented v3 ciphersuite and wire shape.
- The Hermes gateway emits v3 when a paired peer advertises v3 capability.
- The Hermes gateway opens v3 with the pinned sender key and rejects forged,
  downgraded, plaintext, and unauthenticated envelopes on paired links.
- Existing v2 fixtures and tests remain green.
- New v3 fixtures prove Swift-to-Python interop for events, replies,
  model switches, and attachments with current payload schema fields.
- Maintainer-facing docs state the exact threat model, metadata limits, KCI
  limit, replay-counter boundary, and first-pairing safety-code requirement.

## Stop Condition

Stop when the v3 implementation, cross-language vectors, docs, and adversarial
review all pass, and the PR stack is reviewable against the Nous Research
upstream base without unrelated churn.

## Orchestration Model

Codex is the tmux orchestrator. Every implementation workstream runs through
Claude with the literal keyword `ultracode` in the launch prompt so the
Claude-side swarm profile activates.

Use one tmux session:

```bash
cd /Users/albertonunez/Documents/Windsurf/BurnBar
tmux new-session -d -s burnbar-hpke-v3 -n orchestrator
tmux new-window -t burnbar-hpke-v3 -n python
tmux new-window -t burnbar-hpke-v3 -n swift
tmux new-window -t burnbar-hpke-v3 -n kotlin
tmux new-window -t burnbar-hpke-v3 -n vectors
tmux new-window -t burnbar-hpke-v3 -n recon
tmux new-window -t burnbar-hpke-v3 -n architecture
tmux new-window -t burnbar-hpke-v3 -n tests
tmux new-window -t burnbar-hpke-v3 -n docs
tmux new-window -t burnbar-hpke-v3 -n integration
tmux new-window -t burnbar-hpke-v3 -n regression
tmux new-window -t burnbar-hpke-v3 -n security
tmux new-window -t burnbar-hpke-v3 -n release
```

Use this Claude launch shape in each workstream window:

```bash
claude "ultracode: read <agent-plan-file>, execute its Goal, Success means, Stop when, and Constraints exactly. Report files changed, tests run, command results, blockers, and residual risk."
```

The orchestrator reads worker outputs, resolves conflicts, preserves unrelated
dirty-tree changes, runs final tests, and stages only the reviewed HPKE v3
migration files.

## Chosen Protocol

Use HPKE as an authenticated key-wrap replacement only. Keep the existing
payload and attachment AES-GCM sealing layers unchanged so the migration is
limited to the content-key wrap.

Suite:

```text
Mode: Auth
KEM:  DHKEM(P-256, HKDF-SHA256)
KDF:  HKDF-SHA256
AEAD: AES-256-GCM
```

Wire markers:

```text
relayKeyVersion = 3
relayEncryption = "hpke-auth-p256-hkdfsha256-aes256gcm"
```

HPKE context:

```text
info = "OpenBurnBar-HermesRelay-HPKE-v3|" || key_aad
aad  = key_aad
pt   = 32-byte content key
ct   = HPKE Auth seal(pt, aad)
```

Envelope additions:

```json
{
  "relayKeyVersion": 3,
  "relayEncryption": "hpke-auth-p256-hkdfsha256-aes256gcm",
  "enc": "<base64 HPKE encapsulated key>",
  "wrappedKey": "<base64 HPKE ciphertext over the 32-byte content key>",
  "senderPublicKey": "<base64 X9.63 sender public key for diagnostics>"
}
```

Authentication rule:

```text
open_v3(recipient_private, pinned_sender_public, enc, wrappedKey, key_aad)
```

The recipient binds `pinned_sender_public`. The relay-visible
`senderPublicKey` field is retained for diagnostics and vector readability, and
the open path uses the pinned value as the authenticated sender key.

## Implementation Workstreams

### 0. Reconnaissance Agent

Launch through Claude from the tmux `recon` window with the `ultracode`
keyword and `plans/agents/burnbar-hpke-v3-recon-agent.md`.

Map current Python, Swift, Kotlin, fixture, and docs seams before implementation
edits start. Return exact file ownership boundaries and any discovered
dependency or API constraints.

### 0.5. Architecture Guard Agent

Launch through Claude from the tmux `architecture` window with the `ultracode`
keyword and `plans/agents/burnbar-hpke-v3-architecture-agent.md`.

Freeze the v3 wire contract, capability negotiation, compatibility policy, and
security invariants so implementation workers converge on one design.

### 1. Python Hermes Agent

Launch through Claude from the tmux `python` window with the `ultracode`
keyword and `plans/agents/burnbar-hpke-v3-python-agent.md`.

Build a minimal RFC 9180 HPKE Auth key-wrap module using the existing
`cryptography` primitives. Keep the v3 code adjacent to the current relay E2EE
module and expose typed helpers such as:

```python
seal_key_v3(
    *,
    key: bytes,
    recipient_public_key: RelayPublicKey,
    sender_private_key: RelayPrivateKey,
    aad: bytes,
) -> RelayKeyWrapV3

open_key_v3(
    *,
    enc: bytes,
    wrapped_key: bytes,
    recipient_private_key: RelayPrivateKey,
    pinned_sender_public_key: RelayPublicKey,
    aad: bytes,
) -> bytes
```

Wire v3 into the BurnBar adapter capability path:

- Send v3 when the authenticated pairing grant or stored peer capability says
  the phone supports v3.
- Open v3 when `relayKeyVersion == 3`.
- Keep v2 open for paired peers that only advertise v2.
- Keep v1 and plaintext refused on paired links.
- Keep the replay high-water mark and routing-id pinning behavior unchanged.

### 2. Swift BurnBar Client

Launch through Claude from the tmux `swift` window with the `ultracode` keyword
and `plans/agents/burnbar-hpke-v3-swift-agent.md`.

Implement the same HPKE Auth v3 key wrap with byte-exact field names,
point encoding, `info`, and AAD. Emit the canonical fixture set from Swift so
Python proves real cross-language interop instead of Python-only round trips.

### 3. Kotlin Android Parity

Launch through Claude from the tmux `kotlin` window with the `ultracode`
keyword and `plans/agents/burnbar-hpke-v3-kotlin-agent.md`.

Audit whether Android participates in this relay path for the current release.
If it does, implement the same v3 suite and consume the same vectors. If it
does not, add a short parity note in the Android plan file that names the
release gate for adding Kotlin v3 before Android emits gateway traffic.

### 4. Vector Harness

Launch through Claude from the tmux `vectors` window with the `ultracode`
keyword and `plans/agents/burnbar-hpke-v3-vector-agent.md`.

Create a v3 fixture suite generated outside Python and verified by Python. Each
positive vector includes:

- event
- agent reply/message
- model switch
- attachment manifest
- attachment body key

Each negative vector mutates one authenticated input and must fail:

- pinned sender public key
- recipient private key
- `key_aad`
- `enc`
- `wrappedKey`
- `relayKeyVersion`
- `relayEncryption`

### 4.5. Dedicated Test Agent

Launch through Claude from the tmux `tests` window with the `ultracode` keyword
and `plans/agents/burnbar-hpke-v3-test-agent.md`.

Build or harden tests around the final implementation without owning core
crypto code. Coordinate with implementation workers before editing the same test
files.

### 5. Security Review

Launch through Claude from the tmux `security` window with the `ultracode`
keyword and `plans/agents/burnbar-hpke-v3-security-review-agent.md` after the
implementation tests pass.

Run a fresh adversarial review after implementation. The review must verify:

- RFC 9180 schedule and labels
- Auth mode sender binding
- v3/v2 domain separation
- v1 downgrade rejection
- plaintext refusal on paired links
- routing-id pinning
- replay counter enforcement
- attachment AAD binding
- KCI and metadata limits in docs

### 6. Release and Upstream Packaging

Launch through Claude from the tmux `release` window with the `ultracode`
keyword and `plans/agents/burnbar-hpke-v3-release-agent.md` after security
review clears blocking findings.

Update the PR narrative to lead with the standards answer:

```text
v3 uses RFC 9180 HPKE Auth mode for relay key wrapping. v2 remains supported
for compatibility with existing BurnBar clients and fixtures.
```

Keep the stacked PR shape:

- PR 1: BurnBar platform plugin, crypto-free.
- PR 2: relay E2EE, v2 compatibility, v3 HPKE Auth migration, fixtures, docs.

### 7. Documentation Agent

Launch through Claude from the tmux `docs` window with the `ultracode` keyword
and `plans/agents/burnbar-hpke-v3-docs-agent.md`.

Update user-facing and maintainer-facing documentation after implementation
lands. Keep docs scoped to behavior that actually ships.

### 8. Integration Agent

Launch through Claude from the tmux `integration` window with the `ultracode`
keyword and `plans/agents/burnbar-hpke-v3-integration-agent.md`.

Review worker output, reconcile overlaps, remove duplication, and keep naming,
errors, docs, and tests consistent.

### 9. Regression QA Agent

Launch through Claude from the tmux `regression` window with the `ultracode`
keyword and `plans/agents/burnbar-hpke-v3-regression-agent.md`.

Run the final targeted regression matrix across BurnBar and Hermes surfaces and
return a concise pass/fail evidence report.

## Acceptance Commands

Run the existing gateway suite:

```bash
cd /Users/albertonunez/.hermes/hermes-agent
venv/bin/python -m pytest \
  tests/gateway/test_relay_e2ee.py \
  tests/gateway/test_relay_e2ee_v2.py \
  tests/gateway/test_burnbar_plugin.py \
  -q
```

Add and run the new v3 suite:

```bash
cd /Users/albertonunez/.hermes/hermes-agent
venv/bin/python -m pytest \
  tests/gateway/test_relay_e2ee_v3.py \
  tests/gateway/test_burnbar_plugin.py \
  -q
```

Run vector verification:

```bash
cd /Users/albertonunez/.hermes/hermes-agent
venv/bin/python -m pytest tests/gateway/test_burnbar_hpke_v3_vectors.py -q
```

## Review Bar

Score the work at 9 or 10 only when:

- A reviewer can point at RFC 9180 instead of a bespoke KEM.
- Cross-language vectors cover the current production schema.
- The open path binds only pinned sender keys.
- v1 and plaintext are unreachable on paired links.
- Replay counters remain mandatory for sealed inbound events.
- Docs state metadata, KCI, static-key, and safety-code limits plainly.
