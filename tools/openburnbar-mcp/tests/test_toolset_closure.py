#!/usr/bin/env python3
"""`MEMORY_TOOLSET` must be closed under its own dependencies.

`BURNBAR_MCP_TOOLSET=memory` -- what the repo's own `.mcp.json` sets -- narrows
the server to `MEMORY_TOOLSET`. That set once shipped `burnbar_search_code`,
`burnbar_context_pack` and `burnbar_code_context_pack` while withholding
`burnbar_index_project` and `burnbar_index_status`: three tools that read the
project code index, and no way to build one or to ask whether one exists. From
the default configuration the reads could only ever answer `"results": []`, and
the advice in that answer named a tool the client could not call.

An allowlist is not a list of tools, it is a claim that the tools in it work.
So these tests check the claim structurally: for every tool in the set that
reads a store, the tools that create that store and report on it are in the set
too. The relation is declared as data below, so a future consumer added without
its producer fails with both names in the message rather than shipping another
dead tool.

Parsing beats importing here: `server.py` needs the `mcp` package and touches
the environment at import, while the allowlist, the tool registrations and the
rate-limit family of each tool are all literals in the source.
"""

from __future__ import annotations

import ast
from pathlib import Path

import pytest

_SERVER = Path(__file__).resolve().parent.parent / "server.py"


# ---------------------------------------------------------------------------
# The dependency relation.
#
# A `StoreContract` says: this store is built by these tools, inspected by these
# tools, and read by these tools. Closure means every reader that ships forces
# its producers and inspectors to ship with it.
#
# Add a store here when a tool starts reading persistent state that another tool
# creates. Add a reader here when you add a tool that reads an existing store.
# ---------------------------------------------------------------------------


class StoreContract:
    def __init__(
        self,
        name: str,
        *,
        producers: tuple[str, ...],
        inspectors: tuple[str, ...],
        readers: tuple[str, ...],
        external_producer: str | None = None,
    ) -> None:
        self.name = name
        self.producers = producers
        self.inspectors = inspectors
        self.readers = readers
        # Set when nothing in this server creates the store -- some other
        # process does. Recorded rather than omitted so the empty `producers`
        # tuple reads as a decision instead of an oversight.
        self.external_producer = external_producer

    @property
    def required(self) -> tuple[str, ...]:
        return self.producers + self.inspectors


STORE_CONTRACTS: tuple[StoreContract, ...] = (
    StoreContract(
        "project code index",
        producers=("burnbar_index_project",),
        inspectors=("burnbar_index_status",),
        readers=(
            "burnbar_search_code",
            "burnbar_context_pack",
            "burnbar_code_context_pack",
            "burnbar_get_symbol",
            "burnbar_find_references",
            "burnbar_call_graph",
            "burnbar_diagnostics",
            # `burnbar_explore` indexes on its own before it reads, so it is
            # also a producer -- but a caller still needs the explicit build and
            # the status read to reason about what it left behind.
            "burnbar_explore",
        ),
    ),
    StoreContract(
        "memory store",
        producers=("burnbar_remember", "burnbar_memorize"),
        inspectors=("burnbar_memory_doctor", "burnbar_memory_analytics"),
        readers=(
            "burnbar_recall",
            "burnbar_recall_pack",
            "burnbar_memory_ask",
            "burnbar_memory_get",
            "burnbar_memory_list",
            "burnbar_memory_history",
            "burnbar_memory_timeline",
            "burnbar_memory_review",
            "burnbar_memory_entities",
            "burnbar_memory_relations",
            "burnbar_memory_export",
            "burnbar_audit_trail",
        ),
    ),
    StoreContract(
        "conversation index",
        producers=(),
        external_producer=(
            "the BurnBar app ingests provider session files into the app database; "
            "no MCP tool builds this index, so there is no producer to require"
        ),
        inspectors=("burnbar_list_providers", "burnbar_resolve_db_path"),
        readers=(
            "burnbar_search_conversations",
            "burnbar_semantic_search_conversations",
            "burnbar_get_conversation",
            "burnbar_list_resumable_conversations",
            "burnbar_resume_conversation",
        ),
    ),
)

# tool -> every tool that must ship alongside it for it to be able to answer.
TOOL_DEPENDENCIES: dict[str, frozenset[str]] = {}
for _contract in STORE_CONTRACTS:
    for _reader in _contract.readers:
        TOOL_DEPENDENCIES[_reader] = TOOL_DEPENDENCIES.get(_reader, frozenset()) | frozenset(_contract.required)

