"""Named rollback implementation for local-MCP CloudVault primitive transforms.

Keep this module path-addressable until the shared-Rust crypto deletion gate.
It must not acquire I/O, credential, or persistence responsibilities.
"""

from __future__ import annotations

import base64
import hashlib
import hmac
import os
from datetime import UTC, datetime
from typing import Any

OPENBURNBAR_DOC_ID_SALT = b"OpenBurnBar-DocID-Salt-v1"
OPENBURNBAR_PROJECT_MEMORY_DOC_ID_INFO = b"OpenBurnBar-ProjectMemory-DocID-v1"
OPENBURNBAR_CLOUD_VAULT_AAD_PREFIX = "OpenBurnBar-CloudVault-aad-v2"
OPENBURNBAR_CLOUD_VAULT_BLOB_AAD_CONTEXT = "OpenBurnBar-CloudVaultBlob-v2"
OPENBURNBAR_CLOUD_VAULT_HMAC_SALT = b"OpenBurnBar-CloudVault-HMAC-Salt-v1"
OPENBURNBAR_CLOUD_VAULT_HMAC_INFO_PREFIX = b"OpenBurnBar-CloudVault-HMAC-v1"


def _hkdf_sha256(input_key: bytes, salt: bytes, info: bytes, length: int) -> bytes:
    effective_salt = salt if salt else bytes(32)
    prk = hmac.new(effective_salt, input_key, hashlib.sha256).digest()
    output = b""
    previous = b""
    counter = 1
    while len(output) < length:
        previous = hmac.new(prk, previous + info + bytes([counter]), hashlib.sha256).digest()
        output += previous
        counter += 1
    return output[:length]


def _cloud_vault_aad_part(value: str, name: str) -> str:
    if not value or "|" in value or any(ord(ch) < 0x20 or ord(ch) == 0x7F for ch in value):
        raise ValueError(f"invalid CloudVault AAD {name}")
    return value


def _cloud_vault_aad_context(
    uid: str,
    collection: str,
    doc_id: str,
    field: str,
    schema_version: int = 2,
    purpose: str | None = None,
) -> str:
    if schema_version < 2:
        raise ValueError("invalid CloudVault AAD schema version")
    purpose_value = purpose or field
    return "|".join(
        [
            OPENBURNBAR_CLOUD_VAULT_AAD_PREFIX,
            _cloud_vault_aad_part(uid, "uid"),
            _cloud_vault_aad_part(collection, "collection"),
            _cloud_vault_aad_part(doc_id, "docID"),
            _cloud_vault_aad_part(field, "field"),
            str(schema_version),
            _cloud_vault_aad_part(purpose_value, "purpose"),
        ]
    )


def _validate_cloud_vault_aad(value: str) -> str:
    parts = value.split("|")
    if len(parts) != 7 or parts[0] != OPENBURNBAR_CLOUD_VAULT_AAD_PREFIX:
        raise ValueError("invalid CloudVault AAD context")
    _cloud_vault_aad_part(parts[1], "uid")
    _cloud_vault_aad_part(parts[2], "collection")
    _cloud_vault_aad_part(parts[3], "docID")
    _cloud_vault_aad_part(parts[4], "field")
    if not parts[5].isdigit() or int(parts[5]) < 2:
        raise ValueError("invalid CloudVault AAD schema version")
    _cloud_vault_aad_part(parts[6], "purpose")
    return value


def _cloud_vault_hmac_hex(data: bytes, vault_key: bytes, purpose: str) -> str:
    hmac_key = _hkdf_sha256(
        vault_key,
        OPENBURNBAR_CLOUD_VAULT_HMAC_SALT,
        OPENBURNBAR_CLOUD_VAULT_HMAC_INFO_PREFIX + b"|" + purpose.encode("utf-8"),
        32,
    )
    return hmac.new(hmac_key, data, hashlib.sha256).hexdigest()


def _cloud_vault_project_memory_doc_id(project_slug: str, vault_key: bytes) -> str:
    doc_id_key = _hkdf_sha256(vault_key, OPENBURNBAR_DOC_ID_SALT, OPENBURNBAR_PROJECT_MEMORY_DOC_ID_INFO, 32)
    digest = hmac.new(doc_id_key, project_slug.encode("utf-8"), hashlib.sha256).digest()
    return "pm_" + digest[:16].hex()


