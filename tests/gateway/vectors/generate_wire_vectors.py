"""Deterministic, in-tree generator for the BurnBar relay wire vectors.

This module is the canonical, self-contained generator for the two known-answer
vectors the Python relay-crypto suite opens:

  * ``tests/gateway/fixtures/HermesRelayWireVector.json``   (v1 realtime relay)
  * ``tests/gateway/fixtures/HermesGatewayWireVector.json`` (v2 authenticated gateway)

It seals fixed plaintexts under fixed static keypairs, fixed symmetric keys,
fixed ephemeral keys, and fixed nonces, so the exact ciphertext bytes are
reproducible from this file alone. A maintainer can regenerate and byte-verify
the committed fixtures with **no non-Python toolchain**::

    python -m tests.gateway.vectors.generate_wire_vectors --check   # verify in place
    python -m tests.gateway.vectors.generate_wire_vectors --write   # regenerate

``tests/gateway/test_wire_vectors_reproducible.py`` runs ``--check`` as part of
the suite, so the committed fixtures can never silently drift from this
generator.

Scope of the proof. This vector pins the **Python** relay implementation against
a fixed, reproducible target: every wrap/seal/AAD byte is recomputed here from
the documented primitives in :mod:`plugins.platforms.burnbar.relay_e2ee`. The same wire
format (AAD labels, X9.63 key encoding, the v2 authenticated 2-DH key wrap) is
implemented by the BurnBar iOS (CryptoKit) and Android clients; cross-language
parity is maintained in those client repositories and is **not** re-proven here
(no non-Python implementation is vendored in this repo).

The static test keypairs are intentionally low-entropy, clearly-synthetic
scalars (``0x10`` followed by ``0x42`` filler, ``...01`` / ``...02``) so no one
mistakes them for production key material.
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import sys
from contextlib import contextmanager
from pathlib import Path
from unittest import mock

from plugins.platforms.burnbar import relay_e2ee

_FIXTURES = Path(__file__).resolve().parents[1] / "fixtures"
RELAY_VECTOR_PATH = _FIXTURES / "HermesRelayWireVector.json"
GATEWAY_VECTOR_PATH = _FIXTURES / "HermesGatewayWireVector.json"

# Order of the NIST P-256 prime-order group (for deriving in-range ephemerals).
_P256_GROUP_ORDER = 0xFFFFFFFF00000000FFFFFFFFFFFFFFFFBCE6FAADA7179E84F3B9CAC2FC632551

# Crypto-output fields the generator OWNS (everything else in a fixture is an
# input it carries through verbatim). Listing them keeps the diff legible and
# documents exactly what the deterministic procedure produces.
_RELAY_OUTPUT_FIELDS = (
    "algorithm", "revision", "recipientPublicKey",
    "requestAAD", "keyAAD", "chunkAAD",
    "payloadCiphertext", "chunkCiphertext", "wrappedKey",
)
_GATEWAY_PAYLOAD_OUTPUT_FIELDS = (
    "recipientPublicKey", "senderPublicKey",
    "payloadAAD", "keyAAD", "payloadCiphertext", "wrappedKey",
)
_GATEWAY_ATTACHMENT_OUTPUT_FIELDS = (
    "recipientPublicKey", "senderPublicKey",
    "manifestAAD", "bodyAAD", "keyAAD",
    "manifestCiphertext", "bodyCiphertext", "wrappedKey",
)

# AAD labels + id field per gateway payload slot. modelSwitch deliberately reuses
# the event labels (iOS emits a model switch as an ordinary sealed event).
_GATEWAY_PAYLOAD_LABELS = {
    "event": ("gatewayEvent", "gatewayEventKey", "eventId"),
    "modelSwitch": ("gatewayEvent", "gatewayEventKey", "eventId"),
    "message": ("gatewayMessage", "gatewayMessageKey", "messageId"),
}


class _DeterministicEntropy:
    """Counter-driven replacement for the two randomness sources in a seal/wrap:
    the 12-byte GCM nonces (``os.urandom``) and the per-wrap ephemeral key
    (``ec.generate_private_key``). Everything else (ECDH, HKDF, AES-GCM with a
    fixed nonce) is already deterministic, so fixing these two makes the emitted
    ciphertext byte-stable.
    """

    def __init__(self) -> None:
        self._nonce_i = 0
        self._eph_i = 0

    def urandom(self, n: int) -> bytes:
        out = bytearray()
        block = 0
        while len(out) < n:
            out += hashlib.sha256(
                b"hermes-relay-vector|nonce|"
                + self._nonce_i.to_bytes(8, "big")
                + block.to_bytes(2, "big")
            ).digest()
            block += 1
        self._nonce_i += 1
        return bytes(out[:n])

    def generate_private_key(self, _curve):
        # _curve is always SECP256R1 here; we derive from a fixed seed instead.
        from cryptography.hazmat.primitives.asymmetric import ec

        seed = hashlib.sha256(
            b"hermes-relay-vector|ephemeral|" + self._eph_i.to_bytes(8, "big")
        ).digest()
        scalar = (int.from_bytes(seed, "big") % (_P256_GROUP_ORDER - 1)) + 1
        self._eph_i += 1
        return ec.derive_private_key(scalar, ec.SECP256R1())


@contextmanager
def _deterministic():
    """Patch the nonce + ephemeral sources for the duration of one vector build.

    Patches are confined to this context manager (the generator and its test),
    never the production code path.
    """
    from cryptography.hazmat.primitives.asymmetric import ec

    entropy = _DeterministicEntropy()
    with mock.patch.object(relay_e2ee.os, "urandom", entropy.urandom), mock.patch.object(
        ec, "generate_private_key", entropy.generate_private_key
    ):
        yield


def _ns() -> "relay_e2ee.RelayNamespace":
    return relay_e2ee.RelayNamespace(relay_e2ee.HERMES_NAMESPACE)


def _assert_output_fields(outputs: dict, expected, label: str) -> None:
    """Guard that a builder produced EXACTLY the declared crypto-output fields.

    Turns the ``_*_OUTPUT_FIELDS`` declarations into a real invariant: a forgotten
    output (which would silently ship a stale value carried from the spec) or a
    stray one fails loudly here instead of slipping through.
    """
    actual = set(outputs)
    if actual != set(expected):
        missing = sorted(set(expected) - actual)
        extra = sorted(actual - set(expected))
        raise AssertionError(
            f"{label} vector output fields drifted (missing={missing}, extra={extra})"
        )


def build_relay_vector(spec: dict) -> dict:
    """Recompute the v1 (anonymous, single-DH) realtime-relay vector from ``spec``.

    Input fields (ids, plaintexts, recipient private key, symmetric key) are
    carried through; the crypto-output fields are regenerated deterministically.
    """
    uid, conn, req = spec["uid"], spec["connectionId"], spec["requestId"]
    recipient = relay_e2ee.RelayPrivateKey.from_base64(spec["recipientPrivateKey"])
    sym = base64.b64decode(spec["symmetricKey"])
    payload_pt = base64.b64decode(spec["encodedPlaintext"])

    request_aad = relay_e2ee.request_aad(uid, conn, req)
    key_aad = relay_e2ee.key_aad(uid, conn, req)
    chunk_aad = relay_e2ee.chunk_aad(uid, conn, req, spec["chunkSequence"], spec["chunkKind"])

    outputs = {
        "algorithm": relay_e2ee.ALGORITHM,
        "revision": "v1",
        "recipientPublicKey": recipient.public_key_base64(),
        "requestAAD": request_aad.decode("utf-8"),
        "keyAAD": key_aad.decode("utf-8"),
        "chunkAAD": chunk_aad.decode("utf-8"),
    }
    with _deterministic():
        outputs["payloadCiphertext"] = relay_e2ee.seal_to_base64(payload_pt, sym, request_aad)
        outputs["chunkCiphertext"] = relay_e2ee.seal_to_base64(
            spec["chunkPlaintext"].encode("utf-8"), sym, chunk_aad
        )
        outputs["wrappedKey"] = relay_e2ee.wrap_symmetric_key(sym, outputs["recipientPublicKey"], key_aad)
    _assert_output_fields(outputs, _RELAY_OUTPUT_FIELDS, "relay")
    return {**spec, **outputs}


def build_gateway_vector(spec: dict) -> dict:
    """Recompute the v2 (authenticated, 2-DH) gateway vector from ``spec``.

    The two static keypairs are read from the slots that own each private key:
    ``event.recipientPrivateKey`` is the agent (A), ``message.recipientPrivateKey``
    is the phone (B). Senders are bound per slot (phone-to-agent for event/modelSwitch,
    agent-to-phone for message/attachment), exactly mirroring the adapter's send paths.
    """
    ns = _ns()
    out = dict(spec)
    out["algorithm"] = relay_e2ee.ALGORITHM
    out["keyVersion"] = 2
    out["revision"] = "v2"

    priv_a = spec["event"]["recipientPrivateKey"]      # agent static private key
    priv_b = spec["message"]["recipientPrivateKey"]    # phone static private key
    sender_priv_by_slot = {
        "event": priv_b, "modelSwitch": priv_b,        # phone -> agent
        "message": priv_a, "attachment": priv_a,       # agent -> phone
    }

    with _deterministic():
        for slot in ("event", "message", "modelSwitch"):
            s = spec[slot]
            uid, client = s["uid"], s["clientId"]
            payload_label, key_label, id_field = _GATEWAY_PAYLOAD_LABELS[slot]
            obj_id = s[id_field]
            recipient = relay_e2ee.RelayPrivateKey.from_base64(s["recipientPrivateKey"])
            sender = relay_e2ee.RelayPrivateKey.from_base64(sender_priv_by_slot[slot])
            recipient_pub = recipient.public_key_base64()
            sym = base64.b64decode(s["symmetricKey"])
            payload_pt = base64.b64decode(s["encodedPlaintext"])
            payload_aad = ns.aad([payload_label, uid, client, obj_id])
            key_aad = ns.aad([key_label, uid, client, obj_id])

            outputs = {
                "recipientPublicKey": recipient_pub,
                "senderPublicKey": sender.public_key_base64(),
                "payloadAAD": payload_aad.decode("utf-8"),
                "keyAAD": key_aad.decode("utf-8"),
                "payloadCiphertext": relay_e2ee.seal_to_base64(payload_pt, sym, payload_aad),
                "wrappedKey": relay_e2ee.wrap_symmetric_key(
                    sym, recipient_pub, key_aad, sender_private=sender
                ),
            }
            _assert_output_fields(outputs, _GATEWAY_PAYLOAD_OUTPUT_FIELDS, f"gateway {slot}")
            out[slot] = {**s, **outputs}

        a = spec["attachment"]
        uid, client, aid = a["uid"], a["clientId"], a["attachmentId"]
        recipient = relay_e2ee.RelayPrivateKey.from_base64(a["recipientPrivateKey"])
        sender = relay_e2ee.RelayPrivateKey.from_base64(sender_priv_by_slot["attachment"])
        recipient_pub = recipient.public_key_base64()
        body_key = base64.b64decode(a["bodyKey"])
        manifest_aad = ns.aad(["gatewayAttachmentManifest", uid, client, aid])
        body_aad = ns.aad(["gatewayAttachmentBody", uid, client, aid])
        key_aad = ns.aad(["gatewayAttachmentKey", uid, client, aid])

        outputs = {
            "recipientPublicKey": recipient_pub,
            "senderPublicKey": sender.public_key_base64(),
            "manifestAAD": manifest_aad.decode("utf-8"),
            "bodyAAD": body_aad.decode("utf-8"),
            "keyAAD": key_aad.decode("utf-8"),
            "manifestCiphertext": relay_e2ee.seal_to_base64(
                a["manifestPlaintext"].encode("utf-8"), body_key, manifest_aad
            ),
            "bodyCiphertext": relay_e2ee.seal_to_base64(
                a["bodyPlaintext"].encode("utf-8"), body_key, body_aad
            ),
            "wrappedKey": relay_e2ee.wrap_symmetric_key(
                body_key, recipient_pub, key_aad, sender_private=sender
            ),
        }
        _assert_output_fields(outputs, _GATEWAY_ATTACHMENT_OUTPUT_FIELDS, "gateway attachment")
        out["attachment"] = {**a, **outputs}
    return out


def _load(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def _dump(obj: dict) -> str:
    return json.dumps(obj, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def regenerate() -> dict[str, dict]:
    """Return the freshly regenerated vectors keyed by fixture path (no writes)."""
    return {
        str(RELAY_VECTOR_PATH): build_relay_vector(_load(RELAY_VECTOR_PATH)),
        str(GATEWAY_VECTOR_PATH): build_gateway_vector(_load(GATEWAY_VECTOR_PATH)),
    }


def _main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--write", action="store_true", help="regenerate and overwrite the fixtures")
    group.add_argument("--check", action="store_true", help="verify the committed fixtures reproduce")
    args = parser.parse_args(argv)

    targets = ((RELAY_VECTOR_PATH, build_relay_vector), (GATEWAY_VECTOR_PATH, build_gateway_vector))
    drift = False
    for path, builder in targets:
        regenerated = builder(_load(path))
        if args.write:
            path.write_text(_dump(regenerated), encoding="utf-8")
            print(f"wrote {path}")
        else:
            if _load(path) != regenerated:
                drift = True
                print(f"DRIFT: {path} does not match the deterministic generator", file=sys.stderr)
            else:
                print(f"ok    {path}")
    return 1 if drift else 0


if __name__ == "__main__":
    raise SystemExit(_main(sys.argv[1:]))
