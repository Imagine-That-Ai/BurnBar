"""Self-contained Python implementation of the BurnBar relay E2E key wrap.

The relay end-to-end-encryption scheme used by the BurnBar Hermes Gateway seals
private payloads to the peer's P-256 public key, so the relay server stores and
forwards ciphertext for those payloads. The wire format (AAD labels, X9.63 key
encoding, and the v2 authenticated 2-DH key wrap) is the BurnBar relay format
implemented here on the Python side. Known-answer vectors live under
``tests/gateway/fixtures/`` and are regenerated and byte-verified in-tree by
``tests/gateway/vectors/generate_wire_vectors.py`` (see
``tests/gateway/test_wire_vectors_reproducible.py``). BurnBar's mobile clients
implement the same format, but cross-language parity is maintained outside this
repo and is not re-proven here.

Wire invariants (pinned in ``tests/gateway/test_relay_e2ee.py``)

* Curve **NIST P-256 / secp256r1**. Public keys are **X9.63 uncompressed**:
  65 bytes ``0x04 ‖ X(32) ‖ Y(32)`` big-endian. Private keys are the **raw
  32-byte big-endian scalar**, imported via
  ``ec.derive_private_key(int.from_bytes(raw, "big"), SECP256R1())`` — *not*
  PKCS8/DER. This is the trickiest interop point.
* **ECDH** shared secret = raw 32-byte big-endian X-coordinate
  (``private_key.exchange(ec.ECDH(), peer)``), never re-hashed before HKDF.
* **HKDF-SHA256** (key-wrap only): ``salt`` = 32 zero bytes (RFC 5869 empty
  salt), ``info`` = ``b"OpenBurnBar-HermesRelay-KeyWrap-v1|" + key_aad``,
  output 32 bytes.
* **AES-256-GCM**: 12-byte random nonce, 16-byte tag.
  ``cryptography``'s ``AESGCM.encrypt`` returns ``ciphertext ‖ tag(16)``.
* Payload seal (``seal_to_base64``) = ``base64(nonce(12) ‖ ct ‖ tag(16))``.
* Wrapped key (``wrap_symmetric_key``) =
  ``base64(ephPubX963(65) ‖ nonce(12) ‖ ct(32) ‖ tag(16))`` = **125 bytes**,
  ``[0] == 0x04``.
* AAD = ``"<namespace>-v1|" + "|".join(parts)`` UTF-8. **keyAAD for the wrap,
  requestAAD for the payload, a per-chunk chunkAAD for each streamed chunk.**

``cryptography`` is imported lazily inside each function (mirroring
``gateway/platforms/qqbot/crypto.py`` and ``wecom_crypto.py``) so importing
this module never pulls the C extension into a CLI invocation that does not
seal anything.

Security considerations
-----------------------

**Goals.** (1) *Confidentiality* of every sealed payload against the relay,
which only ever store-and-forwards ``base64(...)`` ciphertext. (2) *Sender
authentication* under the v2 2-DH key-wrap: a frame opens only if it was
sealed by the holder of the **pinned** peer static key, so the relay cannot
forge agent-to-phone replies/events or phone-to-agent events under the relay-only
threat model. (3) Forward secrecy
for the *ephemeral* leg only (``dh1`` against a fresh per-message ephemeral
key): compromising one ephemeral does not expose other messages.

**Non-goals (explicit).** (1) *No PFS for the static leg.* ``dh2`` is against
a long-lived pinned static key; compromising a static private key exposes
every message wrapped to it. (2) *No protection against recipient-key
compromise (KCI).* If the recipient's static private key leaks, an attacker
can forge messages that appear to come from any sender — this is an inherent,
documented property of every 2-DH AuthEncap (HPKE ``AuthEncap`` has the same
bound). Under the relay-only threat model here, it is an accepted tradeoff for a
simple, stateless, byte-exact scheme. A double-ratchet/X3DH design would be a
different protocol rather than a small patch to this frame; mitigate static-key
risk by storing the recipient static key in OS-protected storage and rotating by
re-pairing. (3) *Replay resistance is not from the crypto alone.* The AAD
binds the per-message id, but dedup across messages relies on the caller's
replay cache being recorded only AFTER a successful authenticated open (see
the adapter's ``_record_event`` ordering); the cache, not this module, is the
replay boundary.

**Empty-salt rationale.** ``_HKDF_SALT`` is 32 zero bytes, the RFC 5869
empty-salt value for SHA-256. This is a deliberate interop choice: the
domain-separated ``info`` (which binds the namespace version and, for v2, all
three public keys) supplies the separation an explicit salt would otherwise
provide. It is not a weakness.

**Why not RFC 9180 HPKE?** v2 is HPKE-AuthEncap-shaped, but it is not HPKE
wire framing. This frame is kept for compatibility with the existing BurnBar
mobile relay wire format. A future standard-HPKE migration should use a new
``relayKeyVersion`` with new vectors so v2 remains byte-stable.

**Trust anchor.** The v2 sender-auth property holds because the caller
passes the **pinned** peer static key to :func:`unwrap_symmetric_key`
(``sender_public_base64``) — never a wire-supplied ``senderPublicKey`` field.
That pin is rooted at pairing time in the two-key safety code the human
compares; if the pin is wrong, authentication authenticates the wrong party.
"""