# The pre-fix allowlist, verbatim, kept so the closure check is provably able to
# fail. Delete this only alongside the check it guards.
PRE_FIX_MEMORY_TOOLSET: frozenset[str] = frozenset(
    {
        "burnbar_resolve_db_path",
        "burnbar_list_providers",
        "burnbar_search_conversations",
        "burnbar_semantic_search_conversations",
        "burnbar_get_conversation",
        "burnbar_remember",
        "burnbar_memorize",
        "burnbar_memory_extract",
        "burnbar_recall",
        "burnbar_recall_pack",
        "burnbar_memory_ask",
        "burnbar_forget",
        "burnbar_forget_all",
        "burnbar_memory_get",
        "burnbar_memory_list",
        "burnbar_memory_update",
        "burnbar_memory_history",
        "burnbar_memory_timeline",
        "burnbar_memory_review",
        "burnbar_memory_entities",
        "burnbar_memory_relations",
        "burnbar_memory_export",
        "burnbar_memory_import",
        "burnbar_memory_reindex",
        "burnbar_memory_sync_pull",
        "burnbar_memory_doctor",
        "burnbar_project_adopt",
        "burnbar_team_link_project",
        "burnbar_audit_trail",
        "burnbar_memory_analytics",
        "burnbar_search_code",
        "burnbar_context_pack",
        "burnbar_code_context_pack",
        "burnbar_list_project_memory",
        "burnbar_get_project_memory",
        "burnbar_list_resumable_conversations",
        "burnbar_resume_conversation",
        "burnbar_session_briefing",
    }
)


# ---------------------------------------------------------------------------
# Reading the server's facts out of its source.
# ---------------------------------------------------------------------------


def _module() -> ast.Module:
    return ast.parse(_SERVER.read_text(encoding="utf-8"), filename=str(_SERVER))


def _declared_frozenset(module: ast.Module, name: str) -> frozenset[str]:
    """Any module-level `NAME: frozenset[str] = frozenset({...})` literal."""
    for node in module.body:
        if not isinstance(node, ast.AnnAssign) or not isinstance(node.target, ast.Name):
            continue
        if node.target.id != name or node.value is None:
            continue
        call = node.value
        assert isinstance(call, ast.Call) and call.args, f"{name} is no longer frozenset({{...}})"
        return frozenset(ast.literal_eval(call.args[0]))
    raise AssertionError(f"{name} not found in server.py")


def _registered_tools(module: ast.Module) -> dict[str, str | None]:
    """Every `@mcp.tool()` function -> its rate-limit family, when it declares one.

    The family is the server's own grouping of a tool by the substrate it
    touches, so it is the honest way to ask "is this a code-index tool?" without
    a second hand-maintained list.
    """
    tools: dict[str, str | None] = {}
    for node in ast.walk(module):
        if not isinstance(node, ast.FunctionDef):
            continue
        decorated = any(
            isinstance(dec, ast.Call)
            and isinstance(dec.func, ast.Attribute)
            and dec.func.attr == "tool"
            and isinstance(dec.func.value, ast.Name)
            and dec.func.value.id == "mcp"
            for dec in node.decorator_list
        )
        if not decorated:
            continue
        family: str | None = None
        for inner in ast.walk(node):
            if (
                isinstance(inner, ast.Call)
                and isinstance(inner.func, ast.Name)
                and inner.func.id == "_local_mcp_rate_limit"
                and len(inner.args) == 2
                and all(isinstance(arg, ast.Constant) for arg in inner.args)
            ):
                family = inner.args[1].value  # type: ignore[attr-defined]
                break
        tools[node.name] = family
    return tools


def _closure_violations(toolset: frozenset[str]) -> list[tuple[str, str]]:
    """(consumer, missing dependency) pairs, sorted, for a candidate toolset."""
    return sorted(
        (tool, missing)
        for tool in toolset
        for missing in TOOL_DEPENDENCIES.get(tool, frozenset())
        if missing not in toolset
    )


@pytest.fixture(scope="module")
def module() -> ast.Module:
    return _module()


# ---------------------------------------------------------------------------
# The checks.
# ---------------------------------------------------------------------------


def test_memory_toolset_is_closed_under_its_dependencies(module: ast.Module) -> None:
    """Every store-reading tool in the set ships with what builds and inspects that store."""
    violations = _closure_violations(_declared_frozenset(module, "MEMORY_TOOLSET"))
    assert not violations, (
        "MEMORY_TOOLSET serves tools whose store no client of this toolset can build or inspect:\n"
        + "\n".join(f"  {tool} reads a store, but {missing} is not in MEMORY_TOOLSET" for tool, missing in violations)
    )


def test_the_closure_check_fails_on_the_pre_fix_toolset() -> None:
    """The check has teeth: the allowlist this test was written for is not closed."""
    violations = _closure_violations(PRE_FIX_MEMORY_TOOLSET)
    assert violations == [
        ("burnbar_code_context_pack", "burnbar_index_project"),
        ("burnbar_code_context_pack", "burnbar_index_status"),
        ("burnbar_context_pack", "burnbar_index_project"),
        ("burnbar_context_pack", "burnbar_index_status"),
        ("burnbar_search_code", "burnbar_index_project"),
        ("burnbar_search_code", "burnbar_index_status"),
    ], violations


