"""BurnBar Cloud platform adapter for Hermes Agent.

The adapter uses the BurnBar Hermes Gateway API:

    https://api.burnbar.ai/v1/hermes-gateway

It intentionally depends only on ``httpx``, already present in Hermes core, for
transport. End-to-end relay encryption (``p256-hkdf-sha256-aesgcm``) is provided
by :mod:`gateway.crypto.relay_e2ee`, the Python mirror of the canonical Swift
``HermesRelayCrypto``. When the paired phone publishes a relay public key, the
adapter seals every outgoing message body / attachment and opens every inbound
event body so the relay server only ever stores ciphertext and a wrapped key it
cannot open. Legacy (pre-E2E) peers keep working on the plaintext path until the
server reports the link is relay-capable.
"""

from __future__ import annotations

import asyncio
import base64
import collections
import hashlib
import json
import logging
import mimetypes
import os
import secrets
import time
from pathlib import Path
from typing import Any, Dict, Optional

try:
    import httpx

    HTTPX_AVAILABLE = True
except ImportError:  # pragma: no cover - Hermes installs httpx in core.
    HTTPX_AVAILABLE = False
    httpx = None  # type: ignore[assignment]

try:
    from gateway.crypto import relay_e2ee

    RELAY_CRYPTO_AVAILABLE = True
except Exception:  # pragma: no cover - exercised only when cryptography is absent.
    RELAY_CRYPTO_AVAILABLE = False
    relay_e2ee = None  # type: ignore[assignment]

from gateway.config import Platform, PlatformConfig
from gateway.platforms.base import BasePlatformAdapter, MessageEvent, MessageType, SendResult

logger = logging.getLogger(__name__)

DEFAULT_API_BASE_URL = "https://api.burnbar.ai/v1/hermes-gateway"
DEFAULT_HOME_CHANNEL = "burnbar:home"
MAX_MESSAGE_LENGTH = 64000
CURSOR_FILE = Path(os.getenv("HERMES_BURNBAR_CURSOR_FILE", "~/.hermes/cache/burnbar_cursor.json")).expanduser()
MAX_ATTACHMENT_BYTES = 50 * 1024 * 1024
MAX_RUNTIME_MODELS = 100
RUNTIME_STATUS_INTERVAL_SECONDS = 30.0
# How often to refresh the human-in-the-loop oversight toggle from /state.
OVERSIGHT_REFRESH_SECONDS = 15.0
# Bound on the replay-defense seen-event-id cache (oldest ids evicted first).
MAX_SEEN_EVENT_IDS = 4096

# --- E2E relay encryption ---------------------------------------------------
# The relay algorithm + key version are byte-fixed by the cross-stream CONTRACT
# (see gateway/crypto/relay_e2ee.py and the Swift HermesRelayCrypto). The AAD
# namespace prefix is the locked wire constant: every AAD is
# "OpenBurnBar-HermesRelay-v1|" + "|".join(parts). We build the *gateway*-flavoured
# parts here (the relay_e2ee helpers cover the request/key/chunk relay flavour);
# all AES/ECDH/HKDF stays inside relay_e2ee — this module only labels and routes.
RELAY_ENCRYPTION = relay_e2ee.ALGORITHM if RELAY_CRYPTO_AVAILABLE else "p256-hkdf-sha256-aesgcm"
RELAY_KEY_VERSION = relay_e2ee.KEY_VERSION if RELAY_CRYPTO_AVAILABLE else 1
# The gateway wrap-protocol version (authenticated 2-DH). Distinct from
# RELAY_KEY_VERSION (the realtime/published-key version, which stays 1): gateway
# envelopes stamp this and gateway opens hard-require it, so the relay can no
# longer forge an event/reply/attachment by sealing to a known public key.
GATEWAY_RELAY_KEY_VERSION = 2
# Single-source the AAD namespace from relay_e2ee. RelayNamespace.aad(parts)
# yields the locked wire bytes "OpenBurnBar-HermesRelay-v1|" + "|".join(parts);
# we reuse it with the gateway-flavoured parts so the prefix/version is never
# duplicated here. Fall back to the literal only when `cryptography` is absent.
_RELAY_NAMESPACE = relay_e2ee.RelayNamespace(relay_e2ee.HERMES_NAMESPACE) if RELAY_CRYPTO_AVAILABLE else None
# Locked literal AAD prefix (CONTRACT §CRYPTO) for the crypto-unavailable path.
_RELAY_AAD_PREFIX_LITERAL = "OpenBurnBar-HermesRelay-v1"
# Env var holding the agent's persisted relay private key (managed by relay_e2ee).
RELAY_PRIVATE_KEY_ENV = "BURNBAR_RELAY_PRIVATE_KEY"
# Env var recording that this link negotiated E2E at pairing time.
RELAY_E2E_ENV = "BURNBAR_RELAY_E2E"


def _agent_version() -> str:
    """Best-effort Hermes Agent build string for truthful gateway-version display.

    Reads the installed hermes_agent/hermes_cli version when available; falls back
    to an env override or empty (the server simply omits the version then).
    """
    override = os.getenv("HERMES_BURNBAR_AGENT_VERSION")
    if override:
        return override[:120]
    for module_name in ("hermes_agent", "hermes_cli", "hermes"):
        try:
            from importlib import metadata as _metadata

            return f"{module_name}/{_metadata.version(module_name)}"[:120]
        except Exception:
            continue
    return ""


