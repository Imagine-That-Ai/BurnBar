"""A memorized row names where it came from.

`heuristic_extract` stamps every `Fact` with a positional marker (`m3`: the
fourth message of the batch), and the write path only fell back to the caller's
`source_ref` when the fact carried none -- so a `SessionEnd` hook call with
`source_ref="claude-code:<session_id>"` stored rows whose `sourceRef` was just
`m3` and the session was lost. The caller's reference now prefixes the marker.

Driven through `server.burnbar_memorize` (not the engine directly) so the tool
wrapper, the gate and the daemon-mirror path are all in the picture.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path
from typing import Any

import pytest

MCP_DIR = Path(__file__).resolve().parents[1]
if str(MCP_DIR) not in sys.path:
    sys.path.insert(0, str(MCP_DIR))

MARKER_RE = re.compile(r"^m\d+$")


@pytest.fixture
def isolated_server(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> Any:
    """The server bound to a throwaway store, with no daemon and no audit chain."""
    for name, value in {
        "BURNBAR_MCP_TOOLSET": "memory",
        "OPENBURNBAR_MEMORY_DB_PATH": str(tmp_path / "memory.sqlite"),
        "BURNBAR_DB_PATH": str(tmp_path / "app.sqlite"),
        "OPENBURNBAR_MEMORY_EMBEDDING_PROVIDER": "none",
        "OPENBURNBAR_LOCAL_MCP_DISABLE_AUDIT": "true",
        "OPENBURNBAR_DAEMON_SOCKET_PATH": str(tmp_path / "missing.sock"),
    }.items():
        monkeypatch.setenv(name, value)
    for name in list(os.environ):
        if name.startswith("OPENBURNBAR_LOCAL_MCP_ENABLE_") or name == "OPENBURNBAR_LOCAL_MCP_PROFILE":
            monkeypatch.delenv(name, raising=False)
    import server

    return server


def _project(tmp_path: Path, name: str) -> str:
    root = tmp_path / name
    root.mkdir()
    return str(root)


def _memorize(server: Any, **kwargs: Any) -> dict[str, Any]:
    payload = json.loads(server.burnbar_memorize(**kwargs))
    assert payload.get("status") == "ok", payload
    return payload


def _stored_refs(server: Any, project_path: str) -> list[str]:
    with server._memory_engine() as engine:
        listing = engine.list(project_path=project_path, page_size=200)
    return [str(item["sourceRef"]) for item in listing["results"]]


# Five turns whose facts include a pair differing by one content word. With the
# caller's ref folded into the lexical token set, a hook-shaped ref adds eleven
# tokens shared by every fact in the batch and pushes that pair's Jaccard from
# 0.556 over DEDUP_JACCARD (0.75).
DEDUPE_TRANSCRIPT = [
    {"role": "user", "content": "We decided to route all memory writes through the daemon socket."},
    {"role": "assistant", "content": "We decided to route all memory reads through the daemon socket too."},
    {"role": "user", "content": "Always run the bootstrap script before the tests in this repository."},
    {"role": "assistant", "content": "Gotcha: the WAL file must be checkpointed before the backup runs."},
    {"role": "user", "content": "Prefer ruff over black for formatting in this repository."},
]
HOOK_REF = "claude-code:0f8a4c2e-9b31-4d77-8e51-6c2ab7f0d1e9"

CONVERSATION = [
    {"role": "user", "content": "We decided to keep the memory store local-only because the daemon owns sync."},
    {"role": "assistant", "content": "Agreed. Always run the bootstrap script before the tests in this repo."},
]
OTHER_CONVERSATION = [
    {"role": "user", "content": "We chose RRF over a linear blend because the two rankers disagree on scale."},
    {"role": "assistant", "content": "Noted. Prefer ruff over black for formatting in this repository."},
]


def test_a_caller_source_ref_prefixes_the_extractor_marker(isolated_server: Any, tmp_path: Path) -> None:
    project_path = _project(tmp_path, "session")
    result = _memorize(
        isolated_server,
        messages=CONVERSATION,
        project_path=project_path,
        source_kind="session",
        source_ref="claude-code:sess-1",
    )
    assert result["summary"]["ADD"] >= 1, result

    refs = _stored_refs(isolated_server, project_path)
    assert refs, result
    for ref in refs:
        assert ref.startswith("claude-code:sess-1#m"), refs
        assert MARKER_RE.match(ref.split("#", 1)[1]), refs


def test_without_a_caller_source_ref_the_marker_is_stored_alone(isolated_server: Any, tmp_path: Path) -> None:
    project_path = _project(tmp_path, "bare")
    _memorize(isolated_server, messages=OTHER_CONVERSATION, project_path=project_path)

    refs = _stored_refs(isolated_server, project_path)
    assert refs
    assert all(MARKER_RE.match(ref) for ref in refs), refs


def test_a_fact_that_carries_its_own_reference_keeps_it(isolated_server: Any, tmp_path: Path) -> None:
    project_path = _project(tmp_path, "facts")
    _memorize(
        isolated_server,
        facts=[{"text": "The release runner reads its token from the keychain.", "source_ref": "ticket:BB-12"}],
        project_path=project_path,
        source_kind="session",
        source_ref="claude-code:sess-2",
    )

    assert _stored_refs(isolated_server, project_path) == ["ticket:BB-12"]


def test_the_idempotency_receipt_is_unchanged_by_the_combined_reference(isolated_server: Any, tmp_path: Path) -> None:
    """The ingest receipt keys on the caller's inputs, not on the stored refs, so a
    replayed session still answers `ALREADY_INGESTED` and writes nothing."""
    project_path = _project(tmp_path, "replay")
    first = _memorize(
        isolated_server,
        messages=CONVERSATION,
        project_path=project_path,
        source_kind="session",
        source_ref="claude-code:sess-3",
    )
    before = _stored_refs(isolated_server, project_path)

    second = _memorize(
        isolated_server,
        messages=CONVERSATION,
        project_path=project_path,
        source_kind="session",
        source_ref="claude-code:sess-3",
    )
    assert second.get("code") == "ALREADY_INGESTED", second
    assert second["sourceHash"] == first["sourceHash"]
    assert _stored_refs(isolated_server, project_path) == before


def test_a_hook_source_ref_does_not_change_which_facts_are_stored(
    isolated_server: Any, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Provenance is not content: naming the batch must not merge facts inside it.

    `_commit_fact` folded `source_ref` into the lexical token set used for
    near-duplicate detection, so a real hook ref — a session UUID tokenizing into
    eleven tokens shared by every fact in the batch — inflated pairwise Jaccard
    and collapsed two distinct memories into one.

    Each variant gets its own store, not just its own project: the transcript's
    preference lands in `personal` scope, which is deliberately recalled and
    deduplicated across projects, so a shared store would collapse the second run
    for a reason that has nothing to do with the ref.
    """

    def memorize_into(store: str, project: str, **kwargs: Any) -> dict[str, Any]:
        monkeypatch.setenv("OPENBURNBAR_MEMORY_DB_PATH", str(tmp_path / store))
        return _memorize(
            isolated_server, messages=DEDUPE_TRANSCRIPT, project_path=_project(tmp_path, project), **kwargs
        )

    bare = memorize_into("bare.sqlite", "bare-batch")
    hooked = memorize_into("hooked.sqlite", "hooked-batch", source_kind="session", source_ref=HOOK_REF)

    assert bare["summary"]["ADD"] == 5, bare["summary"]
    assert hooked["summary"] == bare["summary"], {
        "bare": bare["summary"],
        "hooked": hooked["summary"],
        "reasons": [decision.get("reason") for decision in hooked["decisions"] if decision.get("reason")],
    }
    # The env still points at the hooked store; every row kept its own identity.
    refs = _stored_refs(isolated_server, str(tmp_path / "hooked-batch"))
    assert len(refs) == 5, refs
    assert len(set(refs)) == 5, refs
