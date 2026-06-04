"""Agent-side (Python adapter) remediation regression tests — VERBATIM, durable copy.

WHY THIS FILE EXISTS: the audit correctly flagged that the agent-side P1 fixes
(MP-2 id round-trip, MP-3 record-after-auth, MP-6 no-free-text) have NO committed
fails-before/passes-after regression test, because the Python gateway tests live
only in the hermes-agent fork — whose working tree was wiped by an external
`git checkout main` mid-run. These tests WERE written + verified (part of the
`109 passed` run) and are reproduced here byte-for-byte so they are not lost again.

HOW TO LAND (Phase 4, on the Nous-bound fork branch):
  1. Append the test functions below into tests/gateway/test_burnbar_plugin.py.
  2. Add `import base64` to that file's imports, AND
     `_relay_safety_code = _burnbar._relay_safety_code` to the `_burnbar.*` import block
     (the pre-v2 file does not bind it). VERIFIED: with both imports added, all 11
     functions below pass against the v2 adapter in the reconstruction worktree
     (`pytest -k "two_key_signal_style or seen_event_id_cache or mp2_ or mp3_ or mp5_
     or mp6_ or mp8_ or mp9_ or mp11_"` → 11 passed).
  3. REPLACE the stale single-key `test_relay_safety_code_matches_burnbar_mobile_derivation`
     with `test_relay_safety_code_is_two_key_signal_style_and_128_bit` (below).
  4. REPLACE the stale `test_seen_event_id_cache_is_bounded` (which calls the removed
     `_event_already_seen`) with the version below (uses `_is_event_seen`/`_record_event`).
  5. Run: cd ~/.hermes/hermes-agent && .venv/bin/python -m pytest \
       tests/gateway/test_relay_e2ee.py tests/gateway/test_relay_e2ee_v2.py \
       tests/gateway/test_burnbar_plugin.py -q   # target: 109 passed

These exercise the SAME `_burnbar`/`relay_e2ee`/`_e2e_adapter`/`_legacy_adapter`/
`_RecordingClient`/`_FakeResponse`/`requires_relay` scaffolding already in
test_burnbar_plugin.py. The crypto-side MP-13/MP-14 tests were already re-applied to
test_relay_e2ee.py in the worktree (46 passed).
"""

# === REPLACEMENT: two-key safety code (was the stale single-key test) ===========


def test_relay_safety_code_is_two_key_signal_style_and_128_bit():
    """MP-1: the safety code hashes BOTH paired keys, is role-independent, >=128
    bits wide, and fails closed on invalid input (MP-22)."""
    agent = "AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4/QEE="
    phone = "QkNERUZHSElKS0xNTk9QUVJTVFVWV1hZWltcXV5fYGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn+AgYI="
    code = _relay_safety_code(agent, phone)
    # Locked cross-language value (Swift + Kotlin must derive the identical code):
    # SHA-256(sorted([agentRaw, phoneRaw]).joined())[:16] as 8 uppercase hex groups.
    assert code == "595F D4F3 50B3 70FA 2D8B 6F15 8004 3F80"
    assert len(code.split()) == 8  # >=128 bits displayed (was 64 bits / 4 groups)
    # Role-independent: sorting the raw key bytes makes both ends agree on the code
    # regardless of which key is "agent" vs "phone".
    assert _relay_safety_code(phone, agent) == code
    # Swapping EITHER key changes the code — this is the single-key MITM MP-1 closes
    # (a relay substituting the phone key at first pin would otherwise still match).
    mutated = base64.b64encode(
        bytes([base64.b64decode(agent)[0] ^ 0xFF]) + base64.b64decode(agent)[1:]
    ).decode()
    assert _relay_safety_code(mutated, phone) != code
    assert _relay_safety_code(agent, mutated) != code
    # MP-22: invalid base64 or a missing key returns "" — never a plausible-looking
    # code a human would compare and wrongly accept.
    assert _relay_safety_code("not-base64!!", phone) == ""
    assert _relay_safety_code(agent, "") == ""
    assert _relay_safety_code("  ", "  ") == ""


# === REPLACEMENT: replay cache split (was the stale _event_already_seen test) ====


