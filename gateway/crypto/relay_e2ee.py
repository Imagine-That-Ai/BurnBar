"""Byte-exact Python mirror of the canonical ``HermesRelayCrypto`` (Swift).

The relay end-to-end-encryption scheme used by the BurnBar Hermes Gateway
(and the PiAgent relay) seals every private payload to the peer's P-256
public key so the relay server only ever store-and-forwards ciphertext. The
single source of truth is the Swift implementation at
``OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayCrypto.swift``;
the Android Kotlin port and this Python port are byte-for-byte
wire-compatible with it. The shared interop gate is the wire vector at
``OpenBurnBarCoreTests/Fixtures/HermesRelayWireVector.json`` (vendored into
``tests/gateway/fixtures/``), which all three implementations open.

Wire invariants (do not drift — pinned in ``tests/gateway/test_relay_e2ee.py``)

* Curve **NIST P-256 / secp256r1**. Public keys are **X9.63 uncompressed**:
  65 bytes ``0x04 ‖ X(32) ‖ Y(32)`` big-endian. Private keys are the **raw
  32-byte big-endian scalar** (Swift ``rawRepresentation``), imported via
  ``ec.derive_private_key(int.from_bytes(raw, "big"), SECP256R1())`` — *not*
  PKCS8/DER. This is the trickiest interop point.
* **ECDH** shared secret = raw 32-byte big-endian X-coordinate
  (``private_key.exchange(ec.ECDH(), peer)``), never re-hashed before HKDF.
* **HKDF-SHA256** (key-wrap only): ``salt`` = 32 zero bytes (RFC 5869 empty
  salt), ``info`` = ``b"OpenBurnBar-HermesRelay-KeyWrap-v1|" + key_aad``,
  output 32 bytes. (PiAgent: ``OpenBurnBar-PiAgentRelay-KeyWrap-v1|``.)
* **AES-256-GCM**: 12-byte random nonce, 16-byte tag.
  ``cryptography``'s ``AESGCM.encrypt`` returns ``ciphertext ‖ tag(16)``.
* Payload seal (``seal_to_base64``) = ``base64(nonce(12) ‖ ct ‖ tag(16))``
  (CryptoKit ``.combined``).
* Wrapped key (``wrap_symmetric_key``) =
  ``base64(ephPubX963(65) ‖ nonce(12) ‖ ct(32) ‖ tag(16))`` = **125 bytes**,
  ``[0] == 0x04``.
* AAD = ``"<namespace>-v1|" + "|".join(parts)`` UTF-8. **keyAAD for the wrap,
  requestAAD for the payload, a per-chunk chunkAAD for each streamed chunk.**

``cryptography`` is imported lazily inside each function (mirroring
``gateway/platforms/qqbot/crypto.py`` and ``wecom_crypto.py``) so importing
this module never pulls the C extension into a CLI invocation that does not
seal anything.
"""

from __future__ import annotations

import base64
import os
from dataclasses import dataclass

# ---------------------------------------------------------------------------
# Constants (copied verbatim from HermesRelayCrypto.swift)
# ---------------------------------------------------------------------------

ALGORITHM = "p256-hkdf-sha256-aesgcm"
KEY_VERSION = 1

# Default namespaces. ``HERMES_NAMESPACE`` mirrors Swift ``HermesRelayCrypto``
# (AAD prefix ``OpenBurnBar-HermesRelay-v1`` / key-wrap info prefix
# ``OpenBurnBar-HermesRelay-KeyWrap-v1|``). ``PIAGENT_NAMESPACE`` mirrors
# Swift ``PiAgentRelayCrypto`` so the same module serves the PiAgent relay.
HERMES_NAMESPACE = "OpenBurnBar-HermesRelay"
PIAGENT_NAMESPACE = "OpenBurnBar-PiAgentRelay"

# Environment variable that stores the agent's persistent relay private key
# (base64 of the raw 32-byte scalar) for ``AgentRelayIdentity.load_or_create``.
RELAY_PRIVATE_KEY_ENV = "BURNBAR_RELAY_PRIVATE_KEY"

