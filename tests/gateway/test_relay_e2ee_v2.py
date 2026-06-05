"""v2 authenticated key-wrap interop against the canonical Swift gateway vector.

Opens the Swift-emitted ``HermesGatewayWireVector.json`` (``revision == "v2"``) and
proves Python unwraps each slot under the v2 2-DH scheme. Forge tests pin a wrong
sender and expect ``InvalidTag``.
"""

from __future__ import annotations

import base64
import json
from pathlib import Path

import pytest

pytest.importorskip("cryptography")

from gateway.crypto import relay_e2ee  # noqa: E402

_GATEWAY_FIXTURE_PATH = (
    Path(__file__).resolve().parent / "fixtures" / "HermesGatewayWireVector.json"
)


@pytest.fixture(scope="module")
def gateway_vector() -> dict:
    with _GATEWAY_FIXTURE_PATH.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def _aad(value: str) -> bytes:
    return value.encode("utf-8")


def _unwrap_v2(node: dict, key_aad: str) -> bytes:
    recipient = relay_e2ee.RelayPrivateKey.from_base64(node["recipientPrivateKey"])
    return relay_e2ee.unwrap_symmetric_key(
        node["wrappedKey"],
        recipient,
        _aad(key_aad),
        sender_public_base64=node["senderPublicKey"],
    )


def test_gateway_vector_is_the_v2_contract(gateway_vector):
    assert gateway_vector["revision"] == "v2"
    assert gateway_vector["keyVersion"] == 2
    assert gateway_vector["algorithm"] == relay_e2ee.ALGORITHM
    for slot in ("event", "message", "modelSwitch", "attachment"):
        assert gateway_vector[slot]["senderPublicKey"], f"{slot} missing senderPublicKey"


@pytest.mark.parametrize("slot", ["event", "message", "modelSwitch"])
def test_v2_unwrap_then_open_payload(gateway_vector, slot):
    node = gateway_vector[slot]
    sym = _unwrap_v2(node, node["keyAAD"])
    assert sym == base64.b64decode(node["symmetricKey"])
    plaintext = relay_e2ee.open_base64(
        node["payloadCiphertext"], sym, _aad(node["payloadAAD"])
    )
    assert plaintext == base64.b64decode(node["encodedPlaintext"])


def test_v2_attachment_unwraps_body_key_and_opens_manifest_and_body(gateway_vector):
    node = gateway_vector["attachment"]
    body_key = _unwrap_v2(node, node["keyAAD"])
    assert body_key == base64.b64decode(node["bodyKey"])
    manifest = relay_e2ee.open_base64(
        node["manifestCiphertext"], body_key, _aad(node["manifestAAD"])
    )
    assert manifest.decode("utf-8") == node["manifestPlaintext"]
    body = relay_e2ee.open_base64(
        node["bodyCiphertext"], body_key, _aad(node["bodyAAD"])
    )
    assert body.decode("utf-8") == node["bodyPlaintext"]


@pytest.mark.parametrize("slot", ["event", "message", "modelSwitch", "attachment"])
def test_v2_unwrap_with_wrong_sender_key_raises_invalid_tag(gateway_vector, slot):
    from cryptography.exceptions import InvalidTag

    node = gateway_vector[slot]
    recipient = relay_e2ee.RelayPrivateKey.from_base64(node["recipientPrivateKey"])
    with pytest.raises(InvalidTag):
        relay_e2ee.unwrap_symmetric_key(
            node["wrappedKey"],
            recipient,
            _aad(node["keyAAD"]),
            sender_public_base64=node["recipientPublicKey"],
        )


@pytest.mark.parametrize("slot", ["event", "message", "modelSwitch", "attachment"])
def test_v2_unwrap_with_wrong_recipient_key_raises_invalid_tag(gateway_vector, slot):
    from cryptography.exceptions import InvalidTag

    node = gateway_vector[slot]
    wrong_recipient = relay_e2ee.generate_private_key()
    with pytest.raises(InvalidTag):
        relay_e2ee.unwrap_symmetric_key(
            node["wrappedKey"],
            wrong_recipient,
            _aad(node["keyAAD"]),
            sender_public_base64=node["senderPublicKey"],
        )


def test_v2_unwrap_rejects_malformed_sender_public_key(gateway_vector):
    node = gateway_vector["event"]
    recipient = relay_e2ee.RelayPrivateKey.from_base64(node["recipientPrivateKey"])
    with pytest.raises(relay_e2ee.InvalidPublicKeyError):
        relay_e2ee.unwrap_symmetric_key(
            node["wrappedKey"],
            recipient,
            _aad(node["keyAAD"]),
            sender_public_base64=node["senderPublicKey"] + "!!",
        )


def test_v2_wrap_is_domain_separated_from_v1_unwrap():
    from cryptography.exceptions import InvalidTag

    sender = relay_e2ee.generate_private_key()
    recipient = relay_e2ee.generate_private_key()
    symmetric_key = relay_e2ee.generate_symmetric_key()
    aad = relay_e2ee.key_aad("u", "c", "r")
    wrapped = relay_e2ee.wrap_symmetric_key(
        symmetric_key, recipient.public_key_base64(), aad, sender_private=sender
    )
    with pytest.raises(InvalidTag):
        relay_e2ee.unwrap_symmetric_key(wrapped, recipient, aad)
