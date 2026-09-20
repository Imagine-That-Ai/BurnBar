"""Stores carry a schema version; the engine upgrades older stores and refuses newer ones."""

from __future__ import annotations

import base64
import sqlite3

import pytest

import memory_engine as me

# 32 raw bytes is the only length KeyRing.load accepts from the env.
TEST_KEY_BASE64 = base64.b64encode(b"\x00" * 32).decode()


def _stamp(db_path, version: str) -> None:
    with sqlite3.connect(db_path) as conn:
        conn.execute("UPDATE engine_meta SET value = ? WHERE key = 'schema_version'", (version,))


def _stored_version(db_path) -> str:
    with sqlite3.connect(db_path) as conn:
        return conn.execute("SELECT value FROM engine_meta WHERE key = 'schema_version'").fetchone()[0]


def _tables(db_path) -> set[str]:
    with sqlite3.connect(db_path) as conn:
        return {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}


def _new_store(tmp_path, monkeypatch):
    monkeypatch.setenv(me.MEMORY_KEY_ENV, TEST_KEY_BASE64)
    db_path = tmp_path / "memory.sqlite"
    me.MemoryEngine.open(db_path=db_path).close()
    return db_path


def test_the_gate_statement_matches_the_schema(tmp_path):
    """`ensure_schema` creates engine_meta on its own before reading the version,
    so that one statement must not drift from the schema it is copied out of."""
    assert f"{me.store._ENGINE_META_SQL};" in me.store.SCHEMA_SQL


def test_open_tolerates_a_newer_store_whose_extra_objects_are_additive(tmp_path, monkeypatch, capsys):
    """A revert must degrade, not brick.

    Refusing every store stamped newer than the running engine is what made
    rolling an engine bump back destroy the member's whole memory surface: the
    store failed AT OPEN, so recall, remember and forget all died rather than
    the one new feature going quiet. A newer schema that only ADDED tables or
    columns still contains every byte this engine reads, so it opens with a
    warning — and keeps its own stamp, so the newer engine can take it back.
    """
    db_path = _new_store(tmp_path, monkeypatch)
    with sqlite3.connect(db_path) as conn:
        conn.execute("CREATE TABLE memories_from_the_future (id TEXT PRIMARY KEY, note TEXT NOT NULL)")
        conn.execute("ALTER TABLE memories ADD COLUMN future_column TEXT")
    _stamp(db_path, "999")

    engine = me.MemoryEngine.open(db_path=db_path)
    try:
        assert engine.conn.execute("SELECT COUNT(*) FROM memories").fetchone()[0] == 0
    finally:
        engine.close()

    warning = capsys.readouterr().err
    assert "999" in warning and "additive" in warning, warning
    assert _stored_version(db_path) == "999", "a tolerated store keeps its newer stamp; this engine never downgrades it"
    assert "memories_from_the_future" in _tables(db_path), "and the newer engine's objects are left alone"


def test_open_still_refuses_a_newer_store_that_removed_something_this_engine_reads(tmp_path, monkeypatch):
    """Tolerance is only for additions. A newer schema that dropped a table this
    engine writes to would fail unpredictably mid-operation; that one is still
    refused at open, loudly and before a byte is written."""
    db_path = _new_store(tmp_path, monkeypatch)
    with sqlite3.connect(db_path) as conn:
        conn.execute("DROP TABLE memory_vault")
    _stamp(db_path, "999")
    with pytest.raises(me.SchemaTooNew) as excinfo:
        me.MemoryEngine.open(db_path=db_path)
    assert "memory_vault" in str(excinfo.value)
    assert "999" in str(excinfo.value)
    assert str(me.ENGINE_SCHEMA_VERSION) in str(excinfo.value)
    assert _stored_version(db_path) == "999", "a refused store must not be rewritten"
    assert "memory_vault" not in _tables(db_path), "a refused store must not have its schema recreated"


def test_a_newer_store_missing_only_a_column_is_refused_too(tmp_path, monkeypatch):
    """A dropped COLUMN is as fatal as a dropped table and less visible, so the
    shape check compares columns, not just table names."""
    db_path = _new_store(tmp_path, monkeypatch)
    with sqlite3.connect(db_path) as conn:
        conn.execute("ALTER TABLE memories DROP COLUMN salience")
    _stamp(db_path, "999")
    with pytest.raises(me.SchemaTooNew) as excinfo:
        me.MemoryEngine.open(db_path=db_path)
    assert "memories.salience" in str(excinfo.value)


def test_open_refuses_a_store_whose_version_is_unreadable(tmp_path, monkeypatch):
    db_path = _new_store(tmp_path, monkeypatch)
    _stamp(db_path, "1.2-rc")
    with pytest.raises(me.SchemaTooNew) as excinfo:
        me.MemoryEngine.open(db_path=db_path)
    assert "1.2-rc" in str(excinfo.value)
    assert _stored_version(db_path) == "1.2-rc"


def test_pending_migrations_run_in_order_and_stamp_the_version(tmp_path, monkeypatch):
    db_path = _new_store(tmp_path, monkeypatch)
    _stamp(db_path, "0")
    monkeypatch.setattr(me.store, "ENGINE_SCHEMA_VERSION", 2)
    monkeypatch.setattr(
        me.store,
        "SCHEMA_MIGRATIONS",
        (
            (1, ("CREATE TABLE migration_probe(step INTEGER)", "INSERT INTO migration_probe(step) VALUES (1)")),
            (2, ("INSERT INTO migration_probe(step) VALUES (2)",)),
        ),
    )
    engine = me.MemoryEngine.open(db_path=db_path)
    try:
        steps = [row[0] for row in engine.conn.execute("SELECT step FROM migration_probe ORDER BY rowid")]
    finally:
        engine.close()
    # Step 2 inserts into a table only step 1 creates, so this ordering cannot happen by accident.
    assert steps == [1, 2]
    assert _stored_version(db_path) == "2"


