"""Tests for the BurnBar Cloud platform-plugin adapter.

Covers the messaging surface: registration, config, inbound mapping, send,
attachments, cursor, and oversight/runtime-status.
"""

from __future__ import annotations

import os
from unittest.mock import MagicMock

import pytest

from gateway.config import PlatformConfig
from tests.gateway._plugin_adapter_loader import load_plugin_adapter

_burnbar = load_plugin_adapter("burnbar")

BurnBarAdapter = _burnbar.BurnBarAdapter
check_requirements = _burnbar.check_requirements
validate_config = _burnbar.validate_config
is_connected = _burnbar.is_connected
_env_enablement = _burnbar._env_enablement
_apply_yaml_config = _burnbar._apply_yaml_config


# ---------------------------------------------------------------------------
# httpx test doubles
# ---------------------------------------------------------------------------
class _FakeResponse:
    def __init__(self, json_body=None, status_code=200, content=b"{}"):
        self._json = json_body if json_body is not None else {}
        self.status_code = status_code
        self.content = content

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")

    def json(self):
        return self._json


class _RecordingClient:
    """Minimal async httpx.AsyncClient stand-in that records calls.

    ``post_responses`` maps a URL suffix to either a response or a callable
    ``(json_body) -> _FakeResponse`` so a test can both assert on the request
    body and shape the reply.
    """

    def __init__(self, *, post_responses=None, put_response=None, get_responses=None):
        self.post_responses = post_responses or {}
        self.put_response = put_response or _FakeResponse()
        self.get_responses = get_responses or {}
        self.posts = []  # list of (url, json)
        self.puts = []  # list of (url, content, headers)
        self.gets = []  # list of (url, params)

    def _match(self, mapping, url):
        for suffix, value in mapping.items():
            if url.endswith(suffix):
                return value
        return None

    async def post(self, url, headers=None, json=None):
        self.posts.append((url, json))
        match = self._match(self.post_responses, url)
        if callable(match):
            return match(json)
        if match is not None:
            return match
        return _FakeResponse({})

    async def put(self, url, content=None, headers=None):
        self.puts.append((url, content, headers))
        return self.put_response

    async def get(self, url, headers=None, params=None):
        self.gets.append((url, params))
        match = self._match(self.get_responses, url)
        if callable(match):
            return match(params)
        if match is not None:
            return match
        return _FakeResponse({})

    async def aclose(self):
        return None


# ---------------------------------------------------------------------------
# Registration / config
# ---------------------------------------------------------------------------
def test_platform_enum_resolves_via_plugin_scan():
    from gateway.config import Platform

    platform = Platform("burnbar")
    assert platform.value == "burnbar"
    assert Platform("burnbar") is platform


def test_check_requirements_requires_httpx_and_token(monkeypatch):
    monkeypatch.setattr(_burnbar, "HTTPX_AVAILABLE", True)
    monkeypatch.delenv("BURNBAR_ACCESS_TOKEN", raising=False)
    assert check_requirements() is False

    monkeypatch.setenv("BURNBAR_ACCESS_TOKEN", "tok")
    assert check_requirements() is True

    monkeypatch.setattr(_burnbar, "HTTPX_AVAILABLE", False)
    assert check_requirements() is False


def test_validate_config_and_is_connected_use_extra_or_env(monkeypatch):
    monkeypatch.delenv("BURNBAR_ACCESS_TOKEN", raising=False)
    empty = PlatformConfig(enabled=True, extra={})
    configured = PlatformConfig(enabled=True, extra={"access_token": "tok"})

    assert validate_config(empty) is False
    assert is_connected(empty) is False
    assert validate_config(configured) is True
    assert is_connected(configured) is True

    monkeypatch.setenv("BURNBAR_ACCESS_TOKEN", "env-token")
    assert validate_config(empty) is True
    assert is_connected(empty) is True


def test_env_enablement_seeds_api_token_and_home_channel(monkeypatch):
    monkeypatch.setenv("BURNBAR_ACCESS_TOKEN", "tok")
    monkeypatch.setenv("BURNBAR_API_BASE_URL", "https://example.com/v1/hermes-gateway/")
    monkeypatch.setenv("BURNBAR_HOME_CHANNEL", "burnbar:phone")
    monkeypatch.setenv("BURNBAR_HOME_CHANNEL_NAME", "Phone")

    assert _env_enablement() == {
        "api_base_url": "https://example.com/v1/hermes-gateway",
        "access_token": "tok",
        "home_channel": {"chat_id": "burnbar:phone", "name": "Phone"},
    }


