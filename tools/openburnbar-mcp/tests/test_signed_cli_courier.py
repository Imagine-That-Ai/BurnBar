"""Signed-CLI courier discovery and verification.

Two review findings are pinned here:

1. The release bundle installs and signs the courier at
   `Contents/Helpers/OpenBurnBarCLI` (see `scripts/build-macos-website-release.sh`),
   not at the `Contents/MacOS/openburnbar-cli` path the server used to probe, so
   production installs never found their own CLI.
2. Discovery must not hand an arbitrary executable the daemon's trust: every
   candidate is code-signature verified against the same designated requirement
   the Swift daemon enforces before it is accepted.
"""

from __future__ import annotations

import importlib.util
import os
import stat
import sys
import types
from pathlib import Path

import pytest

_PARENT = Path(__file__).resolve().parent.parent
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
    spec = importlib.util.spec_from_file_location("openburnbar_mcp_server_signed_cli_test", str(_PARENT / "server.py"))
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules["openburnbar_mcp_server_signed_cli_test"] = module
    spec.loader.exec_module(module)  # type: ignore[union-attr]
    return module


def _fake_executable(path: Path) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(b"#!/bin/sh\nexit 0\n")
    path.chmod(path.stat().st_mode | stat.S_IXUSR)
    return path


def _good_codesign(server, monkeypatch: pytest.MonkeyPatch) -> list[list[str]]:
    """Make every codesign probe succeed, recording the argv it was handed."""
    seen: list[list[str]] = []
    requirement = (
        'designated => anchor apple generic and certificate leaf[subject.OU] = "'
        f'{server._COURIER_TEAM_ID}" and (identifier "com.openburnbar.app" or '
        'identifier "com.openburnbar.daemon" or identifier "com.openburnbar.cli")\n'
    )

    def fake_run(args, **kwargs):
        seen.append(list(args))
        stdout = requirement.encode() if "-d" in args else b""
        return types.SimpleNamespace(returncode=0, stdout=stdout, stderr=requirement.encode())

    monkeypatch.setattr(server.subprocess, "run", fake_run)
    return seen


# ---------------------------------------------------------------------------
# Candidate order
# ---------------------------------------------------------------------------


