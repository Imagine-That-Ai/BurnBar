"""L2 — gateway proof-of-possession (PoP) v1/v2 signer parity tests.

Every vector here is frozen against the server's TypeScript in
functions/src/callables/hermesGateway.ts (gatewayPopSignablePayload(V2),
canonicalGatewayQueryString, stableJSONString, gatewayPath). The server side is
proven by functions/src/__tests__/hermesGatewayPopV2.test.ts; these tests pin
the Python adapter to the same bytes. Run:

    python3 -m unittest tools.hermes-platform-burnbar.test_adapter_pop  # or
    cd tools/hermes-platform-burnbar && python3 -m unittest test_adapter_pop -v
"""

import base64
import hashlib
import importlib.util
import sys
import unittest
from pathlib import Path

_ADAPTER_PATH = Path(__file__).resolve().parent / "adapter.py"
_SPEC = importlib.util.spec_from_file_location("burnbar_adapter_under_test", _ADAPTER_PATH)
adapter = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = adapter
_SPEC.loader.exec_module(adapter)


def _sha256_hex(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class CanonicalQueryStringTests(unittest.TestCase):
    def test_sorted_by_key_then_value_with_repeats_and_spaces(self) -> None:
        # Mirrors the server rule: decoded params, repeated keys expand to
        # multiple pairs, sort by key then value (plain JS `<`), join k=v with
        # `&`, never percent re-encode. "d 1" stays a literal space.
        params = {"cursor": "abc", "destinationId": "d 1", "z": "2", "a": ["b", "a"]}
        self.assertEqual(
            adapter._canonical_query_string(params),
            "a=a&a=b&cursor=abc&destinationId=d 1&z=2",
        )

    def test_empty_and_none_params(self) -> None:
        self.assertEqual(adapter._canonical_query_string(None), "")
        self.assertEqual(adapter._canonical_query_string({}), "")
        # None values are dropped by httpx before the wire; the server never
        # sees them, so the signature must not include them either.
        self.assertEqual(adapter._canonical_query_string({"a": None, "b": "1"}), "b=1")

    def test_percent_encoded_value_signs_decoded_text(self) -> None:
        # The phone sends `q=a%2Bb` on the wire; Express hands the server the
        # DECODED "a+b" and that is what both sides sign.
        self.assertEqual(adapter._canonical_query_string({"q": "a+b"}), "q=a+b")

    def test_utf16_code_unit_ordering(self) -> None:
        # JS `<` compares UTF-16 code units: "Z" (0x5A) < "a" (0x61).
        self.assertEqual(
            adapter._canonical_query_string({"a": ["a", "Z"]}),
            "a=Z&a=a",
        )


class StableJSONStringTests(unittest.TestCase):
    def test_icu_locale_key_sort_lowercase_before_uppercase(self) -> None:
        # Node's localeCompare (ICU root): "a" < "b" < "B" — NOT code-point
        # order ("B" < "a"). This is the case that breaks naive ports.
        self.assertEqual(
            adapter._stable_json_string({"B": 1, "a": 2, "b": 3}),
            '{"a":2,"b":3,"B":1}',
        )

    def test_numbers_render_like_js(self) -> None:
        self.assertEqual(adapter._stable_json_string({"n": 2.0}), '{"n":2}')
        self.assertEqual(adapter._stable_json_string({"n": 1e-7}), '{"n":1e-7}')
        self.assertEqual(adapter._stable_json_string({"n": 1e21}), '{"n":1e+21}')
        self.assertEqual(adapter._stable_json_string({"n": 0.5}), '{"n":0.5}')

    def test_nested_shapes_and_primitives(self) -> None:
        self.assertEqual(
            adapter._stable_json_string({"z": [1, "x", None, True], "a": {"c": False}}),
            '{"a":{"c":false},"z":[1,"x",null,true]}',
        )
        self.assertEqual(adapter._stable_json_string(None), "null")
        self.assertEqual(adapter._stable_json_string("s"), '"s"')


class GatewayPathTests(unittest.TestCase):
    def test_prefix_strips_and_trailing_slash(self) -> None:
        self.assertEqual(
            adapter._gateway_signable_path("https://api.burnbar.ai/burnBarHermesGateway/events?cursor=1"),
            "/events",
        )
        self.assertEqual(adapter._gateway_signable_path("/v1/hermes-gateway/messages/"), "/messages")
        self.assertEqual(adapter._gateway_signable_path("/burnBarHermesGateway"), "/")


class PopPayloadTests(unittest.TestCase):
    TOKEN = "obb_test_token_123"
    NONCE = "hermes-pop-0123456789abcdef0123456789abcdef"
    TIMESTAMP = "2026-06-10T00:00:00.000Z"

    def test_v2_payload_lines(self) -> None:
        body_hash = _sha256_hex(adapter._stable_json_string({}))
        payload = adapter._pop_signable_payload(
            version=2,
            token=self.TOKEN,
            method="get",
            path="/events",
            canonical_query="cursor=7&limit=50",
            body_hash=body_hash,
            nonce=self.NONCE,
            timestamp=self.TIMESTAMP,
        )
        expected = "\n".join(
            [
                "OpenBurnBar.HermesGatewayPoP.v2",
                _sha256_hex(self.TOKEN),
                "GET",
                "/events",
                "cursor=7&limit=50",
                body_hash,
                self.NONCE,
                self.TIMESTAMP,
            ]
        ).encode("utf-8")
        self.assertEqual(payload, expected)

    def test_v1_payload_has_no_query_line(self) -> None:
        payload = adapter._pop_signable_payload(
            version=1,
            token=self.TOKEN,
            method="POST",
            path="/messages",
            canonical_query="ignored=1",
            body_hash="00" * 32,
            nonce=self.NONCE,
            timestamp=self.TIMESTAMP,
        )
        lines = payload.decode("utf-8").split("\n")
        self.assertEqual(lines[0], "OpenBurnBar.HermesGatewayPoP.v1")
        self.assertEqual(len(lines), 7)  # v2 has 8; the query line is absent.
        self.assertNotIn("ignored=1", lines)


@unittest.skipUnless(adapter.CRYPTOGRAPHY_PRIMITIVES_AVAILABLE, "cryptography not installed")
class PopSignerTests(unittest.TestCase):
    def test_headers_sign_and_verify_round_trip(self) -> None:
        private_key = adapter.Ed25519PrivateKey.generate()
        signer = adapter.GatewayPopSigner(private_key)
        params = {"cursor": "7", "limit": "50"}
        headers = signer.headers(
            token="obb_tok",
            method="GET",
            url_or_path="https://api.burnbar.ai/burnBarHermesGateway/events",
            params=params,
            json_body=None,
            nonce=PopPayloadTests.NONCE,
            timestamp=PopPayloadTests.TIMESTAMP,
        )
        self.assertEqual(headers["x-openburnbar-pop-version"], "2")
        self.assertTrue(adapter.POP_NONCE_PATTERN.match(headers["x-openburnbar-pop-nonce"]))
        payload = adapter._pop_signable_payload(
            version=2,
            token="obb_tok",
            method="GET",
            path="/events",
            canonical_query=adapter._canonical_query_string(params),
            body_hash=headers["x-openburnbar-pop-body-sha256"],
            nonce=headers["x-openburnbar-pop-nonce"],
            timestamp=headers["x-openburnbar-pop-timestamp"],
        )
        signature = base64.b64decode(headers["x-openburnbar-pop-signature-ed25519"])
        private_key.public_key().verify(signature, payload)  # raises on mismatch

    def test_tampered_query_breaks_signature(self) -> None:
        private_key = adapter.Ed25519PrivateKey.generate()
        signer = adapter.GatewayPopSigner(private_key)
        headers = signer.headers(
            token="obb_tok",
            method="GET",
            url_or_path="/events",
            params={"destinationId": "honest"},
        )
        tampered = adapter._pop_signable_payload(
            version=2,
            token="obb_tok",
            method="GET",
            path="/events",
            canonical_query=adapter._canonical_query_string({"destinationId": "attacker"}),
            body_hash=headers["x-openburnbar-pop-body-sha256"],
            nonce=headers["x-openburnbar-pop-nonce"],
            timestamp=headers["x-openburnbar-pop-timestamp"],
        )
        signature = base64.b64decode(headers["x-openburnbar-pop-signature-ed25519"])
        with self.assertRaises(Exception):
            private_key.public_key().verify(signature, tampered)

    def test_nonce_generator_satisfies_server_contract(self) -> None:
        for _ in range(16):
            self.assertTrue(adapter.POP_NONCE_PATTERN.match(adapter._generate_pop_nonce()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