def test_seen_event_id_cache_is_bounded(monkeypatch, tmp_path):
    """The replay cache never grows past MAX_SEEN_EVENT_IDS, and (MP-3) recording is
    split from the read-only check so a forged-id flood cannot evict a genuine id."""
    adapter = _legacy_adapter(monkeypatch, tmp_path)
    monkeypatch.setattr(_burnbar, "MAX_SEEN_EVENT_IDS", 8)
    for i in range(50):
        assert adapter._is_event_seen(f"id-{i}") is False
        adapter._record_event(f"id-{i}")
    assert len(adapter._seen_event_ids) <= 8
    # The most recently recorded id is still considered a duplicate.
    assert adapter._is_event_seen("id-49") is True
    # MP-3: the read-only check NEVER records. Probing unseen ids (what a forged-id
    # flood does, since they all fail AEAD before _record_event) consumes no slot,
    # so it cannot evict a genuine recorded id.
    before = len(adapter._seen_event_ids)
    assert adapter._is_event_seen("never-authenticated-1") is False
    assert adapter._is_event_seen("never-authenticated-2") is False
    assert len(adapter._seen_event_ids) == before
    assert adapter._is_event_seen("id-49") is True


# === APPEND: the 9 remediation regressions ======================================


@requires_relay
@pytest.mark.asyncio
async def test_mp2_post_message_echoes_aad_bound_message_id(monkeypatch, tmp_path):
    """MP-2: the agent lifts the AAD-bound messageId to the top-level body so the
    server adopts it; a server-minted DIFFERENT id would fail the phone's AEAD."""
    from cryptography.exceptions import InvalidTag

    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(
        monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64()
    )
    adapter._client = _RecordingClient(
        post_responses={"/messages": _FakeResponse({"message": {"id": "m1"}})}
    )

    assert (await adapter.send("burnbar:home", "secret reply")).success is True
    _, body = adapter._client.posts[-1]
    env = body["relayEnvelope"]
    assert body["messageId"] == env["messageId"]

    # Rebuilding the AAD from a DIFFERENT (server-minted) id fails AEAD — exactly the
    # breakage MP-2 closes by echoing the agent's id.
    with pytest.raises(InvalidTag):
        relay_e2ee.unwrap_symmetric_key(
            env["wrappedKey"],
            phone_priv,
            _burnbar._gateway_message_key_aad("uid-1", "client-1", "msg_server_minted_different"),
            sender_public_base64=env["senderPublicKey"],
        )


@requires_relay
@pytest.mark.asyncio
async def test_mp2_init_attachment_echoes_attachment_id_and_omits_contenttype(monkeypatch, tmp_path):
    """MP-2: the agent echoes the AAD-bound attachmentId so the server adopts it;
    MP-12: the real contentType is never sent plaintext on the sealed path."""
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(
        monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64()
    )
    f = tmp_path / "report.pdf"
    f.write_bytes(b"%PDF-1.4 secret contents")
    adapter._client = _RecordingClient(post_responses={
        # Faithful server: adopt the client-supplied attachmentId (adoptedGatewayDocId).
        "/attachments/init": lambda b: _FakeResponse(
            {"attachment": {"id": b["attachmentId"]}, "uploadURL": "https://up/x"}
        ),
        "/attachments/finalize": _FakeResponse({}),
        "/messages": _FakeResponse({"message": {"id": "m1"}}),
    })

    assert (await adapter.send_document("burnbar:home", str(f), caption="here")).success is True
    init_body = next(b for (u, b) in adapter._client.posts if u.endswith("/attachments/init"))
    assert init_body["attachmentId"] == init_body["relayEnvelope"]["attachmentId"]
    assert "contentType" not in init_body  # MP-12: real media type stays sealed


@requires_relay
@pytest.mark.asyncio
async def test_mp6_arm_approval_body_has_no_free_text(monkeypatch, tmp_path):
    """MP-6: the /approvals control-plane body carries only the opaque actionId +
    coarse toolName + destination — never free text the untrusted relay could read."""
    adapter, _agent = _e2e_adapter(
        monkeypatch, tmp_path, peer_public_key=relay_e2ee.generate_private_key().public_key_base64()
    )
    adapter._client = _RecordingClient(post_responses={"/approvals": _FakeResponse({})})
    assert await adapter._arm_approval(action_id="act_1", tool_name="Bash", destination_id="burnbar:home")
    _, body = adapter._client.posts[-1]
    assert body == {"actionId": "act_1", "toolName": "Bash", "destinationId": "burnbar:home"}
    assert "summary" not in body


