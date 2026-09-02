"""Shared pytest fixtures for tools/openburnbar-mcp.

Keeps every test hermetic with respect to the local memory engine: the engine
store and key file go under the test's tmp_path, the embedding provider is
forced off (tests that want vectors inject `FakeEmbeddingProvider`), and the
gate policy env vars start from their defaults.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

_PARENT = Path(__file__).resolve().parent.parent
if str(_PARENT) not in sys.path:
    sys.path.insert(0, str(_PARENT))

import memory_engine as me  # noqa: E402


@pytest.fixture(autouse=True)
def _hermetic_memory_engine(tmp_path: Path, monkeypatch: pytest.MonkeyPatch):
    monkeypatch.setenv(me.MEMORY_DB_PATH_ENV, str(tmp_path / "memory-store.sqlite"))
    monkeypatch.setenv(me.EMBEDDING_PROVIDER_ENV, "none")
    for name in (
        me.MEMORY_KEY_ENV,
        me.SECRET_POLICY_ENV,
        me.PII_POLICY_ENV,
        me.EXTRACTOR_ENV,
        "OPENBURNBAR_LOCAL_MCP_ENABLE_SECRET_RETAIN",
        "OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_WRITE",
        "OPENBURNBAR_MEMORY_MIRROR_TO_DAEMON",
    ):
        monkeypatch.delenv(name, raising=False)
    me.reset_provider_cache_for_tests()
    yield
    me.reset_provider_cache_for_tests()