_SYMMETRIC_KEY_BYTE_COUNT = 32
_NONCE_BYTE_COUNT = 12
_TAG_BYTE_COUNT = 16
_X963_PUBLIC_KEY_BYTE_COUNT = 65
_P256_COORDINATE_BYTE_COUNT = 32
_HKDF_SALT = b"\x00" * 32  # RFC 5869 empty-salt -> HashLen zero bytes; matches Swift salt: Data()


# ---------------------------------------------------------------------------
# Typed errors (mirror HermesRelayCryptoError cases)
# ---------------------------------------------------------------------------


class RelayCryptoError(Exception):
    """Base class for relay crypto failures."""


class InvalidPublicKeyError(RelayCryptoError):
    """The relay public key is invalid (bad base64 or not an X9.63 P-256 point)."""


class InvalidCiphertextError(RelayCryptoError):
    """The relay ciphertext is invalid (bad base64 or wrong envelope shape)."""


class InvalidSymmetricKeyError(RelayCryptoError):
    """The relay symmetric key is not exactly 32 bytes."""


# ---------------------------------------------------------------------------
# Namespace (AAD prefixing — serves both Hermes and PiAgent)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class RelayNamespace:
    """Carries the AAD / key-wrap prefixes for one relay scheme.

    ``HERMES_NAMESPACE`` -> AAD ``OpenBurnBar-HermesRelay-v1|...`` and key-wrap
    info ``OpenBurnBar-HermesRelay-KeyWrap-v1|...``. ``PIAGENT_NAMESPACE``
    swaps in the PiAgent strings. Pass ``namespace=`` to every AAD/seal call to
    pick the scheme; it defaults to Hermes.
    """

    name: str = HERMES_NAMESPACE

    @property
    def aad_prefix(self) -> str:
        return f"{self.name}-v1"

    @property
    def key_wrap_info_prefix(self) -> bytes:
        return f"{self.name}-KeyWrap-v1|".encode("utf-8")

    def aad(self, parts: list[str]) -> bytes:
        return f"{self.aad_prefix}|{'|'.join(parts)}".encode("utf-8")

    def key_wrap_shared_info(self, aad: bytes) -> bytes:
        return self.key_wrap_info_prefix + aad


_HERMES = RelayNamespace(HERMES_NAMESPACE)
_PIAGENT = RelayNamespace(PIAGENT_NAMESPACE)


def _resolve_namespace(namespace: RelayNamespace | str | None) -> RelayNamespace:
    if namespace is None:
        return _HERMES
    if isinstance(namespace, RelayNamespace):
        return namespace
    if namespace == HERMES_NAMESPACE:
        return _HERMES
    if namespace == PIAGENT_NAMESPACE:
        return _PIAGENT
    return RelayNamespace(namespace)


# ---------------------------------------------------------------------------
# AAD builders (mirror requestAAD / keyAAD / chunkAAD)
# ---------------------------------------------------------------------------


def request_aad(
    uid: str,
    connection_id: str,
    request_id: str,
    *,
    namespace: RelayNamespace | str | None = None,
) -> bytes:
    """AAD for sealing the request payload. Mirrors Swift ``requestAAD``."""
    return _resolve_namespace(namespace).aad(["request", uid, connection_id, request_id])


def key_aad(
    uid: str,
    connection_id: str,
    request_id: str,
    *,
    namespace: RelayNamespace | str | None = None,
) -> bytes:
    """AAD for wrapping the symmetric key. Mirrors Swift ``keyAAD``."""
    return _resolve_namespace(namespace).aad(["key", uid, connection_id, request_id])


def chunk_aad(
    uid: str,
    connection_id: str,
    request_id: str,
    sequence: int,
    kind: str,
    *,
    namespace: RelayNamespace | str | None = None,
) -> bytes:
    """AAD for sealing one streamed chunk. Mirrors Swift ``chunkAAD``.

    ``sequence`` is rendered with ``str(int)`` to match Swift ``String(sequence)``.
    """
    return _resolve_namespace(namespace).aad(
        ["chunk", uid, connection_id, request_id, str(sequence), kind]
    )