def test_signed_cli_prefers_the_shipped_helpers_path(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    server = _load_server()
    helpers = _fake_executable(tmp_path / "Applications/OpenBurnBar.app/Contents/Helpers/OpenBurnBarCLI")
    legacy = _fake_executable(tmp_path / "Applications/OpenBurnBar.app/Contents/MacOS/openburnbar-cli")
    monkeypatch.setattr(
        server,
        "_COURIER_BUNDLE_CANDIDATES",
        (str(helpers), str(legacy)),
    )
    monkeypatch.delenv("OPENBURNBAR_CLI_PATH", raising=False)
    monkeypatch.setattr(server.shutil, "which", lambda _name: None)
    monkeypatch.setattr(server, "_verify_courier", lambda _path: True)

    assert server._signed_cli_path() == str(helpers)


def test_signed_cli_falls_back_to_the_legacy_macos_path(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    server = _load_server()
    legacy = _fake_executable(tmp_path / "Applications/OpenBurnBar.app/Contents/MacOS/openburnbar-cli")
    monkeypatch.setattr(
        server,
        "_COURIER_BUNDLE_CANDIDATES",
        (str(tmp_path / "Applications/OpenBurnBar.app/Contents/Helpers/OpenBurnBarCLI"), str(legacy)),
    )
    monkeypatch.delenv("OPENBURNBAR_CLI_PATH", raising=False)
    monkeypatch.setattr(server.shutil, "which", lambda _name: None)
    monkeypatch.setattr(server, "_verify_courier", lambda _path: True)

    assert server._signed_cli_path() == str(legacy)


def test_shipped_helpers_paths_are_the_first_defaults() -> None:
    server = _load_server()
    assert server._COURIER_BUNDLE_CANDIDATES[:2] == (
        "/Applications/OpenBurnBar.app/Contents/Helpers/OpenBurnBarCLI",
        os.path.expanduser("~/Applications/OpenBurnBar.app/Contents/Helpers/OpenBurnBarCLI"),
    )
    assert "/Applications/OpenBurnBar.app/Contents/MacOS/openburnbar-cli" in server._COURIER_BUNDLE_CANDIDATES


def test_signed_cli_rejects_a_candidate_that_fails_verification(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    server = _load_server()
    helpers = _fake_executable(tmp_path / "Applications/OpenBurnBar.app/Contents/Helpers/OpenBurnBarCLI")
    monkeypatch.setattr(server, "_COURIER_BUNDLE_CANDIDATES", (str(helpers),))
    monkeypatch.delenv("OPENBURNBAR_CLI_PATH", raising=False)
    monkeypatch.setattr(server.shutil, "which", lambda _name: None)
    monkeypatch.setattr(server, "_verify_courier", lambda _path: False)

    assert server._signed_cli_path() is None


def test_env_override_is_verified_outside_pytest(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    server = _load_server()
    impostor = _fake_executable(tmp_path / "impostor-cli")
    monkeypatch.setenv("OPENBURNBAR_CLI_PATH", str(impostor))
    monkeypatch.setattr(server, "_COURIER_BUNDLE_CANDIDATES", ())
    monkeypatch.setattr(server.shutil, "which", lambda _name: None)
    monkeypatch.delenv("PYTEST_CURRENT_TEST", raising=False)
    monkeypatch.setattr(server, "_verify_courier", lambda _path: False)

    assert server._signed_cli_path() is None


def test_env_override_stays_monkeypatchable_under_pytest(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    server = _load_server()
    fake = _fake_executable(tmp_path / "fake-cli")
    monkeypatch.setenv("OPENBURNBAR_CLI_PATH", str(fake))
    monkeypatch.setattr(server, "_COURIER_BUNDLE_CANDIDATES", ())
    monkeypatch.setattr(server.shutil, "which", lambda _name: None)
    monkeypatch.setenv("PYTEST_CURRENT_TEST", "tests/test_signed_cli_courier.py::x (call)")
    monkeypatch.setattr(server, "_verify_courier", lambda _path: False)

    assert server._signed_cli_path() == str(fake)


# ---------------------------------------------------------------------------
# Courier verification
# ---------------------------------------------------------------------------


def test_verify_courier_accepts_a_first_party_signature(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    server = _load_server()
    if not server._IS_MACOS:
        pytest.skip("codesign verification is macOS-only")
    binary = _fake_executable(tmp_path / "OpenBurnBarCLI")
    seen = _good_codesign(server, monkeypatch)

    assert server._verify_courier(str(binary)) is True
    assert seen[0][:4] == ["/usr/bin/codesign", "--verify", "--strict", str(binary)]
    assert any("-d" in argv and "--requirements" in argv for argv in seen)


def test_verify_courier_rejects_a_broken_signature(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    server = _load_server()
    if not server._IS_MACOS:
        pytest.skip("codesign verification is macOS-only")
    binary = _fake_executable(tmp_path / "OpenBurnBarCLI")
    monkeypatch.setattr(
        server.subprocess,
        "run",
        lambda *args, **kwargs: types.SimpleNamespace(returncode=1, stdout=b"", stderr=b"code object is not signed"),
    )

    assert server._verify_courier(str(binary)) is False


def test_verify_courier_rejects_a_foreign_team_id(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    server = _load_server()
    if not server._IS_MACOS:
        pytest.skip("codesign verification is macOS-only")
    binary = _fake_executable(tmp_path / "OpenBurnBarCLI")
    foreign = (
        b'designated => anchor apple generic and certificate leaf[subject.OU] = "ZZZZZZZZZZ" '
        b'and identifier "com.openburnbar.cli"\n'
    )

    def fake_run(args, **kwargs):
        stdout = foreign if "-d" in args else b""
        return types.SimpleNamespace(returncode=0, stdout=stdout, stderr=foreign)

    monkeypatch.setattr(server.subprocess, "run", fake_run)

    assert server._verify_courier(str(binary)) is False


def test_verify_courier_rejects_a_foreign_identifier(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    server = _load_server()
    if not server._IS_MACOS:
        pytest.skip("codesign verification is macOS-only")
    binary = _fake_executable(tmp_path / "OpenBurnBarCLI")
    foreign = (
        b'designated => anchor apple generic and certificate leaf[subject.OU] = "4Y367DF25B" '
        b'and identifier "com.evil.cli"\n'
    )

    def fake_run(args, **kwargs):
        stdout = foreign if "-d" in args else b""
        return types.SimpleNamespace(returncode=0, stdout=stdout, stderr=foreign)

    monkeypatch.setattr(server.subprocess, "run", fake_run)

    assert server._verify_courier(str(binary)) is False


def test_verify_courier_fails_closed_when_codesign_errors(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    server = _load_server()
    if not server._IS_MACOS:
        pytest.skip("codesign verification is macOS-only")
    binary = _fake_executable(tmp_path / "OpenBurnBarCLI")

    def boom(*args, **kwargs):
        raise OSError("codesign missing")

    monkeypatch.setattr(server.subprocess, "run", boom)

    assert server._verify_courier(str(binary)) is False


def test_verify_courier_pins_the_swift_team_id() -> None:
    server = _load_server()
    # OpenBurnBarPrivilegedTrust.teamID in
    # OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/PrivilegedSocketTrust.swift
    assert server._COURIER_TEAM_ID == "4Y367DF25B"
    assert server._COURIER_BUNDLE_IDENTIFIER == "com.openburnbar.cli"


def test_verify_courier_requires_a_root_owned_system_path_on_linux(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    server = _load_server()
    monkeypatch.setattr(server, "_IS_MACOS", False)
    monkeypatch.setattr(server, "_IS_LINUX", True)
    stray = _fake_executable(tmp_path / "openburnbar-cli")

    assert server._verify_courier(str(stray)) is False

    monkeypatch.setattr(server.os, "stat", lambda _p: types.SimpleNamespace(st_uid=0))
    assert server._verify_courier("/opt/openburnbar/bin/openburnbar-cli") is True
    monkeypatch.setattr(server.os, "stat", lambda _p: types.SimpleNamespace(st_uid=501))
    assert server._verify_courier("/opt/openburnbar/bin/openburnbar-cli") is False
