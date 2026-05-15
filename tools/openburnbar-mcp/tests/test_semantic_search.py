#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
import sqlite3
import struct
import sys
import types
from pathlib import Path


_HERE = Path(__file__).resolve().parent
_PARENT = _HERE.parent
if str(_PARENT) not in sys.path:
    sys.path.insert(0, str(_PARENT))


def _load_server():
    if "mcp.server.fastmcp" not in sys.modules:
        mcp_mod = types.ModuleType("mcp")
        server_mod = types.ModuleType("mcp.server")
        fastmcp_mod = types.ModuleType("mcp.server.fastmcp")

        class _FastMCP:
            def __init__(self, _name: str):
                pass

            def tool(self):
                def decorator(func):
                    return func

                return decorator

            def run(self):
                raise AssertionError("test stub should not run the MCP server")

        fastmcp_mod.FastMCP = _FastMCP
        sys.modules["mcp"] = mcp_mod
        sys.modules["mcp.server"] = server_mod
        sys.modules["mcp.server.fastmcp"] = fastmcp_mod

    spec = importlib.util.spec_from_file_location("openburnbar_mcp_server_under_test", str(_PARENT / "server.py"))
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["openburnbar_mcp_server_under_test"] = module
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


server = _load_server()


def _vector_blob(vector: list[float]) -> bytes:
    return struct.pack("<" + "f" * len(vector), *vector)


def test_semantic_search_returns_unavailable_when_tables_missing(tmp_path, monkeypatch):
    db_path = tmp_path / "openburnbar.sqlite"
    sqlite3.connect(db_path).close()
    monkeypatch.setenv("BURNBAR_DB_PATH", str(db_path))

    payload = json.loads(server.burnbar_semantic_search_conversations("quota debugging"))

    assert payload["status"] == "unavailable"
    assert payload["code"] == "SEMANTIC_TABLES_MISSING"
    assert "chunk_embeddings" in payload["missingTables"]
    assert "search_documents" in payload["missingTables"]


def test_cloud_semantic_search_requires_explicit_cloud_credentials(monkeypatch):
    monkeypatch.delenv("OPENBURNBAR_FIREBASE_ID_TOKEN", raising=False)
    monkeypatch.delenv("OPENBURNBAR_CLOUD_VAULT_KEY_BASE64", raising=False)

    payload = json.loads(server.burnbar_cloud_semantic_search_conversations("hosted semantic search"))

    assert payload["status"] == "unavailable"
    assert payload["code"] == "CLOUD_AUTH_UNCONFIGURED"