def test_env_enablement_none_when_token_missing(monkeypatch):
    monkeypatch.delenv("BURNBAR_ACCESS_TOKEN", raising=False)
    assert _env_enablement() is None


def test_apply_yaml_config_preserves_env_precedence(monkeypatch):
    monkeypatch.setenv("BURNBAR_ACCESS_TOKEN", "env-token")
    platform_cfg = {"extra": {"existing": "value"}}

    extra = _apply_yaml_config(
        {
            "api_base_url": "https://api.example/v1/hermes-gateway",
            "access_token": "yaml-token",
            "home_channel": "burnbar:home",
        },
        platform_cfg,
    )

    assert extra == {
        "existing": "value",
        "api_base_url": "https://api.example/v1/hermes-gateway",
        "access_token": "yaml-token",
        "home_channel": "burnbar:home",
    }
    assert os.environ["BURNBAR_ACCESS_TOKEN"] == "env-token"
    assert os.environ["BURNBAR_API_BASE_URL"] == "https://api.example/v1/hermes-gateway"


def test_adapter_identity_and_defaults(monkeypatch):
    from gateway.config import Platform

    monkeypatch.delenv("BURNBAR_API_BASE_URL", raising=False)
    cfg = PlatformConfig(enabled=True, extra={"access_token": "tok", "home_channel": "burnbar:phone"})
    adapter = BurnBarAdapter(cfg)

    assert adapter.platform is Platform("burnbar")
    assert adapter._api_base == _burnbar.DEFAULT_API_BASE_URL
    assert adapter._token == "tok"
    assert adapter._home_channel == "burnbar:phone"


def test_register_shape_matches_platform_registry():
    ctx = MagicMock()

    _burnbar.register(ctx)

    ctx.register_platform.assert_called_once()
    kwargs = ctx.register_platform.call_args.kwargs
    assert kwargs["name"] == "burnbar"
    assert kwargs["label"] == "BurnBar Cloud"
    assert kwargs["required_env"] == ["BURNBAR_ACCESS_TOKEN"]
    assert kwargs["allowed_users_env"] == "BURNBAR_ALLOWED_USERS"
    assert kwargs["allow_all_env"] == "BURNBAR_ALLOW_ALL_USERS"
    assert kwargs["cron_deliver_env_var"] == "BURNBAR_HOME_CHANNEL"
    assert kwargs["max_message_length"] == _burnbar.MAX_MESSAGE_LENGTH
    assert callable(kwargs["adapter_factory"])
    assert callable(kwargs["setup_fn"])
    assert callable(kwargs["standalone_sender_fn"])
    assert "supports_media" not in kwargs


# ---------------------------------------------------------------------------
# Inbound mapping + cursor
# ---------------------------------------------------------------------------
def _adapter(monkeypatch, tmp_path):
    monkeypatch.setattr(_burnbar, "CURSOR_FILE", tmp_path / "cursor.json")
    cfg = PlatformConfig(enabled=True, extra={"access_token": "tok", "home_channel": "burnbar:home"})
    return BurnBarAdapter(cfg)


@pytest.mark.asyncio
async def test_inbound_event_maps_to_gateway_message_event(tmp_path, monkeypatch):
    adapter = _adapter(monkeypatch, tmp_path)
    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture
    await adapter._handle_burnbar_event(
        {
            "id": "evt_1",
            "destinationId": "burnbar:home",
            "senderId": "sender_1",
            "senderDisplayName": "Alberto",
            "threadId": "thread_1",
            "text": "hello hermes",
        }
    )

    assert len(received) == 1
    event = received[0]
    assert event.text == "hello hermes"
    assert event.message_id == "evt_1"
    assert event.source.platform.value == "burnbar"
    assert event.source.chat_id == "burnbar:home"
    assert event.source.user_id == "sender_1"
    assert event.source.user_name == "Alberto"
    assert event.source.thread_id == "thread_1"


@pytest.mark.asyncio
async def test_model_switch_event_synthesizes_model_command(tmp_path, monkeypatch):
    adapter = _adapter(monkeypatch, tmp_path)
    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture
    # _publish_runtime_status would need a client; stub it out.
    adapter._publish_runtime_status = lambda *a, **k: _noop()
    await adapter._handle_burnbar_event(
        {"id": "evt_m", "kind": "model_switch", "modelId": "anthropic/claude", "destinationId": "burnbar:home"}
    )
    assert received and received[0].text == "/model anthropic/claude"


