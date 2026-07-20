"""Legacy Python ratchet prekey transform retained only for staged rollback."""

from __future__ import annotations

import base64

RATCHET_PREKEY_KDF_DOMAIN = b"OpenBurnBar-HermesRatchet-v1-prekey-x3dh-p256"
RATCHET_CHAT_LANE = "chat"


def _append_part(buffer: bytearray, part: bytes) -> None:
    buffer.extend(len(part).to_bytes(8, "big"))
    buffer.extend(part)


def ratchet_prekey_shared_secret(
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
    try:
        from cryptography.hazmat.primitives import hashes
        from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    except ImportError as exc:
        raise RuntimeError("cryptography HKDF is unavailable") from exc

    info = bytearray(RATCHET_PREKEY_KDF_DOMAIN)
    for part in (uid, client_id, RATCHET_CHAT_LANE, initiator_role):
        _append_part(info, part.encode("utf-8"))
    for encoded_key in (
        initiator_identity_public_key_base64,
        responder_identity_public_key_base64,
        initiator_signed_prekey_public_key_base64,
        responder_signed_prekey_public_key_base64,
        initiator_initial_ratchet_public_key_base64,
    ):
        raw = base64.b64decode(encoded_key)
        if len(raw) != 65:
            raise ValueError("ratchet transcript public key must be 65 bytes")
        _append_part(info, raw)
    return HKDF(
        algorithm=hashes.SHA256(),
        length=32,
        salt=RATCHET_PREKEY_KDF_DOMAIN,
        info=bytes(info),
    ).derive(dh1 + dh2 + dh3)