def _aesgcm_open(nonce: bytes, ciphertext_and_tag: bytes, key: bytes, aad: bytes | None = None) -> bytes:
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError as exc:
        raise RuntimeError("install cryptography to decrypt OpenBurnBar cloud data") from exc
    return AESGCM(key).decrypt(nonce, ciphertext_and_tag, aad)


def _open_cloud_sealed_text(envelope: dict[str, Any], vault_key: bytes, expected_aad: str | None = None) -> str:
    if envelope.get("algorithm") != "AES-256-GCM":
        raise ValueError("unsupported sealed text algorithm")
    nonce = base64.b64decode(str(envelope["nonce"]))
    ciphertext = base64.b64decode(str(envelope["ciphertext"]))
    tag = base64.b64decode(str(envelope["tag"]))
    schema_version = int(envelope.get("schemaVersion") or 1)
    aad_bytes: bytes | None = None
    if schema_version >= 2:
        if not expected_aad or envelope.get("aad") != expected_aad:
            raise ValueError("sealed text AAD context mismatch")
        aad_bytes = expected_aad.encode("utf-8")
    return _aesgcm_open(nonce, ciphertext + tag, vault_key, aad_bytes).decode("utf-8")


def _open_cloud_blob_envelope(envelope: dict[str, Any], vault_key: bytes, expected_aad: str | None = None) -> bytes:
    if envelope.get("algorithm") != "AES-256-GCM":
        raise ValueError("unsupported blob algorithm")
    combined = base64.b64decode(str(envelope["sealedBoxBase64"]))
    if len(combined) <= 28:
        raise ValueError("encrypted blob envelope is too short")
    schema_version = int(envelope.get("schemaVersion") or 1)
    aad_bytes: bytes | None = None
    if schema_version >= 2:
        envelope_aad = str(envelope.get("aad", ""))
        if envelope_aad != OPENBURNBAR_CLOUD_VAULT_BLOB_AAD_CONTEXT:
            if not expected_aad or envelope_aad != expected_aad:
                raise ValueError("encrypted blob AAD context mismatch")
            aad_bytes = _validate_cloud_vault_aad(expected_aad).encode("utf-8")
    plaintext = _aesgcm_open(combined[:12], combined[12:], vault_key, aad_bytes)
    if schema_version >= 2:
        if int(envelope.get("integrityHashVersion") or 0) != 1:
            raise ValueError("encrypted blob integrity version mismatch")
        if _cloud_vault_hmac_hex(plaintext, vault_key, "blob-integrity") != str(envelope.get("plaintextHMAC", "")):
            raise ValueError("encrypted blob HMAC mismatch")
    elif hashlib.sha256(plaintext).hexdigest() != str(envelope.get("plaintextSHA256", "")):
        raise ValueError("encrypted blob SHA-256 mismatch")
    return plaintext


def _seal_cloud_blob_envelope(
    plaintext: bytes,
    vault_key: bytes,
    key_version: int = 1,
    aad_context: str | None = None,
    *,
    nonce: bytes | None = None,
    created_at: str | None = None,
) -> dict[str, Any]:
    try:
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    except ImportError as exc:
        raise RuntimeError("install cryptography to seal OpenBurnBar cloud payloads") from exc
    nonce = nonce or os.urandom(12)
    aad = _validate_cloud_vault_aad(aad_context).encode("utf-8") if aad_context else None
    combined = nonce + AESGCM(vault_key).encrypt(nonce, plaintext, aad)
    return {
        "schemaVersion": 2,
        "algorithm": "AES-256-GCM",
        "keyVersion": int(key_version),
        "plaintextHMAC": _cloud_vault_hmac_hex(plaintext, vault_key, "blob-integrity"),
        "integrityHashVersion": 1,
        "sealedBoxBase64": base64.b64encode(combined).decode("utf-8"),
        "createdAt": created_at or datetime.now(UTC).isoformat().replace("+00:00", "Z"),
        "aad": aad_context or OPENBURNBAR_CLOUD_VAULT_BLOB_AAD_CONTEXT,
    }