def test_a_failing_step_leaves_neither_its_ddl_nor_its_stamp(tmp_path, monkeypatch):
    """Each step is one transaction: its statements and its version stamp land
    together or not at all, and the steps that already completed stay applied."""
    db_path = _new_store(tmp_path, monkeypatch)
    _stamp(db_path, "0")
    monkeypatch.setattr(me.store, "ENGINE_SCHEMA_VERSION", 2)
    monkeypatch.setattr(
        me.store,
        "SCHEMA_MIGRATIONS",
        (
            (1, ("CREATE TABLE migration_step_one(x INTEGER)",)),
            (
                2,
                (
                    "CREATE TABLE migration_step_two(x INTEGER)",
                    "CREATE TABLE migration_step_two(x INTEGER)",  # duplicate: fails mid-step
                ),
            ),
        ),
    )
    with pytest.raises(sqlite3.OperationalError):
        me.MemoryEngine.open(db_path=db_path)
    tables = _tables(db_path)
    assert "migration_step_one" in tables, "a completed step stays applied"
    assert "migration_step_two" not in tables, "the failed step rolled back its own DDL"
    assert _stored_version(db_path) == "1", "the stamp names the last step that completed"


def test_current_stores_open_without_running_migrations(tmp_path, monkeypatch):
    db_path = _new_store(tmp_path, monkeypatch)
    monkeypatch.setattr(me.store, "SCHEMA_MIGRATIONS", ((1, ("CREATE TABLE must_not_exist(x INTEGER)",)),))
    engine = me.MemoryEngine.open(db_path=db_path)
    try:
        tables = {row[0] for row in engine.conn.execute("SELECT name FROM sqlite_master WHERE type = 'table'")}
    finally:
        engine.close()
    assert "must_not_exist" not in tables


def _columns(db_path, table: str) -> set[str]:
    with sqlite3.connect(db_path) as conn:
        return {row[1] for row in conn.execute(f"PRAGMA table_info({table})")}


def test_migrations_run_before_the_schema_is_applied(tmp_path, monkeypatch):
    """On an existing store the versioned steps go first and `SCHEMA_SQL` is the
    final validation pass.

    Applying `SCHEMA_SQL` first would create the object a pending migration is
    about to create, so the step would collide with DDL that never belonged to
    it -- and `executescript` runs that DDL outside the step's own transaction.
    """
    db_path = _new_store(tmp_path, monkeypatch)
    with sqlite3.connect(db_path) as conn:
        conn.execute("DROP TABLE memory_vault")
    _stamp(db_path, "0")
    monkeypatch.setattr(me.store, "ENGINE_SCHEMA_VERSION", 1)
    monkeypatch.setattr(
        me.store,
        "SCHEMA_MIGRATIONS",
        (
            (
                1,
                (
                    # Deliberately not IF NOT EXISTS: a step that ran after
                    # SCHEMA_SQL would find the table already there and fail.
                    "CREATE TABLE memory_vault ("
                    "memory_id TEXT PRIMARY KEY, project_id TEXT NOT NULL, secret_cipher BLOB NOT NULL, "
                    "secret_nonce BLOB NOT NULL, key_id TEXT NOT NULL, labels_json TEXT NOT NULL DEFAULT '[]', "
                    "created_at TEXT NOT NULL, migration_probe INTEGER)",
                ),
            ),
        ),
    )
    me.MemoryEngine.open(db_path=db_path).close()
    # The column only the migration writes proves whose DDL created the table.
    assert "migration_probe" in _columns(db_path, "memory_vault")
    assert _stored_version(db_path) == "1"


def test_a_v1_store_gains_the_blind_sync_watermark_table(tmp_path, monkeypatch):
    """The real v2 step: a store written before Memory Blind Sync gets
    `sync_state` from the migration, not from the `SCHEMA_SQL` validation pass."""
    db_path = _new_store(tmp_path, monkeypatch)
    with sqlite3.connect(db_path) as conn:
        conn.execute("DROP TABLE sync_state")
    _stamp(db_path, "1")
    assert "sync_state" not in _tables(db_path)

    engine = me.MemoryEngine.open(db_path=db_path)
    try:
        columns = {row[1] for row in engine.conn.execute("PRAGMA table_info(sync_state)")}
    finally:
        engine.close()
    assert columns == {"user_id", "applied_updated_at", "applied_memory_id", "applied_count", "merged_at"}
    assert _stored_version(db_path) == str(me.ENGINE_SCHEMA_VERSION) == "2"


def test_the_v2_step_is_not_idempotent_so_a_missed_store_is_loud(tmp_path, monkeypatch):
    """The step deliberately omits IF NOT EXISTS. `SCHEMA_SQL` runs after the
    steps as a validation pass, so a silently no-op step would hide a store this
    migration never actually moved."""
    statements = dict(me.store.SCHEMA_MIGRATIONS)[2]
    assert any(statement.startswith("CREATE TABLE sync_state") for statement in statements)
    assert not any("IF NOT EXISTS" in statement for statement in statements)


def test_the_schema_pass_still_restores_objects_no_migration_covers(tmp_path, monkeypatch):
    """`SCHEMA_SQL` runs last as a validation pass, so a current store missing an
    object still gets it back."""
    db_path = _new_store(tmp_path, monkeypatch)
    with sqlite3.connect(db_path) as conn:
        conn.execute("DROP TABLE memory_ingest")
    assert "memory_ingest" not in _tables(db_path)
    me.MemoryEngine.open(db_path=db_path).close()
    assert "memory_ingest" in _tables(db_path)