def test_semantic_search_returns_deterministic_hit(tmp_path, monkeypatch):
    db_path = tmp_path / "openburnbar.sqlite"
    conn = sqlite3.connect(db_path)
    conn.executescript(
        """
        CREATE TABLE search_documents (
            id TEXT PRIMARY KEY,
            sourceKind TEXT NOT NULL,
            sourceID TEXT NOT NULL,
            provider TEXT,
            projectName TEXT,
            title TEXT NOT NULL,
            bodyPreview TEXT,
            indexedAt TEXT NOT NULL
        );
        CREATE TABLE search_chunks (
            id TEXT PRIMARY KEY,
            documentID TEXT NOT NULL,
            sourceKind TEXT NOT NULL,
            sourceID TEXT NOT NULL,
            ordinal INTEGER NOT NULL,
            startOffset INTEGER NOT NULL,
            endOffset INTEGER NOT NULL,
            text TEXT NOT NULL
        );
        CREATE TABLE conversations (
            id TEXT PRIMARY KEY,
            provider TEXT,
            sessionId TEXT,
            projectName TEXT,
            startTime TEXT,
            inferredTaskTitle TEXT,
            fullText TEXT
        );
        CREATE TABLE embedding_models (
            id TEXT PRIMARY KEY,
            provider TEXT NOT NULL,
            modelName TEXT NOT NULL,
            dimensions INTEGER NOT NULL,
            distanceMetric TEXT NOT NULL,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL
        );
        CREATE TABLE embedding_versions (
            id TEXT PRIMARY KEY,
            modelID TEXT NOT NULL,
            versionTag TEXT NOT NULL,
            chunkerVersion TEXT NOT NULL,
            normalizationVersion TEXT NOT NULL,
            promptVersion TEXT NOT NULL,
            isActive INTEGER NOT NULL,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL
        );
        CREATE TABLE chunk_embeddings (
            chunkID TEXT NOT NULL,
            embeddingVersionID TEXT NOT NULL,
            vectorBlob BLOB NOT NULL,
            createdAt TEXT NOT NULL,
            updatedAt TEXT NOT NULL,
            PRIMARY KEY (chunkID, embeddingVersionID)
        );
        """
    )
    conn.execute(
        """
        INSERT INTO embedding_models
            (id, provider, modelName, dimensions, distanceMetric, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """,
        (
            "model-local",
            "openburnbar",
            "deterministic-fake-embedding",
            96,
            "cosine",
            "2026-05-14T00:00:00Z",
            "2026-05-14T00:00:00Z",
        ),
    )
    conn.execute(
        """
        INSERT INTO embedding_versions
            (id, modelID, versionTag, chunkerVersion, normalizationVersion, promptVersion, isActive, createdAt, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
        """,
        (
            "version-local",
            "model-local",
            "ci-v1",
            "openburnbar-chunker-v1",
            "unit-l2-v1",
            "plain-text-v1",
            "2026-05-14T00:00:00Z",
            "2026-05-14T00:00:00Z",
        ),
    )
    conn.execute(
        """
        INSERT INTO conversations
            (id, provider, sessionId, projectName, startTime, inferredTaskTitle, fullText)
        VALUES ('conv-quota', 'Codex', 'session-1', 'BurnBar', '2026-05-14T01:00:00Z', 'Quota Routing Fix', 'quota routing deterministic semantic repair')
        """
    )
    conn.execute(
        """
        INSERT INTO search_documents
            (id, sourceKind, sourceID, provider, projectName, title, bodyPreview, indexedAt)
        VALUES
            ('doc-quota', 'conversation', 'conv-quota', 'Codex', 'BurnBar', 'Quota Routing Fix', 'quota routing deterministic semantic repair', '2026-05-14T01:00:00Z'),
            ('doc-other', 'conversation', 'conv-missing', 'Codex', 'BurnBar', 'Other Work', 'unrelated billing invoice copy', '2026-05-14T01:00:00Z')
        """
    )
    conn.execute(
        """
        INSERT INTO search_chunks
            (id, documentID, sourceKind, sourceID, ordinal, startOffset, endOffset, text)
        VALUES
            ('chunk-quota', 'doc-quota', 'conversation', 'conv-quota', 0, 0, 45, 'quota routing deterministic semantic repair'),
            ('chunk-other', 'doc-other', 'conversation', 'conv-missing', 0, 0, 30, 'unrelated billing invoice copy')
        """
    )

    quota_vector = server._deterministic_query_embedding("quota routing deterministic semantic repair")
    other_vector = server._deterministic_query_embedding("unrelated billing invoice copy")
    conn.executemany(
        """
        INSERT INTO chunk_embeddings
            (chunkID, embeddingVersionID, vectorBlob, createdAt, updatedAt)
        VALUES (?, 'version-local', ?, '2026-05-14T01:00:00Z', '2026-05-14T01:00:00Z')
        """,
        [
            ("chunk-quota", _vector_blob(quota_vector)),
            ("chunk-other", _vector_blob(other_vector)),
        ],
    )
    conn.commit()
    conn.close()

    monkeypatch.setenv("BURNBAR_DB_PATH", str(db_path))
    payload = json.loads(
        server.burnbar_semantic_search_conversations(
            "quota routing deterministic semantic repair",
            provider="Codex",
            project_name="BurnBar",
            limit=5,
        )
    )

    assert payload["status"] == "ok"
    assert payload["embedding"]["versionID"] == "version-local"
    assert payload["results"][0]["chunkID"] == "chunk-quota"
    assert payload["results"][0]["score"] > payload["results"][1]["score"]
    assert payload["results"][0]["provider"] == "Codex"
    assert payload["results"][0]["projectName"] == "BurnBar"
    assert payload["results"][0]["source"]["sessionId"] == "session-1"
    assert "quota routing" in payload["results"][0]["snippet"]