def test_every_code_tool_in_the_toolset_declares_its_dependencies(module: ast.Module) -> None:
    """A new code-index tool cannot join the toolset without joining the relation.

    Membership of the server's own `code` rate-limit family is the trigger, so
    this stays true for tools that do not exist yet.
    """
    declared = _declared_frozenset(module, "MEMORY_TOOLSET")
    families = _registered_tools(module)
    accounted = {
        name for contract in STORE_CONTRACTS for name in contract.producers + contract.inspectors + contract.readers
    }
    undeclared = sorted(name for name in declared if families.get(name) == "code" and name not in accounted)
    assert not undeclared, (
        "these tools touch the code index and are served by MEMORY_TOOLSET, but no store "
        f"contract in this file mentions them: {undeclared}. Add them to STORE_CONTRACTS as "
        "a producer, an inspector or a reader before shipping them."
    )


def test_store_contracts_name_real_registered_tools(module: ast.Module) -> None:
    """The relation cannot go stale by naming tools the server no longer registers."""
    registered = set(_registered_tools(module))
    unknown = sorted(
        name
        for contract in STORE_CONTRACTS
        for name in contract.producers + contract.inspectors + contract.readers
        if name not in registered
    )
    assert not unknown, f"STORE_CONTRACTS names tools server.py does not register: {unknown}"


def test_a_store_without_producers_says_why() -> None:
    """An empty producer tuple is a documented decision, never a blank."""
    for contract in STORE_CONTRACTS:
        if not contract.producers:
            assert contract.external_producer, (
                f"store contract {contract.name!r} declares no producer and gives no reason; "
                "either name the tool that builds it or record what does"
            )


def test_watch_project_is_excluded_on_purpose(module: ast.Module) -> None:
    """The one code tool held back, held back for a reason that is written down.

    `burnbar_watch_project` starts open-ended daemon-owned polling. Nothing in
    the toolset reads a store only it can build, so excluding it breaks no loop.
    """
    declared = _declared_frozenset(module, "MEMORY_TOOLSET")
    assert "burnbar_watch_project" not in declared
    assert not any("burnbar_watch_project" in deps for deps in TOOL_DEPENDENCIES.values()), (
        "burnbar_watch_project became a dependency; it must then join MEMORY_TOOLSET or lose the dependents"
    )
    # Held back from `memory`, not dropped: `ops` still serves it, with the
    # readers and the status tool it needs to be worth calling.
    assert "burnbar_watch_project" in _declared_frozenset(module, "CODE_INDEX_TOOLSET")


def _ops_toolset(module: ast.Module) -> frozenset[str]:
    """What `BURNBAR_MCP_TOOLSET=ops` serves, derived the way the filter derives it.

    Mirrors `_apply_toolset_filter`: the complement of the memory toolset, plus
    the whole code index family. Kept here rather than imported so the test does
    not need `server.py`'s import-time environment.
    """
    memory = _declared_frozenset(module, "MEMORY_TOOLSET")
    code = _declared_frozenset(module, "CODE_INDEX_TOOLSET")
    return frozenset(name for name in _registered_tools(module) if name not in memory or name in code)


def test_the_ops_toolset_is_closed_too(module: ast.Module) -> None:
    """Growing one toolset must not strand a tool in the other.

    `ops` is the complement of `memory`, so every tool `memory` gained is a tool
    `ops` lost. Moving the code index readers into `memory` would have left `ops`
    holding `burnbar_watch_project` as a producer with no reader and no status
    tool -- this defect, pointed the other way -- which is why the filter keeps
    the whole family in `ops`.
    """
    violations = _closure_violations(_ops_toolset(module))
    assert not violations, "the ops toolset serves tools whose store no ops client can build or inspect:\n" + "\n".join(
        f"  {tool} reads a store, but {missing} is not served to ops" for tool, missing in violations
    )


def test_the_ops_toolset_keeps_the_whole_code_index_family(module: ast.Module) -> None:
    """The operator persona owns building and watching the index, so it keeps all of it."""
    code = _declared_frozenset(module, "CODE_INDEX_TOOLSET")
    missing = sorted(code - _ops_toolset(module))
    assert not missing, f"the ops toolset lost part of the code index family: {missing}"


def test_the_code_index_family_is_the_servers_own_code_family(module: ast.Module) -> None:
    """`CODE_INDEX_TOOLSET` is not a second hand-maintained list that can drift.

    Every tool the server rate-limits under its `code` family is a member, and
    every member is one of those tools.
    """
    families = _registered_tools(module)
    by_family = frozenset(name for name, family in families.items() if family == "code")
    declared = _declared_frozenset(module, "CODE_INDEX_TOOLSET")
    # Two named mismatches, both real and both explained:
    #   `burnbar_code_context_pack` delegates to `burnbar_context_pack` and is
    #     rate limited there, so it declares no family of its own.
    #   `burnbar_memory_doctor` rate limits under `code` because it also reports
    #     code schema health, but it is a cross-store doctor on the memory
    #     surface rather than a member of the family the toolsets move as a unit.
    no_family_of_its_own = frozenset({"burnbar_code_context_pack"})
    cross_store = frozenset({"burnbar_memory_doctor"})
    assert declared - no_family_of_its_own == by_family - cross_store, {
        "declared but not rate-limited as code": sorted(declared - no_family_of_its_own - by_family),
        "rate-limited as code but not declared": sorted(by_family - cross_store - declared),
    }