# ---------------------------------------------------------------------------
# Key material
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class RelayPrivateKey:
    """A P-256 relay private key, mirroring Swift ``HermesRelayPrivateKey``.

    Stores the raw 32-byte big-endian scalar (Swift ``rawRepresentation``).
    The ``cryptography`` ``EllipticCurvePrivateKey`` is derived lazily so this
    dataclass never forces the C extension to load.
    """

    raw_representation: bytes

    def __post_init__(self) -> None:
        if len(self.raw_representation) != _P256_COORDINATE_BYTE_COUNT:
            raise InvalidPublicKeyError(
                "relay private key must be the raw 32-byte P-256 scalar"
            )

    @classmethod
    def from_raw(cls, raw: bytes) -> "RelayPrivateKey":
        """Import from the raw 32-byte big-endian scalar (Swift rawRepresentation)."""
        return cls(bytes(raw))

    @classmethod
    def from_base64(cls, raw_base64: str) -> "RelayPrivateKey":
        """Import from base64 of the raw 32-byte scalar."""
        return cls(base64.b64decode(raw_base64))

    def _private_key(self):
        from cryptography.hazmat.primitives.asymmetric import ec

        return ec.derive_private_key(
            int.from_bytes(self.raw_representation, "big"), ec.SECP256R1()
        )

    def public_key_x963(self) -> bytes:
        """The X9.63 uncompressed public key bytes (65B, ``0x04`` prefix)."""
        from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

        return self._private_key().public_key().public_bytes(
            Encoding.X962, PublicFormat.UncompressedPoint
        )

    def public_key_base64(self) -> str:
        """Base64 of the X9.63 uncompressed public key. Mirrors Swift ``publicKeyBase64``."""
        return base64.b64encode(self.public_key_x963()).decode("ascii")

    def raw_base64(self) -> str:
        """Base64 of the raw 32-byte private scalar (for persistence)."""
        return base64.b64encode(self.raw_representation).decode("ascii")


def generate_private_key() -> RelayPrivateKey:
    """Generate a fresh P-256 relay private key. Mirrors Swift ``generatePrivateKey``."""
    from cryptography.hazmat.primitives.asymmetric import ec

    private_key = ec.generate_private_key(ec.SECP256R1())
    raw = private_key.private_numbers().private_value.to_bytes(
        _P256_COORDINATE_BYTE_COUNT, "big"
    )
    return RelayPrivateKey(raw)


def generate_symmetric_key() -> bytes:
    """Generate a fresh 32-byte AES-256 symmetric key.

    Mirrors Swift ``generateSymmetricKeyData``.
    """
    return os.urandom(_SYMMETRIC_KEY_BYTE_COUNT)


@dataclass(frozen=True)
class AgentRelayIdentity:
    """The agent's persistent relay keypair.

    The agent publishes ``public_key_base64`` at ``device/start`` /
    ``handleRuntimeStatus`` (``agentRelayPublicKey`` / ``agentRelayKeyVersion``
    / ``agentRelayEncryption``) so the phone can wrap inbound gateway events to
    it. The private key persists in the ``BURNBAR_RELAY_PRIVATE_KEY`` env var
    (base64 of the raw 32-byte scalar), exactly like the Swift host keypair.
    """

    private_key: RelayPrivateKey

    @property
    def public_key_base64(self) -> str:
        return self.private_key.public_key_base64()

    @property
    def key_version(self) -> int:
        return KEY_VERSION

    @property
    def algorithm(self) -> str:
        return ALGORITHM

    @classmethod
    def load_or_create(
        cls,
        *,
        env_var: str = RELAY_PRIVATE_KEY_ENV,
        environ: dict[str, str] | None = None,
        persist: "callable | None" = None,
    ) -> "AgentRelayIdentity":
        """Load the relay identity from ``env_var`` or mint and persist a new one.

        When the env var is present it is parsed as base64 of the raw 32-byte
        scalar. When absent (or unparseable) a new key is generated; if
        ``persist`` is supplied it is called with ``(env_var, raw_base64)`` so
        the caller can write it back to ``~/.hermes/.env`` (mirroring how the
        BurnBar adapter persists ``BURNBAR_ACCESS_TOKEN``).

        Stability matters: without persistence the agent's relay key would rotate
        on every restart, silently breaking every previously-sealed inbound
        event. So a freshly minted key is (a) written back into the live
        ``environ`` map so an in-process reload sees the SAME key even if disk
        persistence is unavailable, and (b) handed to ``persist`` for durable
        storage. A ``persist`` failure is logged-and-swallowed (never fatal) — the
        in-memory + environ copy keeps the process consistent for this run.
        """
        source = environ if environ is not None else os.environ
        raw_base64 = source.get(env_var)
        if raw_base64:
            try:
                return cls(RelayPrivateKey.from_base64(raw_base64.strip()))
            except (ValueError, RelayCryptoError):
                # Corrupt stored key — fall through and mint a fresh one.
                pass
        private_key = generate_private_key()
        minted_base64 = private_key.raw_base64()
        # Keep the minted key visible to in-process reloads regardless of disk
        # persistence so the identity does not rotate within a single run.
        try:
            source[env_var] = minted_base64
        except Exception:
            pass
        if persist is not None:
            try:
                persist(env_var, minted_base64)
            except Exception:
                import logging

                logging.getLogger(__name__).debug(
                    "relay identity persist callback failed; key kept in-process only",
                    exc_info=True,
                )
        return cls(private_key)


