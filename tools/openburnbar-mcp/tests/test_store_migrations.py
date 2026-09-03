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


def test_open_refuses_a_store_written_by_a_newer_engine(tmp_path, monkeypatch):
    db_path = _new_store(tmp_path, monkeypatch)
    _stamp(db_path, "999")
    with pytest.raises(me.SchemaTooNew) as excinfo:
        me.MemoryEngine.open(db_path=db_path)
    assert "999" in str(excinfo.value)
    assert str(me.ENGINE_SCHEMA_VERSION) in str(excinfo.value)
    assert _stored_version(db_path) == "999", "a refused store must not be rewritten"


def test_a_refused_store_keeps_the_schema_it_had(tmp_path, monkeypatch):
    """The version gate runs before the DDL, so refusing a newer store leaves it
    exactly as found — this engine must not "repair" a schema it cannot read."""
    db_path = _new_store(tmp_path, monkeypatch)
    with sqlite3.connect(db_path) as conn:
        conn.execute("DROP TABLE memory_vault")
    _stamp(db_path, "999")
    with pytest.raises(me.SchemaTooNew):
        me.MemoryEngine.open(db_path=db_path)
    assert "memory_vault" not in _tables(db_path), "a refused store must not have its schema recreated"


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
