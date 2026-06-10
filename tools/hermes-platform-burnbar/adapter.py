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
import re
import secrets
import subprocess
import sys
import time
import unicodedata
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

try:
    import httpx

    HTTPX_AVAILABLE = True
except ImportError:  # pragma: no cover - Hermes installs httpx in core.
    HTTPX_AVAILABLE = False
    httpx = None  # type: ignore[assignment]

try:
    from gateway.crypto import relay_e2ee

    RELAY_CRYPTO_AVAILABLE = True
except ImportError:  # pragma: no cover - exercised only when cryptography is absent.
    # MP-25: narrow to ImportError. A broad `except Exception` would mask a real
    # crypto bug (e.g. a FIPS rejection or a missing system library) as "crypto
    # unavailable" and could silently steer a paired link onto the plaintext path.
    RELAY_CRYPTO_AVAILABLE = False
    relay_e2ee = None  # type: ignore[assignment]

try:
    from gateway.crypto import hermes_ratchet

    HERMES_RATCHET_AVAILABLE = True
except ImportError:  # pragma: no cover - older Hermes checkouts do not yet ship the module.
    HERMES_RATCHET_AVAILABLE = False
    hermes_ratchet = None  # type: ignore[assignment]

try:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF

    CRYPTOGRAPHY_PRIMITIVES_AVAILABLE = True
except ImportError:  # pragma: no cover - same environment that disables relay crypto.
    CRYPTOGRAPHY_PRIMITIVES_AVAILABLE = False
    hashes = None  # type: ignore[assignment]
    serialization = None  # type: ignore[assignment]
    ec = None  # type: ignore[assignment]
    Ed25519PrivateKey = None  # type: ignore[assignment]
    HKDF = None  # type: ignore[assignment]

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
MAX_MALFORMED_SEALED_EVENT_FINGERPRINTS = 512
MAX_MALFORMED_SEALED_EVENT_FAILURES_PER_WINDOW = 64
MALFORMED_SEALED_EVENT_THROTTLE_SECONDS = 60.0
# Persisted replay ledger (survives gateway restart). Buckets are bound to
# uid/clientId plus the pinned peer-key fingerprint; entries store opaque
# replay-key digests for authenticated event ids plus the highest authenticated
# sender counter seen for that bucket. The counter contract is intentionally
# global for one paired client/peer bucket: senders must emit one monotonic
# replayCounter across all event kinds and destinations for that paired link.
REPLAY_LEDGER_FILE = Path(
    os.getenv("HERMES_BURNBAR_REPLAY_FILE", str(CURSOR_FILE.with_name("burnbar_replay_ledger.json")))
).expanduser()
REPLAY_COUNTER_KEYS = ("replayCounter", "eventCounter")
# Operator-pinned oversight on E2E links (relay /state cannot flip it).
OVERSIGHT_MODE_ENV = "BURNBAR_OVERSIGHT_MODE"

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
# The RFC 9180 HPKE Auth-mode gateway wrap version (v3). Emitted ONLY to a peer
# whose authenticated capability advertises v3 (the BURNBAR_RELAY_PEER_KEY_VERSION
# pin or a per-destination override); a v2-only peer is never auto-upgraded. The
# open path accepts any pinned-sender v3 envelope; v1/plaintext stay refused.
GATEWAY_RELAY_KEY_VERSION_V3 = relay_e2ee.HPKE_KEY_VERSION if RELAY_CRYPTO_AVAILABLE else 3
GATEWAY_RELAY_ENCRYPTION_V3 = (
    relay_e2ee.HPKE_ALGORITHM
    if RELAY_CRYPTO_AVAILABLE
    else "hpke-auth-p256-hkdfsha256-aes256gcm"
)
# Gateway wrap versions this agent emits/opens. The open path hard-refuses any
# version outside this set (v1 and plaintext stay unreachable on a paired link),
# and the send path floors unknown values to v2.
_SUPPORTED_GATEWAY_RELAY_VERSIONS = (GATEWAY_RELAY_KEY_VERSION, GATEWAY_RELAY_KEY_VERSION_V3)
# Operator/pairing-pinned peer wrap capability (authenticated, like
# BURNBAR_RELAY_PEER_PUBLIC_KEY). Set to "3" once the paired phone is known to
# support RFC 9180 HPKE v3; absent/unknown stays v2. Never read from the
# untrusted relay runtime path (mirrors the _absorb_relay_state policy).
RELAY_PEER_KEY_VERSION_ENV = "BURNBAR_RELAY_PEER_KEY_VERSION"
GATEWAY_HPKE_V3_DISABLED_ENV = "BURNBAR_DISABLE_GATEWAY_HPKE_V3"
# Single-source the AAD namespace from relay_e2ee. RelayNamespace.aad(parts)
# yields the locked wire bytes "OpenBurnBar-HermesRelay-v1|" + "|".join(parts);
# we reuse it with the gateway-flavoured parts so the prefix/version is never
# duplicated here. Fall back to the literal only when `cryptography` is absent.
_RELAY_NAMESPACE = relay_e2ee.RelayNamespace(relay_e2ee.HERMES_NAMESPACE) if RELAY_CRYPTO_AVAILABLE else None
# Locked literal AAD prefix (CONTRACT §CRYPTO) for the crypto-unavailable path.
_RELAY_AAD_PREFIX_LITERAL = "OpenBurnBar-HermesRelay-v1"
# Legacy env var for the agent relay private key. New writes go to macOS
# Keychain; this remains a read/import source so existing installs migrate
# without silently rotating their relay identity.
RELAY_PRIVATE_KEY_ENV = "BURNBAR_RELAY_PRIVATE_KEY"
RELAY_PRIVATE_KEY_KEYCHAIN_SERVICE = "com.openburnbar.hermes-gateway-relay"
RELAY_PRIVATE_KEY_KEYCHAIN_ACCOUNT = "agent-relay-private-key"
RATCHET_PRIVATE_KEY_KEYCHAIN_SERVICE = "com.openburnbar.hermes-gateway-ratchet"
RATCHET_IDENTITY_KEYCHAIN_ACCOUNT = "agent-ratchet-identity-private-key"
RATCHET_SIGNING_KEYCHAIN_ACCOUNT = "agent-ratchet-signing-private-key"
RATCHET_SIGNED_PREKEY_KEYCHAIN_ACCOUNT = "agent-ratchet-signed-prekey-private-key"
RATCHET_SIGNED_PREKEY_DOMAIN = b"OpenBurnBar-HermesRatchet-v1-signed-prekey"
RATCHET_IDENTITY_PRIVATE_KEY_ENV = "BURNBAR_RATCHET_IDENTITY_PRIVATE_KEY"
RATCHET_SIGNING_PRIVATE_KEY_ENV = "BURNBAR_RATCHET_SIGNING_PRIVATE_KEY"
RATCHET_SIGNED_PREKEY_PRIVATE_KEY_ENV = "BURNBAR_RATCHET_SIGNED_PREKEY_PRIVATE_KEY"
RATCHET_PEER_IDENTITY_PUBLIC_KEY_ENV = "BURNBAR_RATCHET_PEER_IDENTITY_PUBLIC_KEY"
RATCHET_PEER_SIGNING_PUBLIC_KEY_ENV = "BURNBAR_RATCHET_PEER_SIGNING_PUBLIC_KEY"
RATCHET_PEER_SIGNED_PREKEY_PUBLIC_KEY_ENV = "BURNBAR_RATCHET_PEER_SIGNED_PREKEY_PUBLIC_KEY"
RATCHET_PEER_SIGNED_PREKEY_ID_ENV = "BURNBAR_RATCHET_PEER_SIGNED_PREKEY_ID"
RATCHET_PEER_SIGNED_PREKEY_SIGNATURE_ENV = "BURNBAR_RATCHET_PEER_SIGNED_PREKEY_SIGNATURE"
RATCHET_SESSION_KEYCHAIN_SERVICE = "com.openburnbar.hermes-gateway-ratchet-session"
RATCHET_PREKEY_KDF_DOMAIN = b"OpenBurnBar-HermesRatchet-v1-prekey-x3dh-p256"
RATCHET_SESSION_ID_DOMAIN = b"OpenBurnBar-HermesRatchet-v1-session"
RATCHET_CHAT_LANE = "chat"
# Env var recording that this link negotiated E2E at pairing time.
RELAY_E2E_ENV = "BURNBAR_RELAY_E2E"

# --- Gateway proof-of-possession (PoP) -----------------------------------
# Every authenticated Hermes Gateway request is signed with this agent's
# Ed25519 client signing key (registered at pairing via
# `agentClientSigningPublicKeyBase64`), so a stolen bearer token alone cannot
# replay the API. PoP v2 (L2) additionally binds the canonical query string
# into the signature; v1 left GET query params unprotected. The payload-line
# contract is byte-locked with the server's gatewayPopSignablePayload(V2) in
# functions/src/callables/hermesGateway.ts — change NEITHER side alone.
GATEWAY_POP_VERSION = 2
POP_PAYLOAD_PREFIX_V1 = "OpenBurnBar.HermesGatewayPoP.v1"
POP_PAYLOAD_PREFIX_V2 = "OpenBurnBar.HermesGatewayPoP.v2"
# Server contract: /^[A-Za-z0-9._:-]{16,160}$/ — anything else 401s as
# missing_pop_nonce.
POP_NONCE_PATTERN = re.compile(r"^[A-Za-z0-9._:-]{16,160}$")
# Private key storage mirrors the relay/ratchet pattern: macOS Keychain is the
# production store; the env var is a read/import source (and the non-macOS
# persistence target, alongside BURNBAR_ACCESS_TOKEN in ~/.hermes/.env).
POP_SIGNING_PRIVATE_KEY_ENV = "BURNBAR_POP_SIGNING_PRIVATE_KEY"
POP_SIGNING_KEYCHAIN_SERVICE = "com.openburnbar.hermes-gateway-pop"
POP_SIGNING_KEYCHAIN_ACCOUNT = "agent-client-pop-signing-private-key"
POP_SIGNING_KEY_LABEL = "BurnBar gateway PoP signing private key"
APPROVAL_DECISION_KIND = "approval_decision"
OVERSIGHT_MODE_KIND = "oversight_mode"


RelayKeyPersister = Callable[[str, str], None]


def _relay_keychain_command() -> Optional[str]:
    if sys.platform != "darwin":
        return None
    command = Path("/usr/bin/security")
    return str(command) if command.exists() else None