from __future__ import annotations

import base64
import binascii
import os
from dataclasses import dataclass

# ---------------------------------------------------------------------------
# Wire constants
# ---------------------------------------------------------------------------

ALGORITHM = "p256-hkdf-sha256-aesgcm"
KEY_VERSION = 1

# Default namespace for the BurnBar relay wire format (AAD prefix
# ``OpenBurnBar-HermesRelay-v1`` / key-wrap info prefix
# ``OpenBurnBar-HermesRelay-KeyWrap-v1|``).
HERMES_NAMESPACE = "OpenBurnBar-HermesRelay"

# Environment variable that stores the agent's persistent relay private key
# (base64 of the raw 32-byte scalar) for ``AgentRelayIdentity.load_or_create``.
RELAY_PRIVATE_KEY_ENV = "BURNBAR_RELAY_PRIVATE_KEY"

_SYMMETRIC_KEY_BYTE_COUNT = 32
_NONCE_BYTE_COUNT = 12
_TAG_BYTE_COUNT = 16
_X963_PUBLIC_KEY_BYTE_COUNT = 65
_P256_COORDINATE_BYTE_COUNT = 32
# Order of the NIST P-256 / secp256r1 prime-order group. A valid private scalar
# is in [1, n-1]; 0 and any value >= n are rejected at construction so a corrupt
# stored key surfaces a typed RelayCryptoError instead of a raw library
# ValueError deep inside an ECDH call.
_P256_GROUP_ORDER = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551
_HKDF_SALT = b"\x00" * 32  # RFC 5869 empty-salt -> HashLen zero bytes for SHA-256.


# ---------------------------------------------------------------------------
# Typed errors for relay-crypto boundary failures.
# ---------------------------------------------------------------------------


class RelayCryptoError(Exception):
    """Base class for relay crypto failures."""


class InvalidPublicKeyError(RelayCryptoError):
    """The relay public key is invalid (bad base64 or not an X9.63 P-256 point)."""


class InvalidCiphertextError(RelayCryptoError):
    """The relay ciphertext is invalid (bad base64 or wrong envelope shape)."""


class InvalidSymmetricKeyError(RelayCryptoError):
    """The relay symmetric key is not exactly 32 bytes."""


class CorruptIdentityError(RelayCryptoError):
    """A stored relay private key is present but unparseable.

    Raised instead of silently minting a fresh identity so a corrupt or
    truncated ``BURNBAR_RELAY_PRIVATE_KEY`` cannot rotate the agent's identity
    out from under previously-sealed inbound events (which would be
    indistinguishable from a relay key-substitution attack). Re-pairing — or
    explicitly clearing the env var — is required to recover.
    """


