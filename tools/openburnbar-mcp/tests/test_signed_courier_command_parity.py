"""The signed-courier command table, and the Swift CLI that has to carry it.

The defect this file pins down is not a typo. It is a missing invariant.

`server._SIGNED_DAEMON_COMMANDS` decides which daemon methods travel the signed
CLI courier. Anything absent from it does not degrade politely — it falls
through to a direct socket connection, which on a signed install with the
first-party peer gate enforced is refused outright:

    daemon rejected daemon.code.index_project: code=-32001
    message='OpenBurnBar RPC peer failed first-party code-signature verification.'

Nothing said that adding a tool which needs daemon authority obliges you to add
the command that carries it, so `daemon.code.index_project`,
`daemon.code.watch_project` and `daemon.code.explore` shipped with no route.

Four relations are checked, all read out of the real sources:

1. every daemon method this server reaches through `_memory_write_authority`
   has an entry in `_SIGNED_DAEMON_COMMANDS`;
2. every command named by the Python side is a command the Swift CLI accepts
   (`BurnBarCLIRunner.directCommandNames`);
3. every one of those commands has a stdin-JSON dispatch branch in
   `OpenBurnBarCLIMain.swift`, so it is parsed rather than falling through to
   the human-facing argument runner;
4. every daemon method behind such a command is permitted by
   `BurnBarPeerCapabilityProfile.cliSupport`, or the courier reaches the daemon
   and dies at the capability gate instead of the signature gate.

Python is read with `ast`; the Swift lists are literals and are read with
targeted parsing. Neither side is imported or built.
"""

from __future__ import annotations

import ast
import re
import sys
import types
from pathlib import Path

import pytest

_PARENT = Path(__file__).resolve().parent.parent
if str(_PARENT) not in sys.path:
    sys.path.insert(0, str(_PARENT))

_REPO_ROOT = Path(__file__).resolve().parents[3]
_SERVER_PATH = _PARENT / "server.py"
_PROVIDERS_PATH = _PARENT / "memory_engine" / "providers.py"
_CLI_RUNNER_PATH = _REPO_ROOT / "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/OpenBurnBarCLI.swift"
_CLI_MAIN_PATH = _REPO_ROOT / "OpenBurnBarDaemon/Sources/OpenBurnBarCLI/OpenBurnBarCLIMain.swift"
_RPC_CONTRACTS_PATH = _REPO_ROOT / "OpenBurnBarCore/Sources/OpenBurnBarKernel/Contracts/BurnBarRPCContracts.swift"
_RPC_CAPABILITY_PATH = _REPO_ROOT / "OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/BurnBarRPCCapability.swift"

# The write-authority helpers, and which positional argument carries the daemon
# method name. Both funnel into `_memory_write_authority`, which is the only
# place `_SIGNED_DAEMON_COMMANDS` is consulted.
_WRITE_AUTHORITY_CALLS = {
    "_memory_write_authority": 0,
    "_local_memory_write_authority": 1,
}

# The read helpers take the courier subcommand directly rather than a daemon
# method, so they are checked against the Swift command list only.
_READ_COURIER_CALLS = ("_signed_cli_read", "_signed_cli_read_detail")

# `search-sql` and `memory-sync-inbox-list` are reads: they name a subcommand,
# not a daemon method, so the method each one ends up invoking is recorded here
# for the capability-gate check. `memory-model-policy` is invoked by the memory
# engine's provider module rather than by `server.py`.
_READ_COMMAND_METHODS = {
    "search-sql": "daemon.search.sql",
    "memory-sync-inbox-list": "daemon.memory.sync.inbox.list",
    "memory-model-policy": "daemon.memory.model_policy",
}

# The table exactly as `org/main` shipped it before this fix, kept so the
# checker itself stays able to fail. See
# `test_the_parity_check_fails_on_the_pre_fix_command_table`.
_PRE_FIX_SIGNED_DAEMON_COMMANDS = {
    "daemon.memory.remember": "memory-remember",
    "daemon.memory.forget": "memory-forget",
    "daemon.memory.sync.inbox.ack": "memory-sync-inbox-ack",
}


def _load_server():
    """Import `server.py` with a stub `mcp` package, exactly like its siblings."""
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
        server_mod.fastmcp = fastmcp_mod
        mcp_mod.server = server_mod
        sys.modules["mcp"] = mcp_mod
        sys.modules["mcp.server"] = server_mod
        sys.modules["mcp.server.fastmcp"] = fastmcp_mod

    import server as server_module

    return server_module