@requires_relay
@pytest.mark.asyncio
async def test_mp6_mp27_sealed_followup_carries_actionid(monkeypatch, tmp_path):
    """MP-6/MP-27: the human-readable approval detail rides ENCRYPTED with the
    actionId (so the phone binds detail->gate); /approvals stays free-text-free."""
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(
        monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64()
    )
    adapter._oversight_mode = "supervised"
    adapter._client = _RecordingClient(post_responses={
        "/approvals": _FakeResponse({}),
        "/messages": _FakeResponse({"message": {"id": "m1"}}),
    })
    res = await adapter.send_slash_confirm(
        "burnbar:home", "Run command", "rm -rf /tmp/x", "sess", "act_42", None
    )
    assert res.success is True
    approvals_body = next(b for (u, b) in adapter._client.posts if u.endswith("/approvals"))
    assert "summary" not in approvals_body
    assert "rm -rf" not in json.dumps(approvals_body)

    msg_body = next(b for (u, b) in adapter._client.posts if u.endswith("/messages"))
    env = msg_body["relayEnvelope"]
    mid = env["messageId"]
    sym = relay_e2ee.unwrap_symmetric_key(
        env["wrappedKey"], phone_priv,
        _burnbar._gateway_message_key_aad("uid-1", "client-1", mid),
        sender_public_base64=env["senderPublicKey"],
    )
    opened = json.loads(relay_e2ee.open_base64(
        env["payloadCiphertext"], sym, _burnbar._gateway_message_aad("uid-1", "client-1", mid)
    ).decode())
    assert opened["actionId"] == "act_42"
    assert opened["kind"] == "approval"
    assert "rm -rf" in opened["text"]  # detail is end-to-end encrypted, not plaintext


@requires_relay
@pytest.mark.asyncio
async def test_mp3_failed_open_does_not_record_event_id(monkeypatch, tmp_path):
    """MP-3: an event that fails to authenticate must NOT record its id, so a forged-
    id flood (all failing AEAD) cannot evict a genuine pending id from the cache."""
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(
        monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64()
    )
    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture

    # A v2 frame sealed to the WRONG recipient: the agent's unwrap fails AEAD.
    wrong_recipient = relay_e2ee.generate_private_key()
    eid = "evt_forged"
    sym = relay_e2ee.generate_symmetric_key()
    payload_ct = relay_e2ee.seal_to_base64(
        json.dumps({"text": "x"}).encode(), sym,
        _burnbar._gateway_event_aad("uid-1", "client-1", eid),
    )
    wrapped = relay_e2ee.wrap_symmetric_key(
        sym, wrong_recipient.public_key_base64(),
        _burnbar._gateway_event_key_aad("uid-1", "client-1", eid),
        sender_private=phone_priv,
    )
    await adapter._handle_burnbar_event({
        "id": eid, "destinationId": "burnbar:home",
        "relayEnvelope": {
            "payloadCiphertext": payload_ct, "wrappedKey": wrapped,
            "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
            "senderPublicKey": phone_priv.public_key_base64(),
        },
    })
    assert received == []  # failed to authenticate
    key = (adapter._relay_uid, adapter._relay_client_id, eid)
    assert key not in adapter._seen_event_ids  # MP-3: id recorded only AFTER auth


