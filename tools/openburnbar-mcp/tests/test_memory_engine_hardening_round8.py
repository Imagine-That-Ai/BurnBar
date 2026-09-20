#!/usr/bin/env python3
"""Regression tests for the eighth independent review of memory MCP v2."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

_HERE = Path(__file__).resolve().parent
_PARENT = _HERE.parent
if str(_PARENT) not in sys.path:
    sys.path.insert(0, str(_PARENT))

import memory_engine as me  # noqa: E402
from test_memory_engine import _engine, _repo  # noqa: E402


def test_import_rejects_unknown_sensitivity(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    with _engine(tmp_path) as engine:
        result = engine.import_memories(
            [{"body": "The deploy credential is stored in the vault.", "sensitivity": "secre"}],
            project_path=repo,
        )
        assert result["decisions"][0]["code"] == "INVALID_SENSITIVITY"
        assert engine.list(project_path=repo)["total"] == 0


def test_unknown_kinds_are_rejected_on_every_write_boundary(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    with _engine(tmp_path) as engine:
        direct = engine.remember("The release profile is stable.", project_path=repo, kind="profiel")
        assert direct["status"] == "rejected" and direct["code"] == "INVALID_KIND"
        imported = engine.import_memories([{"body": "Imported profile.", "kind": "profiel"}], project_path=repo)
        assert imported["decisions"][0]["code"] == "INVALID_KIND"
        stored = engine.remember("The release profile is stable.", project_path=repo, kind="profile")
        updated = engine.update(stored["memoryID"], kind="profiel")
        assert updated["status"] == "rejected" and updated["code"] == "INVALID_KIND"
        assert engine.get(stored["memoryID"])["memory"]["kind"] == "profile"


def test_legacy_personal_import_uses_original_project_owner(tmp_path: Path) -> None:
    repo_a = tmp_path / "repo-a"
    repo_b = tmp_path / "repo-b"
    repo_a.mkdir()
    repo_b.mkdir()
    with _engine(tmp_path) as engine:
        result = engine.import_legacy(
            [
                {
                    "legacyMemoryID": "legacy-personal-a",
                    "legacyProjectPath": str(repo_a),
                    "text": "Alberto prefers compact release notes.",
                    "kind": "preference",
                    "scope": "personal",
                    "metadata": {"legacyProjectID": "legacy-project-a"},
                }
            ],
            project_path=str(repo_b),
        )
        memory_id = result["decisions"][0]["memoryID"]
        assert engine.project_path_for_memory(memory_id) == str(repo_a.resolve())
        assert engine.daemon_mirror_project_path(memory_id) == str(repo_a.resolve())


def test_unresolved_legacy_owner_is_retryable_not_reassigned(tmp_path: Path) -> None:
    repo = _repo(tmp_path)
    with _engine(tmp_path) as engine:
        result = engine.import_legacy(
            [
                {
                    "legacyMemoryID": "legacy-missing-owner",
                    "text": "Alberto prefers compact release notes.",
                    "kind": "preference",
                    "scope": "personal",
                    "metadata": {"legacyProjectID": "different-project"},
                }
            ],
            project_path=repo,
        )
        assert result["retryable"] == 1
        assert result["decisions"][0]["code"] == "LEGACY_PROJECT_UNAVAILABLE"
        assert engine.list(project_path=repo)["total"] == 0


def test_ollama_embedding_version_binds_digest_and_endpoint(monkeypatch: pytest.MonkeyPatch) -> None:
    digest = "a" * 64
    monkeypatch.setattr(
        me.OllamaEmbeddingProvider,
        "_get",
        lambda self, _path: {"models": [{"name": "embed:latest", "digest": digest}]},
    )
    monkeypatch.setattr(
        me.OllamaEmbeddingProvider,
        "_post",
        lambda self, _path, _payload: {"embeddings": [[1.0, 0.0, 0.0]]},
    )
    first = me.OllamaEmbeddingProvider("embed", "http://127.0.0.1:11434")
    other_endpoint = me.OllamaEmbeddingProvider("embed", "http://127.0.0.1:21434")
    assert digest in first.version_id
    assert first.version_id != other_endpoint.version_id

    monkeypatch.setattr(
        me.OllamaEmbeddingProvider,
        "_get",
        lambda self, _path: {"models": [{"name": "embed:latest", "digest": "b" * 64}]},
    )
    upgraded = me.OllamaEmbeddingProvider("embed", "http://127.0.0.1:11434")
    assert upgraded.version_id != first.version_id
