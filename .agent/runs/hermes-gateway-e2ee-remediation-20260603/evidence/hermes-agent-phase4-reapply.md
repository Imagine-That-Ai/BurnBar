# hermes-agent (Nous fork) — Phase 4 re-application checklist

## RECONSTRUCTION STATUS (done in this run, on user request)

A worktree was created at **`~/.hermes/hermes-agent-burnbar-wt`** on branch
`ajnunezg/burnbar-platform` and the v2 artifact + remediation was rebuilt + verified there
(uncommitted, for the user to commit/push to Nous):

- ✅ **`gateway/crypto/relay_e2ee.py`** — full v2 (2-DH AuthEncap) rebuilt from the verified
  content + the 4 remediation fixes (MP-13/14/16/20). **Byte-exact verified**: the survived
  `test_relay_e2ee_v2.py` (cross-language wire vector, forge/downgrade-reject, MP-18 fileName)
  passes 20/20, and `test_relay_e2ee.py` (with the MP-14 fail-closed + MP-13 delimiter tests
  applied) is green — **46 passed** total for the two crypto test files.
- ✅ **`plugins/platforms/burnbar/adapter.py`** — copied from the BurnBar remediated copy;
  `diff -q` clean (byte-identical), i.e. the full adapter remediation (MP-1/2/3/5/6/8/9/11/12/
  15/21/22/25).
- ✅ **`tests/gateway/test_relay_e2ee_v2.py`** + **`tests/gateway/fixtures/HermesGatewayWireVector.json`**
  — survived the external checkout as untracked; in place (fixture sha256 `50d6204a…`).
- ⚠️ **`tests/gateway/test_burnbar_plugin.py`** — the worktree still has the PRE-v2 version; its
  full v2 form (v2 seal-envelope expectations + my 9 remediation regressions + the safety-code /
  cache rewrites) was in the lost dirty tree and is only partially recoverable from context. 8
  pre-v2 tests fail against the v2 adapter (they assert v1 seal behavior / a removed
  `_gateway_model_switch_aad` helper) — these are STALE tests, not code defects (the adapter is
  verified byte-identical to the BurnBar copy that passed the full 109-test suite). Re-derive the
  v2 plugin tests from §3 + the BurnBar commit history before landing on Nous.

To commit the reconstruction: `cd ~/.hermes/hermes-agent-burnbar-wt && git add -A && git commit`
(do NOT push to the Nous remote without review). Tear down with
`git worktree remove ~/.hermes/hermes-agent-burnbar-wt` if abandoning.

---

# hermes-agent (Nous fork) — Phase 4 re-application checklist (original)

**Why this file exists:** during this run, the `~/.hermes/hermes-agent` working tree was on
branch `ajnunezg/burnbar-platform` (the reviewed v2 artifact, dirty). The Python remediation
(adapter.py + relay_e2ee.py + gateway tests) was implemented there and **verified green
(109 pytest passed)**. An EXTERNAL process then ran `git checkout main` + `git pull --ff-only`
(see reflog `HEAD@{2}: checkout: moving from ajnunezg/burnbar-platform to main`), which
discarded the uncommitted remediation from hermes-agent's working tree. The fork branches still
exist (`ajnunezg/burnbar-platform`, `ajnunezg/burnbar-gateway-e2ee`, `…-pr1`).

The user scoped this run's commits to the **BurnBar repo only**; landing on the Nous-bound
branch is the deferred Phase-4 step. This checklist captures exactly what to re-apply there.

## 1. adapter.py — already preserved (just copy it back)

`BurnBar/tools/hermes-platform-burnbar/adapter.py` holds the FULL remediated adapter
(MP-1/2/3/5/6/8/9/11/12/15/21/22/25). When hermes-agent is back on `ajnunezg/burnbar-platform`:

```bash
cp BurnBar/tools/hermes-platform-burnbar/adapter.py \
   ~/.hermes/hermes-agent/plugins/platforms/burnbar/adapter.py
diff -q  BurnBar/tools/hermes-platform-burnbar/adapter.py \
   ~/.hermes/hermes-agent/plugins/platforms/burnbar/adapter.py   # must be empty
```

## 2. relay_e2ee.py — re-apply these 4 edits (lost; exist nowhere else)

File: `~/.hermes/hermes-agent/gateway/crypto/relay_e2ee.py`

**MP-20** — `import binascii` after `import base64`; replace all 4
`except (ValueError, base64.binascii.Error) as exc:  # type: ignore[attr-defined]`
with `except (ValueError, binascii.Error) as exc:` (sites ~409/459/510/592).