# ---------------------------------------------------------------------------
# Namespace (AAD prefixing)
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class RelayNamespace:
    """Carries the AAD / key-wrap prefixes for one relay scheme.

    ``HERMES_NAMESPACE`` -> AAD ``OpenBurnBar-HermesRelay-v1|...`` and key-wrap
    info ``OpenBurnBar-HermesRelay-KeyWrap-v1|...``. Pass ``namespace=`` to
    every AAD/seal call to pick a different explicit scheme; it defaults to
    Hermes.
    """

    name: str = HERMES_NAMESPACE

    @property
    def aad_prefix(self) -> str:
        return f"{self.name}-v1"

    @property
    def key_wrap_info_prefix(self) -> bytes:
        return f"{self.name}-KeyWrap-v1|".encode("utf-8")

    @property
    def key_wrap_info_prefix_v2(self) -> bytes:
        """Domain-separated key-wrap prefix for the v2 authenticated 2-DH wrap.

        The ``v2`` suffix is a hard domain separation from ``v1`` so a wrapping
        key derived under the authenticated (sender-bound) scheme can never
        collide with the anonymous v1 scheme even given identical ``aad``.
        """
        return f"{self.name}-KeyWrap-v2|".encode("utf-8")

    def aad(self, parts: list[str]) -> bytes:
        # Delimiter safety: the AAD is a flat "|"-joined string with no
        # escaping, so a part containing a literal "|" — or a control char — could
        # forge an equivalent part list (e.g. ["a|b", "c"] vs ["a", "b|c"]) and let
        # a relay collide two distinct contexts onto the same AAD. Production parts
        # are all token_hex / Firebase ids (no "|"), so this never fires in practice;
        # it is a fail-closed guard for any future caller that forwards a less
        # constrained string. A length-prefixed/CBOR canonical AAD is the future
        # version path.
        for part in parts:
            if "|" in part or any(ord(ch) < 0x20 for ch in part):
                raise ValueError(
                    "relay AAD part contains an illegal '|' delimiter or control character"
                )
        return f"{self.aad_prefix}|{'|'.join(parts)}".encode("utf-8")

    def key_wrap_shared_info(self, aad: bytes) -> bytes:
        return self.key_wrap_info_prefix + aad

    def key_wrap_shared_info_v2(
        self,
        aad: bytes,
        enc_x963: bytes,
        recipient_pub_x963: bytes,
        sender_pub_x963: bytes,
    ) -> bytes:
        """HKDF ``info`` for the v2 authenticated key-wrap.

        Matches the shared mobile/Python wire contract exactly::

            b"<ns>-KeyWrap-v2|" + aad + enc + recipientPubX963 + senderPubX963

        where ``enc`` is the ephemeral public key (X9.63, 65B) and the recipient
        and sender public keys are also the raw 65-byte X9.63 uncompressed form
        (``0x04 || X || Y``), not DER/SPKI. Binding all three public keys into the
        KDF info, together with the second ECDH leg against the *pinned* sender
        key, is what makes a forged sender fail to derive the wrapping key.
        """
        return (
            self.key_wrap_info_prefix_v2
            + aad
            + enc_x963
            + recipient_pub_x963
            + sender_pub_x963
        )


_HERMES = RelayNamespace(HERMES_NAMESPACE)


def _resolve_namespace(namespace: RelayNamespace | str | None) -> RelayNamespace:
    if namespace is None:
        return _HERMES
    if isinstance(namespace, RelayNamespace):
        return namespace
    if namespace == HERMES_NAMESPACE:
        return _HERMES
    return RelayNamespace(namespace)


# ---------------------------------------------------------------------------
# AAD builders for the relay request/key/chunk labels.
# ---------------------------------------------------------------------------


def request_aad(
    uid: str,
    connection_id: str,
    request_id: str,
    *,
    namespace: RelayNamespace | str | None = None,
) -> bytes:
    """AAD for sealing the request payload."""
    return _resolve_namespace(namespace).aad(["request", uid, connection_id, request_id])


