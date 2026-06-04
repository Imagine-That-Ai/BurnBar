# BurnBar HPKE v3 Kotlin Agent Prompt

Goal: Establish Android/Kotlin parity for the BurnBar relay HPKE v3 key wrap or
document why Android is outside the current gateway release path.

Claude launch: run this workstream through Claude from the tmux `kotlin`
window with the literal keyword `ultracode` in the prompt.

Success means:

- If Android emits or opens Hermes gateway traffic, Kotlin implements the same
  RFC 9180 HPKE Auth v3 suite and consumes the shared vector suite.
- If Android is outside the current release path, the handoff names the exact
  gate that must be satisfied before Android gateway traffic ships.
- Kotlin uses the same field names, X9.63 P-256 point encoding, `info`, AAD,
  and version markers as Python and Swift.
- Kotlin rejects wrong sender, wrong recipient, wrong AAD, mutated `enc`, and
  mutated `wrappedKey`.

Stop when:

- Android/Kotlin v3 unit tests pass, or the no-op parity proof is written with
  the release gate and owner.
- The shared fixture status is recorded for Android.

Constraints:

- Use `relayKeyVersion = 3` and
  `relayEncryption = "hpke-auth-p256-hkdfsha256-aes256gcm"`.
- Use `info = "OpenBurnBar-HermesRelay-HPKE-v3|" || key_aad`.
- Use HPKE Auth mode with the pinned sender key.
- Keep Android field names byte-compatible with the shared JSON fixtures.

## Context

Hermes upstream review can accept staged client parity if the release boundary
is explicit. It will read poorly if a partial Android crypto path exists without
tests or if Android silently emits a different variant.

## Implementation Path

1. Search the Android source for Hermes gateway relay crypto, BurnBar relay
   envelopes, and current vector tests.
2. Decide from code evidence whether Android participates in this relay path
   for the current release.
3. If Android participates, implement v3 key wrap and fixture verification.
4. If Android is out of scope, create a short no-op note in the handoff that
   names:
   - current Android gateway state
   - release gate for enabling Android v3
   - files that future work must update
   - shared vector fixture Android must consume
5. Run the relevant Android test command or record why no Android test target
   applies.

## Test Requirements

For an active Android path, add tests for:

- Swift/Python fixture open
- Kotlin-generated fixture open by Python
- wrong pinned sender rejection
- wrong recipient rejection
- wrong AAD rejection
- mutated envelope field rejection
- v2 compatibility if Android currently supports v2

## Handoff Output

Return:

- Android participation decision
- files changed or no-op proof path
- tests run
- vector fixture status
- release gate for Android parity