def _load_relay_private_key_base64_from_keychain() -> Optional[str]:
    """Read the agent relay private key from macOS Keychain, if present."""
    command = _relay_keychain_command()
    if command is None:
        return None
    completed = subprocess.run(
        [
            command,
            "find-generic-password",
            "-s",
            RELAY_PRIVATE_KEY_KEYCHAIN_SERVICE,
            "-a",
            RELAY_PRIVATE_KEY_KEYCHAIN_ACCOUNT,
            "-w",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode == 0:
        value = completed.stdout.strip()
        return value or None
    stderr = (completed.stderr or "").lower()
    if completed.returncode == 44 or "could not be found" in stderr:
        return None
    raise RuntimeError(
        "could not read BurnBar relay private key from Keychain: "
        f"{(completed.stderr or completed.stdout or '').strip()}"
    )


def _store_relay_private_key_base64_to_keychain(_env_var: str, value: str) -> None:
    """Persist the agent relay private key to macOS Keychain."""
    _store_private_key_base64_to_keychain(
        RELAY_PRIVATE_KEY_KEYCHAIN_SERVICE,
        RELAY_PRIVATE_KEY_KEYCHAIN_ACCOUNT,
        value,
        "BurnBar relay private key",
    )


def _load_private_key_base64_from_keychain(service: str, account: str, label: str) -> Optional[str]:
    """Read a base64 private key from macOS Keychain, if present."""
    command = _relay_keychain_command()
    if command is None:
        return None
    completed = subprocess.run(
        [
            command,
            "find-generic-password",
            "-s",
            service,
            "-a",
            account,
            "-w",
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode == 0:
        value = completed.stdout.strip()
        return value or None
    stderr = (completed.stderr or "").lower()
    if completed.returncode == 44 or "could not be found" in stderr:
        return None
    raise RuntimeError(
        f"could not read {label} from Keychain: "
        f"{(completed.stderr or completed.stdout or '').strip()}"
    )


def _store_private_key_base64_to_keychain(service: str, account: str, value: str, label: str) -> None:
    """Persist a base64 private key to macOS Keychain."""
    command = _relay_keychain_command()
    if command is None:
        raise RuntimeError(f"macOS Keychain is unavailable for {label} persistence")
    completed = subprocess.run(
        [
            command,
            "add-generic-password",
            "-U",
            "-s",
            service,
            "-a",
            account,
            "-w",
            value,
        ],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(
            f"could not store {label} in Keychain: "
            f"{(completed.stderr or completed.stdout or '').strip()}"
        )


def _relay_key_persister() -> Optional[RelayKeyPersister]:
    """Return the durable relay-private-key persister.

    macOS Keychain is the production store. Non-macOS/test environments return
    ``None`` so crypto unit tests can run without touching a host secret store.
    """
    if _relay_keychain_command() is None:
        return None
    return _store_relay_private_key_base64_to_keychain


def _agent_identity_from_private_key_base64(raw_base64: str):
    """Validate and wrap a stored relay private key, failing closed on corruption."""
    try:
        return relay_e2ee.AgentRelayIdentity(
            relay_e2ee.RelayPrivateKey.from_base64(raw_base64.strip())
        )
    except (ValueError, relay_e2ee.RelayCryptoError) as exc:
        raise relay_e2ee.CorruptIdentityError(
            f"{RELAY_PRIVATE_KEY_ENV} is present but invalid — re-pair required; "
            "refusing to silently rotate the relay identity"
        ) from exc


def _load_or_create_relay_identity_secure(
    *,
    persist: Optional[RelayKeyPersister] = None,
):
    """Load/create the agent relay identity without writing private keys to .env."""
    if not RELAY_CRYPTO_AVAILABLE:
        return None

    keychain_value = _load_relay_private_key_base64_from_keychain()
    if keychain_value:
        return _agent_identity_from_private_key_base64(keychain_value)

    legacy_value = (os.getenv(RELAY_PRIVATE_KEY_ENV) or "").strip()
    effective_persist = persist if persist is not None else _relay_key_persister()
    if legacy_value:
        identity = _agent_identity_from_private_key_base64(legacy_value)
        if effective_persist is not None:
            effective_persist(RELAY_PRIVATE_KEY_ENV, legacy_value)
        elif sys.platform == "darwin":
            raise RuntimeError("cannot import legacy BurnBar relay private key: Keychain is unavailable")
        return identity

    private_key = relay_e2ee.generate_private_key()
    raw_base64 = private_key.raw_base64()
    if effective_persist is not None:
        effective_persist(RELAY_PRIVATE_KEY_ENV, raw_base64)
    elif sys.platform == "darwin":
        raise RuntimeError("cannot persist BurnBar relay private key: Keychain is unavailable")
    return relay_e2ee.AgentRelayIdentity(private_key)


def _p256_private_key_from_base64(raw_base64: str, label: str):
    if not CRYPTOGRAPHY_PRIMITIVES_AVAILABLE:
        raise RuntimeError("cryptography primitives are unavailable")
    try:
        raw = base64.b64decode(raw_base64.strip(), validate=True)
    except Exception as exc:
        raise ValueError(f"{label} is not valid base64") from exc
    if len(raw) != 32:
        raise ValueError(f"{label} must be a 32-byte P-256 private scalar")
    private_value = int.from_bytes(raw, "big")
    if private_value <= 0:
        raise ValueError(f"{label} must be a non-zero P-256 private scalar")
    try:
        return ec.derive_private_key(private_value, ec.SECP256R1())  # type: ignore[union-attr]
    except Exception as exc:
        raise ValueError(f"{label} is not a valid P-256 private scalar") from exc


def _p256_private_key_base64(private_key) -> str:
    raw = private_key.private_numbers().private_value.to_bytes(32, "big")
    return base64.b64encode(raw).decode("ascii")


def _p256_public_key_x963(private_key) -> bytes:
    return private_key.public_key().public_bytes(
        encoding=serialization.Encoding.X962,  # type: ignore[union-attr]
        format=serialization.PublicFormat.UncompressedPoint,  # type: ignore[union-attr]
    )


def _load_or_create_p256_private_key_base64(env_var: str, account: str, label: str) -> Optional[str]:
    if not CRYPTOGRAPHY_PRIMITIVES_AVAILABLE:
        return None
    keychain_value = _load_private_key_base64_from_keychain(
        RATCHET_PRIVATE_KEY_KEYCHAIN_SERVICE,
        account,
        label,
    )
    if keychain_value:
        _p256_private_key_from_base64(keychain_value, label)
        return keychain_value.strip()

    legacy_value = (os.getenv(env_var) or "").strip()
    if legacy_value:
        _p256_private_key_from_base64(legacy_value, label)
        if _relay_keychain_command() is not None:
            _store_private_key_base64_to_keychain(
                RATCHET_PRIVATE_KEY_KEYCHAIN_SERVICE,
                account,
                legacy_value,
                label,
            )
        elif sys.platform == "darwin":
            raise RuntimeError(f"cannot import legacy {label}: Keychain is unavailable")
        return legacy_value

    private_key = ec.generate_private_key(ec.SECP256R1())  # type: ignore[union-attr]
    raw_base64 = _p256_private_key_base64(private_key)
    if _relay_keychain_command() is not None:
        _store_private_key_base64_to_keychain(
            RATCHET_PRIVATE_KEY_KEYCHAIN_SERVICE,
            account,
            raw_base64,
            label,
        )
    elif sys.platform == "darwin":
        raise RuntimeError(f"cannot persist {label}: Keychain is unavailable")
    return raw_base64


def _ratchet_signed_prekey_id(signed_prekey_public: bytes) -> str:
    return f"spk_agent_{hashlib.sha256(signed_prekey_public).hexdigest()[:16]}"


def _ratchet_signed_prekey_payload(
    identity_public_key: bytes,
    signed_prekey_public_key: bytes,
    signed_prekey_id: str,
) -> bytes:
    payload = bytearray(RATCHET_SIGNED_PREKEY_DOMAIN)
    for part in (identity_public_key, signed_prekey_public_key, signed_prekey_id.encode("utf-8")):
        payload.extend(len(part).to_bytes(8, "big"))
        payload.extend(part)
    return bytes(payload)


def _agent_ratchet_prekey_bundle() -> Optional[dict[str, Any]]:
    """Return the public Phase 6 ratchet prekey bundle for this agent.

    The private identity, signing, and signed-prekey scalars live in macOS
    Keychain. Only X9.63 public keys and the DER ECDSA signature are published.
    Returning ``None`` leaves the adapter on relayEnvelope only; callers must not
    fall back to plaintext for an already E2E-paired relay link.
    """
    if not (HERMES_RATCHET_AVAILABLE and CRYPTOGRAPHY_PRIMITIVES_AVAILABLE):
        return None
    try:
        identity_raw = _load_or_create_p256_private_key_base64(
            RATCHET_IDENTITY_PRIVATE_KEY_ENV,
            RATCHET_IDENTITY_KEYCHAIN_ACCOUNT,
            "BurnBar ratchet identity private key",
        )
        signing_raw = _load_or_create_p256_private_key_base64(
            RATCHET_SIGNING_PRIVATE_KEY_ENV,
            RATCHET_SIGNING_KEYCHAIN_ACCOUNT,
            "BurnBar ratchet signing private key",
        )
        signed_prekey_raw = _load_or_create_p256_private_key_base64(
            RATCHET_SIGNED_PREKEY_PRIVATE_KEY_ENV,
            RATCHET_SIGNED_PREKEY_KEYCHAIN_ACCOUNT,
            "BurnBar ratchet signed-prekey private key",
        )
        if not (identity_raw and signing_raw and signed_prekey_raw):
            return None
        identity_key = _p256_private_key_from_base64(identity_raw, "BurnBar ratchet identity private key")
        signing_key = _p256_private_key_from_base64(signing_raw, "BurnBar ratchet signing private key")
        signed_prekey = _p256_private_key_from_base64(signed_prekey_raw, "BurnBar ratchet signed-prekey private key")
        identity_public = _p256_public_key_x963(identity_key)
        signing_public = _p256_public_key_x963(signing_key)
        signed_prekey_public = _p256_public_key_x963(signed_prekey)
        signed_prekey_id = _ratchet_signed_prekey_id(signed_prekey_public)
        signature = signing_key.sign(
            _ratchet_signed_prekey_payload(identity_public, signed_prekey_public, signed_prekey_id),
            ec.ECDSA(hashes.SHA256()),  # type: ignore[union-attr]
        )
        return {
            "agentRatchetIdentityPublicKey": base64.b64encode(identity_public).decode("ascii"),
            "agentRatchetSigningPublicKey": base64.b64encode(signing_public).decode("ascii"),
            "agentRatchetSignedPreKeyPublicKey": base64.b64encode(signed_prekey_public).decode("ascii"),
            "agentRatchetSignedPreKeyId": signed_prekey_id,
            "agentRatchetSignedPreKeySignature": base64.b64encode(signature).decode("ascii"),
            "agentSupportsRatchetV1": True,
        }
    except Exception:
        logger.debug("Could not prepare BurnBar ratchet prekey bundle", exc_info=True)
        return None


def _agent_ratchet_private_bundle() -> Optional[dict[str, Any]]:
    if not (HERMES_RATCHET_AVAILABLE and CRYPTOGRAPHY_PRIMITIVES_AVAILABLE):
        return None
    identity_raw = _load_or_create_p256_private_key_base64(
        RATCHET_IDENTITY_PRIVATE_KEY_ENV,
        RATCHET_IDENTITY_KEYCHAIN_ACCOUNT,
        "BurnBar ratchet identity private key",
    )
    signing_raw = _load_or_create_p256_private_key_base64(
        RATCHET_SIGNING_PRIVATE_KEY_ENV,
        RATCHET_SIGNING_KEYCHAIN_ACCOUNT,
        "BurnBar ratchet signing private key",
    )
    signed_prekey_raw = _load_or_create_p256_private_key_base64(
        RATCHET_SIGNED_PREKEY_PRIVATE_KEY_ENV,
        RATCHET_SIGNED_PREKEY_KEYCHAIN_ACCOUNT,
        "BurnBar ratchet signed-prekey private key",
    )
    if not (identity_raw and signing_raw and signed_prekey_raw):
        return None
    identity_key = _p256_private_key_from_base64(identity_raw, "BurnBar ratchet identity private key")
    signing_key = _p256_private_key_from_base64(signing_raw, "BurnBar ratchet signing private key")
    signed_prekey = _p256_private_key_from_base64(signed_prekey_raw, "BurnBar ratchet signed-prekey private key")
    identity_public = _p256_public_key_x963(identity_key)
    signing_public = _p256_public_key_x963(signing_key)
    signed_prekey_public = _p256_public_key_x963(signed_prekey)
    signed_prekey_id = _ratchet_signed_prekey_id(signed_prekey_public)
    signature = signing_key.sign(
        _ratchet_signed_prekey_payload(identity_public, signed_prekey_public, signed_prekey_id),
        ec.ECDSA(hashes.SHA256()),  # type: ignore[union-attr]
    )
    return {
        "identityPrivateKeyBase64": identity_raw,
        "identityPublicKeyBase64": base64.b64encode(identity_public).decode("ascii"),
        "signingPublicKeyBase64": base64.b64encode(signing_public).decode("ascii"),
        "signedPreKeyPrivateKeyBase64": signed_prekey_raw,
        "signedPreKeyPublicKeyBase64": base64.b64encode(signed_prekey_public).decode("ascii"),
        "signedPreKeyId": signed_prekey_id,
        "signedPreKeySignatureBase64": base64.b64encode(signature).decode("ascii"),
    }


def _append_ratchet_part(buffer: bytearray, part: bytes) -> None:
    buffer.extend(len(part).to_bytes(8, "big"))
    buffer.extend(part)


def _ratchet_device_id(prefix: str, identity_public_key_base64: str) -> str:
    raw = base64.b64decode(identity_public_key_base64)
    if len(raw) != 65:
        raise ValueError("ratchet identity public key must be 65 bytes")
    return f"{prefix}:{hashlib.sha256(raw).hexdigest()[:16]}"


def _ratchet_session_id(
    *,
    uid: str,
    client_id: str,
    initiator_role: str,
    initiator_identity_public_key_base64: str,
    responder_identity_public_key_base64: str,
    initiator_signed_prekey_public_key_base64: str,
    responder_signed_prekey_public_key_base64: str,
    initiator_initial_ratchet_public_key_base64: str,
) -> str:
    transcript = bytearray(RATCHET_SESSION_ID_DOMAIN)
    for part in (uid, client_id, RATCHET_CHAT_LANE, initiator_role):
        _append_ratchet_part(transcript, part.encode("utf-8"))
    for key in (
        initiator_identity_public_key_base64,
        responder_identity_public_key_base64,
        initiator_signed_prekey_public_key_base64,
        responder_signed_prekey_public_key_base64,
        initiator_initial_ratchet_public_key_base64,
    ):
        raw = base64.b64decode(key)
        if len(raw) != 65:
            raise ValueError("ratchet transcript public key must be 65 bytes")
        _append_ratchet_part(transcript, raw)
    return "hgr1_" + hashlib.sha256(bytes(transcript)).hexdigest()[:40]


def _ratchet_prekey_shared_secret(
    *,
    dh1: bytes,
    dh2: bytes,
    dh3: bytes,
    uid: str,
    client_id: str,
    initiator_role: str,
    initiator_identity_public_key_base64: str,
    responder_identity_public_key_base64: str,
    initiator_signed_prekey_public_key_base64: str,
    responder_signed_prekey_public_key_base64: str,
    initiator_initial_ratchet_public_key_base64: str,
) -> bytes:
    if HKDF is None:
        raise RuntimeError("cryptography HKDF is unavailable")
    info = bytearray(RATCHET_PREKEY_KDF_DOMAIN)
    for part in (uid, client_id, RATCHET_CHAT_LANE, initiator_role):
        _append_ratchet_part(info, part.encode("utf-8"))
    for key in (
        initiator_identity_public_key_base64,
        responder_identity_public_key_base64,
        initiator_signed_prekey_public_key_base64,
        responder_signed_prekey_public_key_base64,
        initiator_initial_ratchet_public_key_base64,
    ):
        raw = base64.b64decode(key)
        if len(raw) != 65:
            raise ValueError("ratchet transcript public key must be 65 bytes")
        _append_ratchet_part(info, raw)
    return HKDF(
        algorithm=hashes.SHA256(),  # type: ignore[union-attr]
        length=32,
        salt=RATCHET_PREKEY_KDF_DOMAIN,
        info=bytes(info),
    ).derive(dh1 + dh2 + dh3)


def _ratchet_initiator_shared_secret(
    *,
    uid: str,
    client_id: str,
    initiator_role: str,
    local_identity_private_key_base64: str,
    local_signed_prekey_public_key_base64: str,
    local_initial_ratchet_key_pair,
    remote_identity_public_key_base64: str,
    remote_signed_prekey_public_key_base64: str,
) -> bytes:
    local_identity = _p256_private_key_from_base64(local_identity_private_key_base64, "ratchet identity private key")
    local_initial = _p256_private_key_from_base64(local_initial_ratchet_key_pair.private_key_base64, "ratchet initial private key")
    remote_identity = hermes_ratchet._public_key_from_base64(remote_identity_public_key_base64)
    remote_signed_prekey = hermes_ratchet._public_key_from_base64(remote_signed_prekey_public_key_base64)
    local_identity_public = base64.b64encode(_p256_public_key_x963(local_identity)).decode("ascii")
    return _ratchet_prekey_shared_secret(
        dh1=local_identity.exchange(ec.ECDH(), remote_signed_prekey),  # type: ignore[union-attr]
        dh2=local_initial.exchange(ec.ECDH(), remote_identity),  # type: ignore[union-attr]
        dh3=local_initial.exchange(ec.ECDH(), remote_signed_prekey),  # type: ignore[union-attr]
        uid=uid,
        client_id=client_id,
        initiator_role=initiator_role,
        initiator_identity_public_key_base64=local_identity_public,
        responder_identity_public_key_base64=remote_identity_public_key_base64,
        initiator_signed_prekey_public_key_base64=local_signed_prekey_public_key_base64,
        responder_signed_prekey_public_key_base64=remote_signed_prekey_public_key_base64,
        initiator_initial_ratchet_public_key_base64=local_initial_ratchet_key_pair.public_key_base64,
    )


def _ratchet_responder_shared_secret(
    *,
    uid: str,
    client_id: str,
    initiator_role: str,
    local_identity_private_key_base64: str,
    local_signed_prekey_private_key_base64: str,
    local_identity_public_key_base64: str,
    local_signed_prekey_public_key_base64: str,
    remote_identity_public_key_base64: str,
    remote_signed_prekey_public_key_base64: str,
    remote_initial_ratchet_public_key_base64: str,
) -> bytes:
    local_identity = _p256_private_key_from_base64(local_identity_private_key_base64, "ratchet identity private key")
    local_signed = _p256_private_key_from_base64(local_signed_prekey_private_key_base64, "ratchet signed-prekey private key")
    remote_identity = hermes_ratchet._public_key_from_base64(remote_identity_public_key_base64)
    remote_initial = hermes_ratchet._public_key_from_base64(remote_initial_ratchet_public_key_base64)
    return _ratchet_prekey_shared_secret(
        dh1=local_signed.exchange(ec.ECDH(), remote_identity),  # type: ignore[union-attr]
        dh2=local_identity.exchange(ec.ECDH(), remote_initial),  # type: ignore[union-attr]
        dh3=local_signed.exchange(ec.ECDH(), remote_initial),  # type: ignore[union-attr]
        uid=uid,
        client_id=client_id,
        initiator_role=initiator_role,
        initiator_identity_public_key_base64=remote_identity_public_key_base64,
        responder_identity_public_key_base64=local_identity_public_key_base64,
        initiator_signed_prekey_public_key_base64=remote_signed_prekey_public_key_base64,
        responder_signed_prekey_public_key_base64=local_signed_prekey_public_key_base64,
        initiator_initial_ratchet_public_key_base64=remote_initial_ratchet_public_key_base64,
    )


def _verify_ratchet_signed_prekey(
    *,
    signing_public_key_base64: str,
    identity_public_key_base64: str,
    signed_prekey_public_key_base64: str,
    signed_prekey_id: str,
    signature_base64: str,
) -> bool:
    try:
        signing_public = ec.EllipticCurvePublicKey.from_encoded_point(  # type: ignore[union-attr]
            ec.SECP256R1(), base64.b64decode(signing_public_key_base64)
        )
        signing_public.verify(
            base64.b64decode(signature_base64),
            _ratchet_signed_prekey_payload(
                base64.b64decode(identity_public_key_base64),
                base64.b64decode(signed_prekey_public_key_base64),
                signed_prekey_id,
            ),
            ec.ECDSA(hashes.SHA256()),  # type: ignore[union-attr]
        )
        return True
    except Exception:
        return False


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


def _pairing_safety_code(public_keys_b64: list[str]) -> str:
    """Signal-style safety code matching BurnBar's mobile display.

    Hashes every paired public identity key (MP-1): relay keys for legacy links
    and, once both peers publish Phase 6 material, ratchet identity keys too.
    Sorting by raw decoded bytes lets both sides derive the identical code
    without agreeing on roles. The displayed code is the first **16** digest
    bytes (>=128 bits) rendered as eight uppercase hex groups.

    Why all keys + 128 bits: an untrusted relay can substitute either peer key at
    first pin; a single-key code would still match, so the human comparison
    authenticates nothing. Hashing every active public identity binds
    substitution into the code. The 64-bit truncation the old code shipped let a
    key-substituting relay grind a ~2^64 collision on the displayed code; 128
    bits closes that.

    Returns ``""`` if any key is missing or not a valid canonical X9.63 P-256
    public key (MP-22) — never a plausible-looking code derived from raw string
    bytes, which a human would compare and wrongly accept.
    """
    trimmed = [(value or "").strip() for value in public_keys_b64]
    if len(trimmed) < 2 or any(not value for value in trimmed):
        return ""
    if not RELAY_CRYPTO_AVAILABLE:
        return ""
    try:
        decoded = [relay_e2ee.public_key_x963_from_base64(value) for value in trimmed]
    except Exception:
        return ""
    digest = hashlib.sha256(b"".join(sorted(decoded))).digest()
    return " ".join(digest[offset : offset + 2].hex().upper() for offset in range(0, 16, 2))


def _relay_safety_code(
    agent_public_key_b64: str,
    phone_public_key_b64: str,
    *,
    extra_public_keys_b64: Optional[list[str]] = None,
) -> str:
    return _pairing_safety_code(
        [agent_public_key_b64, phone_public_key_b64] + list(extra_public_keys_b64 or [])
    )


# Catalog-id charset for a model-switch value (MP-11). First char alphanumeric so
# the value can never start with a dash, and no whitespace, so it cannot smuggle
# ``--provider`` / ``--global`` flags into the ``/model <id>`` slash parser.
_SAFE_MODEL_ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._:/-]{0,179}$")


def _is_safe_model_id(model_id: str) -> bool:
    """Reject a model-switch id that could inject slash-command flags or control chars."""
    return bool(model_id) and bool(_SAFE_MODEL_ID.fullmatch(model_id))


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
    if not (HTTPX_AVAILABLE and bool(_access_token())):
        return False
    # MP-15: an E2E-paired link cannot operate without the crypto backend. Refuse
    # to start LOUDLY rather than connect and then refuse every send silently — and
    # never fall back to plaintext on a paired link.
    if (os.getenv(RELAY_E2E_ENV) or "").strip() == "1" and not RELAY_CRYPTO_AVAILABLE:
        logger.error(
            "BurnBar end-to-end encryption is paired (BURNBAR_RELAY_E2E=1) but the "
            "`cryptography` backend is unavailable. Install it with "
            "`pip install -e '.[gateway-e2ee]'`. Refusing to start the BurnBar link "
            "(it would refuse every send)."
        )
        return False
    return True


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


# ---------------------------------------------------------------------------
# Gateway proof-of-possession (PoP) signing
#
# The server (functions/src/callables/hermesGateway.ts) verifies, on EVERY
# authenticated request, an Ed25519 signature over:
#
#   v2: [POP_PAYLOAD_PREFIX_V2, sha256hex(token), METHOD, path, canonicalQuery,
#        sha256hex(stableJSON(body)), nonce, timestamp].join("\n")
#   v1: same lines without canonicalQuery (and the v1 prefix).
#
# Every helper below is a byte-locked mirror of the server's TypeScript:
#  - `_stable_json_string`     ⇄ stableJSONString (incl. localeCompare key sort)
#  - `_canonical_query_string` ⇄ canonicalGatewayQueryString (decoded params
#    sorted by key then value via UTF-16 code-unit `<`, joined k=v with `&`,
#    repeated params as multiple pairs, no percent re-encoding)
#  - `_gateway_signable_path`  ⇄ gatewayPath (prefix strips + trailing-slash)
# Frozen Node-generated vectors in test_adapter_pop.py pin the parity.
# ---------------------------------------------------------------------------

# ICU root single-character order for printable ASCII as produced by Node's
# default `String.prototype.localeCompare` (punctuation < digits < letters,
# lowercase before uppercase at the tertiary level). Captured empirically from
# the same ICU the server runs; letters appear as lower/upper pairs.
_ICU_ROOT_ASCII_ORDER = (
    "\t\n\x0b\x0c\r _-,;:!?.'\"()[]{}@*/\\&#%`^+<=>|~$"
    "0123456789aAbBcCdDeEfFgGhHiIjJkKlLmMnNoOpPqQrRsStTuUvVwWxXyYzZ"
)


def _build_icu_ascii_weights() -> Tuple[Dict[str, int], Dict[str, int]]:
    primary: Dict[str, int] = {}
    tertiary: Dict[str, int] = {}
    rank = 1
    index = 0
    order = _ICU_ROOT_ASCII_ORDER
    while index < len(order):
        char = order[index]
        primary[char] = rank
        tertiary[char] = 0
        if char.isalpha() and index + 1 < len(order) and order[index + 1].lower() == char:
            upper = order[index + 1]
            primary[upper] = rank
            tertiary[upper] = 1
            index += 2
        else:
            index += 1
        rank += 1
    return primary, tertiary


_ICU_ASCII_PRIMARY, _ICU_ASCII_TERTIARY = _build_icu_ascii_weights()


def _icu_locale_sort_key(value: str) -> Tuple[Tuple[Tuple[int, int], ...], Tuple[int, ...], Tuple[int, ...]]:
    """Sort key approximating Node's default ``localeCompare`` (ICU root).

    Exact for printable-ASCII strings (the entire gateway body-key domain):
    primaries are compared across the whole string first, then secondaries
    (Latin diacritics via NFD), then tertiaries (case). Characters outside the
    table fall back to code-point order *after* all tabled characters — the
    documented approximation boundary; protocol object keys never reach it.
    """
    primaries: List[Tuple[int, int]] = []
    secondaries: List[int] = []
    tertiaries: List[int] = []
    for char in value:
        weight = _ICU_ASCII_PRIMARY.get(char)
        if weight is not None:
            primaries.append((0, weight))
            secondaries.append(0)
            tertiaries.append(_ICU_ASCII_TERTIARY[char])
            continue
        decomposed = unicodedata.normalize("NFD", char)
        base = decomposed[0] if decomposed else char
        base_weight = _ICU_ASCII_PRIMARY.get(base)
        if base_weight is not None:
            primaries.append((0, base_weight))
            secondaries.append(ord(decomposed[1]) if len(decomposed) > 1 else 0)
            tertiaries.append(_ICU_ASCII_TERTIARY[base])
        else:
            primaries.append((1, ord(char)))
            secondaries.append(0)
            tertiaries.append(0)
    return (tuple(primaries), tuple(secondaries), tuple(tertiaries))


def _utf16_code_unit_key(value: str) -> bytes:
    """JS ``<`` on strings compares UTF-16 code units; this key matches it."""
    return value.encode("utf-16-be", "surrogatepass")


def _js_number_string(value: Any) -> str:
    """ECMA-262 Number-to-string (what JSON.stringify/String emit server-side).

    The server re-parses the wire JSON and re-serializes numbers as doubles, so
    the client must hash the JS rendering (2.0 → "2", 1e-7 → "1e-7",
    1e21 → "1e+21"), not Python's.
    """
    if isinstance(value, int) and not isinstance(value, bool):
        if -(2**53) < value < 2**53:
            return str(value)
        value = float(value)  # JSON.parse precision loss past 2^53.
    number = float(value)
    if number != number or number in (float("inf"), float("-inf")):
        return "null"  # JSON.stringify(NaN/Infinity) === "null".
    if number == 0:
        return "0"  # Covers -0.0 the way String(-0) does.
    sign = "-" if number < 0 else ""
    mantissa = repr(abs(number))  # Shortest round-trip decimal, like JS.
    if "e" in mantissa:
        mantissa, _, exponent_text = mantissa.partition("e")
        exponent = int(exponent_text)
    else:
        exponent = 0
    integer_part, _, fraction_part = mantissa.partition(".")
    digits = (integer_part + fraction_part).lstrip("0")
    # n: value == 0.digits × 10^n (ECMA-262 6.1.6.1.20 notation).
    n = exponent + len(integer_part.lstrip("0")) - (len(integer_part) - len(integer_part.lstrip("0")) and 0)
    leading_zeros = len(integer_part) - len(integer_part.lstrip("0"))
    if integer_part.lstrip("0"):
        n = exponent + len(integer_part)
    else:
        stripped_fraction = fraction_part.lstrip("0")
        n = exponent - (len(fraction_part) - len(stripped_fraction))
    del leading_zeros
    digits = digits.rstrip("0") or "0"
    k = len(digits)
    if k <= n <= 21:
        return sign + digits + "0" * (n - k)
    if 0 < n <= 21:
        return sign + digits[:n] + "." + digits[n:]
    if -6 < n <= 0:
        return sign + "0." + "0" * (-n) + digits
    exponent_value = n - 1
    exponent_repr = ("+" if exponent_value >= 0 else "-") + str(abs(exponent_value))
    if k == 1:
        return sign + digits + "e" + exponent_repr
    return sign + digits[0] + "." + digits[1:] + "e" + exponent_repr


def _js_json_quote(value: str) -> str:
    """JSON.stringify string escaping (escape only what JSON requires)."""
    return json.dumps(value, ensure_ascii=False)


def _stable_json_string(value: Any) -> str:
    """Byte mirror of the server's stableJSONString (the PoP body-hash input)."""
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, str):
        return _js_json_quote(value)
    if isinstance(value, (int, float)):
        return _js_number_string(value)
    if isinstance(value, (list, tuple)):
        return "[" + ",".join(_stable_json_string(item) for item in value) + "]"
    if isinstance(value, dict):
        entries = sorted(
            ((str(key), item) for key, item in value.items()),
            key=lambda pair: _icu_locale_sort_key(pair[0]),
        )
        return "{" + ",".join(f"{_js_json_quote(key)}:{_stable_json_string(item)}" for key, item in entries) + "}"
    return "{}"  # Server collapses anything non-JSON-shaped to "{}".


def _query_param_wire_string(value: Any) -> Optional[str]:
    """How the param crosses the wire (httpx encode → Express decode)."""
    if value is None:
        return None  # httpx drops None params; the server never sees them.
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)  # httpx stringifies with str(); the server signs the decoded text.
    return str(value)


def _canonical_query_string(params: Optional[Dict[str, Any]]) -> str:
    """Mirror of canonicalGatewayQueryString over the DECODED params.

    Repeated params (list/tuple values) expand to multiple pairs; pairs sort by
    key then value using UTF-16 code-unit order (the server's plain JS ``<``);
    pairs join as ``key=value`` with ``&`` and are never percent re-encoded.
    """
    pairs: List[Tuple[str, str]] = []
    for key, value in (params or {}).items():
        if isinstance(value, (list, tuple)):
            for item in value:
                rendered = _query_param_wire_string(item)
                if rendered is not None:
                    pairs.append((str(key), rendered))
        else:
            rendered = _query_param_wire_string(value)
            if rendered is not None:
                pairs.append((str(key), rendered))
    pairs.sort(key=lambda pair: (_utf16_code_unit_key(pair[0]), _utf16_code_unit_key(pair[1])))
    return "&".join(f"{key}={value}" for key, value in pairs)


def _gateway_signable_path(url_or_path: str) -> str:
    """Mirror of gatewayPath: the endpoint suffix the server signs over."""
    path = url_or_path
    if "://" in path:
        path = "/" + path.split("://", 1)[1].split("/", 1)[1] if "/" in path.split("://", 1)[1] else "/"
    path = path.split("?", 1)[0].split("#", 1)[0]
    path = re.sub(r"^/burnBarHermesGateway\b", "", path)
    path = re.sub(r"^/v1/hermes-gateway\b", "", path)
    return path.rstrip("/") or "/"


def _generate_pop_nonce() -> str:
    nonce = f"hermes-pop-{secrets.token_hex(16)}"
    if not POP_NONCE_PATTERN.match(nonce):  # pragma: no cover - charset is fixed.
        raise RuntimeError("generated PoP nonce violates the server nonce contract")
    return nonce


def _pop_timestamp() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def _pop_signable_payload(
    *,
    version: int,
    token: str,
    method: str,
    path: str,
    canonical_query: str,
    body_hash: str,
    nonce: str,
    timestamp: str,
) -> bytes:
    token_hash = _sha256(token)
    if version >= 2:
        lines = [POP_PAYLOAD_PREFIX_V2, token_hash, method.upper(), path, canonical_query, body_hash, nonce, timestamp]
    else:
        lines = [POP_PAYLOAD_PREFIX_V1, token_hash, method.upper(), path, body_hash, nonce, timestamp]
    return "\n".join(lines).encode("utf-8")


def _ed25519_private_key_from_base64(raw_base64: str, label: str):
    if not CRYPTOGRAPHY_PRIMITIVES_AVAILABLE:
        raise RuntimeError("cryptography primitives are unavailable")
    try:
        raw = base64.b64decode(raw_base64.strip(), validate=True)
    except Exception as exc:
        raise ValueError(f"{label} is not valid base64") from exc
    if len(raw) != 32:
        raise ValueError(f"{label} must be a 32-byte Ed25519 private key seed")
    return Ed25519PrivateKey.from_private_bytes(raw)  # type: ignore[union-attr]


def _load_pop_signing_private_key_base64() -> Optional[str]:
    """Load (never create) the PoP signing key: Keychain first, env import second."""
    if not CRYPTOGRAPHY_PRIMITIVES_AVAILABLE:
        return None
    keychain_value = _load_private_key_base64_from_keychain(
        POP_SIGNING_KEYCHAIN_SERVICE,
        POP_SIGNING_KEYCHAIN_ACCOUNT,
        POP_SIGNING_KEY_LABEL,
    )
    if keychain_value:
        _ed25519_private_key_from_base64(keychain_value, POP_SIGNING_KEY_LABEL)
        return keychain_value.strip()
    legacy_value = (os.getenv(POP_SIGNING_PRIVATE_KEY_ENV) or "").strip()
    if legacy_value:
        _ed25519_private_key_from_base64(legacy_value, POP_SIGNING_KEY_LABEL)
        if _relay_keychain_command() is not None:
            _store_private_key_base64_to_keychain(
                POP_SIGNING_KEYCHAIN_SERVICE,
                POP_SIGNING_KEYCHAIN_ACCOUNT,
                legacy_value,
                POP_SIGNING_KEY_LABEL,
            )
        return legacy_value
    return None


def _ensure_pop_signing_key_for_pairing(persist_env: Optional[Callable[[str, str], None]] = None) -> str:
    """Load-or-create the PoP signing key at pairing; return the public key base64.

    Creation persists the private seed to macOS Keychain (production) or, on
    non-macOS hosts, to ~/.hermes/.env via ``persist_env`` — the same file that
    already holds BURNBAR_ACCESS_TOKEN, so this widens no trust boundary.
    """
    if not CRYPTOGRAPHY_PRIMITIVES_AVAILABLE:
        raise RuntimeError("cryptography primitives are unavailable; cannot mint the PoP signing key")
    raw_base64 = _load_pop_signing_private_key_base64()
    if raw_base64 is None:
        private_key = Ed25519PrivateKey.generate()  # type: ignore[union-attr]
        raw_base64 = base64.b64encode(
            private_key.private_bytes(
                encoding=serialization.Encoding.Raw,  # type: ignore[union-attr]
                format=serialization.PrivateFormat.Raw,  # type: ignore[union-attr]
                encryption_algorithm=serialization.NoEncryption(),  # type: ignore[union-attr]
            )
        ).decode("ascii")
        if _relay_keychain_command() is not None:
            _store_private_key_base64_to_keychain(
                POP_SIGNING_KEYCHAIN_SERVICE,
                POP_SIGNING_KEYCHAIN_ACCOUNT,
                raw_base64,
                POP_SIGNING_KEY_LABEL,
            )
        elif sys.platform == "darwin":
            raise RuntimeError(f"cannot persist {POP_SIGNING_KEY_LABEL}: Keychain is unavailable")
        elif persist_env is not None:
            persist_env(POP_SIGNING_PRIVATE_KEY_ENV, raw_base64)
            os.environ[POP_SIGNING_PRIVATE_KEY_ENV] = raw_base64
        else:
            raise RuntimeError(f"cannot persist {POP_SIGNING_KEY_LABEL}: no secret store is available")
    _reset_pop_signer_cache()
    private_key = _ed25519_private_key_from_base64(raw_base64, POP_SIGNING_KEY_LABEL)
    public_raw = private_key.public_key().public_bytes(
        encoding=serialization.Encoding.Raw,  # type: ignore[union-attr]
        format=serialization.PublicFormat.Raw,  # type: ignore[union-attr]
    )
    return base64.b64encode(public_raw).decode("ascii")


class GatewayPopSigner:
    """Signs gateway requests with the registered Ed25519 client signing key."""

    def __init__(self, private_key) -> None:
        self._private_key = private_key

    @property
    def public_key_base64(self) -> str:
        raw = self._private_key.public_key().public_bytes(
            encoding=serialization.Encoding.Raw,  # type: ignore[union-attr]
            format=serialization.PublicFormat.Raw,  # type: ignore[union-attr]
        )
        return base64.b64encode(raw).decode("ascii")

    def headers(
        self,
        *,
        token: str,
        method: str,
        url_or_path: str,
        params: Optional[Dict[str, Any]] = None,
        json_body: Optional[Dict[str, Any]] = None,
        version: int = GATEWAY_POP_VERSION,
        nonce: Optional[str] = None,
        timestamp: Optional[str] = None,
    ) -> Dict[str, str]:
        nonce = nonce or _generate_pop_nonce()
        timestamp = timestamp or _pop_timestamp()
        body_hash = _sha256(_stable_json_string(json_body if isinstance(json_body, dict) else {}))
        payload = _pop_signable_payload(
            version=version,
            token=token,
            method=method,
            path=_gateway_signable_path(url_or_path),
            canonical_query=_canonical_query_string(params),
            body_hash=body_hash,
            nonce=nonce,
            timestamp=timestamp,
        )
        signature = base64.b64encode(self._private_key.sign(payload)).decode("ascii")
        headers = {
            "x-openburnbar-pop-nonce": nonce,
            "x-openburnbar-pop-timestamp": timestamp,
            "x-openburnbar-pop-body-sha256": body_hash,
            "x-openburnbar-pop-signature-ed25519": signature,
        }
        if version >= 2:
            headers["x-openburnbar-pop-version"] = str(version)
        return headers


_POP_SIGNER_CACHE: Dict[str, Any] = {"loaded": False, "signer": None, "warned": False}


def _reset_pop_signer_cache() -> None:
    _POP_SIGNER_CACHE.update({"loaded": False, "signer": None, "warned": False})


def _pop_signer() -> Optional[GatewayPopSigner]:
    if not _POP_SIGNER_CACHE["loaded"]:
        _POP_SIGNER_CACHE["loaded"] = True
        try:
            raw_base64 = _load_pop_signing_private_key_base64()
            if raw_base64:
                _POP_SIGNER_CACHE["signer"] = GatewayPopSigner(
                    _ed25519_private_key_from_base64(raw_base64, POP_SIGNING_KEY_LABEL)
                )
        except Exception:
            logger.debug("Could not load the BurnBar gateway PoP signing key", exc_info=True)
    return _POP_SIGNER_CACHE["signer"]


def _signed_headers(
    token: str,
    method: str,
    url_or_path: str,
    *,
    params: Optional[Dict[str, Any]] = None,
    json_body: Optional[Dict[str, Any]] = None,
) -> Dict[str, str]:
    """Bearer + PoP v2 headers for one gateway request.

    Falls back to bare Bearer headers when no signing key is available (the
    server then 401s exactly as it does for today's unsigned adapter — no new
    failure mode, but a paired client always has the key).
    """
    headers = _headers(token)
    signer = _pop_signer()
    if signer is None:
        if not _POP_SIGNER_CACHE["warned"]:
            _POP_SIGNER_CACHE["warned"] = True
            logger.warning(
                "BurnBar gateway PoP signing key is unavailable; sending unsigned requests "
                "(the server will refuse them). Re-run `hermes gateway setup` to mint one."
            )
        return headers
    try:
        headers.update(
            signer.headers(token=token, method=method, url_or_path=url_or_path, params=params, json_body=json_body)
        )
    except Exception:
        logger.warning("Could not sign BurnBar gateway request with the PoP key", exc_info=True)
    return headers


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


def _read_replay_ledger() -> Dict[str, Any]:
    try:
        data = json.loads(REPLAY_LEDGER_FILE.read_text())
        return data if isinstance(data, dict) else {}
    except Exception:
        return {}


def _write_replay_ledger(ledger: Dict[str, Any]) -> None:
    REPLAY_LEDGER_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = REPLAY_LEDGER_FILE.with_name(f"{REPLAY_LEDGER_FILE.name}.tmp")
    tmp.write_text(json.dumps(ledger, separators=(",", ":")))
    try:
        os.chmod(tmp, 0o600)
    except Exception:
        pass
    tmp.replace(REPLAY_LEDGER_FILE)


def _coerce_replay_counter(value: Any) -> Optional[int]:
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, int):
        counter = value
    elif isinstance(value, str) and value.strip().isdigit():
        counter = int(value.strip())
    else:
        return None
    return counter if counter >= 0 else None


def _gateway_hpke_v3_enabled() -> bool:
    """True unless an operator explicitly break-glass disables HPKE v3.

    Production parity now exists across Cloud validation and client open/seal
    paths, so v3 is the preferred negotiated envelope. The disable flag is for
    emergency rollback only; normal pairing advertises v2+v3 and prefers v3.
    """
    return (os.getenv(GATEWAY_HPKE_V3_DISABLED_ENV) or "").strip() != "1"


def _supported_gateway_relay_versions() -> list[int]:
    versions = [GATEWAY_RELAY_KEY_VERSION]
    if _gateway_hpke_v3_enabled():
        versions.append(GATEWAY_RELAY_KEY_VERSION_V3)
    return versions


def _preferred_gateway_relay_version() -> int:
    versions = _supported_gateway_relay_versions()
    return versions[-1]


def _gateway_relay_encryption_for(version: int) -> str:
    return GATEWAY_RELAY_ENCRYPTION_V3 if version == GATEWAY_RELAY_KEY_VERSION_V3 else RELAY_ENCRYPTION


def _gateway_relay_capability_payload() -> dict:
    preferred = _preferred_gateway_relay_version()
    return {
        "supportsRelayEnvelopeVersions": _supported_gateway_relay_versions(),
        "preferredRelayEnvelopeVersion": preferred,
        "supportsHpkeV3": preferred == GATEWAY_RELAY_KEY_VERSION_V3,
        "clientPlatform": "python-hermes-agent",
        "clientAppBuild": "burnbar-platform",
    }


def _coerce_peer_relay_key_version(value: Any) -> int:
    """Parse an advertised/configured peer wrap version to a SUPPORTED version.

    Floors absent / malformed / unsupported values to the v2 gateway version so a
    v2-only peer is never auto-upgraded and an unknown future version never
    selects an unimplemented wrap path. v3 is accepted only when the local
    break-glass rollback flag has not disabled HPKE.
    """
    counter = _coerce_replay_counter(value)
    if counter == GATEWAY_RELAY_KEY_VERSION:
        return counter
    if counter == GATEWAY_RELAY_KEY_VERSION_V3 and _gateway_hpke_v3_enabled():
        return counter
    return GATEWAY_RELAY_KEY_VERSION


def _peer_relay_key_version_from_pairing_grant(approved: dict, client_payload: dict) -> int:
    """Read peer gateway-wrap capability from the authenticated pairing grant.

    Runtime relay state is untrusted and never upgrades a peer. The device-code
    grant is the authenticated setup channel, so this is the only automatic path
    that may persist a v3-capable peer. Unknown/missing values floor to v2.
    """
    candidates = (approved, client_payload)
    version_keys = (
        "gatewayRelayKeyVersion",
        "peerRelayKeyVersion",
        "phoneRelayKeyVersion",
        "relayKeyVersion",
    )
    for source in candidates:
        if not isinstance(source, dict):
            continue
        for key in version_keys:
            version = _coerce_peer_relay_key_version(source.get(key))
            if version == GATEWAY_RELAY_KEY_VERSION_V3:
                return version
    encryption_keys = ("gatewayRelayEncryption", "relayEncryption")
    for source in candidates:
        if not isinstance(source, dict):
            continue
        for key in encryption_keys:
            if str(source.get(key) or "") == GATEWAY_RELAY_ENCRYPTION_V3:
                return GATEWAY_RELAY_KEY_VERSION_V3 if _gateway_hpke_v3_enabled() else GATEWAY_RELAY_KEY_VERSION
    return GATEWAY_RELAY_KEY_VERSION


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
        "byteCount": byte_count,
    }
    if relay_envelope is not None:
        # Sealed path: fileName, the real contentType, and the plaintext byteCount
        # all live INSIDE the sealed manifest — never send them to the untrusted
        # relay. The server already neutralizes contentType to
        # application/octet-stream on the sealed path, so we omit it here (MP-12).
        # The top-level byteCount above is the CIPHERTEXT length (≈ plaintext + GCM
        # overhead): it reveals approximate size only, no content, and the server
        # needs it for the upload size gate.
        body["relayEnvelope"] = relay_envelope
        body["relayEncryption"] = relay_envelope.get("relayEncryption") or RELAY_ENCRYPTION
        # MP-10: no top-level relayKeyVersion on a sealed write — the relayEnvelope
        # carries the authoritative gateway wrap version (server + phone read THAT,
        # never this body field). The top-level relayEncryption mirrors the envelope
        # only as a server routing/indexing hint.
        # MP-2: echo the agent's AAD-bound attachment id so the server adopts it
        # (adoptedGatewayDocId) byte-for-byte instead of minting a different id —
        # otherwise the phone rebuilds all three attachment AADs from the server id
        # and every AEAD open fails.
        body["attachmentId"] = relay_envelope["attachmentId"]
    else:
        body["contentType"] = content_type
        body["fileName"] = file_path.name

    response = await client.post(
        f"{api_base}/attachments/init",
        headers=_signed_headers(token, "POST", f"{api_base}/attachments/init", json_body=body),
        json=body,
    )
    response.raise_for_status()
    payload = response.json()
    attachment = payload.get("attachment") or {}
    attachment_id = attachment.get("id")
    upload_url = payload.get("uploadURL")
    if not attachment_id or not upload_url:
        raise RuntimeError("BurnBar attachment init response was missing attachment.id or uploadURL")
    if relay_envelope is not None:
        expected_id = relay_envelope.get("attachmentId")
        if expected_id and str(attachment_id) != str(expected_id):
            raise _RelayPlaintextRefused(
                "attachment init returned a different id than the AAD-bound attachmentId "
                f"({attachment_id!r} != {expected_id!r})"
            )
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
    finalize_body = {
        "attachmentId": attachment_id,
        "destinationId": destination_id,
        "sha256": hashlib.sha256(uploaded_bytes).hexdigest(),
    }
    response = await client.post(
        f"{api_base}/attachments/finalize",
        headers=_signed_headers(token, "POST", f"{api_base}/attachments/finalize", json_body=finalize_body),
        json=finalize_body,
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
    action_id: str | None = None,
    kind: str | None = None,
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
        envelope = sealer.seal_message(
            destination_id=destination_id,
            text=clipped,
            thread_id=thread_id,
            action_id=action_id,
            kind=kind,
        )
        if envelope.get("ratchetEnvelope") is not None:
            body["ratchetEnvelope"] = envelope["ratchetEnvelope"]
        else:
            body["relayEnvelope"] = envelope
            body["relayEncryption"] = envelope.get("relayEncryption") or RELAY_ENCRYPTION
        # MP-10: no top-level relayKeyVersion on a sealed write — the relayEnvelope
        # carries the authoritative gateway wrap version (server + phone read THAT,
        # never this body field). The top-level relayEncryption mirrors the envelope
        # only as a server routing/indexing hint.
        # MP-2: echo the agent's AAD-bound message id so the server adopts it
        # (safeIdentifier) byte-for-byte instead of minting a different id —
        # otherwise the phone rebuilds the message AAD from the server id and the
        # AEAD open fails (the whole agent->phone reply channel breaks).
        body["messageId"] = envelope["messageId"]
    elif sealer is not None and sealer.must_seal:
        # E2E negotiated but we cannot seal (no peer key, or crypto/identity load
        # failed). Refuse rather than leak plaintext on a paired link (fail-closed).
        raise _RelayPlaintextRefused(sealer.cannot_seal_reason("exchange messages"))
    else:
        body["text"] = clipped
    response = await client.post(
        f"{api_base}/messages",
        headers=_signed_headers(token, "POST", f"{api_base}/messages", json_body=body),
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
            and self._adapter._relay_e2e_config_error is None
            and self._adapter._ensure_relay_identity() is not None
            and bool(self._adapter._peer_public_key)
        )

    @property
    def must_seal(self) -> bool:
        """True when plaintext is forbidden on this link — never emit it.

        Deliberately independent of whether the relay identity / peer key is
        available: once a link is E2E-paired, plaintext is forbidden even when
        crypto cannot be loaded. The send path checks ``can_seal`` first (seal)
        and falls back to refusing — never to plaintext — when ``must_seal`` is
        True but ``can_seal`` is False.

        MP-5: also forbid plaintext when this agent holds a relay identity (it
        completed E2E setup) but the link is not E2E-paired, so the untrusted relay
        cannot harvest plaintext by advertising the link as "legacy". An operator
        can opt back into the plaintext relay path explicitly with
        ``BURNBAR_ALLOW_PLAINTEXT=1``.
        """
        if self._adapter._relay_e2e_enabled:
            return True
        return (
            self._adapter._has_relay_identity_without_e2e
            and not self._adapter._plaintext_explicitly_allowed
        )

    def _peer_key_for(self, destination_id: str) -> Optional[str]:
        return self._adapter._peer_public_keys.get(destination_id) or self._adapter._peer_public_key

    def _can_ratchet(self) -> bool:
        return (
            HERMES_RATCHET_AVAILABLE
            and CRYPTOGRAPHY_PRIMITIVES_AVAILABLE
            and self._adapter._relay_e2e_enabled
            and self._adapter._ratchet_private_payload() is not None
            and self._adapter._ratchet_peer_bundle() is not None
        )

    def cannot_seal_reason(self, action: str) -> str:
        """Explain why an E2E-paired link cannot seal right now (fail-closed copy)."""
        if not self._adapter._relay_e2e_enabled and self._adapter._has_relay_identity_without_e2e:
            return (
                f"this agent has an end-to-end relay identity but the BurnBar link is "
                f"not E2E-paired; refusing to {action} in plaintext. Re-pair with an "
                f"E2EE-capable BurnBar, or set BURNBAR_ALLOW_PLAINTEXT=1 to opt in to "
                f"the legacy plaintext relay path."
            )
        if self._adapter._relay_e2e_config_error:
            return self._adapter._relay_e2e_config_error
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

    def _inbound_plaintext_refusal_reason(self, kind: str) -> str:
        """Explain why an unsealed inbound ``kind`` is refused (fail-closed, P2-1).

        Mirrors the send-side ``must_seal`` predicate so the receive path is
        SYMMETRIC with it: once plaintext is forbidden on a link, an untrusted relay
        cannot DRIVE the agent with an injected plaintext event/control just by
        advertising an E2E-capable link as "legacy". Re-pairing (or an explicit
        ``BURNBAR_ALLOW_PLAINTEXT=1`` opt-in) is the only way back to plaintext.
        """
        if self._adapter._relay_e2e_enabled:
            return (
                f"received a legacy plaintext {kind} on an E2E-paired link; "
                f"upgrade BurnBar on the sender"
            )
        return (
            f"this agent holds an end-to-end relay identity but the BurnBar link is not "
            f"E2E-paired; refusing a relay-supplied plaintext {kind} (an untrusted relay "
            f"must not drive the agent). Re-pair with an E2EE-capable BurnBar, or set "
            f"BURNBAR_ALLOW_PLAINTEXT=1 to opt into the legacy plaintext relay path."
        )


    def _wrap_content_key(
        self,
        *,
        peer: str,
        key_data: bytes,
        key_aad: bytes,
        sender_private,
        destination_id: str,
    ) -> dict:
        """Wrap one content key to ``peer`` and return the version-specific
        envelope fields (``wrappedKey`` + version markers, plus ``enc`` for v3).

        Chooses RFC 9180 HPKE Auth v3 only when the peer's authenticated
        capability advertises v3 (:meth:`BurnBarAdapter._peer_relay_key_version_for`);
        otherwise the byte-stable v2 authenticated 2-DH wrap. In BOTH paths the
        agent's own static relay key is bound as the authenticated sender, so the
        phone opens the wrap only against this agent's pinned key. v2 callers get a
        byte-identical envelope (no ``enc`` field, ``relayKeyVersion`` 2).
        """
        version = self._adapter._peer_relay_key_version_for(destination_id)
        if version >= GATEWAY_RELAY_KEY_VERSION_V3 and RELAY_CRYPTO_AVAILABLE:
            wrap = relay_e2ee.wrap_symmetric_key_v3(
                key_data, peer, key_aad, sender_private=sender_private
            )
            return {
                "wrappedKey": wrap.wrapped_key,
                "enc": wrap.enc,
                "relayEncryption": wrap.relay_encryption,
                "relayKeyVersion": wrap.relay_key_version,
                "senderPublicKey": sender_private.public_key_base64(),
            }
        wrapped = relay_e2ee.wrap_symmetric_key(
            key_data, peer, key_aad, sender_private=sender_private
        )
        return {
            "wrappedKey": wrapped,
            "relayEncryption": RELAY_ENCRYPTION,
            "relayKeyVersion": GATEWAY_RELAY_KEY_VERSION,
            "senderPublicKey": sender_private.public_key_base64(),
        }

    def seal_message(
        self,
        *,
        destination_id: str,
        text: str,
        thread_id: str | None = None,
        action_id: str | None = None,
        kind: str | None = None,
    ) -> dict:
        if self._can_ratchet():
            return self._seal_ratchet_message(
                destination_id=destination_id,
                text=text,
                thread_id=thread_id,
                action_id=action_id,
                kind=kind,
            )
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
        # Sealed payload schema (MP-27): {text, destinationId, threadId?,
        # actionId?, kind?}. The phone decodes this JSON (never renders it raw) and
        # trusts the sealed routing fields over relay-visible top-level metadata.
        payload: Dict[str, Any] = {"text": text, "destinationId": destination_id}
        if thread_id:
            payload["threadId"] = thread_id
        if action_id:
            payload["actionId"] = action_id
        if kind:
            payload["kind"] = kind
        payload_ct = relay_e2ee.seal_to_base64(
            json.dumps(payload).encode("utf-8"),
            sym,
            _gateway_message_aad(self._uid, self._client_id, message_id),
        )
        fields = self._wrap_content_key(
            peer=peer,
            key_data=sym,
            key_aad=_gateway_message_key_aad(self._uid, self._client_id, message_id),
            sender_private=sender_private,
            destination_id=destination_id,
        )
        return {"payloadCiphertext": payload_ct, **fields, "messageId": message_id}

    def _seal_ratchet_message(
        self,
        *,
        destination_id: str,
        text: str,
        thread_id: str | None,
        action_id: str | None,
        kind: str | None,
    ) -> dict:
        local = self._adapter._ratchet_private_payload()
        peer = self._adapter._ratchet_peer_bundle()
        if not local or not peer:
            raise _RelayPlaintextRefused(self.cannot_seal_reason("exchange messages"))
        message_id = secrets.token_hex(16)
        payload: Dict[str, Any] = {"text": text, "destinationId": destination_id}
        if thread_id:
            payload["threadId"] = thread_id
        if action_id:
            payload["actionId"] = action_id
        if kind:
            payload["kind"] = kind

        session_id = self._adapter._current_ratchet_session_id()
        state = self._adapter._load_ratchet_session(session_id) if session_id else None
        if state is None:
            initial = hermes_ratchet.generate_key_pair()
            session_id = _ratchet_session_id(
                uid=self._uid,
                client_id=self._client_id,
                initiator_role="agent",
                initiator_identity_public_key_base64=local["identityPublicKeyBase64"],
                responder_identity_public_key_base64=peer["identityPublicKeyBase64"],
                initiator_signed_prekey_public_key_base64=local["signedPreKeyPublicKeyBase64"],
                responder_signed_prekey_public_key_base64=peer["signedPreKeyPublicKeyBase64"],
                initiator_initial_ratchet_public_key_base64=initial.public_key_base64,
            )
            shared = _ratchet_initiator_shared_secret(
                uid=self._uid,
                client_id=self._client_id,
                initiator_role="agent",
                local_identity_private_key_base64=local["identityPrivateKeyBase64"],
                local_signed_prekey_public_key_base64=local["signedPreKeyPublicKeyBase64"],
                local_initial_ratchet_key_pair=initial,
                remote_identity_public_key_base64=peer["identityPublicKeyBase64"],
                remote_signed_prekey_public_key_base64=peer["signedPreKeyPublicKeyBase64"],
            )
            state = hermes_ratchet.initiator_state(
                session_id=session_id,
                local_device_id=_ratchet_device_id("agent", local["identityPublicKeyBase64"]),
                remote_device_id=_ratchet_device_id("phone", peer["identityPublicKeyBase64"]),
                shared_secret=shared,
                remote_initial_ratchet_public_key_base64=peer["signedPreKeyPublicKeyBase64"],
                local_initial_ratchet_key_pair=initial,
            )
        envelope = hermes_ratchet.encrypt(
            json.dumps(payload).encode("utf-8"),
            state,
            associated_data=_gateway_message_aad(self._uid, self._client_id, message_id),
        )
        self._adapter._save_ratchet_session(state)
        self._adapter._save_current_ratchet_session_id(state.session_id)
        return {"ratchetEnvelope": envelope.to_wire(), "messageId": message_id}

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
            {
                "fileName": file_path.name,
                "byteCount": len(data),
                "contentType": content_type,
                "destinationId": destination_id,
            }
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
        fields = self._wrap_content_key(
            peer=peer,
            key_data=body_key,
            key_aad=_gateway_attachment_key_aad(self._uid, self._client_id, attachment_id),
            sender_private=sender_private,
            destination_id=destination_id,
        )
        envelope = {"payloadCiphertext": manifest_ct, **fields, "attachmentId": attachment_id}
        return envelope, body_bytes

    def open_event(self, raw: dict) -> Optional[dict]:
        """Open a sealed inbound event in place.

        Returns the opened ``{text, senderDisplayName?, threadId?}`` dict, or
        ``None`` when the event carries no relay envelope (legacy plaintext).
        Raises :class:`_RelayPlaintextRefused` when E2E is required but the event
        is unsealed.
        """
        ratchet_envelope = raw.get("ratchetEnvelope")
        if isinstance(ratchet_envelope, dict):
            return self._open_ratchet_event(raw, ratchet_envelope)
        envelope = raw.get("relayEnvelope")
        if not isinstance(envelope, dict):
            envelope = None
        # Some servers flatten the envelope onto the event; tolerate both shapes.
        if envelope is None and raw.get("payloadCiphertext") and raw.get("wrappedKey"):
            envelope = {
                "payloadCiphertext": raw.get("payloadCiphertext"),
                "wrappedKey": raw.get("wrappedKey"),
            }
            for field in ("enc", "relayEncryption", "relayKeyVersion", "senderPublicKey", "eventId"):
                if raw.get(field) is not None:
                    envelope[field] = raw.get(field)
        if not isinstance(envelope, dict) or not envelope.get("payloadCiphertext"):
            # Fail-closed: refuse an unsealed (plaintext) event whenever plaintext is
            # forbidden on this link — the SAME predicate the send path uses
            # (``must_seal``). That covers BOTH an E2E-paired link AND the MP-5 state
            # (this agent holds a relay identity but the link is not yet E2E-paired):
            # an untrusted relay must not DRIVE the agent with an injected plaintext
            # event just because it advertised the link as "legacy". Only a link with
            # no relay identity at all (or an explicit BURNBAR_ALLOW_PLAINTEXT=1 opt-in)
            # still accepts the legacy plaintext path.
            if self.must_seal:
                raise _RelayPlaintextRefused(self._inbound_plaintext_refusal_reason("event"))
            return None
        if self._adapter._relay_e2e_config_error:
            raise _RelayPlaintextRefused(self._adapter._relay_e2e_config_error)
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
        ratchet_envelope = raw.get("ratchetEnvelope")
        if isinstance(ratchet_envelope, dict):
            return self._open_ratchet_event(raw, ratchet_envelope)
        envelope = raw.get("relayEnvelope")
        if not isinstance(envelope, dict) or not envelope.get("payloadCiphertext"):
            # Symmetric with ``must_seal`` (P2-1): refuse an unsealed control event
            # whenever plaintext is forbidden on this link, not only on a paired link.
            if self.must_seal:
                raise _RelayPlaintextRefused(
                    self._inbound_plaintext_refusal_reason("model_switch")
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
            json.dumps(
                {"kind": "model_switch", "modelId": model_id, "destinationId": destination_id}
            ).encode("utf-8"),
            sym,
            payload_aad,
        )
        fields = self._wrap_content_key(
            peer=peer,
            key_data=sym,
            key_aad=key_aad,
            sender_private=sender_private,
            destination_id=destination_id,
        )
        return {"payloadCiphertext": payload_ct, **fields, "eventId": event_id}

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
        event_id = str(envelope.get("eventId") or raw.get("id") or "")
        payload_aad = payload_aad_builder(self._uid, self._client_id, event_id)
        key_aad = key_aad_builder(self._uid, self._client_id, event_id)
        # v2-only authenticated open: require the gateway wrap protocol AND bind the
        # phone's PINNED relay key as the sender. Fail closed on a v1 envelope or a
        # missing pin — unwrapping without the pinned sender key (or accepting v1)
        # would reopen the anonymous-sender forgery this upgrade closes. The pinned
        # key (never the relay-supplied wire field) is what makes the static-static
        # DH authenticate the sender.
        pinned_phone = (
            self._adapter._peer_public_key
            or self._adapter._peer_public_keys.get(str(raw.get("destinationId") or ""))
        )
        version = envelope.get("relayKeyVersion", raw.get("relayKeyVersion"))
        try:
            version_int = int(version) if version is not None else 0
        except (TypeError, ValueError):
            version_int = 0
        # Dispatch v2 (authenticated 2-DH) or v3 (RFC 9180 HPKE Auth) and refuse
        # everything else: a stripped/forged version, a v1 wrap, or a downgrade to
        # 1/0 all fail closed here, so plaintext and the anonymous-sender v1 wrap
        # stay unreachable on a paired link. Both paths bind the PINNED phone key
        # (never the wire senderPublicKey), so a missing pin is refused too.
        if not pinned_phone or version_int not in _SUPPORTED_GATEWAY_RELAY_VERSIONS:
            raise _RelayPlaintextRefused(
                "refusing a non-v2/v3 or unpinned gateway envelope: the authenticated "
                "sender pin is required to open"
            )
        if version_int == GATEWAY_RELAY_KEY_VERSION_V3:
            relay_encryption = envelope.get("relayEncryption", raw.get("relayEncryption"))
            if relay_encryption != GATEWAY_RELAY_ENCRYPTION_V3:
                raise _RelayPlaintextRefused(
                    "refusing a v3 gateway envelope without the HPKE relayEncryption marker"
                )
            enc = envelope.get("enc") or raw.get("enc")
            if not enc:
                raise _RelayPlaintextRefused(
                    "refusing a v3 gateway envelope without its HPKE `enc` encapsulated key"
                )
            sym = relay_e2ee.unwrap_symmetric_key_v3(
                enc, envelope["wrappedKey"], private_key, key_aad,
                pinned_sender_public=pinned_phone,
            )
        else:
            sym = relay_e2ee.unwrap_symmetric_key(
                envelope["wrappedKey"], private_key, key_aad, sender_public_base64=pinned_phone
            )
        plaintext = relay_e2ee.open_base64(envelope["payloadCiphertext"], sym, payload_aad)
        # MP-21: the wire senderPublicKey is ADVISORY only. The unwrap above already
        # authenticated this frame against the PINNED phone key, so the carried field
        # cannot weaken that proof. We still pass it to _pin_peer_public_key to (a)
        # confirm it matches the pin and (b) emit the MITM warning if it diverges, but
        # we intentionally IGNORE the return value: a mismatching advisory field does
        # not invalidate an already-authenticated frame, and allow_new_pin=False means
        # it can never seed a new pin. Policy = accept-but-warn (documented), not
        # hard-drop, because the crypto — not the wire field — is the trust anchor.
        peer = raw.get("senderPublicKey") or envelope.get("senderPublicKey")
        if peer:
            destination_id = str(raw.get("destinationId") or "")
            _ = self._adapter._pin_peer_public_key(
                destination_id, str(peer), source="event", allow_new_pin=False
            )
        decoded = json.loads(plaintext.decode("utf-8"))
        return decoded if isinstance(decoded, dict) else {"text": str(decoded)}

    def _open_ratchet_event(self, raw: dict, envelope_raw: dict) -> dict:
        local = self._adapter._ratchet_private_payload()
        peer = self._adapter._ratchet_peer_bundle()
        if not local or not peer or not HERMES_RATCHET_AVAILABLE:
            raise _RelayPlaintextRefused("ratchet event received but ratchet state is unavailable")
        envelope = hermes_ratchet.HermesRatchetEnvelope.from_wire(envelope_raw)
        state = self._adapter._load_ratchet_session(envelope.header.session_id)
        if state is None:
            if not str(envelope.header.sender_device_id).startswith("phone:"):
                raise _RelayPlaintextRefused("ratchet session is missing for non-phone-initiated event")
            shared = _ratchet_responder_shared_secret(
                uid=self._uid,
                client_id=self._client_id,
                initiator_role="phone",
                local_identity_private_key_base64=local["identityPrivateKeyBase64"],
                local_signed_prekey_private_key_base64=local["signedPreKeyPrivateKeyBase64"],
                local_identity_public_key_base64=local["identityPublicKeyBase64"],
                local_signed_prekey_public_key_base64=local["signedPreKeyPublicKeyBase64"],
                remote_identity_public_key_base64=peer["identityPublicKeyBase64"],
                remote_signed_prekey_public_key_base64=peer["signedPreKeyPublicKeyBase64"],
                remote_initial_ratchet_public_key_base64=envelope.header.ratchet_public_key_base64,
            )
            state = hermes_ratchet.responder_state(
                session_id=envelope.header.session_id,
                local_device_id=envelope.header.receiver_device_id,
                remote_device_id=envelope.header.sender_device_id,
                shared_secret=shared,
                local_initial_ratchet_key_pair=hermes_ratchet.HermesRatchetKeyPair(
                    private_key_base64=local["signedPreKeyPrivateKeyBase64"],
                    public_key_base64=local["signedPreKeyPublicKeyBase64"],
                ),
            )
        event_id = str(raw.get("id") or envelope_raw.get("eventId") or "")
        plaintext = hermes_ratchet.decrypt(
            envelope,
            state,
            associated_data=_gateway_event_aad(self._uid, self._client_id, event_id),
        )
        self._adapter._save_ratchet_session(state)
        self._adapter._save_current_ratchet_session_id(state.session_id)
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
        # Human-in-the-loop oversight. On legacy plaintext links the server toggle
        # is mirrored from /state. On E2E-paired links the mode is pinned from
        # BURNBAR_OVERSIGHT_MODE at pairing (an untrusted relay must not flip it).
        pinned_oversight = (os.getenv(OVERSIGHT_MODE_ENV) or "").strip()
        self._oversight_mode = (
            pinned_oversight if pinned_oversight in ("supervised", "autonomous") else "supervised"
        )
        self._oversight_checked_at = 0.0
        # Armed approval gates awaiting a phone decision: actionId -> context.
        self._pending_confirms: Dict[str, Dict[str, Any]] = {}
        # --- E2E relay state ---
        # The agent's own relay identity (private key persisted to Keychain).
        # Lazily loaded so the import-time path stays cheap and so a missing
        # `cryptography` never blocks the plaintext (legacy) link.
        self._relay_identity = None
        # The paired phone's relay public key(s). `_peer_public_key` is the
        # default/home link; `_peer_public_keys[destinationId]` overrides per link.
        # Seeded from pairing (persisted to ~/.hermes/.env), refreshed from polls.
        self._peer_public_key: Optional[str] = (os.getenv("BURNBAR_RELAY_PEER_PUBLIC_KEY") or "").strip() or None
        self._peer_public_keys: Dict[str, str] = {}
        # Per-link relay WRAP capability (which key-wrap version to EMIT). Defaults
        # to the v2 floor; only the authenticated BURNBAR_RELAY_PEER_KEY_VERSION pin
        # (or a per-destination override seeded at pairing) raises a link to v3,
        # never the untrusted relay runtime path. Emit-only: the open path is
        # version-dispatched independently and always binds the pinned sender.
        self._peer_relay_key_version_default: int = _coerce_peer_relay_key_version(
            os.getenv(RELAY_PEER_KEY_VERSION_ENV)
        )
        self._peer_relay_key_versions: Dict[str, int] = {}
        # Replay defense for the current uid/clientId/pinned-peer tuple. A relay
        # can redeliver a valid sealed event; the AAD binds the id, so the bounded
        # digest cache drops normal duplicates, and the sealed replay counter's
        # high-water mark keeps an old authenticated event from being accepted once
        # after the digest cache saturates.
        self._seen_event_ids: "collections.OrderedDict[str, None]" = collections.OrderedDict()
        self._event_replay_high_water = -1
        self._malformed_sealed_event_failures: "collections.OrderedDict[str, float]" = collections.OrderedDict()
        self._malformed_sealed_event_failure_times: "collections.deque[float]" = collections.deque()
        # E2E negotiated at pairing (server reports the link relay-capable).
        self._relay_e2e_enabled = (os.getenv(RELAY_E2E_ENV) or "").strip() == "1"
        self._agent_ratchet_prekey_bundle: Optional[dict[str, Any]] = None
        self._agent_ratchet_private_bundle: Optional[dict[str, Any]] = None
        self._ratchet_sessions: Dict[str, Any] = {}
        # AAD identity binding. uid/clientId are routing ids the server echoes and
        # every gateway AAD includes. On E2E links they MUST come from the
        # authenticated pairing grant (persisted env). Learning the first value from
        # runtime /events|/state would let a malicious relay pin the wrong AAD
        # identity and permanently DoS decrypts, so E2E fails closed if either is
        # absent. Legacy plaintext can still use deterministic local fallbacks.
        env_uid = (os.getenv("BURNBAR_RELAY_UID") or "").strip()
        env_client_id = (os.getenv("BURNBAR_RELAY_CLIENT_ID") or "").strip()
        self._relay_uid = env_uid if self._relay_e2e_enabled else (env_uid or _sha256(self._token or "anon")[:32])
        self._relay_client_id = env_client_id if self._relay_e2e_enabled else (env_client_id or self._home_channel)
        self._relay_uid_pinned = bool(env_uid)
        self._relay_client_id_pinned = bool(env_client_id)
        self._relay_e2e_config_error: Optional[str] = None
        if self._relay_e2e_enabled and (not self._relay_uid_pinned or not self._relay_client_id_pinned):
            missing = []
            if not self._relay_uid_pinned:
                missing.append("BURNBAR_RELAY_UID")
            if not self._relay_client_id_pinned:
                missing.append("BURNBAR_RELAY_CLIENT_ID")
            self._relay_e2e_config_error = (
                "end-to-end encryption is enabled but the authenticated pairing grant "
                f"did not persist {', '.join(missing)}; refusing the relay link until "
                "you re-run setup with a gateway that returns uid and clientId"
            )
            logger.error("[%s] SECURITY: %s", self.name, self._relay_e2e_config_error)
        # MP-5: explicit operator opt-in to the legacy plaintext relay path even
        # though this agent is E2E-capable (holds a persisted relay identity).
        self._plaintext_explicitly_allowed = (os.getenv("BURNBAR_ALLOW_PLAINTEXT") or "").strip() == "1"
        if RELAY_CRYPTO_AVAILABLE and self._relay_e2e_enabled:
            self._ensure_relay_identity()
            self._agent_ratchet_prekey_bundle = _agent_ratchet_prekey_bundle()
        self._load_replay_ledger()
        self._sealer = _RelaySealer(self)

    # ------------------------------------------------------------------
    # Relay identity / peer key management
    # ------------------------------------------------------------------
    def _ensure_relay_identity(self):
        """Load (or create+persist) the agent relay private key. Returns it or None.

        A freshly minted key is persisted to macOS Keychain so the agent's relay
        identity is stable across restarts without placing private key material
        in ``~/.hermes/.env``. A legacy ``BURNBAR_RELAY_PRIVATE_KEY`` value is
        accepted only as a validated import source, then copied to Keychain.
        """
        if not RELAY_CRYPTO_AVAILABLE:
            return None
        if self._relay_identity is not None:
            return self._relay_identity
        persist = self._relay_key_persister()
        try:
            self._relay_identity = _load_or_create_relay_identity_secure(persist=persist)
        except relay_e2ee.CorruptIdentityError:
            logger.error(
                "[%s] corrupt relay private key; refusing E2E (re-pair or delete the key)",
                self.name,
            )
            raise
        except Exception:
            logger.debug("[%s] Could not load relay identity", self.name, exc_info=True)
            self._relay_identity = None
        return self._relay_identity

    @staticmethod
    def _relay_key_persister():
        """Return a ``(env_var, value) -> None`` persister for relay private keys."""
        return _relay_key_persister()

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

    def _ratchet_public_payload(self) -> dict[str, Any]:
        if self._agent_ratchet_prekey_bundle is None:
            self._agent_ratchet_prekey_bundle = _agent_ratchet_prekey_bundle()
        return dict(self._agent_ratchet_prekey_bundle or {})

    def _ratchet_private_payload(self) -> Optional[dict[str, Any]]:
        if self._agent_ratchet_private_bundle is None:
            self._agent_ratchet_private_bundle = _agent_ratchet_private_bundle()
        return dict(self._agent_ratchet_private_bundle or {}) or None

    def _ratchet_peer_bundle(self) -> Optional[dict[str, str]]:
        identity = (os.getenv(RATCHET_PEER_IDENTITY_PUBLIC_KEY_ENV) or "").strip()
        signing = (os.getenv(RATCHET_PEER_SIGNING_PUBLIC_KEY_ENV) or "").strip()
        signed_prekey = (os.getenv(RATCHET_PEER_SIGNED_PREKEY_PUBLIC_KEY_ENV) or "").strip()
        signed_prekey_id = (os.getenv(RATCHET_PEER_SIGNED_PREKEY_ID_ENV) or "").strip()
        signature = (os.getenv(RATCHET_PEER_SIGNED_PREKEY_SIGNATURE_ENV) or "").strip()
        if not all((identity, signing, signed_prekey, signed_prekey_id, signature)):
            return None
        if not _verify_ratchet_signed_prekey(
            signing_public_key_base64=signing,
            identity_public_key_base64=identity,
            signed_prekey_public_key_base64=signed_prekey,
            signed_prekey_id=signed_prekey_id,
            signature_base64=signature,
        ):
            return None
        return {
            "identityPublicKeyBase64": identity,
            "signingPublicKeyBase64": signing,
            "signedPreKeyPublicKeyBase64": signed_prekey,
            "signedPreKeyId": signed_prekey_id,
            "signedPreKeySignatureBase64": signature,
        }

    @staticmethod
    def _ratchet_session_account(session_id: str) -> str:
        return f"session|{session_id}"

    def _load_ratchet_session(self, session_id: str):
        if not HERMES_RATCHET_AVAILABLE:
            return None
        if session_id in self._ratchet_sessions:
            return self._ratchet_sessions[session_id]
        account = self._ratchet_session_account(session_id)
        raw: Optional[str] = None
        if _relay_keychain_command() is not None:
            raw = _load_private_key_base64_from_keychain(
                RATCHET_SESSION_KEYCHAIN_SERVICE,
                account,
                "BurnBar ratchet session state",
            )
        if raw:
            state = hermes_ratchet.HermesRatchetSessionState.from_wire(json.loads(raw))
            self._ratchet_sessions[session_id] = state
            return state
        return None

    def _save_ratchet_session(self, state) -> None:
        self._ratchet_sessions[state.session_id] = state
        raw = json.dumps(state.to_wire(), sort_keys=True)
        if _relay_keychain_command() is not None:
            _store_private_key_base64_to_keychain(
                RATCHET_SESSION_KEYCHAIN_SERVICE,
                self._ratchet_session_account(state.session_id),
                raw,
                "BurnBar ratchet session state",
            )

    def _current_ratchet_session_id(self) -> Optional[str]:
        raw = (os.getenv("BURNBAR_RATCHET_CHAT_SESSION_ID") or "").strip()
        return raw or None

    def _save_current_ratchet_session_id(self, session_id: str) -> None:
        save_env_value("BURNBAR_RATCHET_CHAT_SESSION_ID", session_id)

    @property
    def _has_relay_identity_without_e2e(self) -> bool:
        """MP-5: True when the agent is E2E-capable (a relay private key is
        persisted) but the link is not E2E-paired — the state where an untrusted
        relay could otherwise harvest plaintext by advertising the link as legacy.
        """
        if not RELAY_CRYPTO_AVAILABLE or self._relay_e2e_enabled:
            return False
        if self._relay_identity is not None:
            return True
        if (os.getenv(RELAY_PRIVATE_KEY_ENV) or "").strip():
            return True
        try:
            return _load_relay_private_key_base64_from_keychain() is not None
        except Exception:
            logger.warning(
                "[%s] could not inspect relay private key store; refusing legacy plaintext downgrade",
                self.name,
                exc_info=True,
            )
            return True

    def _pin_peer_public_key(
        self,
        destination_id: str,
        public_key_b64: str,
        *,
        source: str,
        allow_new_pin: bool = False,
    ) -> bool:
        """Pin the peer relay public key once (trust-on-first-use), then treat it as IMMUTABLE.

        The relay server is untrusted: ``senderPublicKey`` / ``relayPublicKey`` on
        an inbound doc are NOT authenticated. So a NEW pin (the very first peer
        key for this link) may only be established by an explicit authenticated
        pairing caller (``allow_new_pin=True``), then persisted to
        ``BURNBAR_RELAY_PEER_PUBLIC_KEY`` and read at ``__init__``. The live
        runtime responses (``/destinations`` / ``/events`` / ``/state``) flow in
        through :meth:`_absorb_relay_state` with ``allow_new_pin=False`` so a
        compromised relay can never TOFU-seed an attacker key once a persisted pin
        was lost — it refuses to seal (clear error) instead of pin-jacking.

        Once a key IS pinned, this is the immutability guard for every source: a
        *changed* key is rejected (logged, not adopted) as a possible MITM and we
        return ``False`` so callers (e.g. event handling) can drop the event. A
        re-advertised matching key is idempotent.

        Rotation is explicit re-pair only: no relay-supplied update, signed or
        unsigned, can change a pin in place.
        """
        if not public_key_b64:
            return True
        if RELAY_CRYPTO_AVAILABLE:
            try:
                relay_e2ee.public_key_x963_from_base64(public_key_b64)
            except Exception:
                logger.warning(
                    "[%s] SECURITY: refusing malformed peer relay key from source=%s",
                    self.name,
                    source,
                )
                return False
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
            # First key wins (TOFU) only from an explicit authenticated pairing path.
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

    def _replay_peer_fingerprint(self) -> str:
        pinned = (self._peer_public_key or "").strip()
        if not pinned:
            return "legacy"
        if RELAY_CRYPTO_AVAILABLE:
            try:
                raw = relay_e2ee.public_key_x963_from_base64(pinned)
                return hashlib.sha256(raw).hexdigest()
            except Exception:
                logger.warning("[%s] pinned peer relay key is invalid; using opaque replay fingerprint", self.name)
        return hashlib.sha256(pinned.encode("utf-8")).hexdigest()

    def _replay_ledger_bucket(self) -> str:
        material = json.dumps(
            [self._relay_uid, self._relay_client_id, self._replay_peer_fingerprint()],
            separators=(",", ":"),
        )
        return hashlib.sha256(material.encode("utf-8")).hexdigest()

    def _event_replay_key(self, event_id: str) -> str:
        material = json.dumps(
            [self._relay_uid, self._relay_client_id, self._replay_peer_fingerprint(), str(event_id)],
            separators=(",", ":"),
        )
        return hashlib.sha256(material.encode("utf-8")).hexdigest()

    def _load_replay_ledger(self, *, reset: bool = False) -> None:
        """Hydrate the in-memory replay cache from disk (E2E restart hardening)."""
        if reset:
            self._seen_event_ids.clear()
            self._event_replay_high_water = -1
        bucket = self._replay_ledger_bucket()
        entry = _read_replay_ledger().get(bucket, [])
        if isinstance(entry, dict):
            replay_keys = entry.get("ids") if isinstance(entry.get("ids"), list) else []
            high_water = _coerce_replay_counter(entry.get("highWater"))
            self._event_replay_high_water = high_water if high_water is not None else -1
        elif isinstance(entry, list):
            replay_keys = entry
        else:
            replay_keys = []
        for replay_key in replay_keys[-MAX_SEEN_EVENT_IDS:]:
            replay_key = str(replay_key)
            if replay_key:
                self._seen_event_ids[replay_key] = None

    def _persist_replay_ledger(self) -> None:
        """Persist replay cache state for this uid/clientId/peer bucket."""
        bucket = self._replay_ledger_bucket()
        ordered_ids = list(self._seen_event_ids.keys())
        ledger = _read_replay_ledger()
        ledger[bucket] = {
            "ids": ordered_ids[-MAX_SEEN_EVENT_IDS:],
            "highWater": self._event_replay_high_water,
        }
        _write_replay_ledger(ledger)

    def _sealed_event_replay_counter(self, authed: Optional[dict]) -> Optional[int]:
        """Return the authenticated sender replay counter from sealed payload JSON.

        The relay is fully untrusted, so this intentionally ignores top-level raw
        event fields. Only the AES-GCM-authenticated JSON opened with the pinned
        sender key may advance or satisfy the high-water mark.
        """
        if not isinstance(authed, dict):
            return None
        for key in REPLAY_COUNTER_KEYS:
            if key not in authed:
                continue
            counter = _coerce_replay_counter(authed.get(key))
            if counter is None:
                raise _RelayPlaintextRefused("sealed event replayCounter must be a non-negative integer")
            return counter
        if self._relay_e2e_enabled:
            raise _RelayPlaintextRefused(
                "sealed event is missing authenticated replayCounter/eventCounter; "
                "upgrade the sender before processing E2E events"
            )
        return None

    def _is_replay_counter_seen(self, replay_counter: Optional[int]) -> bool:
        return (
            self._relay_e2e_enabled
            and replay_counter is not None
            and replay_counter <= self._event_replay_high_water
        )

    def _is_event_seen(self, event_id: str) -> bool:
        """Read-only replay check (MP-3): True if this id was already processed.

        Does not change cache MEMBERSHIP — on a hit it refreshes recency
        (``move_to_end``) of an ALREADY-recorded id, but recording a NEW id
        happens only in :meth:`_record_event`, after a successful authenticated
        open. That ordering is the
        cache-flush-replay fix: a relay flooding forged-id events with garbage
        ciphertext (all of which fail AEAD) can no longer evict a genuine pending
        id before it is ever authenticated. Idless events are never deduped here
        (the caller refuses idless events on an E2E-paired link).
        """
        if not event_id:
            return False
        key = self._event_replay_key(event_id)
        if key in self._seen_event_ids:
            # Refresh recency so a steadily-redelivered id is not evicted then
            # re-accepted; move it to the most-recent end.
            self._seen_event_ids.move_to_end(key)
            return True
        return False

    def _record_event(self, event_id: str, *, replay_counter: Optional[int] = None) -> bool:
        """Record replay state — call ONLY after a successful authenticated open.

        Recording after authentication (not before) is the replay-cache fix
        (MP-3): only ids that actually authenticated consume a slot, so a
        forged-id flood cannot evict a genuine pending id. The cache is bounded to
        ``MAX_SEEN_EVENT_IDS`` per (uid, clientId); the oldest entries evict first.
        If the sealed payload carries a sender replay counter, also persist a
        monotonic high-water mark so an old event cannot replay once after ID-cache
        saturation.
        """
        if not event_id:
            return not self._relay_e2e_enabled
        key = self._event_replay_key(event_id)
        prior_seen = collections.OrderedDict(self._seen_event_ids)
        prior_high_water = self._event_replay_high_water
        self._seen_event_ids[key] = None
        self._seen_event_ids.move_to_end(key)
        while len(self._seen_event_ids) > MAX_SEEN_EVENT_IDS:
            self._seen_event_ids.popitem(last=False)
        if replay_counter is not None:
            self._event_replay_high_water = max(self._event_replay_high_water, replay_counter)
        try:
            self._persist_replay_ledger()
            return True
        except Exception:
            logger.warning("[%s] failed to persist BurnBar replay ledger", self.name, exc_info=True)
            if self._relay_e2e_enabled:
                self._seen_event_ids = prior_seen
                self._event_replay_high_water = prior_high_water
            # On E2E links, fail closed before dispatching a side-effect. Legacy
            # plaintext keeps the in-memory dedup behavior.
            return not self._relay_e2e_enabled

    def _sealed_event_failure_fingerprint(self, raw: dict) -> str:
        envelope = raw.get("relayEnvelope") if isinstance(raw.get("relayEnvelope"), dict) else {}
        material = {
            "eventId": str(envelope.get("eventId") or raw.get("id") or ""),
            "payloadCiphertext": str(envelope.get("payloadCiphertext") or raw.get("payloadCiphertext") or ""),
            "wrappedKey": str(envelope.get("wrappedKey") or raw.get("wrappedKey") or ""),
            "enc": str(envelope.get("enc") or raw.get("enc") or ""),
            "senderPublicKey": str(envelope.get("senderPublicKey") or raw.get("senderPublicKey") or ""),
            "relayEncryption": str(envelope.get("relayEncryption") or raw.get("relayEncryption") or ""),
            "relayKeyVersion": str(envelope.get("relayKeyVersion") or raw.get("relayKeyVersion") or ""),
        }
        return hashlib.sha256(json.dumps(material, sort_keys=True, separators=(",", ":")).encode()).hexdigest()

    def _prune_malformed_sealed_event_failures(self, now: float) -> None:
        expired = [
            key for key, seen_at in self._malformed_sealed_event_failures.items()
            if now - seen_at > MALFORMED_SEALED_EVENT_THROTTLE_SECONDS
        ]
        for key in expired:
            self._malformed_sealed_event_failures.pop(key, None)
        while (
            self._malformed_sealed_event_failure_times
            and now - self._malformed_sealed_event_failure_times[0] > MALFORMED_SEALED_EVENT_THROTTLE_SECONDS
        ):
            self._malformed_sealed_event_failure_times.popleft()

    def _drop_throttled_malformed_sealed_event(self, raw: dict) -> bool:
        if not self._relay_e2e_enabled:
            return False
        now = time.monotonic()
        self._prune_malformed_sealed_event_failures(now)
        key = self._sealed_event_failure_fingerprint(raw)
        seen_at = self._malformed_sealed_event_failures.get(key)
        if seen_at is not None:
            self._malformed_sealed_event_failures.move_to_end(key)
            return True
        return len(self._malformed_sealed_event_failure_times) >= MAX_MALFORMED_SEALED_EVENT_FAILURES_PER_WINDOW

    def _record_malformed_sealed_event_failure(self, raw: dict) -> None:
        if not self._relay_e2e_enabled:
            return
        now = time.monotonic()
        self._prune_malformed_sealed_event_failures(now)
        self._malformed_sealed_event_failure_times.append(now)
        key = self._sealed_event_failure_fingerprint(raw)
        self._malformed_sealed_event_failures[key] = now
        self._malformed_sealed_event_failures.move_to_end(key)
        while len(self._malformed_sealed_event_failures) > MAX_MALFORMED_SEALED_EVENT_FINGERPRINTS:
            self._malformed_sealed_event_failures.popitem(last=False)

    def _absorb_routing_id(self, field: str, value: str) -> None:
        """Confirm-or-warn a runtime routing id (uid/clientId) that feeds every AAD.

        MP-9/F-01: ``uid``/``clientId`` bind every gateway AAD. On E2E links they
        must already be pinned from the authenticated pairing grant; runtime state
        can only confirm or warn. Legacy plaintext links may still learn a first
        value from runtime state because no sealed AAD depends on it.
        """
        if field == "uid":
            current, pinned = self._relay_uid, self._relay_uid_pinned
        else:
            current, pinned = self._relay_client_id, self._relay_client_id_pinned
        if pinned:
            if value != current:
                logger.warning(
                    "[%s] SECURITY: relay %s changed at runtime (%s -> %s); ignoring "
                    "(an untrusted relay must not rotate an AAD-binding id)",
                    self.name,
                    field,
                    current,
                    value,
                )
            return
        if self._relay_e2e_enabled:
            logger.warning(
                "[%s] SECURITY: refusing to pin first relay %s from untrusted runtime "
                "state on an E2E link; re-run setup so the authenticated grant persists it",
                self.name,
                field,
            )
            return
        # First concrete value wins, then lock.
        if field == "uid":
            self._relay_uid = value
            self._relay_uid_pinned = True
        else:
            self._relay_client_id = value
            self._relay_client_id_pinned = True
        self._load_replay_ledger(reset=True)

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

        uid/clientId are routing ids the server echoes (not secret). On E2E links
        they are confirmation-only because they are AAD-binding values.
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
            self._absorb_routing_id("uid", str(uid))
        client_id = payload.get("clientId") or payload.get("id")
        if client_id:
            self._absorb_routing_id("clientId", str(client_id))
        # Deliberately NOT acting on relayCapable/e2eEnabled here: an untrusted
        # runtime response must not flip a never-paired agent into E2E.


    def _peer_relay_key_version_for(self, destination_id: str) -> int:
        """Resolve the relay key-wrap version to EMIT for one destination.

        Returns v3 only when the authenticated capability (the
        ``BURNBAR_RELAY_PEER_KEY_VERSION`` pin or a per-destination override) says
        the paired peer supports it; otherwise the v2 floor. A v2-only peer is
        NEVER auto-upgraded, and an unsupported value floors to v2 — so this only
        ever selects a wrap version both sides implement. This gates emission
        only; the open path dispatches on the envelope's own ``relayKeyVersion``
        and always binds the pinned sender, independent of this value.
        """
        version = self._peer_relay_key_versions.get(str(destination_id or ""))
        if version is None:
            version = self._peer_relay_key_version_default
        if version == GATEWAY_RELAY_KEY_VERSION_V3 and not _gateway_hpke_v3_enabled():
            return GATEWAY_RELAY_KEY_VERSION
        if version in _SUPPORTED_GATEWAY_RELAY_VERSIONS:
            return version
        return GATEWAY_RELAY_KEY_VERSION

    async def connect(self) -> bool:
        if not HTTPX_AVAILABLE:
            logger.warning("[%s] httpx is unavailable", self.name)
            return False
        if not self._token:
            logger.warning("[%s] BURNBAR_ACCESS_TOKEN is not configured", self.name)
            return False
        self._client = httpx.AsyncClient(timeout=30)
        try:
            response = await self._client.get(
                f"{self._api_base}/destinations",
                headers=_signed_headers(self._token, "GET", f"{self._api_base}/destinations"),
            )
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
        events_params = {"cursor": str(self._cursor), "limit": "50"}
        response = await self._client.get(
            f"{self._api_base}/events",
            headers=_signed_headers(self._token, "GET", f"{self._api_base}/events", params=events_params),
            params=events_params,
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
        envelope = raw.get("relayEnvelope") if isinstance(raw.get("relayEnvelope"), dict) else {}
        event_id = str(envelope.get("eventId") or raw.get("id") or "")
        # MP-3: read-only replay check BEFORE decrypt. The id is recorded only after
        # a successful authenticated open (below), so a relay flooding forged-id
        # events with garbage ciphertext (all of which fail AEAD) cannot evict a
        # genuine pending id from the bounded cache.
        if self._is_event_seen(event_id):
            logger.info("[%s] dropped duplicate event id (replay) %s", self.name, event_id)
            return
        # MP-3/MP-7: on an E2E-paired link an event we cannot key (no id) cannot be
        # replay-protected — refuse it rather than process a possibly-replayed
        # sealed event.
        if self._relay_e2e_enabled and not event_id:
            logger.warning("[%s] dropped sealed event with no id (cannot replay-protect)", self.name)
            return
        authed: Optional[dict] = None
        replay_counter: Optional[int] = None
        model_switch_applied = False
        destination_id = str(raw.get("destinationId") or self._home_channel)
        if self._drop_throttled_malformed_sealed_event(raw):
            logger.info("[%s] throttled malformed sealed event", self.name)
            return
        try:
            authed = self._sealer.open_event(raw)
        except _RelayPlaintextRefused as exc:
            self._record_malformed_sealed_event_failure(raw)
            logger.warning("[%s] dropped unsealed event: %s", self.name, exc)
            return
        except Exception:
            self._record_malformed_sealed_event_failure(raw)
            logger.warning("[%s] failed to open sealed event", self.name, exc_info=True)
            return
        if authed is not None:
            kind = str(authed.get("kind") or "").strip()
            sealed_dest = str(authed.get("destinationId") or "").strip()
            if self._relay_e2e_enabled and not sealed_dest:
                logger.warning("[%s] dropped sealed event without authenticated destinationId", self.name)
                return
            destination_id = sealed_dest or destination_id
            try:
                replay_counter = self._sealed_event_replay_counter(authed)
            except _RelayPlaintextRefused as exc:
                logger.warning("[%s] dropped sealed event: %s", self.name, exc)
                return
            if self._is_replay_counter_seen(replay_counter):
                logger.info(
                    "[%s] dropped old sealed event replayCounter=%s highWater=%s",
                    self.name,
                    replay_counter,
                    self._event_replay_high_water,
                )
                return
            if kind == APPROVAL_DECISION_KIND:
                if not self._record_event(event_id, replay_counter=replay_counter):
                    return
                await self._handle_sealed_approval_decision(authed)
                return
            if kind == OVERSIGHT_MODE_KIND:
                if not self._record_event(event_id, replay_counter=replay_counter):
                    return
                self._handle_sealed_oversight_mode(authed)
                return
            if kind == "model_switch":
                model_id = str(authed.get("modelId") or "").strip()
                if not _is_safe_model_id(model_id):
                    logger.warning("[%s] dropped model_switch with unsafe modelId %r", self.name, model_id)
                    return
                text = f"/model {model_id}"
                thread_id = authed.get("threadId")
                model_switch_applied = True
            else:
                text = str(authed.get("text") or "").strip()
                thread_id = authed.get("threadId")
        else:
            # LEGACY plaintext fallback (only reached when E2E is not required).
            if raw.get("kind") == "model_switch":
                model_id = str(raw.get("modelId") or "").strip()
                if not _is_safe_model_id(model_id):
                    logger.warning("[%s] dropped model_switch with unsafe modelId %r", self.name, model_id)
                    return
                text = f"/model {model_id}"
                model_switch_applied = True
            else:
                text = str(raw.get("text") or "").strip()
            thread_id = raw.get("threadId")
        if not text:
            return
        # MP-3: record the authenticated id ONLY now — after a successful open and
        # before dispatch — so only events that actually authenticated consume a
        # cache slot.
        if not self._record_event(event_id, replay_counter=replay_counter):
            return
        # MP-8: on an E2E-authenticated event, sender identity MUST come from the
        # sealed payload, never from relay-controlled top-level metadata (which a
        # relay can spoof for authz). Fall back to raw only on the legacy
        # plaintext path. A sealed model_switch carries no sender, so identity
        # safely defaults to the static sentinel rather than the relay's value.
        if authed is not None:
            sender_display = authed.get("senderDisplayName")
            sender_id = str(authed.get("senderId") or "burnbar-user")
        else:
            sender_display = raw.get("senderDisplayName")
            sender_id = str(raw.get("senderId") or "burnbar-user")
        source = self.build_source(
            chat_id=destination_id,
            chat_name=destination_id,
            chat_type="dm",
            user_id=sender_id,
            user_name=sender_display or sender_id,
            thread_id=thread_id,
            message_id=event_id,
        )
        event = MessageEvent(
            text=text,
            message_type=MessageType.TEXT,
            source=source,
            raw_message=raw,
            message_id=event_id,
        )
        await self.handle_message(event)
        if model_switch_applied:
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
                preferred_gateway_relay_version = _preferred_gateway_relay_version()
                body["relayPublicKey"] = pub
                body["relayEncryption"] = RELAY_ENCRYPTION
                body["relayKeyVersion"] = RELAY_KEY_VERSION
                body["agentRelayPublicKey"] = pub
                body["agentRelayEncryption"] = RELAY_ENCRYPTION
                body["agentRelayKeyVersion"] = RELAY_KEY_VERSION
                body["gatewayRelayKeyVersion"] = preferred_gateway_relay_version
                body["gatewayRelayEncryption"] = _gateway_relay_encryption_for(preferred_gateway_relay_version)
                body["supportedGatewayRelayKeyVersions"] = _supported_gateway_relay_versions()
                body.update(_gateway_relay_capability_payload())
                body.update(self._ratchet_public_payload())
        try:
            response = await self._client.post(
                f"{self._api_base}/runtime",
                headers=_signed_headers(self._token, "POST", f"{self._api_base}/runtime", json_body=body),
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
        """Mirror the server-owned oversight toggle on legacy links only."""
        if self._client is None:
            return
        now = time.monotonic()
        if now - self._oversight_checked_at < OVERSIGHT_REFRESH_SECONDS:
            return
        self._oversight_checked_at = now
        try:
            response = await self._client.get(
                f"{self._api_base}/state",
                headers=_signed_headers(self._token, "GET", f"{self._api_base}/state"),
            )
            response.raise_for_status()
            state = response.json()
            self._absorb_relay_state(state)
            # E2E-paired links pin oversight at pairing (BURNBAR_OVERSIGHT_MODE). A
            # malicious relay can write arbitrary /state; trusting oversightMode here
            # would let it force autonomous mode and bypass human approval gates.
            if self._relay_e2e_enabled:
                return
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
            action_id=confirm_id, tool_name=title, destination_id=chat_id
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
        # MP-6: the human-readable detail rides ONLY on the sealed message, bound to
        # the approval gate by actionId so the phone joins the right detail to the
        # right gate (informed consent). The /approvals control-plane body carries
        # no free text.
        await self._post_confirm_followup(
            chat_id, card, metadata, action_id=confirm_id, kind="approval"
        )
        return SendResult(success=True)

    async def _arm_approval(
        self, *, action_id: str, tool_name: str, destination_id: str
    ) -> bool:
        if self._client is None:
            return False
        # MP-6: control-plane only. This /approvals body carries NO free text — no
        # summary, command, file path, or tool args (the untrusted relay sees it in
        # transit). Only the opaque actionId, a coarse toolName category, and the
        # destination. All human-readable detail rides the sealed message channel.
        body: Dict[str, Any] = {"actionId": action_id}
        if tool_name:
            body["toolName"] = tool_name
        if destination_id:
            body["destinationId"] = destination_id
        try:
            response = await self._client.post(
                f"{self._api_base}/approvals",
                headers=_signed_headers(self._token, "POST", f"{self._api_base}/approvals", json_body=body),
                json=body,
            )
            response.raise_for_status()
            return True
        except Exception:
            logger.debug("[%s] BurnBar approval arm failed", self.name, exc_info=True)
            return False

    async def _resolve_pending_confirms(self) -> None:
        if self._client is None:
            return
        # E2E-paired links resolve approvals from pinned-sender sealed
        # ``approval_decision`` events only. The relay-visible /approvals poll is
        # not authenticated and must not authorize side effects.
        if self._relay_e2e_enabled:
            return
        for action_id, ctx in list(self._pending_confirms.items()):
            try:
                approval_params = {"actionId": action_id}
                response = await self._client.get(
                    f"{self._api_base}/approvals",
                    headers=_signed_headers(self._token, "GET", f"{self._api_base}/approvals", params=approval_params),
                    params=approval_params,
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

    async def _handle_sealed_approval_decision(self, authed: dict) -> None:
        """Apply a phone-authenticated approval decision from a sealed event."""
        action_id = str(authed.get("actionId") or "").strip()
        choice_raw = str(authed.get("choice") or authed.get("status") or "").strip().lower()
        if not action_id:
            logger.warning("[%s] dropped approval_decision without actionId", self.name)
            return
        ctx = self._pending_confirms.get(action_id)
        if ctx is None:
            logger.debug("[%s] approval_decision for unknown actionId %s", self.name, action_id)
            return
        sealed_dest = str(authed.get("destinationId") or "").strip()
        expected_dest = str(ctx.get("chat_id") or "").strip()
        if not sealed_dest or (expected_dest and sealed_dest != expected_dest):
            logger.warning(
                "[%s] dropped approval_decision for %s with destinationId %r (expected %r)",
                self.name,
                action_id,
                sealed_dest,
                expected_dest,
            )
            return
        choice_map = {
            "approve": "once",
            "approved": "once",
            "once": "once",
            "allow": "once",
            "reject": "cancel",
            "rejected": "cancel",
            "denied": "cancel",
            "cancel": "cancel",
            "cancelled": "cancel",
            "canceled": "cancel",
            "expired": "cancel",
        }
        choice = choice_map.get(choice_raw)
        if choice is None:
            logger.warning(
                "[%s] dropped approval_decision with unknown choice %r", self.name, choice_raw
            )
            return
        fallback = None
        if choice == "cancel" and choice_raw in ("reject", "rejected", "denied"):
            fallback = "Action denied from your BurnBar device."
        elif choice == "cancel" and choice_raw == "expired":
            fallback = "Approval request expired without a decision."
        self._pending_confirms.pop(action_id, None)
        await self._resolve_slash_confirm(
            ctx["session_key"], action_id, choice, ctx.get("chat_id"), ctx.get("metadata"), fallback
        )

    def _handle_sealed_oversight_mode(self, authed: dict) -> None:
        """Apply a phone-authenticated oversight-mode update from a sealed event."""
        mode = str(authed.get("mode") or authed.get("oversightMode") or "").strip().lower()
        if mode not in ("supervised", "autonomous"):
            logger.warning("[%s] dropped oversight_mode with invalid mode %r", self.name, mode)
            return
        self._oversight_mode = mode
        try:
            from hermes_cli.config import save_env_value

            save_env_value(OVERSIGHT_MODE_ENV, mode)
        except Exception:
            logger.debug("[%s] Could not persist BurnBar oversight mode", self.name, exc_info=True)

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
        self,
        chat_id: Optional[str],
        text: str,
        metadata: Optional[Dict[str, Any]] = None,
        *,
        action_id: Optional[str] = None,
        kind: Optional[str] = None,
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
                action_id=action_id,
                kind=kind,
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
            typing_body = {"destinationId": chat_id or self._home_channel, "threadId": (metadata or {}).get("thread_id")}
            await self._client.post(
                f"{self._api_base}/typing",
                headers=_signed_headers(self._token, "POST", f"{self._api_base}/typing", json_body=typing_body),
                json=typing_body,
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
    # adapter __init__ reads the pairing flags / peer public key from
    # ~/.hermes/.env and the agent private key from Keychain, so the sealer's
    # must_seal/can_seal reflect pairing.
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
    # key is persisted to macOS Keychain; only ciphertext leaves.
    agent_relay_public_key = ""
    if RELAY_CRYPTO_AVAILABLE:
        try:
            identity = _load_or_create_relay_identity_secure()
            agent_relay_public_key = _public_key_base64(identity)
        except Exception:
            logger.debug("Could not prepare BurnBar relay identity for pairing", exc_info=True)
            agent_relay_public_key = ""
    agent_ratchet_prekey_bundle = _agent_ratchet_prekey_bundle() if agent_relay_public_key else None

    device_secret = secrets.token_urlsafe(32)
    payload: Dict[str, Any] = {
        "clientName": "Hermes Agent",
        "deviceSecretHash": _sha256(device_secret),
        "scopes": ["hermes.gateway.read", "hermes.gateway.write", "hermes.gateway.manage"],
    }
    # L2/PoP: register this agent's Ed25519 client signing key so every gateway
    # request is proof-of-possession signed, and declare PoP v2 capability (the
    # server then refuses v1 downgrades for this client). The server derives the
    # key id from the public key; only the public key crosses the wire.
    try:
        pop_public_key = _ensure_pop_signing_key_for_pairing(persist_env=_relay_key_persister())
        payload["agentClientSigningPublicKeyBase64"] = pop_public_key
        payload["popVersion"] = GATEWAY_POP_VERSION
    except Exception:
        logger.debug("Could not prepare BurnBar gateway PoP signing key for pairing", exc_info=True)
        print_warning(
            "Could not mint the gateway PoP signing key; pairing will proceed but the "
            "server will refuse unsigned requests from modern clients."
        )
    if agent_relay_public_key:
        preferred_gateway_relay_version = _preferred_gateway_relay_version()
        payload["agentRelayPublicKey"] = agent_relay_public_key
        payload["agentRelayKeyVersion"] = RELAY_KEY_VERSION
        payload["agentRelayEncryption"] = RELAY_ENCRYPTION
        payload["relayKeyVersion"] = RELAY_KEY_VERSION
        payload["relayEncryption"] = RELAY_ENCRYPTION
        payload["gatewayRelayKeyVersion"] = preferred_gateway_relay_version
        payload["gatewayRelayEncryption"] = _gateway_relay_encryption_for(preferred_gateway_relay_version)
        payload["supportedGatewayRelayKeyVersions"] = _supported_gateway_relay_versions()
        payload.update(_gateway_relay_capability_payload())
        if agent_ratchet_prekey_bundle:
            payload.update(agent_ratchet_prekey_bundle)
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
    peer_relay_key_version = _peer_relay_key_version_from_pairing_grant(approved, client_payload)
    client_id = approved.get("clientId") or client_payload.get("id")
    uid = approved.get("uid") or approved.get("userId")
    peer_ratchet_identity_public_key = (
        approved.get("phoneRatchetIdentityPublicKey")
        or client_payload.get("phoneRatchetIdentityPublicKey")
        or ""
    )
    peer_ratchet_signing_public_key = (
        approved.get("phoneRatchetSigningPublicKey")
        or client_payload.get("phoneRatchetSigningPublicKey")
        or ""
    )
    peer_ratchet_signed_prekey_public_key = (
        approved.get("phoneRatchetSignedPreKeyPublicKey")
        or client_payload.get("phoneRatchetSignedPreKeyPublicKey")
        or ""
    )
    peer_ratchet_signed_prekey_id = (
        approved.get("phoneRatchetSignedPreKeyId")
        or client_payload.get("phoneRatchetSignedPreKeyId")
        or ""
    )
    peer_ratchet_signed_prekey_signature = (
        approved.get("phoneRatchetSignedPreKeySignature")
        or client_payload.get("phoneRatchetSignedPreKeySignature")
        or ""
    )
    if agent_relay_public_key and relay_capable and peer_relay_public_key:
        if not uid or not client_id:
            print_warning(
                "BurnBar approved an E2E-capable relay link without uid/clientId. "
                "NOT enabling the gateway: those routing ids bind every encrypted AAD, "
                "and learning them from the first relay poll would let an untrusted relay "
                "pin the wrong values. Upgrade BurnBar Cloud and run setup again."
            )
            return
        # MP-1: gate the pin on the user confirming the TWO-KEY safety code BEFORE
        # persisting the peer key / enabling E2E. An untrusted relay can substitute
        # the phone key at first pin; the human comparing the combined code (a hash
        # of BOTH keys) on the Mac and in BurnBar is what authenticates it.
        ratchet_safety_keys: list[str] = []
        if agent_ratchet_prekey_bundle and peer_ratchet_identity_public_key:
            ratchet_safety_keys = [
                str(agent_ratchet_prekey_bundle["agentRatchetIdentityPublicKey"]),
                str(peer_ratchet_identity_public_key),
            ]
        safety_code = _relay_safety_code(
            agent_relay_public_key,
            str(peer_relay_public_key),
            extra_public_keys_b64=ratchet_safety_keys,
        )
        if not safety_code:
            print_warning(
                "Could not derive the pairing safety code (invalid relay key). "
                "NOT enabling end-to-end encryption; please re-run setup."
            )
            return
        print_info(f"Safety code (compare with BurnBar's Private messages screen): {safety_code}")
        if not prompt_yes_no("Does this safety code match the one shown in BurnBar?", False):
            print_warning(
                "Safety code mismatch — NOT enabling end-to-end encryption. This can "
                "indicate an untrusted relay substituting the phone key. Re-run setup "
                "and compare the code carefully."
            )
            return
        oversight = (
            prompt("Oversight mode for this link (supervised/autonomous)", default="supervised")
            .strip()
            .lower()
        )
        if oversight not in ("supervised", "autonomous"):
            oversight = "supervised"
        save_env_value("BURNBAR_API_BASE_URL", api_base)
        save_env_value("BURNBAR_ACCESS_TOKEN", approved["accessToken"])
        save_env_value("BURNBAR_HOME_CHANNEL", approved.get("homeDestinationId") or DEFAULT_HOME_CHANNEL)
        save_env_value(OVERSIGHT_MODE_ENV, oversight)
        save_env_value(RELAY_E2E_ENV, "1")
        save_env_value("BURNBAR_RELAY_PEER_PUBLIC_KEY", str(peer_relay_public_key))
        save_env_value(RELAY_PEER_KEY_VERSION_ENV, str(peer_relay_key_version))
        save_env_value("BURNBAR_RELAY_CLIENT_ID", str(client_id))
        save_env_value("BURNBAR_RELAY_UID", str(uid))
        if ratchet_safety_keys:
            save_env_value(RATCHET_PEER_IDENTITY_PUBLIC_KEY_ENV, str(peer_ratchet_identity_public_key))
            if peer_ratchet_signing_public_key:
                save_env_value(RATCHET_PEER_SIGNING_PUBLIC_KEY_ENV, str(peer_ratchet_signing_public_key))
            if peer_ratchet_signed_prekey_public_key:
                save_env_value(RATCHET_PEER_SIGNED_PREKEY_PUBLIC_KEY_ENV, str(peer_ratchet_signed_prekey_public_key))
            if peer_ratchet_signed_prekey_id:
                save_env_value(RATCHET_PEER_SIGNED_PREKEY_ID_ENV, str(peer_ratchet_signed_prekey_id))
            if peer_ratchet_signed_prekey_signature:
                save_env_value(RATCHET_PEER_SIGNED_PREKEY_SIGNATURE_ENV, str(peer_ratchet_signed_prekey_signature))
        print_success("End-to-end encryption is enabled for this BurnBar link.")
    else:
        save_env_value("BURNBAR_API_BASE_URL", api_base)
        save_env_value("BURNBAR_ACCESS_TOKEN", approved["accessToken"])
        save_env_value("BURNBAR_HOME_CHANNEL", approved.get("homeDestinationId") or DEFAULT_HOME_CHANNEL)
    if agent_relay_public_key and not (relay_capable and peer_relay_public_key):
        print_info(
            "Paired without end-to-end encryption (legacy BurnBar). Messages use "
            "the plaintext relay path until BurnBar is upgraded."
        )
    if not get_env_value("BURNBAR_ALLOWED_USERS") and not get_env_value("BURNBAR_ALLOW_ALL_USERS"):
        print_info(
            "No BURNBAR_ALLOWED_USERS allowlist is configured. BurnBar setup now leaves "
            "BURNBAR_ALLOW_ALL_USERS unset; add an explicit allowlist or set "
            "BURNBAR_ALLOW_ALL_USERS=true yourself only for a deliberately open local gateway."
        )
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
        allow_update_command=False,
    )