def key_aad(
    uid: str,
    connection_id: str,
    request_id: str,
    *,
    namespace: RelayNamespace | str | None = None,
) -> bytes:
    """AAD for wrapping the symmetric key."""
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
    """AAD for sealing one streamed chunk.

    ``sequence`` is rendered as base-10 ASCII with ``str(int)``.
    """
    return _resolve_namespace(namespace).aad(
        ["chunk", uid, connection_id, request_id, str(sequence), kind]
    )


# ---------------------------------------------------------------------------
# Key material
# ---------------------------------------------------------------------------


@dataclass(frozen=True)
class RelayPrivateKey:
    """A P-256 relay private key for the relay wire format.

    Stores the raw 32-byte big-endian scalar.
    The ``cryptography`` ``EllipticCurvePrivateKey`` is derived lazily so this
    dataclass never forces the C extension to load.
    """

    raw_representation: bytes

    def __post_init__(self) -> None:
        if len(self.raw_representation) != _P256_COORDINATE_BYTE_COUNT:
            raise InvalidPublicKeyError(
                "relay private key must be the raw 32-byte P-256 scalar"
            )
        # Range-check the scalar so a zero/overflowing key fails closed here with a
        # typed error rather than as a bare ValueError later inside
        # ``ec.derive_private_key`` (which every wrap/unwrap/public-key path hits).
        scalar = int.from_bytes(self.raw_representation, "big")
        if not 1 <= scalar < _P256_GROUP_ORDER:
            raise InvalidPublicKeyError(
                "relay private key scalar is out of range [1, n-1] for P-256"
            )

    @classmethod
    def from_raw(cls, raw: bytes) -> "RelayPrivateKey":
        """Import from the raw 32-byte big-endian scalar."""
        return cls(bytes(raw))

    @classmethod
    def from_base64(cls, raw_base64: str) -> "RelayPrivateKey":
        """Import from base64 of the raw 32-byte scalar."""
        try:
            return cls(base64.b64decode(raw_base64, validate=True))
        except (ValueError, binascii.Error) as exc:
            raise InvalidPublicKeyError("relay private key is invalid") from exc

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
        """Base64 of the X9.63 uncompressed public key."""
        return base64.b64encode(self.public_key_x963()).decode("ascii")

    def raw_base64(self) -> str:
        """Base64 of the raw 32-byte private scalar (for persistence)."""
        return base64.b64encode(self.raw_representation).decode("ascii")


def generate_private_key() -> RelayPrivateKey:
    """Generate a fresh P-256 relay private key."""
    from cryptography.hazmat.primitives.asymmetric import ec

    private_key = ec.generate_private_key(ec.SECP256R1())
    raw = private_key.private_numbers().private_value.to_bytes(
        _P256_COORDINATE_BYTE_COUNT, "big"
    )
    return RelayPrivateKey(raw)


def generate_symmetric_key() -> bytes:
    """Generate a fresh 32-byte AES-256 symmetric key."""
    return os.urandom(_SYMMETRIC_KEY_BYTE_COUNT)