def test_project_memory_local_list_and_get(tmp_path, monkeypatch):
    db_path = tmp_path / "openburnbar.sqlite"
    conn = sqlite3.connect(db_path)
    conn.execute(
        """
        CREATE TABLE project_memory_snapshots (
            projectSlug TEXT PRIMARY KEY,
            projectDisplayName TEXT NOT NULL,
            snapshotJSON TEXT NOT NULL,
            contentHash TEXT NOT NULL,
            sourceSessionCount INTEGER NOT NULL,
            sourceConversationCount INTEGER NOT NULL,
            generatedAt TEXT NOT NULL,
            schemaVersion INTEGER NOT NULL,
            updatedAt TEXT NOT NULL
        )
        """
    )
    snapshot = {
        "projectSlug": "burnbar",
        "projectDisplayName": "BurnBar",
        "freshness": "fresh",
        "sections": [{"id": "executive-summary"}],
        "visuals": [{"id": "timeline", "kind": "timeline"}],
    }
    conn.execute(
        """
        INSERT INTO project_memory_snapshots
            (projectSlug, projectDisplayName, snapshotJSON, contentHash, sourceSessionCount, sourceConversationCount, generatedAt, schemaVersion, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            "burnbar",
            "BurnBar",
            json.dumps(snapshot),
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            7,
            4,
            "2026-05-15T12:00:00Z",
            1,
            "2026-05-15T12:05:00Z",
        ),
    )
    conn.commit()
    conn.close()
    monkeypatch.setenv("BURNBAR_DB_PATH", str(db_path))

    listed = json.loads(server.burnbar_list_project_memory())
    fetched = json.loads(server.burnbar_get_project_memory("burnbar", source="local"))

    assert listed["status"] == "ok"
    assert listed["count"] == 1
    assert listed["snapshots"][0]["projectSlug"] == "burnbar"
    assert listed["snapshots"][0]["visualKinds"] == ["timeline"]
    assert fetched["status"] == "ok"
    assert fetched["source"] == "local"
    assert fetched["snapshot"]["projectDisplayName"] == "BurnBar"
    assert fetched["snapshot"]["freshness"] == "fresh"


def test_project_memory_cloud_get_decrypts_snapshot(monkeypatch):
    called: dict[str, object] = {}

    monkeypatch.setattr(server, "_cloud_config", lambda: {
        "status": "ok",
        "projectID": "burnbar",
        "region": "us-central1",
        "idToken": "token",
        "vaultKey": b"\x00" * 32,
    })

    def _fake_callable(name, payload, _config):
        called["name"] = name
        called["payload"] = payload
        return {
            "snapshot": {
                "projectSlug": "burnbar",
                "projectDisplayName": "BurnBar",
                "contentHash": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
                "sourceSessionCount": 3,
                "sourceConversationCount": 2,
                "generatedAt": "2026-05-15T12:00:00Z",
                "freshness": "fresh",
                "visualKinds": ["timeline"],
                "sealedSnapshot": {"algorithm": "AES-256-GCM"},
                "updatedAt": "2026-05-15T12:01:00Z",
                "schemaVersion": 1,
            }
        }

    monkeypatch.setattr(server, "_call_firebase_callable", _fake_callable)
    monkeypatch.setattr(
        server,
        "_open_cloud_blob_envelope",
        lambda _envelope, _vault_key: json.dumps({
            "projectSlug": "burnbar",
            "projectDisplayName": "BurnBar",
            "freshness": "fresh",
            "sections": [{"id": "executive-summary"}],
            "visuals": [{"id": "timeline", "kind": "timeline"}],
        }).encode("utf-8"),
    )

    payload = json.loads(server.burnbar_get_project_memory("burnbar", source="cloud"))

    assert called["name"] == "getEncryptedProjectMemorySnapshot"
    assert called["payload"] == {"projectSlug": "burnbar"}
    assert payload["status"] == "ok"
    assert payload["source"] == "cloud"
    assert payload["projectSlug"] == "burnbar"
    assert payload["snapshot"]["projectDisplayName"] == "BurnBar"
    assert payload["sectionCount"] == 1


def test_project_memory_cloud_sync_encrypts_and_commits(tmp_path, monkeypatch):
    db_path = tmp_path / "openburnbar.sqlite"
    conn = sqlite3.connect(db_path)
    conn.execute(
        """
        CREATE TABLE project_memory_snapshots (
            projectSlug TEXT PRIMARY KEY,
            projectDisplayName TEXT NOT NULL,
            snapshotJSON TEXT NOT NULL,
            contentHash TEXT NOT NULL,
            sourceSessionCount INTEGER NOT NULL,
            sourceConversationCount INTEGER NOT NULL,
            generatedAt TEXT NOT NULL,
            schemaVersion INTEGER NOT NULL,
            updatedAt TEXT NOT NULL
        )
        """
    )
    conn.execute(
        """
        INSERT INTO project_memory_snapshots
            (projectSlug, projectDisplayName, snapshotJSON, contentHash, sourceSessionCount, sourceConversationCount, generatedAt, schemaVersion, updatedAt)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        (
            "burnbar",
            "BurnBar",
            json.dumps({
                "projectSlug": "burnbar",
                "projectDisplayName": "BurnBar",
                "freshness": "needsRefresh",
                "visuals": [{"id": "timeline", "kind": "timeline"}],
            }),
            "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc",
            5,
            3,
            "2026-05-15T12:00:00Z",
            1,
            "2026-05-15T12:05:00Z",
        ),
    )
    conn.commit()
    conn.close()
    monkeypatch.setenv("BURNBAR_DB_PATH", str(db_path))

    monkeypatch.setattr(server, "_cloud_config", lambda: {
        "status": "ok",
        "projectID": "burnbar",
        "region": "us-central1",
        "idToken": "token",
        "vaultKey": b"\x00" * 32,
    })
    monkeypatch.setattr(server, "_seal_cloud_blob_envelope", lambda _plaintext, _vault_key, key_version=1: {
        "schemaVersion": 1,
        "algorithm": "AES-256-GCM",
        "keyVersion": key_version,
        "plaintextSHA256": "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
        "sealedBoxBase64": "AA==",
        "createdAt": "2026-05-15T12:06:00Z",
    })

    captured: dict[str, object] = {}

    def _fake_callable(name, payload, _config):
        captured["name"] = name
        captured["payload"] = payload
        return {"ok": True, "projectSlug": payload.get("projectSlug")}

    monkeypatch.setattr(server, "_call_firebase_callable", _fake_callable)
    response = json.loads(server.burnbar_cloud_sync_project_memory("burnbar"))

    assert response["status"] == "ok"
    assert captured["name"] == "commitEncryptedProjectMemorySnapshot"
    payload = captured["payload"]
    assert isinstance(payload, dict)
    assert payload["projectSlug"] == "burnbar"
    assert payload["projectDisplayName"] == "BurnBar"
    assert payload["freshness"] == "needsRefresh"
    assert payload["visualKinds"] == ["timeline"]