def _server_tree() -> ast.Module:
    return ast.parse(_SERVER_PATH.read_text(encoding="utf-8"))


def _called_name(node: ast.Call) -> str | None:
    func = node.func
    if isinstance(func, ast.Name):
        return func.id
    if isinstance(func, ast.Attribute):
        return func.attr
    return None


def _string_argument(node: ast.Call, index: int) -> str | None:
    if len(node.args) <= index:
        return None
    argument = node.args[index]
    if isinstance(argument, ast.Constant) and isinstance(argument.value, str):
        return argument.value
    return None


def _enclosing_tool(tree: ast.Module, target: ast.AST) -> str:
    """The MCP tool (or plain function) a call site sits inside."""
    for function in ast.walk(tree):
        if not isinstance(function, (ast.FunctionDef, ast.AsyncFunctionDef)):
            continue
        for child in ast.walk(function):
            if child is target:
                return function.name
    return "<module level>"


def _daemon_write_call_sites() -> dict[str, set[str]]:
    """Daemon method -> the server functions that ask for write authority on it."""
    tree = _server_tree()
    sites: dict[str, set[str]] = {}
    for node in ast.walk(tree):
        if not isinstance(node, ast.Call):
            continue
        name = _called_name(node)
        index = _WRITE_AUTHORITY_CALLS.get(name or "")
        if index is None:
            continue
        method = _string_argument(node, index)
        if method is None:
            continue
        sites.setdefault(method, set()).add(_enclosing_tool(tree, node))
    return sites


def _read_courier_commands() -> set[str]:
    """Courier subcommands invoked directly by the read helpers."""
    commands: set[str] = set()
    for node in ast.walk(_server_tree()):
        if not isinstance(node, ast.Call):
            continue
        if _called_name(node) not in _READ_COURIER_CALLS:
            continue
        command = _string_argument(node, 0)
        if command is not None:
            commands.add(command)
    # The memory engine's provider module runs one courier command of its own.
    providers = _PROVIDERS_PATH.read_text(encoding="utf-8")
    commands.update(re.findall(r'\[cli, "([a-z0-9-]+)"\]', providers))
    return commands


def _swift_string_set(source: str, declaration: str) -> set[str]:
    """The string literals of a `let <declaration>: Set<String> = [ … ]`."""
    start = source.index(declaration)
    open_bracket = source.index("[", start)
    depth = 0
    for offset in range(open_bracket, len(source)):
        if source[offset] == "[":
            depth += 1
        elif source[offset] == "]":
            depth -= 1
            if depth == 0:
                body = source[open_bracket : offset + 1]
                break
    else:  # pragma: no cover - a malformed literal is a compile error first
        raise AssertionError(f"unterminated literal for {declaration}")
    return set(re.findall(r'"([^"]+)"', body))


def _direct_command_names() -> set[str]:
    return _swift_string_set(
        _CLI_RUNNER_PATH.read_text(encoding="utf-8"),
        "directCommandNames: Set<String>",
    )


# `@main` reaches a stdin-JSON command one of two ways. Seven of them are still
# hand-written `if arguments == ["name"]` branches. The project-code-memory
# family is dispatched through a table in the runner library, because the branch
# body is unreachable from a test while it lives inside an `exit()`-terminated
# entry point. Both shapes are a real route; neither is taken on faith.
_COURIER_TABLE_DECLARATION = "public enum ProjectCodeCourierCommand: String, CaseIterable, Sendable {"
_COURIER_TABLE_LOOKUP = "BurnBarCLIRunner.ProjectCodeCourierCommand(rawValue: arguments[0])"
_COURIER_TABLE_INVOCATION = "courierCommand.run("


def _courier_table_commands() -> set[str]:
    """The raw values of `BurnBarCLIRunner.ProjectCodeCourierCommand`."""
    source = _CLI_RUNNER_PATH.read_text(encoding="utf-8")
    start = source.index(_COURIER_TABLE_DECLARATION)
    open_brace = source.index("{", start)
    depth = 0
    for offset in range(open_brace, len(source)):
        if source[offset] == "{":
            depth += 1
        elif source[offset] == "}":
            depth -= 1
            if depth == 0:
                body = source[open_brace : offset + 1]
                break
    else:  # pragma: no cover - an unterminated enum is a compile error first
        raise AssertionError("unterminated ProjectCodeCourierCommand declaration")
    return set(re.findall(r'case \w+ = "([a-z0-9-]+)"', body))


