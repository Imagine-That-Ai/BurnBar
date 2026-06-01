"""Tests for the BurnBar Cloud platform-plugin adapter."""

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


@pytest.mark.asyncio
async def test_inbound_event_maps_to_gateway_message_event(tmp_path, monkeypatch):
    monkeypatch.setattr(_burnbar, "CURSOR_FILE", tmp_path / "cursor.json")
    cfg = PlatformConfig(enabled=True, extra={"access_token": "tok", "home_channel": "burnbar:home"})
    adapter = BurnBarAdapter(cfg)
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