@requires_relay
@pytest.mark.asyncio
async def test_mp8_sender_identity_from_sealed_payload(monkeypatch, tmp_path):
    """MP-8: on an authenticated sealed event, sender identity is taken from the
    sealed payload, never from relay-controlled top-level metadata."""
    phone_priv = relay_e2ee.generate_private_key()
    phone_pub = phone_priv.public_key_base64()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_pub)
    agent_pub = adapter._relay_public_key_base64()
    eid = "evt_mp8"
    sym = relay_e2ee.generate_symmetric_key()
    payload_ct = relay_e2ee.seal_to_base64(
        json.dumps({"text": "hi", "senderId": "real-user", "senderDisplayName": "Real"}).encode(),
        sym, _burnbar._gateway_event_aad("uid-1", "client-1", eid),
    )
    wrapped = relay_e2ee.wrap_symmetric_key(
        sym, agent_pub, _burnbar._gateway_event_key_aad("uid-1", "client-1", eid),
        sender_private=phone_priv,
    )
    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture
    await adapter._handle_burnbar_event({
        "id": eid, "destinationId": "burnbar:home",
        "senderId": "spoofed-by-relay", "senderDisplayName": "Spoofed",
        "relayEnvelope": {
            "payloadCiphertext": payload_ct, "wrappedKey": wrapped,
            "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
            "senderPublicKey": phone_pub,
        },
    })
    assert len(received) == 1
    assert received[0].source.user_id == "real-user"
    assert received[0].source.user_name == "Real"


def test_mp9_relay_cannot_rotate_pinned_routing_ids(monkeypatch, tmp_path):
    """MP-9: once uid/clientId are pinned, an untrusted runtime response cannot
    rotate them (they bind every gateway AAD)."""
    monkeypatch.setenv("BURNBAR_RELAY_UID", "uid-pinned")
    monkeypatch.setenv("BURNBAR_RELAY_CLIENT_ID", "client-pinned")
    adapter = _legacy_adapter(monkeypatch, tmp_path)
    assert adapter._relay_uid == "uid-pinned"
    adapter._absorb_relay_state({"uid": "uid-attacker", "clientId": "client-attacker"})
    assert adapter._relay_uid == "uid-pinned"
    assert adapter._relay_client_id == "client-pinned"


@pytest.mark.asyncio
async def test_mp11_unsafe_model_id_is_rejected(monkeypatch, tmp_path):
    """MP-11: a model_switch whose modelId could inject slash flags / control chars
    is dropped; a clean catalog id is accepted."""
    adapter = _legacy_adapter(monkeypatch, tmp_path)
    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture
    for i, bad in enumerate(["model --global", "-rf", "evil id", "x;y", "a" * 200]):
        await adapter._handle_burnbar_event(
            {"id": f"evt_bad_{i}", "kind": "model_switch", "modelId": bad, "destinationId": "burnbar:home"}
        )
    assert received == []
    await adapter._handle_burnbar_event(
        {"id": "evt_ok", "kind": "model_switch", "modelId": "anthropic/claude-opus-4", "destinationId": "burnbar:home"}
    )
    assert len(received) == 1
    assert received[0].text == "/model anthropic/claude-opus-4"


@requires_relay
@pytest.mark.asyncio
async def test_mp5_e2e_capable_agent_refuses_plaintext_without_optin(monkeypatch, tmp_path):
    """MP-5: an agent holding a relay identity but not E2E-paired refuses plaintext
    unless BURNBAR_ALLOW_PLAINTEXT=1 — the relay cannot elect plaintext."""
    monkeypatch.setattr(_burnbar, "CURSOR_FILE", tmp_path / "cursor.json")
    monkeypatch.setenv("BURNBAR_RELAY_PRIVATE_KEY", relay_e2ee.generate_private_key().raw_base64())
    monkeypatch.delenv("BURNBAR_RELAY_E2E", raising=False)
    monkeypatch.delenv("BURNBAR_ALLOW_PLAINTEXT", raising=False)
    cfg = PlatformConfig(enabled=True, extra={"access_token": "tok", "home_channel": "burnbar:home"})

    refusing = BurnBarAdapter(cfg)
    refusing._client = _RecordingClient(post_responses={"/messages": _FakeResponse({"message": {"id": "m1"}})})
    res = await refusing.send("burnbar:home", "would-be plaintext")
    assert res.success is False
    assert "BURNBAR_ALLOW_PLAINTEXT" in (res.error or "")
    assert refusing._client.posts == []  # nothing left the process in plaintext

    monkeypatch.setenv("BURNBAR_ALLOW_PLAINTEXT", "1")
    allowing = BurnBarAdapter(cfg)
    allowing._client = _RecordingClient(post_responses={"/messages": _FakeResponse({"message": {"id": "m2"}})})
    res2 = await allowing.send("burnbar:home", "explicit plaintext")
    assert res2.success is True
    _, body = allowing._client.posts[-1]
    assert body["text"] == "explicit plaintext"
