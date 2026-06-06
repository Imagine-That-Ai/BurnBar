"""The committed wire vectors must reproduce byte-for-byte from the in-tree
deterministic generator.

This is what makes the vectors honest: rather than asserting an unverifiable
"emitted by some other implementation" provenance, we prove the committed
fixtures are exactly what :mod:`tests.gateway.vectors.generate_wire_vectors`
produces from their (human-readable) inputs and fixed seeds. A maintainer can
re-derive every ciphertext byte with ``python -m
tests.gateway.vectors.generate_wire_vectors --check`` and no non-Python
toolchain, and this test fails the moment a fixture drifts from the generator.
"""

from __future__ import annotations

import json

import pytest

pytest.importorskip("cryptography")

from tests.gateway.vectors import generate_wire_vectors as gen  # noqa: E402


def _committed(path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def test_relay_vector_reproduces_from_generator():
    committed = _committed(gen.RELAY_VECTOR_PATH)
    assert gen.build_relay_vector(committed) == committed


def test_gateway_vector_reproduces_from_generator():
    committed = _committed(gen.GATEWAY_VECTOR_PATH)
    assert gen.build_gateway_vector(committed) == committed


def test_generator_is_byte_deterministic():
    # Two independent regenerations must be identical (no hidden entropy leak).
    assert gen.build_gateway_vector(_committed(gen.GATEWAY_VECTOR_PATH)) == gen.build_gateway_vector(
        _committed(gen.GATEWAY_VECTOR_PATH)
    )
    assert gen.build_relay_vector(_committed(gen.RELAY_VECTOR_PATH)) == gen.build_relay_vector(
        _committed(gen.RELAY_VECTOR_PATH)
    )
