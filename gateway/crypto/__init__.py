"""End-to-end relay crypto for the BurnBar / PiAgent gateway.

This package is the Python mirror of the canonical Swift
``HermesRelayCrypto`` (``OpenBurnBarCore/.../HermesRelayCrypto.swift``) and
the Kotlin ``HermesRelayCrypto`` (``android/.../data/hermes/relay/``). All
three open the same wire vector
(``OpenBurnBarCoreTests/Fixtures/HermesRelayWireVector.json``) byte-for-byte.

The gateway adapter (``plugins/platforms/burnbar/adapter.py``) imports the
sealing primitives from :mod:`gateway.crypto.relay_e2ee` so the agent can
seal message text / attachment bodies to the paired phone's relay public key
and unwrap inbound events sealed to its own relay public key — without the
relay server ever seeing plaintext.
"""

from .relay_e2ee import (
    ALGORITHM,
    KEY_VERSION,
    HERMES_NAMESPACE,
    PIAGENT_NAMESPACE,
    RelayNamespace,
    RelayPrivateKey,
    AgentRelayIdentity,
    RelayCryptoError,
    InvalidPublicKeyError,
    InvalidCiphertextError,
    InvalidSymmetricKeyError,
    generate_private_key,
    generate_symmetric_key,
    seal_to_base64,
    open_base64,
    wrap_symmetric_key,
    unwrap_symmetric_key,
    request_aad,
    key_aad,
    chunk_aad,
)

__all__ = [
    "ALGORITHM",
    "KEY_VERSION",
    "HERMES_NAMESPACE",
    "PIAGENT_NAMESPACE",
    "RelayNamespace",
    "RelayPrivateKey",
    "AgentRelayIdentity",
    "RelayCryptoError",
    "InvalidPublicKeyError",
    "InvalidCiphertextError",
    "InvalidSymmetricKeyError",
    "generate_private_key",
    "generate_symmetric_key",
    "seal_to_base64",
    "open_base64",
    "wrap_symmetric_key",
    "unwrap_symmetric_key",
    "request_aad",
    "key_aad",
    "chunk_aad",
]