@dataclass(frozen=True)
class AgentRelayIdentity:
    """The agent's persistent relay keypair.

    The agent publishes ``public_key_base64`` at ``device/start`` /
    ``handleRuntimeStatus`` (``agentRelayPublicKey`` / ``agentRelayKeyVersion``
    / ``agentRelayEncryption``) so the phone can wrap inbound gateway events to
    it. The private key persists in the ``BURNBAR_RELAY_PRIVATE_KEY`` env var
    (base64 of the raw 32-byte scalar).
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
        the caller can write it back through Hermes' configured environment
        persistence path (mirroring how the BurnBar adapter persists
        ``BURNBAR_ACCESS_TOKEN``).

        Stability matters: without persistence the agent's relay key would rotate
        on every restart, silently breaking every previously-sealed inbound
        event. So a freshly minted key is (a) written back into the live
        ``environ`` map so an in-process reload sees the same key even if disk
        persistence is unavailable, and (b) handed to ``persist`` for durable
        storage. A ``persist`` failure is logged-and-swallowed (never fatal) — the
        in-memory + environ copy keeps the process consistent for this run.
        """
        source = environ if environ is not None else os.environ
        raw_base64 = source.get(env_var)
        if raw_base64:
            try:
                return cls(RelayPrivateKey.from_base64(raw_base64.strip()))
            except (ValueError, RelayCryptoError, binascii.Error) as exc:
                # A present-but-invalid stored key must FAIL CLOSED, not
                # silently mint a new identity. Silent rotation makes every prior
                # sealed inbound event undecryptable and is indistinguishable from
                # a relay key-substitution attack, so the operator must re-pair
                # (or explicitly clear the env var) to recover.
                raise CorruptIdentityError(
                    f"{env_var} is present but invalid — re-pair required; "
                    "refusing to silently rotate the relay identity"
                ) from exc
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
    result already carries the 16-byte tag.
    """
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    if len(key_data) != _SYMMETRIC_KEY_BYTE_COUNT:
        raise InvalidSymmetricKeyError("symmetric key must be 32 bytes")
    nonce = os.urandom(_NONCE_BYTE_COUNT)
    ciphertext_with_tag = AESGCM(key_data).encrypt(nonce, plaintext, aad)
    return base64.b64encode(nonce + ciphertext_with_tag).decode("ascii")


def open_base64(ciphertext_base64: str, key_data: bytes, aad: bytes) -> bytes:
    """Open a ``seal_to_base64`` envelope.

    Raises ``cryptography.exceptions.InvalidTag`` when ``aad`` / ``key_data``
    do not match (authenticated decryption failure).
    """
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM

    if len(key_data) != _SYMMETRIC_KEY_BYTE_COUNT:
        raise InvalidSymmetricKeyError("symmetric key must be 32 bytes")
    try:
        raw = base64.b64decode(ciphertext_base64, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise InvalidCiphertextError("ciphertext is not valid base64") from exc
    if len(raw) <= _NONCE_BYTE_COUNT:
        raise InvalidCiphertextError("ciphertext too short")
    return AESGCM(key_data).decrypt(raw[:_NONCE_BYTE_COUNT], raw[_NONCE_BYTE_COUNT:], aad)


# ---------------------------------------------------------------------------
# Symmetric-key wrapping (ECIES: ephemeral P-256 ECDH -> HKDF -> AES-256-GCM)
# ---------------------------------------------------------------------------


def _hkdf_derive(shared_secret: bytes, info: bytes) -> bytes:
    """HKDF-SHA256 with the RFC-5869 empty salt to a 32-byte key.

    Shared by both the v1 and v2 key-wrap paths so the salt / length / hash are
    defined in exactly one place. Only the ``info`` differs between schemes.
    """
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF

    return HKDF(
        algorithm=hashes.SHA256(),
        length=_SYMMETRIC_KEY_BYTE_COUNT,
        salt=_HKDF_SALT,
        info=info,
    ).derive(shared_secret)


def _hkdf_wrapping_key(
    shared_secret: bytes, aad: bytes, namespace: RelayNamespace
) -> bytes:
    """v1 wrapping key: ``info = "<ns>-KeyWrap-v1|" + aad`` (byte-unchanged)."""
    return _hkdf_derive(shared_secret, namespace.key_wrap_shared_info(aad))


def _public_key_x963_from_base64(public_key_base64: str) -> bytes:
    """Parse a base64 X9.63 P-256 public key and return its raw 65-byte form.

    Uses the same ``ec.EllipticCurvePublicKey.from_encoded_point`` parsing the
    module already applies to the recipient key, so an invalid point raises
    :class:`InvalidPublicKeyError` consistently, and re-serializes it to the
    canonical uncompressed X9.63 bytes for use in the v2 HKDF ``info``.
    """
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

    try:
        raw = base64.b64decode(public_key_base64, validate=True)
        public_key = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), raw)
    except (ValueError, binascii.Error) as exc:
        raise InvalidPublicKeyError("public key is invalid") from exc
    return public_key.public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)


def public_key_x963_from_base64(public_key_base64: str) -> bytes:
    """Return canonical X9.63 P-256 public bytes from base64, or raise.

    This public wrapper is for callers that need to validate user-visible
    pairing material before pinning or displaying a safety code. It deliberately
    shares the same parser as the key-wrap path, so invalid-curve / malformed
    points fail identically everywhere.
    """
    return _public_key_x963_from_base64(public_key_base64)


def wrap_symmetric_key(
    key_data: bytes,
    recipient_public_key_base64: str,
    aad: bytes,
    *,
    namespace: RelayNamespace | str | None = None,
    sender_private: "RelayPrivateKey | bytes | None" = None,
) -> str:
    """Wrap the 32-byte ``key_data`` to ``recipient_public_key_base64``.

    **v1 (default, ``sender_private=None``)** matches the existing
    ``wrapSymmetricKey`` wire shape:
    fresh ephemeral P-256 keypair, ECDH to the recipient, HKDF-SHA256 (empty
    salt, info = ``"<ns>-KeyWrap-v1|" + aad``) to a wrapping key, AES-256-GCM
    seal of ``key_data`` under it with ``aad``. This path is byte-identical to
    the prior behaviour.

    **v2 (``sender_private`` supplied)** is the HPKE-AuthEncap-shaped
    authenticated 2-DH key-wrap (the sender-bound forgery defense). It matches
    the shared v2 wire contract exactly::

        eph = fresh P-256
        dh1 = ECDH(eph_priv,    recipientPub)      # 32B raw X
        dh2 = ECDH(senderPriv,  recipientPub)      # 32B raw X
        ikm = dh1 || dh2                           # 64B concat, dh1 first
        info = "<ns>-KeyWrap-v2|" + aad + enc + recipientPubX963 + senderPubX963
        wrappingKey = HKDF-SHA256(ikm, empty-salt, info, 32)
        sealed      = AES-256-GCM(wrappingKey, random12, key_data, aad)

    In both versions the wire uses the same layout:
    ``base64(enc(65) || nonce(12) || ct(32) || tag(16))`` = 125B, ``[0] == 0x04``,
    where ``enc`` is the ephemeral public key (X9.63 uncompressed).

    ``aad`` must be the ``key_aad`` for the request.
    """
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

    ns = _resolve_namespace(namespace)
    if len(key_data) != _SYMMETRIC_KEY_BYTE_COUNT:
        raise InvalidSymmetricKeyError("symmetric key must be 32 bytes")
    try:
        recipient_bytes = base64.b64decode(recipient_public_key_base64, validate=True)
        recipient = ec.EllipticCurvePublicKey.from_encoded_point(
            ec.SECP256R1(), recipient_bytes
        )
    except (ValueError, binascii.Error) as exc:
        raise InvalidPublicKeyError("recipient public key is invalid") from exc

    ephemeral = ec.generate_private_key(ec.SECP256R1())
    eph_x963 = ephemeral.public_key().public_bytes(
        Encoding.X962, PublicFormat.UncompressedPoint
    )

    if sender_private is None:
        # v1 anonymous path, byte-unchanged.
        shared_secret = ephemeral.exchange(ec.ECDH(), recipient)
        wrapping_key = _hkdf_wrapping_key(shared_secret, aad, ns)
    else:
        # v2 authenticated 2-DH path.
        sender = (
            sender_private
            if isinstance(sender_private, RelayPrivateKey)
            else RelayPrivateKey.from_raw(sender_private)
        )
        recipient_pub_x963 = recipient.public_bytes(
            Encoding.X962, PublicFormat.UncompressedPoint
        )
        sender_pub_x963 = sender.public_key_x963()
        dh1 = ephemeral.exchange(ec.ECDH(), recipient)
        dh2 = sender._private_key().exchange(ec.ECDH(), recipient)
        ikm = dh1 + dh2  # Concatenate dh1 first; do not combine with XOR.
        info = ns.key_wrap_shared_info_v2(
            aad, eph_x963, recipient_pub_x963, sender_pub_x963
        )
        wrapping_key = _hkdf_derive(ikm, info)

    nonce = os.urandom(_NONCE_BYTE_COUNT)
    sealed = AESGCM(wrapping_key).encrypt(nonce, key_data, aad)
    return base64.b64encode(eph_x963 + nonce + sealed).decode("ascii")


def unwrap_symmetric_key(
    wrapped_key_base64: str,
    private_key: RelayPrivateKey | bytes,
    aad: bytes,
    *,
    namespace: RelayNamespace | str | None = None,
    sender_public_base64: str | None = None,
) -> bytes:
    """Unwrap a ``wrap_symmetric_key`` envelope using the shared wire contract.

    ``private_key`` may be a :class:`RelayPrivateKey` or the raw 32-byte
    big-endian scalar bytes. Splits ``prefix(65)`` = ephemeral pub (``enc``),
    ``suffix(65:)`` = ``nonce(12) || ct || tag(16)``.

    **v1 (default, ``sender_public_base64=None``)** does a single ECDH against
    the embedded ephemeral key, then the v1 HKDF, byte-unchanged.

    **v2 (``sender_public_base64`` supplied)** is the authenticated 2-DH unwrap.
    It binds the pinned sender public key (passed by the caller, not a
    wire-supplied field) as the forgery defense::

        dh1 = ECDH(recipientPriv, enc)             # against the wire ephemeral
        dh2 = ECDH(recipientPriv, senderPubPinned) # against the pinned sender key
        ikm = dh1 || dh2                           # concat, dh1 first
        info = "<ns>-KeyWrap-v2|" + aad + enc + recipientOwnPubX963 + senderPubPinnedX963
        wrappingKey = HKDF-SHA256(ikm, empty-salt, info, 32)

    A wrong/forged sender key changes both ``dh2`` and the ``info``, so the
    derived wrapping key is wrong and AES-256-GCM ``open`` raises
    :class:`cryptography.exceptions.InvalidTag`.

    Raises ``InvalidTag`` on wrong ``aad`` / wrong recipient key / wrong sender
    key.
    """
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

    ns = _resolve_namespace(namespace)
    if isinstance(private_key, RelayPrivateKey):
        relay_private = private_key
    else:
        relay_private = RelayPrivateKey.from_raw(private_key)

    try:
        envelope = base64.b64decode(wrapped_key_base64, validate=True)
    except (ValueError, binascii.Error) as exc:
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

    if sender_public_base64 is None:
        # v1 anonymous path, byte-unchanged.
        shared_secret = relay_private._private_key().exchange(
            ec.ECDH(), ephemeral_public
        )
        wrapping_key = _hkdf_wrapping_key(shared_secret, aad, ns)
    else:
        # v2 authenticated 2-DH path: bind the pinned sender key.
        sender_pub_x963 = _public_key_x963_from_base64(sender_public_base64)
        sender_public = ec.EllipticCurvePublicKey.from_encoded_point(
            ec.SECP256R1(), sender_pub_x963
        )
        recipient_own_pub_x963 = relay_private.public_key_x963()
        dh1 = relay_private._private_key().exchange(ec.ECDH(), ephemeral_public)
        dh2 = relay_private._private_key().exchange(ec.ECDH(), sender_public)
        ikm = dh1 + dh2  # Concatenate dh1 first; do not combine with XOR.
        info = ns.key_wrap_shared_info_v2(
            aad, eph_pub_bytes, recipient_own_pub_x963, sender_pub_x963
        )
        wrapping_key = _hkdf_derive(ikm, info)

    return AESGCM(wrapping_key).decrypt(body[:_NONCE_BYTE_COUNT], body[_NONCE_BYTE_COUNT:], aad)