def _sha256(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _relay_safety_code(public_key_b64: str) -> str:
    """Human-comparable safety code matching BurnBar's mobile display.

    BurnBar Mobile derives the code from the raw paired agent public-key bytes:
    SHA-256, first eight digest bytes, rendered as four uppercase hex groups.
    Keeping the transform byte-identical lets the CLI print the Mac-side code
    immediately after setup so users can verify first pairing rather than
    silently relying on TOFU.
    """
    public_key = (public_key_b64 or "").strip()
    if not public_key:
        return ""
    try:
        key_bytes = base64.b64decode(public_key, validate=True)
    except Exception:
        key_bytes = public_key.encode("utf-8")
    digest = hashlib.sha256(key_bytes).digest()
    return " ".join(digest[offset : offset + 2].hex().upper() for offset in range(0, 8, 2))


def _api_base(config: PlatformConfig | None = None) -> str:
    extra = getattr(config, "extra", {}) or {}
    return (extra.get("api_base_url") or os.getenv("BURNBAR_API_BASE_URL") or DEFAULT_API_BASE_URL).rstrip("/")


def _access_token(config: PlatformConfig | None = None) -> str:
    extra = getattr(config, "extra", {}) or {}
    return (extra.get("access_token") or os.getenv("BURNBAR_ACCESS_TOKEN") or "").strip()


def _home_channel(config: PlatformConfig | None = None) -> str:
    extra = getattr(config, "extra", {}) or {}
    return (extra.get("home_channel") or os.getenv("BURNBAR_HOME_CHANNEL") or DEFAULT_HOME_CHANNEL).strip()


def check_requirements() -> bool:
    return HTTPX_AVAILABLE and bool(_access_token())


def validate_config(config: PlatformConfig) -> bool:
    return bool(_access_token(config))


def is_connected(config: PlatformConfig) -> bool:
    return bool(_access_token(config))


def _home_channel_payload(config: PlatformConfig | None = None) -> dict:
    home = _home_channel(config)
    return {"chat_id": home, "name": os.getenv("BURNBAR_HOME_CHANNEL_NAME") or "BurnBar Home"}


def _env_enablement() -> Optional[dict]:
    token = _access_token()
    if not token:
        return None
    return {
        "api_base_url": _api_base(),
        "access_token": token,
        "home_channel": _home_channel_payload(),
    }


def _headers(token: str) -> Dict[str, str]:
    return {
        "Authorization": f"Bearer {token}",
        "Content-Type": "application/json",
        "Accept": "application/json",
        "User-Agent": "hermes-agent-burnbar-platform/1.0",
    }


def _read_cursor() -> int:
    try:
        data = json.loads(CURSOR_FILE.read_text())
        value = int(data.get("cursor", 0))
        return value if value > 0 else 0
    except Exception:
        return 0


def _write_cursor(cursor: int) -> None:
    CURSOR_FILE.parent.mkdir(parents=True, exist_ok=True)
    CURSOR_FILE.write_text(json.dumps({"cursor": cursor}))


def _guess_content_type(path: Path) -> str:
    return mimetypes.guess_type(path.name)[0] or "application/octet-stream"


# --- gateway AAD builders (locked wire contract) ----------------------------
def _gateway_aad(*parts: str) -> bytes:
    """Build the namespaced AAD for a gateway relay envelope.

    The bytes are ``"OpenBurnBar-HermesRelay-v1|" + "|".join(parts)`` UTF-8, the
    exact rule used by the Swift/Kotlin ``HermesRelayCrypto.aad`` and by
    :func:`relay_e2ee.request_aad`. Only the *parts list* differs for the gateway
    flavour (``gatewayEvent`` / ``gatewayEventKey`` / ``gatewayMessage`` /
    ``gatewayMessageKey`` / ``gatewayAttachmentBody`` /
    ``gatewayAttachmentKey``), so the byte invariant stays single-sourced
    through :meth:`relay_e2ee.RelayNamespace.aad`.
    """
    string_parts = [str(p) for p in parts]
    if _RELAY_NAMESPACE is not None:
        return _RELAY_NAMESPACE.aad(string_parts)
    return ("|".join([_RELAY_AAD_PREFIX_LITERAL, *string_parts])).encode("utf-8")


def _gateway_event_aad(uid: str, client_id: str, event_id: str) -> bytes:
    return _gateway_aad("gatewayEvent", uid, client_id, event_id)


def _gateway_event_key_aad(uid: str, client_id: str, event_id: str) -> bytes:
    return _gateway_aad("gatewayEventKey", uid, client_id, event_id)


def _gateway_message_aad(uid: str, client_id: str, message_id: str) -> bytes:
    return _gateway_aad("gatewayMessage", uid, client_id, message_id)


def _gateway_message_key_aad(uid: str, client_id: str, message_id: str) -> bytes:
    return _gateway_aad("gatewayMessageKey", uid, client_id, message_id)


def _gateway_attachment_manifest_aad(uid: str, client_id: str, attachment_id: str) -> bytes:
    """AAD for the sealed attachment *manifest* (``{fileName, byteCount, contentType}``).

    Distinct from :func:`_gateway_attachment_body_aad` so a relay cannot swap a
    manifest ciphertext into the body slot (or vice-versa): each slot is bound to
    its own AAD label and decryption fails on a cross-slot swap.
    """
    return _gateway_aad("gatewayAttachmentManifest", uid, client_id, attachment_id)


def _gateway_attachment_body_aad(uid: str, client_id: str, attachment_id: str) -> bytes:
    return _gateway_aad("gatewayAttachmentBody", uid, client_id, attachment_id)


def _gateway_attachment_key_aad(uid: str, client_id: str, attachment_id: str) -> bytes:
    return _gateway_aad("gatewayAttachmentKey", uid, client_id, attachment_id)


def _public_key_base64(identity) -> str:
    """Read the X9.63 relay public key off a RelayPrivateKey or AgentRelayIdentity.

    relay_e2ee exposes ``public_key_base64`` as a *method* on ``RelayPrivateKey``
    and as a *property* on ``AgentRelayIdentity``; tolerate both.
    """
    value = getattr(identity, "public_key_base64")
    return value() if callable(value) else str(value)


async def _init_attachment(
    client: "httpx.AsyncClient",
    *,
    api_base: str,
    token: str,
    destination_id: str,
    file_path: Path,
    content_type: str,
    relay_envelope: Optional[dict] = None,
    byte_count_override: Optional[int] = None,
) -> tuple[str, str]:
    byte_count = byte_count_override if byte_count_override is not None else file_path.stat().st_size
    plaintext_count = file_path.stat().st_size
    if plaintext_count < 1:
        raise ValueError(f"{file_path} is empty")
    if plaintext_count > MAX_ATTACHMENT_BYTES:
        raise ValueError(f"{file_path} exceeds BurnBar's {MAX_ATTACHMENT_BYTES} byte attachment limit")

    body: Dict[str, Any] = {
        "destinationId": destination_id,
        "contentType": content_type,
        "byteCount": byte_count,
    }
    if relay_envelope is not None:
        # Sealed: the filename lives inside the relay envelope; never send it plaintext.
        body["relayEnvelope"] = relay_envelope
        body["relayEncryption"] = RELAY_ENCRYPTION
        body["relayKeyVersion"] = RELAY_KEY_VERSION
    else:
        body["fileName"] = file_path.name

    response = await client.post(
        f"{api_base}/attachments/init",
        headers=_headers(token),
        json=body,
    )
    response.raise_for_status()
    payload = response.json()
    attachment = payload.get("attachment") or {}
    attachment_id = attachment.get("id")
    upload_url = payload.get("uploadURL")
    if not attachment_id or not upload_url:
        raise RuntimeError("BurnBar attachment init response was missing attachment.id or uploadURL")
    return str(attachment_id), str(upload_url)


async def _upload_attachment(
    client: "httpx.AsyncClient",
    *,
    upload_url: str,
    file_path: Path,
    content_type: str,
    body_bytes: Optional[bytes] = None,
) -> bytes:
    data = body_bytes if body_bytes is not None else file_path.read_bytes()
    # Sealed bodies are opaque ciphertext; advertise octet-stream so no proxy
    # tries to sniff/transcode them. Plaintext uploads keep their real type.
    upload_type = "application/octet-stream" if body_bytes is not None else content_type
    response = await client.put(upload_url, content=data, headers={"Content-Type": upload_type})
    response.raise_for_status()
    return data


async def _finalize_attachment(
    client: "httpx.AsyncClient",
    *,
    api_base: str,
    token: str,
    attachment_id: str,
    destination_id: str,
    uploaded_bytes: bytes,
) -> None:
    response = await client.post(
        f"{api_base}/attachments/finalize",
        headers=_headers(token),
        json={
            "attachmentId": attachment_id,
            "destinationId": destination_id,
            "sha256": hashlib.sha256(uploaded_bytes).hexdigest(),
        },
    )
    response.raise_for_status()


async def _create_attachments(
    client: "httpx.AsyncClient",
    *,
    api_base: str,
    token: str,
    destination_id: str,
    media_files: list | None,
    sealer: Optional["_RelaySealer"] = None,
) -> list[str]:
    attachment_ids: list[str] = []
    for item in media_files or []:
        raw_path = item[0] if isinstance(item, (tuple, list)) else item
        file_path = Path(str(raw_path)).expanduser()
        if not file_path.is_file():
            raise FileNotFoundError(f"Attachment not found: {file_path}")
        content_type = _guess_content_type(file_path)
        relay_envelope: Optional[dict] = None
        body_bytes: Optional[bytes] = None
        byte_count_override: Optional[int] = None
        if sealer is not None and sealer.can_seal:
            relay_envelope, body_bytes = sealer.seal_attachment(
                destination_id=destination_id,
                file_path=file_path,
                content_type=content_type,
            )
            byte_count_override = len(body_bytes)
        elif sealer is not None and sealer.must_seal:
            # E2E-paired but cannot seal: never upload plaintext bytes / a
            # plaintext fileName to a paired link (fail-closed).
            raise _RelayPlaintextRefused(sealer.cannot_seal_reason("exchange files"))
        attachment_id, upload_url = await _init_attachment(
            client,
            api_base=api_base,
            token=token,
            destination_id=destination_id,
            file_path=file_path,
            content_type=content_type,
            relay_envelope=relay_envelope,
            byte_count_override=byte_count_override,
        )
        uploaded_bytes = await _upload_attachment(
            client,
            upload_url=upload_url,
            file_path=file_path,
            content_type=content_type,
            body_bytes=body_bytes,
        )
        await _finalize_attachment(
            client,
            api_base=api_base,
            token=token,
            attachment_id=attachment_id,
            destination_id=destination_id,
            uploaded_bytes=uploaded_bytes,
        )
        attachment_ids.append(attachment_id)
    return attachment_ids


async def _post_message(
    client: "httpx.AsyncClient",
    *,
    api_base: str,
    token: str,
    destination_id: str,
    text: str,
    thread_id: str | None = None,
    reply_to: str | None = None,
    attachment_ids: list[str] | None = None,
    sealer: Optional["_RelaySealer"] = None,
) -> dict:
    body: Dict[str, Any] = {
        "destinationId": destination_id,
        "threadId": thread_id,
        "replyToEventId": reply_to,
        "attachmentIds": attachment_ids or [],
    }
    clipped = text[:MAX_MESSAGE_LENGTH]
    if sealer is not None and sealer.can_seal:
        # E2E-paired: seal the reply body to the phone's relay public key and
        # drop the plaintext entirely. The server stores opaque ciphertext.
        body["relayEnvelope"] = sealer.seal_message(destination_id=destination_id, text=clipped)
        body["relayEncryption"] = RELAY_ENCRYPTION
        body["relayKeyVersion"] = RELAY_KEY_VERSION
    elif sealer is not None and sealer.must_seal:
        # E2E negotiated but we cannot seal (no peer key, or crypto/identity load
        # failed). Refuse rather than leak plaintext on a paired link (fail-closed).
        raise _RelayPlaintextRefused(sealer.cannot_seal_reason("exchange messages"))
    else:
        body["text"] = clipped
    response = await client.post(
        f"{api_base}/messages",
        headers=_headers(token),
        json=body,
    )
    response.raise_for_status()
    return response.json().get("message", {})


def _runtime_status_payload() -> dict:
    """Build a compact current-model/catalog status payload for BurnBar.

    The gateway adapter sits inside Hermes Agent, so it can reuse Hermes'
    own curated model inventory instead of inventing a second catalog. If the
    local checkout is older or inventory probing fails, the adapter still
    works as a messaging platform; it just skips catalog publication.
    """
    try:
        from hermes_cli.inventory import build_models_payload, load_picker_context

        payload = build_models_payload(load_picker_context(), max_models=MAX_RUNTIME_MODELS)
    except Exception:
        logger.debug("[%s] Could not build Hermes model inventory", "burnbar", exc_info=True)
        return {}

    options: list[dict[str, str]] = []
    for provider in payload.get("providers") or []:
        if not isinstance(provider, dict):
            continue
        provider_id = str(provider.get("slug") or provider.get("provider") or "hermes").strip() or "hermes"
        provider_name = str(provider.get("label") or provider.get("name") or provider_id).strip() or provider_id
        for model in provider.get("models") or []:
            if isinstance(model, dict):
                model_id = str(model.get("id") or model.get("model") or model.get("name") or "").strip()
                display_name = str(model.get("display_name") or model.get("displayName") or model_id).strip()
            else:
                model_id = str(model or "").strip()
                display_name = model_id
            if not model_id:
                continue
            options.append(
                {
                    "providerId": provider_id[:80],
                    "providerName": provider_name[:120],
                    "modelId": model_id[:180],
                    "displayName": (display_name or model_id)[:180],
                }
            )
            if len(options) >= MAX_RUNTIME_MODELS:
                break
        if len(options) >= MAX_RUNTIME_MODELS:
            break

    current_model = str(payload.get("model") or "").strip()
    current_provider = str(payload.get("provider") or "").strip()
    body: dict[str, object] = {"modelOptions": options}
    if current_model:
        body["currentModelId"] = current_model[:180]
    if current_provider:
        body["currentProviderId"] = current_provider[:80]
    agent_version = _agent_version()
    if agent_version:
        body["agentVersion"] = agent_version
    return body


class _RelayPlaintextRefused(RuntimeError):
    """Raised when E2E is negotiated but no peer key is available to seal to."""


class _RelaySealer:
    """Seals outgoing gateway payloads / opens inbound events for one link.

    All AES/ECDH/HKDF is delegated to :mod:`gateway.crypto.relay_e2ee`. This
    helper only chooses the right gateway-flavoured AAD parts and decides when a
    plaintext fallback is still allowed (legacy peers) versus refused (paired).
    """

    def __init__(self, adapter: "BurnBarAdapter") -> None:
        self._adapter = adapter

    @property
    def _uid(self) -> str:
        return self._adapter._relay_uid

    @property
    def _client_id(self) -> str:
        return self._adapter._relay_client_id

    @property
    def can_seal(self) -> bool:
        """True when relay crypto is importable, E2E is negotiated, identity loads, and we hold a pinned peer key.

        Requires the relay identity to actually load (``_ensure_relay_identity``)
        so a paired link with a broken/absent key never silently downgrades — if
        it cannot load, ``can_seal`` is False AND ``must_seal`` stays True, so the
        send path refuses rather than emitting plaintext (fail-closed).
        """
        return (
            RELAY_CRYPTO_AVAILABLE
            and self._adapter._relay_e2e_enabled
            and self._adapter._ensure_relay_identity() is not None
            and bool(self._adapter._peer_public_key)
        )

    @property
    def must_seal(self) -> bool:
        """True when E2E is negotiated — we must NEVER emit plaintext on this link.

        Deliberately independent of whether the relay identity / peer key is
        available: once a link is E2E-paired, plaintext is forbidden even when
        crypto cannot be loaded. The send path checks ``can_seal`` first (seal)
        and falls back to refusing — never to plaintext — when ``must_seal`` is
        True but ``can_seal`` is False.
        """
        return self._adapter._relay_e2e_enabled

    def _peer_key_for(self, destination_id: str) -> Optional[str]:
        return self._adapter._peer_public_keys.get(destination_id) or self._adapter._peer_public_key

    def cannot_seal_reason(self, action: str) -> str:
        """Explain why an E2E-paired link cannot seal right now (fail-closed copy)."""
        if not RELAY_CRYPTO_AVAILABLE:
            return (
                f"end-to-end encryption is required for this BurnBar link but the "
                f"`cryptography` package is unavailable; cannot {action} without it"
            )
        if self._adapter._ensure_relay_identity() is None:
            return (
                f"end-to-end encryption is required but this agent's relay key could "
                f"not be loaded; cannot {action}"
            )
        return (
            f"peer is on a legacy non-E2E BurnBar build; upgrade BurnBar to {action}"
        )

    def seal_message(self, *, destination_id: str, text: str) -> dict:
        peer = self._peer_key_for(destination_id)
        if not peer:
            raise _RelayPlaintextRefused(self.cannot_seal_reason("exchange messages"))
        # v2 authenticated seal: the agent's OWN static relay key is the sender,
        # bound into the key-wrap so the phone can verify the reply came from us.
        sender_private = self._adapter._relay_private_key()
        if sender_private is None:
            raise _RelayPlaintextRefused(self.cannot_seal_reason("exchange messages"))
        message_id = secrets.token_hex(16)
        sym = relay_e2ee.generate_symmetric_key()
        payload_ct = relay_e2ee.seal_to_base64(
            json.dumps({"text": text}).encode("utf-8"),
            sym,
            _gateway_message_aad(self._uid, self._client_id, message_id),
        )
        wrapped = relay_e2ee.wrap_symmetric_key(
            sym, peer, _gateway_message_key_aad(self._uid, self._client_id, message_id),
            sender_private=sender_private,
        )
        return {
            "payloadCiphertext": payload_ct,
            "wrappedKey": wrapped,
            "relayEncryption": RELAY_ENCRYPTION,
            "relayKeyVersion": GATEWAY_RELAY_KEY_VERSION,
            "senderPublicKey": sender_private.public_key_base64(),
            "messageId": message_id,
        }

    def seal_attachment(
        self, *, destination_id: str, file_path: Path, content_type: str
    ) -> tuple[dict, bytes]:
        peer = self._peer_key_for(destination_id)
        if not peer:
            raise _RelayPlaintextRefused(self.cannot_seal_reason("exchange files"))
        sender_private = self._adapter._relay_private_key()
        if sender_private is None:
            raise _RelayPlaintextRefused(self.cannot_seal_reason("exchange files"))
        attachment_id = secrets.token_hex(16)
        data = file_path.read_bytes()
        body_key = relay_e2ee.generate_symmetric_key()
        sealed_body_b64 = relay_e2ee.seal_to_base64(
            data, body_key, _gateway_attachment_body_aad(self._uid, self._client_id, attachment_id)
        )
        body_bytes = sealed_body_b64.encode("ascii")
        manifest = json.dumps(
            {"fileName": file_path.name, "byteCount": len(data), "contentType": content_type}
        ).encode("utf-8")
        # The manifest payload is sealed with the same body key BUT under a
        # DISTINCT AAD label (gatewayAttachmentManifest) from the body
        # (gatewayAttachmentBody). The phone unwraps the body key once and opens
        # both, each bound to its own AAD — so a relay cannot swap the manifest
        # ciphertext into the body slot (or vice-versa): the AAD mismatch fails
        # the tag.
        manifest_ct = relay_e2ee.seal_to_base64(
            manifest, body_key, _gateway_attachment_manifest_aad(self._uid, self._client_id, attachment_id)
        )
        wrapped = relay_e2ee.wrap_symmetric_key(
            body_key, peer, _gateway_attachment_key_aad(self._uid, self._client_id, attachment_id),
            sender_private=sender_private,
        )
        envelope = {
            "payloadCiphertext": manifest_ct,
            "wrappedKey": wrapped,
            "relayEncryption": RELAY_ENCRYPTION,
            "relayKeyVersion": GATEWAY_RELAY_KEY_VERSION,
            "senderPublicKey": sender_private.public_key_base64(),
            "attachmentId": attachment_id,
        }
        return envelope, body_bytes

    def open_event(self, raw: dict) -> Optional[dict]:
        """Open a sealed inbound event in place.

        Returns the opened ``{text, senderDisplayName?, threadId?}`` dict, or
        ``None`` when the event carries no relay envelope (legacy plaintext).
        Raises :class:`_RelayPlaintextRefused` when E2E is required but the event
        is unsealed.
        """
        envelope = raw.get("relayEnvelope")
        if not isinstance(envelope, dict):
            envelope = None
        # Some servers flatten the envelope onto the event; tolerate both shapes.
        if envelope is None and raw.get("payloadCiphertext") and raw.get("wrappedKey"):
            envelope = {
                "payloadCiphertext": raw.get("payloadCiphertext"),
                "wrappedKey": raw.get("wrappedKey"),
            }
        if not isinstance(envelope, dict) or not envelope.get("payloadCiphertext"):
            # Fail-closed: once a link is E2E-paired, a plaintext (unsealed) event
            # is refused regardless of whether the relay identity loaded. We never
            # downgrade to plaintext on a paired link.
            if self._adapter._relay_e2e_enabled:
                raise _RelayPlaintextRefused(
                    "received a legacy plaintext event on an E2E-paired link; upgrade BurnBar on the sender"
                )
            return None
        private_key = self._adapter._relay_private_key()
        if private_key is None:
            # E2E required but the agent's own key could not be loaded: refuse to
            # accept (we cannot prove this ciphertext was sealed to us).
            raise _RelayPlaintextRefused(
                "end-to-end encryption is required but this agent's relay key could not be loaded; "
                "cannot open the inbound event"
            )
        return self._open_envelope(raw, envelope, private_key, _gateway_event_aad, _gateway_event_key_aad)

    def open_model_switch(self, raw: dict) -> Optional[dict]:
        """Open a sealed ``model_switch`` control event.

        On an E2E-paired link a ``model_switch`` MUST be sealed (a relay must not
        be able to inject a cleartext control event). Returns the opened
        ``{modelId}`` dict, or ``None`` when E2E is not paired and the event is
        plaintext (legacy). Raises :class:`_RelayPlaintextRefused` when E2E is
        required but the control event is unsealed.
        """
        envelope = raw.get("relayEnvelope")
        if not isinstance(envelope, dict) or not envelope.get("payloadCiphertext"):
            if self._adapter._relay_e2e_enabled:
                raise _RelayPlaintextRefused(
                    "received an unsealed model_switch on an E2E-paired link; refusing the control event"
                )
            return None
        private_key = self._adapter._relay_private_key()
        if private_key is None:
            raise _RelayPlaintextRefused(
                "end-to-end encryption is required but this agent's relay key could not be loaded; "
                "cannot open the model_switch control event"
            )
        # iOS emits model_switch as a normal sealed gateway event with
        # {"modelId": ...} inside the event payload. Keep the AAD labels
        # identical to the event path so phone-generated switches open here.
        return self._open_envelope(raw, envelope, private_key, _gateway_event_aad, _gateway_event_key_aad)

    def seal_model_switch(self, *, destination_id: str, model_id: str) -> dict:
        """Seal a ``model_switch`` control payload to the peer (E2E send path)."""
        peer = self._peer_key_for(destination_id)
        if not peer:
            raise _RelayPlaintextRefused(self.cannot_seal_reason("switch the model"))
        sender_private = self._adapter._relay_private_key()
        if sender_private is None:
            raise _RelayPlaintextRefused(self.cannot_seal_reason("switch the model"))
        event_id = secrets.token_hex(16)
        payload_aad = _gateway_event_aad(self._uid, self._client_id, event_id)
        key_aad = _gateway_event_key_aad(self._uid, self._client_id, event_id)
        sym = relay_e2ee.generate_symmetric_key()
        payload_ct = relay_e2ee.seal_to_base64(
            json.dumps({"modelId": model_id}).encode("utf-8"), sym, payload_aad
        )
        wrapped = relay_e2ee.wrap_symmetric_key(sym, peer, key_aad, sender_private=sender_private)
        return {
            "payloadCiphertext": payload_ct,
            "wrappedKey": wrapped,
            "relayEncryption": RELAY_ENCRYPTION,
            "relayKeyVersion": GATEWAY_RELAY_KEY_VERSION,
            "senderPublicKey": sender_private.public_key_base64(),
            "eventId": event_id,
        }

    def _open_envelope(self, raw: dict, envelope: dict, private_key, payload_aad_builder, key_aad_builder) -> dict:
        """Unwrap + open one sealed envelope, then pin the peer key (TOFU/immutable).

        ``payload_aad_builder(uid, client_id, event_id)`` selects the payload
        AAD label and ``key_aad_builder`` selects the key-wrap label. Swift uses
        distinct ``...Key`` AADs for the wrapped symmetric key, and Python must
        mirror that split exactly for cross-language opens to work. Peer-key
        pinning is enforced here, but ONLY to confirm/guard an already-pinned key
        (``allow_new_pin=False``): a *changed* key is rejected (logged, not
        adopted) as a possible MITM. We never establish the FIRST pin from an
        inbound ``senderPublicKey`` — the agent's own public key is published, so
        a malicious relay can seal a valid event to it while riding in its own
        ``senderPublicKey``; only the authenticated pairing handshake seeds a new
        pin.
        """
        event_id = str(raw.get("id") or envelope.get("eventId") or "")
        payload_aad = payload_aad_builder(self._uid, self._client_id, event_id)
        key_aad = key_aad_builder(self._uid, self._client_id, event_id)
        # v2-only authenticated open: require the gateway wrap protocol AND bind the
        # phone's PINNED relay key as the sender. Fail closed on a v1 envelope or a
        # missing pin — unwrapping without the pinned sender key (or accepting v1)
        # would reopen the anonymous-sender forgery this upgrade closes. The pinned
        # key (never the relay-supplied wire field) is what makes the static-static
        # DH authenticate the sender.
        destination_id = str(raw.get("destinationId") or "")
        pinned_phone = (
            self._adapter._peer_public_keys.get(destination_id)
            or self._adapter._peer_public_key
        )
        version = envelope.get("relayKeyVersion", raw.get("relayKeyVersion"))
        try:
            version_int = int(version) if version is not None else 0
        except (TypeError, ValueError):
            version_int = 0
        if version_int != GATEWAY_RELAY_KEY_VERSION or not pinned_phone:
            raise _RelayPlaintextRefused(
                "refusing a non-v2 or unpinned gateway envelope: the authenticated "
                "sender pin is required to open"
            )
        sym = relay_e2ee.unwrap_symmetric_key(
            envelope["wrappedKey"], private_key, key_aad, sender_public_base64=pinned_phone
        )
        plaintext = relay_e2ee.open_base64(envelope["payloadCiphertext"], sym, payload_aad)
        # The authenticated unwrap above already proved the frame was sealed by the
        # holder of the pinned phone key. Confirm/guard the pin (never seed a new
        # one from an inbound field).
        peer = raw.get("senderPublicKey") or envelope.get("senderPublicKey")
        if peer:
            self._adapter._pin_peer_public_key(
                destination_id, str(peer), source="event", allow_new_pin=False
            )
        decoded = json.loads(plaintext.decode("utf-8"))
        return decoded if isinstance(decoded, dict) else {"text": str(decoded)}


class BurnBarAdapter(BasePlatformAdapter):
    """BurnBar Cloud adapter backed by the BurnBar Hermes Gateway API."""

    MAX_MESSAGE_LENGTH = MAX_MESSAGE_LENGTH

    def __init__(self, config: PlatformConfig):
        super().__init__(config=config, platform=Platform("burnbar"))
        self._api_base = _api_base(config)
        self._token = _access_token(config)
        self._home_channel = _home_channel(config)
        self._client: Optional["httpx.AsyncClient"] = None
        self._poll_task: Optional[asyncio.Task] = None
        self._cursor = _read_cursor()
        self._last_runtime_publish = 0.0
        # Human-in-the-loop oversight. The toggle lives on the server (the phone
        # sets it); the adapter mirrors it here and obeys it. Default is the safe
        # option (supervised) until /state says otherwise.
        self._oversight_mode = "supervised"
        self._oversight_checked_at = 0.0
        # Armed approval gates awaiting a phone decision: actionId -> context.
        self._pending_confirms: Dict[str, Dict[str, Any]] = {}
        # --- E2E relay state ---
        # The agent's own relay identity (private key persisted to ~/.hermes/.env
        # by relay_e2ee). Lazily loaded so the import-time path stays cheap and so
        # a missing `cryptography` never blocks the plaintext (legacy) link.
        self._relay_identity = None
        # The paired phone's relay public key(s). `_peer_public_key` is the
        # default/home link; `_peer_public_keys[destinationId]` overrides per link.
        # Seeded from pairing (persisted to ~/.hermes/.env), refreshed from polls.
        self._peer_public_key: Optional[str] = (os.getenv("BURNBAR_RELAY_PEER_PUBLIC_KEY") or "").strip() or None
        self._peer_public_keys: Dict[str, str] = {}
        # Replay defense: a bounded per-(uid,clientId) set of already-processed
        # event ids. A relay can redeliver a valid sealed event; the AAD binds the
        # id, so dropping a duplicate id before handling stops re-triggering it.
        self._seen_event_ids: "collections.OrderedDict[tuple[str, str, str], None]" = collections.OrderedDict()
        # E2E negotiated at pairing (server reports the link relay-capable).
        self._relay_e2e_enabled = (os.getenv(RELAY_E2E_ENV) or "").strip() == "1"
        # AAD identity binding. uid/clientId are routing ids the server echoes;
        # default to the access-token hash / home channel until /state reports them.
        self._relay_uid = (os.getenv("BURNBAR_RELAY_UID") or "").strip() or _sha256(self._token or "anon")[:32]
        self._relay_client_id = (os.getenv("BURNBAR_RELAY_CLIENT_ID") or "").strip() or self._home_channel
        if RELAY_CRYPTO_AVAILABLE and self._relay_e2e_enabled:
            self._ensure_relay_identity()
        self._sealer = _RelaySealer(self)

    # ------------------------------------------------------------------
    # Relay identity / peer key management
    # ------------------------------------------------------------------
    def _ensure_relay_identity(self):
        """Load (or create+persist) the agent relay private key. Returns it or None.

        A freshly minted key is persisted to ``~/.hermes/.env`` (0600, via
        ``hermes_cli.config.save_env_value``) so the agent's relay identity is
        STABLE across restarts. Without persistence the key rotated every restart,
        silently breaking every previously-sealed inbound event.
        """
        if not RELAY_CRYPTO_AVAILABLE:
            return None
        if self._relay_identity is not None:
            return self._relay_identity
        persist = self._relay_key_persister()
        try:
            self._relay_identity = relay_e2ee.AgentRelayIdentity.load_or_create(
                env_var=RELAY_PRIVATE_KEY_ENV, persist=persist
            )
        except TypeError:
            # Tolerate an older signature that takes no env_var / persist kwarg.
            try:
                self._relay_identity = relay_e2ee.AgentRelayIdentity.load_or_create(persist=persist)
            except TypeError:
                self._relay_identity = relay_e2ee.AgentRelayIdentity.load_or_create()
        except Exception:
            logger.debug("[%s] Could not load relay identity", self.name, exc_info=True)
            self._relay_identity = None
        return self._relay_identity

    @staticmethod
    def _relay_key_persister():
        """Return a ``(env_var, value) -> None`` persister that writes ~/.hermes/.env at 0600.

        ``save_env_value`` already atomically writes ``~/.hermes/.env`` and chmods
        it 0600 (``_secure_file``). Returns ``None`` when the CLI config module is
        unavailable (e.g. unit tests) so identity creation still works in-memory.
        """
        try:
            from hermes_cli.config import save_env_value
        except Exception:  # pragma: no cover - hermes_cli always present in prod.
            return None
        return save_env_value

    def _relay_private_key(self):
        """Return the RelayPrivateKey suitable for unwrap (handles identity wrapper)."""
        identity = self._ensure_relay_identity()
        if identity is None:
            return None
        # AgentRelayIdentity wraps a RelayPrivateKey; unwrap_symmetric_key needs the
        # inner key (or a raw RelayPrivateKey passed directly in tests).
        return getattr(identity, "private_key", identity)

    def _relay_public_key_base64(self) -> Optional[str]:
        identity = self._ensure_relay_identity()
        if identity is None:
            return None
        try:
            return _public_key_base64(identity)
        except Exception:
            logger.debug("[%s] Could not derive relay public key", self.name, exc_info=True)
            return None

    def _pin_peer_public_key(
        self, destination_id: str, public_key_b64: str, *, source: str, allow_new_pin: bool = True
    ) -> bool:
        """Pin the peer relay public key once (trust-on-first-use), then treat it as IMMUTABLE.

        The relay server is untrusted: ``senderPublicKey`` / ``relayPublicKey`` on
        an inbound doc are NOT authenticated. So a NEW pin (the very first peer
        key for this link) may only be established from the authenticated pairing
        handshake (``interactive_setup`` / device-grant, persisted to
        ``BURNBAR_RELAY_PEER_PUBLIC_KEY`` and read at ``__init__``). The live
        runtime responses (``/destinations`` / ``/events`` / ``/state``) flow in
        through :meth:`_absorb_relay_state` with ``allow_new_pin=False`` so a
        compromised relay can never TOFU-seed an attacker key once a persisted pin
        was lost — it refuses to seal (clear error) instead of pin-jacking.

        Once a key IS pinned, this is the immutability guard for every source: a
        *changed* key is rejected (logged, not adopted) as a possible MITM and we
        return ``False`` so callers (e.g. event handling) can drop the event. A
        re-advertised matching key is idempotent.

        Signed key rotation is a deferred follow-up; pin-only is the policy now.
        """
        if not public_key_b64:
            return True
        pinned = self._peer_public_key
        if pinned is None:
            if not allow_new_pin:
                # No persisted pin AND an untrusted runtime source: NEVER TOFU-seed
                # a new peer key from the relay. Adopting it here would let a
                # malicious /destinations|/events|/state response substitute an
                # attacker key and read every agent->phone reply (pin-jacking). We
                # refuse to establish the pin; the send path then fails closed.
                logger.warning(
                    "[%s] SECURITY: refusing to pin a peer relay key from untrusted source=%s "
                    "(no authenticated pairing pin present); will refuse to seal until re-paired",
                    self.name,
                    source,
                )
                return False
            # First key wins (TOFU) — only from the authenticated pairing path.
            # Persist so it survives restart and stays the single pinned identity
            # for this link.
            self._peer_public_key = public_key_b64
            if destination_id:
                self._peer_public_keys[destination_id] = public_key_b64
            try:
                from hermes_cli.config import save_env_value

                save_env_value("BURNBAR_RELAY_PEER_PUBLIC_KEY", public_key_b64)
            except Exception:
                logger.debug("[%s] Could not persist pinned peer relay key", self.name, exc_info=True)
            logger.info("[%s] pinned peer relay public key (TOFU, source=%s)", self.name, source)
            return True
        if public_key_b64 != pinned:
            logger.warning(
                "[%s] SECURITY: inbound peer relay key (source=%s) differs from the pinned key; "
                "refusing the change (possible MITM / key substitution)",
                self.name,
                source,
            )
            return False
        # Same key re-advertised: harmless, keep the per-destination mapping fresh.
        if destination_id and self._peer_public_keys.get(destination_id) != pinned:
            self._peer_public_keys[destination_id] = pinned
        return True

    def _event_already_seen(self, event_id: str) -> bool:
        """Record ``event_id`` for the current (uid, clientId) and report if it repeats.

        Returns ``True`` when this id was already processed for this link (a relay
        redelivery / replay) so the caller drops it BEFORE ``handle_message``.
        Returns ``False`` (and records it) the first time. Ids without a value are
        never deduped (we cannot key them). The cache is bounded to
        ``MAX_SEEN_EVENT_IDS`` per process; the oldest entries evict first.
        """
        if not event_id:
            return False
        key = (self._relay_uid, self._relay_client_id, event_id)
        if key in self._seen_event_ids:
            # Refresh recency so a steadily-redelivered id is not evicted and then
            # re-accepted; move it to the most-recent end.
            self._seen_event_ids.move_to_end(key)
            return True
        self._seen_event_ids[key] = None
        while len(self._seen_event_ids) > MAX_SEEN_EVENT_IDS:
            self._seen_event_ids.popitem(last=False)
        return False

    def _absorb_relay_state(self, payload: dict) -> None:
        """Pick up uid / clientId from an UNTRUSTED server doc (live runtime path).

        This is fed by ``/destinations`` (connect), ``/events`` (poll) and
        ``/state`` (oversight) — all relay-controlled and unauthenticated. So:

        * Peer pubkeys (``relayPublicKey`` / ``phoneRelayPublicKey``) are passed
          through with ``allow_new_pin=False``: they can only CONFIRM an
          already-pinned key (or trip the MITM warning on a changed one); they can
          NEVER establish the first pin. A new pin comes solely from the
          authenticated pairing handshake (``interactive_setup`` / device-grant),
          so a relay that lost/never-saw the persisted pin cannot seed an attacker
          key here.
        * ``relayCapable`` / ``e2eEnabled`` are NOT allowed to flip a never-paired
          agent into E2E. Promoting an unpaired agent to "encrypted" on the
          untrusted relay's say-so only fabricates an encrypted UI state (and, with
          the pin gap above, would otherwise hand the channel to the relay). E2E is
          negotiated at pairing time and read from ``BURNBAR_RELAY_E2E`` at
          ``__init__`` — never toggled on by a runtime response.

        uid/clientId are routing ids the server echoes (not secret) and may update.
        """
        if not isinstance(payload, dict):
            return
        peer = payload.get("relayPublicKey") or payload.get("phoneRelayPublicKey")
        if peer:
            # allow_new_pin=False: confirm/guard only — never TOFU-seed from the relay.
            self._pin_peer_public_key(
                str(payload.get("destinationId") or ""), str(peer), source="state", allow_new_pin=False
            )
        uid = payload.get("uid") or payload.get("userId")
        if uid:
            self._relay_uid = str(uid)
        client_id = payload.get("clientId") or payload.get("id")
        if client_id:
            self._relay_client_id = str(client_id)
        # Deliberately NOT acting on relayCapable/e2eEnabled here: an untrusted
        # runtime response must not flip a never-paired agent into E2E.

    async def connect(self) -> bool:
        if not HTTPX_AVAILABLE:
            logger.warning("[%s] httpx is unavailable", self.name)
            return False
        if not self._token:
            logger.warning("[%s] BURNBAR_ACCESS_TOKEN is not configured", self.name)
            return False
        self._client = httpx.AsyncClient(timeout=30)
        try:
            response = await self._client.get(f"{self._api_base}/destinations", headers=_headers(self._token))
            response.raise_for_status()
            self._absorb_relay_state(response.json() if response.content else {})
        except Exception as exc:
            logger.warning("[%s] BurnBar connection check failed: %s", self.name, exc)
            await self.disconnect()
            return False
        await self._publish_runtime_status(force=True)
        self._poll_task = asyncio.create_task(self._poll_loop())
        self._mark_connected()
        logger.info("[%s] Connected to BurnBar Cloud (e2e=%s)", self.name, self._relay_e2e_enabled)
        return True

    async def disconnect(self) -> None:
        if self._poll_task:
            self._poll_task.cancel()
            try:
                await self._poll_task
            except asyncio.CancelledError:
                pass
        self._poll_task = None
        if self._client:
            await self._client.aclose()
        self._client = None
        self._mark_disconnected()

    async def _poll_loop(self) -> None:
        backoff = 1.0
        while self._running:
            try:
                await self._poll_once()
                backoff = 1.0
                await asyncio.sleep(1.0)
            except asyncio.CancelledError:
                raise
            except Exception as exc:
                logger.warning("[%s] BurnBar event poll failed: %s", self.name, exc)
                await asyncio.sleep(backoff)
                backoff = min(30.0, backoff * 2)

    async def _poll_once(self) -> None:
        assert self._client is not None
        await self._publish_runtime_status()
        await self._refresh_oversight_mode()
        # Resolve any oversight gates the phone has decided since the last poll.
        if self._pending_confirms:
            await self._resolve_pending_confirms()
        response = await self._client.get(
            f"{self._api_base}/events",
            headers=_headers(self._token),
            params={"cursor": str(self._cursor), "limit": "50"},
        )
        response.raise_for_status()
        payload = response.json()
        self._absorb_relay_state(payload)
        for raw in payload.get("events", []):
            await self._handle_burnbar_event(raw)
        next_cursor = int(payload.get("nextCursor") or self._cursor)
        if next_cursor > self._cursor:
            self._cursor = next_cursor
            _write_cursor(self._cursor)

    async def _handle_burnbar_event(self, raw: dict) -> None:
        # Replay defense: a relay can redeliver a valid sealed event to re-trigger
        # it. The AAD binds the id; drop a duplicate id BEFORE any handling.
        envelope = raw.get("relayEnvelope") if isinstance(raw.get("relayEnvelope"), dict) else {}
        event_id = str(raw.get("id") or envelope.get("eventId") or "")
        if self._event_already_seen(event_id):
            logger.info("[%s] dropped duplicate event id (replay) %s", self.name, event_id)
            return
        is_model_switch = raw.get("kind") == "model_switch"
        if is_model_switch:
            # model_switch is a CONTROL event. On an E2E-paired link it MUST be
            # sealed (a relay must not be able to inject a cleartext control
            # event). The agent holds its own key and opens the sealed {modelId}.
            try:
                opened_ms = self._sealer.open_model_switch(raw)
            except _RelayPlaintextRefused as exc:
                logger.warning("[%s] dropped unsealed model_switch: %s", self.name, exc)
                return
            except Exception:
                logger.warning("[%s] failed to open sealed model_switch", self.name, exc_info=True)
                return
            if opened_ms is not None:
                model_id = str(opened_ms.get("modelId") or "").strip()
            else:
                # LEGACY plaintext fallback (only reached when E2E is not paired).
                model_id = str(raw.get("modelId") or "").strip()
            text = f"/model {model_id}".strip()
            sender_display = raw.get("senderDisplayName")
            thread_id = raw.get("threadId")
            if not model_id:
                return
        else:
            opened: Optional[dict] = None
            try:
                opened = self._sealer.open_event(raw)
            except _RelayPlaintextRefused as exc:
                logger.warning("[%s] dropped unsealed event: %s", self.name, exc)
                return
            except Exception:
                logger.warning("[%s] failed to open sealed event", self.name, exc_info=True)
                return
            if opened is not None:
                text = str(opened.get("text") or "").strip()
                sender_display = opened.get("senderDisplayName") or raw.get("senderDisplayName")
                thread_id = opened.get("threadId") or raw.get("threadId")
            else:
                # LEGACY plaintext fallback (only reached when E2E is not required).
                text = str(raw.get("text") or "").strip()
                sender_display = raw.get("senderDisplayName")
                thread_id = raw.get("threadId")
        if not text:
            return
        destination_id = str(raw.get("destinationId") or self._home_channel)
        sender_id = str(raw.get("senderId") or "burnbar-user")
        source = self.build_source(
            chat_id=destination_id,
            chat_name=destination_id,
            chat_type="dm",
            user_id=sender_id,
            user_name=sender_display or sender_id,
            thread_id=thread_id,
            message_id=raw.get("id"),
        )
        event = MessageEvent(
            text=text,
            message_type=MessageType.TEXT,
            source=source,
            raw_message=raw,
            message_id=raw.get("id"),
        )
        await self.handle_message(event)
        if is_model_switch:
            # Republish immediately so the server reflects the newly applied model
            # in ~1s instead of waiting out the 30s heartbeat. Also reset the
            # throttle so the next poll re-confirms once Hermes has fully applied.
            self._last_runtime_publish = 0.0
            await self._publish_runtime_status(force=True)

    async def _publish_runtime_status(self, *, force: bool = False) -> None:
        if self._client is None:
            return
        now = time.monotonic()
        if not force and now - self._last_runtime_publish < RUNTIME_STATUS_INTERVAL_SECONDS:
            return
        body = _runtime_status_payload()
        if not body:
            self._last_runtime_publish = now
            return
        # Re-advertise the agent relay pubkey alongside status so the server keeps
        # the link relay-capable even if the device-start publish was missed.
        if RELAY_CRYPTO_AVAILABLE and self._relay_e2e_enabled:
            pub = self._relay_public_key_base64()
            if pub:
                body["relayPublicKey"] = pub
                body["relayEncryption"] = RELAY_ENCRYPTION
                body["relayKeyVersion"] = RELAY_KEY_VERSION
        try:
            response = await self._client.post(
                f"{self._api_base}/runtime",
                headers=_headers(self._token),
                json=body,
            )
            response.raise_for_status()
            self._last_runtime_publish = now
        except Exception:
            logger.debug("[%s] BurnBar runtime status publish failed", self.name, exc_info=True)

    # ------------------------------------------------------------------
    # Human-in-the-loop oversight
    # ------------------------------------------------------------------
    async def _refresh_oversight_mode(self) -> None:
        """Mirror the server-owned oversight toggle (the phone sets it)."""
        if self._client is None:
            return
        now = time.monotonic()
        if now - self._oversight_checked_at < OVERSIGHT_REFRESH_SECONDS:
            return
        self._oversight_checked_at = now
        try:
            response = await self._client.get(f"{self._api_base}/state", headers=_headers(self._token))
            response.raise_for_status()
            state = response.json()
            self._absorb_relay_state(state)
            mode = str(state.get("oversightMode") or "").strip()
            if mode in ("supervised", "autonomous"):
                self._oversight_mode = mode
        except Exception:
            logger.debug("[%s] BurnBar oversight refresh failed", self.name, exc_info=True)

    async def send_slash_confirm(
        self,
        chat_id: str,
        title: str,
        message: str,
        session_key: str,
        confirm_id: str,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        """Gate Hermes slash-confirm prompts through BurnBar oversight.

        Autonomous mode auto-approves so the agent runs unattended. Supervised
        mode arms an approval gate on the BurnBar gateway and surfaces it to the
        phone; the decision is applied from the poll loop via
        ``tools.slash_confirm.resolve``. If the gateway is unreachable while
        supervised, we fall back to Hermes' built-in text confirm (which still
        requires an explicit ``/approve``) rather than silently proceeding.
        """
        if self._client is None:
            return SendResult(success=False, error="Not connected")
        if self._oversight_mode == "autonomous":
            await self._resolve_slash_confirm(session_key, confirm_id, "once", chat_id, metadata)
            return SendResult(success=True)
        armed = await self._arm_approval(
            action_id=confirm_id, summary=message, tool_name=title, destination_id=chat_id
        )
        if not armed:
            return await super().send_slash_confirm(
                chat_id, title, message, session_key, confirm_id, metadata
            )
        self._pending_confirms[confirm_id] = {
            "session_key": session_key,
            "chat_id": chat_id,
            "metadata": metadata,
        }
        card = f"{title}\n\n{message}\n\nApprove this action on your BurnBar device to continue."
        await self._post_confirm_followup(chat_id, card, metadata)
        return SendResult(success=True)

    async def _arm_approval(
        self, *, action_id: str, summary: str, tool_name: str, destination_id: str
    ) -> bool:
        if self._client is None:
            return False
        body: Dict[str, Any] = {"actionId": action_id, "summary": summary}
        if tool_name:
            body["toolName"] = tool_name
        if destination_id:
            body["destinationId"] = destination_id
        try:
            response = await self._client.post(
                f"{self._api_base}/approvals", headers=_headers(self._token), json=body
            )
            response.raise_for_status()
            return True
        except Exception:
            logger.debug("[%s] BurnBar approval arm failed", self.name, exc_info=True)
            return False

    async def _resolve_pending_confirms(self) -> None:
        if self._client is None:
            return
        for action_id, ctx in list(self._pending_confirms.items()):
            try:
                response = await self._client.get(
                    f"{self._api_base}/approvals",
                    headers=_headers(self._token),
                    params={"actionId": action_id},
                )
                if response.status_code == 404:
                    self._pending_confirms.pop(action_id, None)
                    continue
                response.raise_for_status()
                status = str((response.json().get("approval") or {}).get("status") or "").strip()
            except Exception:
                logger.debug("[%s] BurnBar approval poll failed", self.name, exc_info=True)
                continue
            if status == "waiting_for_approval":
                continue
            self._pending_confirms.pop(action_id, None)
            choice = "once" if status == "approved" else "cancel"
            fallback = None
            if status == "rejected":
                fallback = "Action denied from your BurnBar device."
            elif status == "expired":
                fallback = "Approval request expired without a decision."
            await self._resolve_slash_confirm(
                ctx["session_key"], action_id, choice, ctx.get("chat_id"), ctx.get("metadata"), fallback
            )

    async def _resolve_slash_confirm(
        self,
        session_key: str,
        confirm_id: str,
        choice: str,
        chat_id: Optional[str],
        metadata: Optional[Dict[str, Any]],
        fallback: Optional[str] = None,
    ) -> None:
        output: Optional[str] = None
        try:
            from tools import slash_confirm as _slash_confirm

            output = await _slash_confirm.resolve(session_key, confirm_id, choice)
        except Exception:
            logger.debug("[%s] slash-confirm resolve failed", self.name, exc_info=True)
        message = output or fallback
        if message and chat_id:
            await self._post_confirm_followup(chat_id, message, metadata)

    async def _post_confirm_followup(
        self, chat_id: Optional[str], text: str, metadata: Optional[Dict[str, Any]] = None
    ) -> None:
        if self._client is None or not text:
            return
        destination_id = chat_id or self._home_channel
        try:
            await _post_message(
                self._client,
                api_base=self._api_base,
                token=self._token,
                destination_id=destination_id,
                text=str(text),
                thread_id=(metadata or {}).get("thread_id"),
                sealer=self._sealer,
            )
        except _RelayPlaintextRefused as exc:
            logger.warning("[%s] BurnBar confirm follow-up refused: %s", self.name, exc)
        except Exception:
            logger.debug("[%s] BurnBar confirm follow-up post failed", self.name, exc_info=True)

    async def send(
        self,
        chat_id: str,
        content: str,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        if self._client is None:
            self._client = httpx.AsyncClient(timeout=30)
        destination_id = chat_id or self._home_channel
        try:
            message = await _post_message(
                self._client,
                api_base=self._api_base,
                token=self._token,
                destination_id=destination_id,
                text=content,
                thread_id=(metadata or {}).get("thread_id"),
                reply_to=reply_to,
                sealer=self._sealer,
            )
            return SendResult(success=True, message_id=message.get("id"))
        except _RelayPlaintextRefused as exc:
            logger.warning("[%s] BurnBar send refused (no E2E peer key): %s", self.name, exc)
            return SendResult(success=False, error=str(exc))
        except Exception as exc:
            logger.warning("[%s] BurnBar send failed: %s", self.name, exc)
            return SendResult(success=False, error=str(exc))

    async def _send_local_file(
        self,
        chat_id: str,
        file_path: str,
        *,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> SendResult:
        if self._client is None:
            self._client = httpx.AsyncClient(timeout=30)
        destination_id = chat_id or self._home_channel
        try:
            attachment_ids = await _create_attachments(
                self._client,
                api_base=self._api_base,
                token=self._token,
                destination_id=destination_id,
                media_files=[file_path],
                sealer=self._sealer,
            )
            message = await _post_message(
                self._client,
                api_base=self._api_base,
                token=self._token,
                destination_id=destination_id,
                text=caption or "",
                thread_id=(metadata or {}).get("thread_id"),
                reply_to=reply_to,
                attachment_ids=attachment_ids,
                sealer=self._sealer,
            )
            return SendResult(success=True, message_id=message.get("id"))
        except _RelayPlaintextRefused as exc:
            logger.warning("[%s] BurnBar attachment send refused (no E2E peer key): %s", self.name, exc)
            return SendResult(success=False, error=str(exc))
        except Exception as exc:
            logger.warning("[%s] BurnBar attachment send failed: %s", self.name, exc)
            return SendResult(success=False, error=str(exc))

    async def send_document(
        self,
        chat_id: str,
        file_path: str,
        caption: Optional[str] = None,
        file_name: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **kwargs,
    ) -> SendResult:
        return await self._send_local_file(chat_id, file_path, caption=caption, reply_to=reply_to, metadata=metadata)

    async def send_image_file(
        self,
        chat_id: str,
        image_path: str,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **kwargs,
    ) -> SendResult:
        return await self._send_local_file(chat_id, image_path, caption=caption, reply_to=reply_to, metadata=metadata)

    async def send_voice(
        self,
        chat_id: str,
        audio_path: str,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **kwargs,
    ) -> SendResult:
        return await self._send_local_file(chat_id, audio_path, caption=caption, reply_to=reply_to, metadata=metadata)

    async def send_video(
        self,
        chat_id: str,
        video_path: str,
        caption: Optional[str] = None,
        reply_to: Optional[str] = None,
        metadata: Optional[Dict[str, Any]] = None,
        **kwargs,
    ) -> SendResult:
        return await self._send_local_file(chat_id, video_path, caption=caption, reply_to=reply_to, metadata=metadata)

    async def send_typing(self, chat_id: str, metadata=None) -> None:
        if self._client is None:
            self._client = httpx.AsyncClient(timeout=15)
        try:
            await self._client.post(
                f"{self._api_base}/typing",
                headers=_headers(self._token),
                json={"destinationId": chat_id or self._home_channel, "threadId": (metadata or {}).get("thread_id")},
            )
        except Exception:
            logger.debug("[%s] BurnBar typing failed", self.name, exc_info=True)

    async def get_chat_info(self, chat_id: str) -> Dict[str, Any]:
        return {"chat_id": chat_id, "name": chat_id or "BurnBar Home", "type": "dm"}


async def _standalone_send(
    pconfig,
    chat_id,
    message,
    *,
    thread_id=None,
    media_files=None,
    force_document=False,
) -> dict:
    if not HTTPX_AVAILABLE:
        return {"error": "httpx is not available"}
    token = _access_token(pconfig)
    if not token:
        return {"error": "BURNBAR_ACCESS_TOKEN is not configured"}
    destination_id = chat_id or _home_channel(pconfig)
    # Build a sealer carrying the persisted E2E pairing state (relay identity,
    # pinned peer key, uid/clientId) so a one-shot standalone send on a paired
    # link seals exactly like the live adapter — and NEVER leaks plaintext. The
    # adapter __init__ reads BURNBAR_RELAY_E2E / BURNBAR_RELAY_PEER_PUBLIC_KEY
    # from ~/.hermes/.env, so the sealer's must_seal/can_seal reflect pairing.
    try:
        adapter = BurnBarAdapter(pconfig if pconfig is not None else PlatformConfig(enabled=True, extra={}))
        sealer: Optional["_RelaySealer"] = adapter._sealer
    except Exception:
        # If the adapter cannot be built but E2E is paired, refusing is the only
        # safe answer; if not paired, fall back to a plaintext standalone send.
        if (os.getenv(RELAY_E2E_ENV) or "").strip() == "1":
            return {"error": "BurnBar standalone send refused: E2E is paired but the relay sealer is unavailable"}
        sealer = None
    async with httpx.AsyncClient(timeout=30) as client:
        try:
            attachment_ids = await _create_attachments(
                client,
                api_base=_api_base(pconfig),
                token=token,
                destination_id=destination_id,
                media_files=media_files,
                sealer=sealer,
            )
            posted = await _post_message(
                client,
                api_base=_api_base(pconfig),
                token=token,
                destination_id=destination_id,
                thread_id=thread_id,
                text=message,
                attachment_ids=attachment_ids,
                sealer=sealer,
            )
        except _RelayPlaintextRefused as exc:
            return {"error": f"BurnBar standalone send refused (no plaintext on a paired E2E link): {exc}"}
        except Exception as exc:
            return {"error": f"BurnBar standalone send failed: {exc}"}
        return {
            "success": True,
            "platform": "burnbar",
            "chat_id": destination_id,
            "message_id": posted.get("id"),
            "attachment_ids": attachment_ids,
        }


def _apply_yaml_config(yaml_cfg: dict, platform_cfg: dict) -> Optional[dict]:
    """Translate BurnBar's config.yaml keys into PlatformConfig.extra.

    Environment variables still win; this hook only lets users configure
    BurnBar in structured YAML without core Hermes knowing BurnBar-specific
    field names.
    """
    extra = dict(platform_cfg.get("extra") or {})
    for yaml_key, env_key, extra_key in (
        ("api_base_url", "BURNBAR_API_BASE_URL", "api_base_url"),
        ("access_token", "BURNBAR_ACCESS_TOKEN", "access_token"),
        ("home_channel", "BURNBAR_HOME_CHANNEL", "home_channel"),
    ):
        value = yaml_cfg.get(yaml_key)
        if value is None:
            continue
        value = str(value).strip()
        if not value:
            continue
        extra[extra_key] = value
        os.environ.setdefault(env_key, value)
    return extra or None


def _poll_device_authorization(api_base: str, device_code: str, device_secret: str, interval: int) -> dict:
    with httpx.Client(timeout=30) as client:
        while True:
            poll = client.post(
                f"{api_base}/device/poll",
                json={"deviceCode": device_code, "deviceSecret": device_secret},
            )
            poll.raise_for_status()
            status = poll.json()
            if status.get("status") == "approved":
                return status
            if status.get("status") in {"denied", "expired"}:
                raise RuntimeError(f"BurnBar link {status['status']}")
            time.sleep(interval)


def interactive_setup() -> None:
    """Device-code setup helper for ``hermes gateway setup``."""
    from hermes_cli.setup import (
        get_env_value,
        print_header,
        print_info,
        print_success,
        print_warning,
        prompt,
        prompt_yes_no,
        save_env_value,
    )

    print_header("BurnBar Cloud")
    existing_token = get_env_value("BURNBAR_ACCESS_TOKEN")
    if existing_token:
        print_info("BurnBar Cloud is already configured.")
        if not prompt_yes_no("Reconfigure BurnBar Cloud?", False):
            return

    api_base = (
        prompt(
            "BurnBar Hermes Gateway API base URL",
            default=get_env_value("BURNBAR_API_BASE_URL") or DEFAULT_API_BASE_URL,
        ).strip()
        or DEFAULT_API_BASE_URL
    ).rstrip("/")

    # Generate (or load) this agent's relay keypair and publish the public key at
    # device/start so the server records the client as E2E-capable. The private
    # key is persisted to ~/.hermes/.env by relay_e2ee; only ciphertext leaves.
    agent_relay_public_key = ""
    if RELAY_CRYPTO_AVAILABLE:
        try:
            # persist= wires the freshly minted private key to ~/.hermes/.env (0600,
            # via save_env_value) so the agent's relay identity is STABLE across
            # restarts; without it the key rotated every restart and silently broke
            # every previously-sealed inbound event.
            try:
                identity = relay_e2ee.AgentRelayIdentity.load_or_create(
                    env_var=RELAY_PRIVATE_KEY_ENV, persist=save_env_value
                )
            except TypeError:
                try:
                    identity = relay_e2ee.AgentRelayIdentity.load_or_create(persist=save_env_value)
                except TypeError:
                    identity = relay_e2ee.AgentRelayIdentity.load_or_create()
            agent_relay_public_key = _public_key_base64(identity)
        except Exception:
            logger.debug("Could not prepare BurnBar relay identity for pairing", exc_info=True)
            agent_relay_public_key = ""

    device_secret = secrets.token_urlsafe(32)
    payload: Dict[str, Any] = {
        "clientName": "Hermes Agent",
        "deviceSecretHash": _sha256(device_secret),
        "scopes": ["hermes.gateway.read", "hermes.gateway.write", "hermes.gateway.manage"],
    }
    if agent_relay_public_key:
        payload["agentRelayPublicKey"] = agent_relay_public_key
        payload["relayKeyVersion"] = RELAY_KEY_VERSION
        payload["relayEncryption"] = RELAY_ENCRYPTION
    try:
        with httpx.Client(timeout=30) as client:
            start = client.post(f"{api_base}/device/start", json=payload)
            start.raise_for_status()
            body = start.json()
    except Exception as exc:
        print_warning(f"Could not start BurnBar device authorization: {exc}")
        return

    print()
    print_info("Open BurnBar, sign in with Cloud or Cloud Pro, and approve this code:")
    print_info(f"  {body['userCode']}")
    print_info(f"  {body['verificationUriComplete']}")
    print_info("Waiting for approval...")

    try:
        approved = _poll_device_authorization(
            api_base,
            body["deviceCode"],
            device_secret,
            int(body.get("interval", 3)),
        )
    except Exception as exc:
        print_warning(f"BurnBar authorization failed: {exc}")
        return

    save_env_value("BURNBAR_API_BASE_URL", api_base)
    save_env_value("BURNBAR_ACCESS_TOKEN", approved["accessToken"])
    save_env_value("BURNBAR_HOME_CHANNEL", approved.get("homeDestinationId") or DEFAULT_HOME_CHANNEL)
    # Record the negotiated E2E capability + the phone's relay public key so the
    # adapter seals from the next start. The grant returns the peer pubkey.
    peer_relay_public_key = (
        approved.get("relayPublicKey")
        or approved.get("phoneRelayPublicKey")
        or (approved.get("client") or {}).get("relayPublicKey")
        or (approved.get("client") or {}).get("phoneRelayPublicKey")
        or ""
    )
    client_payload = approved.get("client") or {}
    relay_capable = approved.get("relayCapable") is True or client_payload.get("relayCapable") is True
    if agent_relay_public_key and (relay_capable or peer_relay_public_key):
        save_env_value(RELAY_E2E_ENV, "1")
        if peer_relay_public_key:
            save_env_value("BURNBAR_RELAY_PEER_PUBLIC_KEY", str(peer_relay_public_key))
        client_id = approved.get("clientId") or (approved.get("client") or {}).get("id")
        if client_id:
            save_env_value("BURNBAR_RELAY_CLIENT_ID", str(client_id))
        uid = approved.get("uid") or approved.get("userId")
        if uid:
            save_env_value("BURNBAR_RELAY_UID", str(uid))
        print_info("End-to-end encryption is enabled for this BurnBar link.")
        safety_code = _relay_safety_code(agent_relay_public_key)
        if safety_code:
            print_info(f"Safety code: {safety_code}")
            print_info("Compare this with BurnBar's Private messages screen before sending sensitive prompts.")
    elif agent_relay_public_key:
        print_info(
            "Paired without end-to-end encryption (legacy BurnBar). Messages use "
            "the plaintext relay path until BurnBar is upgraded."
        )
    if not get_env_value("BURNBAR_ALLOWED_USERS") and not get_env_value("BURNBAR_ALLOW_ALL_USERS"):
        save_env_value("BURNBAR_ALLOW_ALL_USERS", "true")
    print_success("BurnBar Cloud configuration saved to ~/.hermes/.env")
    print_info("Restart the gateway for changes to take effect: hermes gateway restart")


def register(ctx) -> None:
    ctx.register_platform(
        name="burnbar",
        label="BurnBar Cloud",
        adapter_factory=lambda cfg: BurnBarAdapter(cfg),
        check_fn=check_requirements,
        validate_config=validate_config,
        is_connected=is_connected,
        required_env=["BURNBAR_ACCESS_TOKEN"],
        install_hint="Configure from BurnBar Cloud with `hermes gateway setup`.",
        setup_fn=interactive_setup,
        env_enablement_fn=_env_enablement,
        apply_yaml_config_fn=_apply_yaml_config,
        allowed_users_env="BURNBAR_ALLOWED_USERS",
        allow_all_env="BURNBAR_ALLOW_ALL_USERS",
        cron_deliver_env_var="BURNBAR_HOME_CHANNEL",
        standalone_sender_fn=_standalone_send,
        max_message_length=MAX_MESSAGE_LENGTH,
        emoji="🔥",
        platform_hint=(
            "You are speaking through BurnBar Cloud. Keep replies concise, "
            "mobile-friendly, and explicit about completed actions. Use plain "
            "Markdown that renders cleanly in compact app chat surfaces."
        ),
        allow_update_command=True,
    )