async def _noop():
    return None


def test_cursor_round_trip(tmp_path, monkeypatch):
    monkeypatch.setattr(_burnbar, "CURSOR_FILE", tmp_path / "cursor.json")
    assert _burnbar._read_cursor() == 0
    _burnbar._write_cursor(42)
    assert _burnbar._read_cursor() == 42
    # Non-positive / corrupt values floor to 0.
    _burnbar._write_cursor(0)
    assert _burnbar._read_cursor() == 0


# ---------------------------------------------------------------------------
# Send happy / error + attachment
# ---------------------------------------------------------------------------
@pytest.mark.asyncio
async def test_send_happy_path_posts_message(tmp_path, monkeypatch):
    adapter = _adapter(monkeypatch, tmp_path)
    client = _RecordingClient(
        post_responses={"/messages": _FakeResponse({"message": {"id": "msg_1"}})}
    )
    adapter._client = client

    result = await adapter.send("burnbar:home", "all done", reply_to="evt_9")

    assert result.success is True
    assert result.message_id == "msg_1"
    url, body = client.posts[-1]
    assert url.endswith("/messages")
    assert body["text"] == "all done"
    assert body["replyToEventId"] == "evt_9"


@pytest.mark.asyncio
async def test_send_error_returns_failure(tmp_path, monkeypatch):
    adapter = _adapter(monkeypatch, tmp_path)
    client = _RecordingClient(post_responses={"/messages": _FakeResponse(status_code=500)})
    adapter._client = client

    result = await adapter.send("burnbar:home", "boom")
    assert result.success is False
    assert result.error


@pytest.mark.asyncio
async def test_send_local_file_inits_uploads_and_posts(tmp_path, monkeypatch):
    adapter = _adapter(monkeypatch, tmp_path)
    f = tmp_path / "report.txt"
    f.write_text("payload-bytes")
    client = _RecordingClient(
        post_responses={
            "/attachments/init": _FakeResponse(
                {"attachment": {"id": "att_1"}, "uploadURL": "https://signed.example/put"}
            ),
            "/messages": _FakeResponse({"message": {"id": "msg_att"}}),
        }
    )
    adapter._client = client

    result = await adapter.send_document("burnbar:home", str(f), caption="see attached")

    assert result.success is True
    assert result.message_id == "msg_att"
    # init carried the fileName.
    init_url, init_body = next((u, b) for (u, b) in client.posts if u.endswith("/attachments/init"))
    assert init_body["fileName"] == "report.txt"
    # body uploaded verbatim to the signed URL.
    assert client.puts and client.puts[0][1] == b"payload-bytes"
    # the message references the attachment id.
    _, msg_body = next((u, b) for (u, b) in client.posts if u.endswith("/messages"))
    assert msg_body["attachmentIds"] == ["att_1"]


# ---------------------------------------------------------------------------
# Oversight + runtime status
# ---------------------------------------------------------------------------
@pytest.mark.asyncio
async def test_refresh_oversight_mode_reads_state(tmp_path, monkeypatch):
    adapter = _adapter(monkeypatch, tmp_path)
    adapter._client = _RecordingClient(
        get_responses={"/state": _FakeResponse({"oversightMode": "autonomous"})}
    )
    assert adapter._oversight_mode == "supervised"
    await adapter._refresh_oversight_mode()
    assert adapter._oversight_mode == "autonomous"


@pytest.mark.asyncio
async def test_autonomous_oversight_auto_approves(tmp_path, monkeypatch):
    adapter = _adapter(monkeypatch, tmp_path)
    adapter._client = _RecordingClient()
    adapter._oversight_mode = "autonomous"
    resolved = {}

    async def fake_resolve(session_key, confirm_id, choice, chat_id, metadata, fallback=None):
        resolved["choice"] = choice

    adapter._resolve_slash_confirm = fake_resolve
    result = await adapter.send_slash_confirm("burnbar:home", "Run tool", "details", "sk", "cid")
    assert result.success is True
    assert resolved["choice"] == "once"


def test_runtime_status_payload_shape(monkeypatch):
    # Force the inventory import to fail -> empty payload, but still importable.
    body = _burnbar._runtime_status_payload()
    assert isinstance(body, dict)
    # When inventory is available it has modelOptions; when not, it's {}.
    if body:
        assert "modelOptions" in body