def _consults_courier_table(cli_main_source: str) -> bool:
    """Whether `@main` looks a command up in the table AND runs what it returns.

    A case added to the enum but never reached from `@main` is not a route, so
    the table only counts while both halves of the wiring are present.
    """
    return _COURIER_TABLE_LOOKUP in cli_main_source and _COURIER_TABLE_INVOCATION in cli_main_source


def _dispatch_commands_in(cli_main_source: str) -> set[str]:
    dispatched = set(re.findall(r'arguments == \["([a-z0-9-]+)"\]', cli_main_source))
    if _consults_courier_table(cli_main_source):
        dispatched |= _courier_table_commands()
    return dispatched


def _cli_main_dispatch_commands() -> set[str]:
    return _dispatch_commands_in(_CLI_MAIN_PATH.read_text(encoding="utf-8"))


def _rpc_method_cases() -> dict[str, str]:
    """`daemon.x.y` -> the `BurnBarRPCMethod` case name that carries it."""
    source = _RPC_CONTRACTS_PATH.read_text(encoding="utf-8")
    return {method: case for case, method in re.findall(r'case (\w+) = "(daemon\.[\w.]+)"', source)}


def _cli_support_methods() -> set[str]:
    """The `BurnBarRPCMethod` case names in `BurnBarPeerCapabilityProfile.cliSupport`."""
    source = _RPC_CAPABILITY_PATH.read_text(encoding="utf-8")
    start = source.index("public static let cliSupport = methodScoped([")
    open_bracket = source.index("[", source.index("methodScoped", start))
    depth = 0
    for offset in range(open_bracket, len(source)):
        if source[offset] == "[":
            depth += 1
        elif source[offset] == "]":
            depth -= 1
            if depth == 0:
                body = source[open_bracket : offset + 1]
                break
    else:  # pragma: no cover
        raise AssertionError("unterminated cliSupport literal")
    uncommented = "\n".join(line for line in body.splitlines() if not line.strip().startswith("//"))
    return set(re.findall(r"\.(\w+)\s*(?:,|\])", uncommented))


def _uncarried_write_methods(commands: dict[str, str]) -> list[str]:
    """Write-authority call sites with no signed command, both halves named."""
    breaks: list[str] = []
    for method, tools in sorted(_daemon_write_call_sites().items()):
        if method in commands:
            continue
        for tool in sorted(tools):
            breaks.append(
                f"{tool} asks the daemon for write authority on {method}, "
                "but no signed CLI command carries it — on a signed install with the "
                "peer gate on it falls through to a socket the daemon refuses"
            )
    return breaks


# ---------------------------------------------------------------------------
# The relation
# ---------------------------------------------------------------------------


def test_every_daemon_write_authority_call_site_has_a_signed_command() -> None:
    """The invariant the code-index tools broke."""
    server = _load_server()
    breaks = _uncarried_write_methods(server._SIGNED_DAEMON_COMMANDS)
    assert not breaks, "Daemon writes with no signed courier command:\n    " + "\n    ".join(breaks)


def test_the_parity_check_fails_on_the_pre_fix_command_table() -> None:
    """The checker must stay able to fail, and must name both halves of a break."""
    breaks = _uncarried_write_methods(_PRE_FIX_SIGNED_DAEMON_COMMANDS)
    uncarried = {line.split(" asks the daemon for write authority on ")[1].split(",")[0] for line in breaks}
    assert uncarried == {
        "daemon.code.index_project",
        "daemon.code.watch_project",
        "daemon.code.explore",
    }
    assert any("burnbar_index_project asks the daemon" in line for line in breaks)
    assert any("burnbar_watch_project asks the daemon" in line for line in breaks)
    assert any("burnbar_explore asks the daemon" in line for line in breaks)


def test_every_python_courier_command_is_a_swift_cli_command() -> None:
    """`_SIGNED_DAEMON_COMMANDS` and `directCommandNames` must not drift apart."""
    server = _load_server()
    declared = set(server._SIGNED_DAEMON_COMMANDS.values()) | _read_courier_commands()
    missing = sorted(declared - _direct_command_names())
    assert not missing, f"The Python courier names commands the Swift CLI would reject in startup preflight: {missing}"


def test_every_courier_command_is_dispatched_as_stdin_json() -> None:
    """A name in `directCommandNames` with no branch would hit the human runner."""
    server = _load_server()
    declared = set(server._SIGNED_DAEMON_COMMANDS.values()) | _read_courier_commands()
    dispatched = _cli_main_dispatch_commands()
    missing = sorted(declared - dispatched)
    assert not missing, f"Courier commands with no stdin-JSON dispatch branch in OpenBurnBarCLIMain.swift: {missing}"