# ---------------------------------------------------------------------------
# Payload / chunk sealing (AES-256-GCM, combined = nonce ‖ ct ‖ tag)
# ---------------------------------------------------------------------------


def seal_to_base64(plaintext: bytes, key_data: bytes, aad: bytes) -> str:
    """Seal ``plaintext`` under the 32-byte symmetric ``key_data`` with ``aad``.

    Wire = ``base64(nonce(12) ‖ AESGCM.encrypt(nonce, pt, aad))`` where the
    result already carries the 16-byte tag. Mirrors Swift ``sealToBase64``.
    """
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    if len(key_data) != _SYMMETRIC_KEY_BYTE_COUNT:
        raise InvalidSymmetricKeyError("symmetric key must be 32 bytes")
    nonce = os.urandom(_NONCE_BYTE_COUNT)
    ciphertext_with_tag = AESGCM(key_data).encrypt(nonce, plaintext, aad)
    return base64.b64encode(nonce + ciphertext_with_tag).decode("ascii")


def open_base64(ciphertext_base64: str, key_data: bytes, aad: bytes) -> bytes:
    """Open a ``seal_to_base64`` envelope. Mirrors Swift ``openBase64``.

    Raises ``cryptography.exceptions.InvalidTag`` when ``aad`` / ``key_data``
    do not match (authenticated decryption failure).
    """
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    if len(key_data) != _SYMMETRIC_KEY_BYTE_COUNT:
        raise InvalidSymmetricKeyError("symmetric key must be 32 bytes")
    try:
        raw = base64.b64decode(ciphertext_base64)
    except (ValueError, base64.binascii.Error) as exc:  # type: ignore[attr-defined]
        raise InvalidCiphertextError("ciphertext is not valid base64") from exc
    if len(raw) <= _NONCE_BYTE_COUNT:
        raise InvalidCiphertextError("ciphertext too short")
    return AESGCM(key_data).decrypt(raw[:_NONCE_BYTE_COUNT], raw[_NONCE_BYTE_COUNT:], aad)


# ---------------------------------------------------------------------------
# Symmetric-key wrapping (ECIES: ephemeral P-256 ECDH -> HKDF -> AES-256-GCM)
# ---------------------------------------------------------------------------


def _hkdf_wrapping_key(
    shared_secret: bytes, aad: bytes, namespace: RelayNamespace
) -> bytes:
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF

    return HKDF(
        algorithm=hashes.SHA256(),
        length=_SYMMETRIC_KEY_BYTE_COUNT,
        salt=_HKDF_SALT,
        info=namespace.key_wrap_shared_info(aad),
    ).derive(shared_secret)