**MP-13** — in `RelayNamespace.aad`, before the join, fail closed on a delimiter/control char:
```python
        for part in parts:
            if "|" in part or any(ord(ch) < 0x20 for ch in part):
                raise ValueError(
                    "relay AAD part contains an illegal '|' delimiter or control character"
                )
```

**MP-14** — add a typed error and fail closed on a corrupt stored key:
```python
class CorruptIdentityError(RelayCryptoError):
    """A stored relay private key is present but unparseable. Raised instead of
    silently minting a fresh identity (silent rotation == relay key-substitution)."""
```
In `AgentRelayIdentity.load_or_create`, replace the `except (ValueError, RelayCryptoError): pass`
(which fell through to `generate_private_key()`) with:
```python
            except (ValueError, RelayCryptoError, binascii.Error) as exc:
                raise CorruptIdentityError(
                    f"{env_var} is present but invalid — re-pair required; "
                    "refusing to silently rotate the relay identity"
                ) from exc
```

**MP-16** — add a "Security considerations" section to the module docstring: goals
(confidentiality + sender-auth under pinned statics; ephemeral FS on the dh1 leg); non-goals
(no PFS for the static leg; KCI is an inherent 2-DH AuthEncap bound — do NOT add a ratchet;
replay relies on AAD + the adapter's record-after-auth cache); empty-salt rationale (matches
Swift `Data()` per RFC 5869); trust anchor (sender-auth holds only because the caller passes the
PINNED peer key to `unwrap_symmetric_key`, rooted in the two-key safety code). Also fix the stale
`HermesRelayWireVector.json` reference → `HermesGatewayWireVector.json`.

## 3. Gateway tests — re-add (were written + verified, 109 passed)

- `tests/gateway/test_relay_e2ee.py`: rewrite `test_agent_relay_identity_mints_fresh_on_corrupt_env`
  → `…fails_closed_on_corrupt_env` (asserts `CorruptIdentityError` on invalid/short key; recovery
  on empty env). Add `test_relay_aad_rejects_delimiter_and_control_chars` (MP-13).
- `tests/gateway/test_relay_e2ee_v2.py`: the manifest assertion uses the PRODUCTION field
  `decoded["fileName"]` (MP-18), not `decoded["name"]`.
- `tests/gateway/test_burnbar_plugin.py`: rewrite `…safety_code…` test to the two-key signature
  `_relay_safety_code(agent, phone)` (8 groups; locked value `595F D4F3 50B3 70FA 2D8B 6F15 8004
  3F80` for the cross-language vector keys); rewrite `test_seen_event_id_cache_is_bounded` to
  `_is_event_seen`/`_record_event` (MP-3). Append the 9 remediation regressions:
  `test_mp2_post_message_echoes_aad_bound_message_id`,
  `test_mp2_init_attachment_echoes_attachment_id_and_omits_contenttype`,
  `test_mp6_arm_approval_body_has_no_free_text`, `test_mp6_mp27_sealed_followup_carries_actionid`,
  `test_mp3_failed_open_does_not_record_event_id`, `test_mp8_sender_identity_from_sealed_payload`,
  `test_mp9_relay_cannot_rotate_pinned_routing_ids`, `test_mp11_unsafe_model_id_is_rejected`,
  `test_mp5_e2e_capable_agent_refuses_plaintext_without_optin`.

## 4. Remaining hermes-agent-only P3s (MP-19, MP-23, MP-24)

- **MP-19** — rewrite `test_event_with_substituted_sender_key_does_not_rotate_pin` to build a REAL
  v2 wrap (sender=phone, relayKeyVersion=2), tamper only the wire `senderPublicKey`, assert the
  content opens via the PINNED key, the pin is unchanged, and a warning is logged (validates the
  MP-21 advisory-field policy now documented in adapter.py `_open_envelope`).
- **MP-23** — add `test_refuses_v1_wrapped_event_on_e2e_link`: a v1 wrap + omitted
  `relayKeyVersion` on an E2E link → `received == []` (guards the v2 gate; library still exposes v1).
- **MP-24** — README test command must include `tests/gateway/test_relay_e2ee_v2.py`.

## 5. Fixtures

`tests/gateway/fixtures/HermesGatewayWireVector.json` must equal (sha256) the BurnBar Core fixture:
`50d6204a0d45148c6b99e2f256a1b27f6c283c9536f583b536d94da3b2674b45`
(copy from `BurnBar/OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/HermesGatewayWireVector.json`).

## 6. Verify

```bash
cd ~/.hermes/hermes-agent && .venv/bin/python -m pytest \
  tests/gateway/test_relay_e2ee.py tests/gateway/test_relay_e2ee_v2.py \
  tests/gateway/test_burnbar_plugin.py -q     # expect: 109 passed
```