def test_the_dispatch_check_fails_when_main_stops_consulting_the_courier_table() -> None:
    """The table is only a route while `@main` actually consults it.

    Without this, moving the dispatch into a library table would have turned the
    stdin-JSON check into a tautology: three enum cases asserting about
    themselves. Unwire the lookup and the three code commands must go missing
    again, exactly as they did before this fix existed.
    """
    source = _CLI_MAIN_PATH.read_text(encoding="utf-8")
    assert _consults_courier_table(source)
    assert _courier_table_commands() == {"code-index-project", "code-watch-project", "code-explore"}

    unwired = source.replace(_COURIER_TABLE_LOOKUP, "nil as BurnBarCLIRunner.ProjectCodeCourierCommand?")
    assert unwired != source
    assert not _consults_courier_table(unwired)
    assert _dispatch_commands_in(unwired) & _courier_table_commands() == set()


def test_every_courier_method_is_permitted_by_the_cli_peer_profile() -> None:
    """Passing the signature gate is worth nothing if the capability gate refuses."""
    server = _load_server()
    methods = set(server._SIGNED_DAEMON_COMMANDS)
    for command in _read_courier_commands():
        method = _READ_COMMAND_METHODS.get(command)
        assert method is not None, (
            f"{command} is invoked as a courier read but this test does not know which "
            "daemon method it reaches; add it to _READ_COMMAND_METHODS"
        )
        methods.add(method)

    cases = _rpc_method_cases()
    permitted = _cli_support_methods()
    breaks: list[str] = []
    for method in sorted(methods):
        case = cases.get(method)
        if case is None:
            breaks.append(f"{method} has no BurnBarRPCMethod case")
        elif case not in permitted:
            breaks.append(
                f"{method} (.{case}) is carried by the courier but is absent from "
                "BurnBarPeerCapabilityProfile.cliSupport, so the daemon refuses it "
                "at the capability gate"
            )
    assert not breaks, "Courier methods the CLI peer profile does not permit:\n    " + "\n    ".join(breaks)


def test_the_capability_check_fails_when_cli_support_omits_explore() -> None:
    """`.codeExplore` was the one method the pre-fix profile was missing."""
    permitted = _cli_support_methods() - {"codeExplore"}
    cases = _rpc_method_cases()
    assert cases["daemon.code.explore"] == "codeExplore"
    assert "codeExplore" not in permitted
    # The other two code methods were already permitted before this fix; only
    # their courier commands were missing.
    assert {"codeIndexProject", "codeWatchProject"} <= permitted


# ---------------------------------------------------------------------------
# The relation must stay honest
# ---------------------------------------------------------------------------


def test_the_command_table_names_no_command_twice() -> None:
    server = _load_server()
    values = list(server._SIGNED_DAEMON_COMMANDS.values())
    assert len(values) == len(set(values)), f"a courier command carries two daemon methods: {values}"


def test_every_courier_method_is_a_real_daemon_rpc() -> None:
    server = _load_server()
    cases = _rpc_method_cases()
    unknown = sorted(method for method in server._SIGNED_DAEMON_COMMANDS if method not in cases)
    assert not unknown, f"_SIGNED_DAEMON_COMMANDS names methods the daemon does not serve: {unknown}"


def test_the_swift_sources_this_test_reads_are_present() -> None:
    """A silently missing source file would make every check above vacuous."""
    for path in (_CLI_RUNNER_PATH, _CLI_MAIN_PATH, _RPC_CONTRACTS_PATH, _RPC_CAPABILITY_PATH):
        assert path.is_file(), f"{path} moved; this parity test reads it by path"
    assert _direct_command_names(), "directCommandNames parsed empty"
    assert _cli_support_methods(), "cliSupport parsed empty"
    assert _rpc_method_cases(), "BurnBarRPCMethod cases parsed empty"


@pytest.mark.parametrize(
    "method",
    ["daemon.code.index_project", "daemon.code.watch_project", "daemon.code.explore"],
)
def test_the_code_index_methods_now_have_a_route(method: str) -> None:
    server = _load_server()
    assert method in server._SIGNED_DAEMON_COMMANDS
    command = server._SIGNED_DAEMON_COMMANDS[method]
    assert command in _direct_command_names()
    assert command in _cli_main_dispatch_commands()