def wrap_symmetric_key(
    key_data: bytes,
    recipient_public_key_base64: str,
    aad: bytes,
    *,
    namespace: RelayNamespace | str | None = None,
) -> str:
    """Wrap the 32-byte ``key_data`` to ``recipient_public_key_base64``.

    Mirrors Swift ``wrapSymmetricKey``: fresh ephemeral P-256 keypair, ECDH to
    the recipient, HKDF-SHA256 (empty salt, info = key-wrap prefix + ``aad``)
    to a wrapping key, AES-256-GCM seal of ``key_data`` under it with ``aad``,
    wire = ``base64(ephPubX963(65) ‖ nonce(12) ‖ ct(32) ‖ tag(16))`` = 125B.

    ``aad`` MUST be the ``key_aad`` for the request.
    """
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

    ns = _resolve_namespace(namespace)
    if len(key_data) != _SYMMETRIC_KEY_BYTE_COUNT:
        raise InvalidSymmetricKeyError("symmetric key must be 32 bytes")
    try:
        recipient_bytes = base64.b64decode(recipient_public_key_base64)
        recipient = ec.EllipticCurvePublicKey.from_encoded_point(
            ec.SECP256R1(), recipient_bytes
        )
    except (ValueError, base64.binascii.Error) as exc:  # type: ignore[attr-defined]
        raise InvalidPublicKeyError("recipient public key is invalid") from exc

    ephemeral = ec.generate_private_key(ec.SECP256R1())
    shared_secret = ephemeral.exchange(ec.ECDH(), recipient)
    wrapping_key = _hkdf_wrapping_key(shared_secret, aad, ns)
    nonce = os.urandom(_NONCE_BYTE_COUNT)
    sealed = AESGCM(wrapping_key).encrypt(nonce, key_data, aad)
    eph_x963 = ephemeral.public_key().public_bytes(
        Encoding.X962, PublicFormat.UncompressedPoint
    )
    return base64.b64encode(eph_x963 + nonce + sealed).decode("ascii")


def unwrap_symmetric_key(
    wrapped_key_base64: str,
    private_key: RelayPrivateKey | bytes,
    aad: bytes,
    *,
    namespace: RelayNamespace | str | None = None,
) -> bytes:
    """Unwrap a ``wrap_symmetric_key`` envelope. Mirrors Swift ``unwrapSymmetricKey``.

    ``private_key`` may be a :class:`RelayPrivateKey` or the raw 32-byte
    big-endian scalar bytes. Splits ``prefix(65)`` = ephemeral pub,
    ``suffix(65:)`` = ``nonce(12) ‖ ct ‖ tag(16)``; ECDH -> identical HKDF ->
    AES-256-GCM open. Raises ``InvalidTag`` on wrong ``aad`` / wrong key.
    """
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    ns = _resolve_namespace(namespace)
    if isinstance(private_key, RelayPrivateKey):
        relay_private = private_key
    else:
        relay_private = RelayPrivateKey.from_raw(private_key)

    try:
        envelope = base64.b64decode(wrapped_key_base64)
    except (ValueError, base64.binascii.Error) as exc:  # type: ignore[attr-defined]
        raise InvalidCiphertextError("wrapped key is not valid base64") from exc
    if len(envelope) <= _X963_PUBLIC_KEY_BYTE_COUNT:
        raise InvalidCiphertextError("wrapped key too short")

    eph_pub_bytes = envelope[:_X963_PUBLIC_KEY_BYTE_COUNT]
    body = envelope[_X963_PUBLIC_KEY_BYTE_COUNT:]
    if len(body) <= _NONCE_BYTE_COUNT:
        raise InvalidCiphertextError("wrapped key body too short")
    try:
        ephemeral_public = ec.EllipticCurvePublicKey.from_encoded_point(
            ec.SECP256R1(), eph_pub_bytes
        )
    except ValueError as exc:
        raise InvalidPublicKeyError("ephemeral public key is invalid") from exc

    shared_secret = relay_private._private_key().exchange(ec.ECDH(), ephemeral_public)
    wrapping_key = _hkdf_wrapping_key(shared_secret, aad, ns)
    return AESGCM(wrapping_key).decrypt(body[:_NONCE_BYTE_COUNT], body[_NONCE_BYTE_COUNT:], aad)
