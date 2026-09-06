"""Signed-CLI courier discovery and verification.

Three review findings are pinned here:

1. The release bundle installs and signs the courier at
   `Contents/Helpers/OpenBurnBarCLI` (see `scripts/build-macos-website-release.sh`),
   not at the `Contents/MacOS/openburnbar-cli` path the server used to probe, so
   production installs never found their own CLI.
2. Discovery must not hand an arbitrary executable the daemon's trust: every
   candidate is code-signature verified against the same designated requirement
   the Swift daemon enforces before it is accepted.
3. That verification must be *evaluated by codesign* (`--verify -R=<requirement>`),
   not substring-matched against the binary's own auto-generated designated
   requirement text. The DR text phrases a Developer ID identity as
   `certificate leaf[subject.OU]` and an Apple Development identity as
   `certificate leaf[subject.CN]`, even though both leaves carry the same
   `OU = <team id>`. Matching the text therefore rejected every locally built
   install while also being the weaker check.

Fixtures are built at runtime. No certificate, key, or other secret-shaped
literal is committed.
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import stat
import subprocess
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


def _fake_codesign(
    server,
    monkeypatch: pytest.MonkeyPatch,
    *,
    satisfies: bool = True,
    flags: int = 0x12000,
    signed: bool = True,
) -> list[list[str]]:
    """
    Stand in for `/usr/bin/codesign`, recording the argv it was handed.

    `satisfies` models whether the OS decided the signature meets the `-R=`
    requirement — which is the whole point: the requirement is evaluated, not
    grepped, so the fixture never has to fake a designated-requirement string.
    """
    seen: list[list[str]] = []

    def fake_run(args, **kwargs):
        seen.append(list(args))
        if "--verify" in args:
            if not signed:
                return types.SimpleNamespace(returncode=1, stdout=b"", stderr=b"code object is not signed at all\n")
            if not satisfies:
                return types.SimpleNamespace(
                    returncode=3,
                    stdout=b"",
                    stderr=b"test-requirement: code failed to satisfy specified code requirement(s)\n",
                )
            return types.SimpleNamespace(returncode=0, stdout=b"", stderr=b"")
        described = (
            b"Identifier=com.openburnbar.cli\n"
            b"CodeDirectory v=20500 size=1 flags=0x%x(library-validation,runtime) hashes=1+2\n"
            b"Authority=Apple Development: Test Signer (XXXXXXXXXX)\n"
            b"TeamIdentifier=4Y367DF25B\n" % flags
        )
        return types.SimpleNamespace(returncode=0, stdout=described, stderr=b"")

    monkeypatch.setattr(server.subprocess, "run", fake_run)
    return seen


def _real_codesign_fixture(tmp_path: Path, name: str, *, adhoc: bool) -> Path | None:
    """Copy a real Mach-O and strip or ad-hoc sign it. None when codesign is absent."""
    if not os.path.exists("/usr/bin/codesign") or not os.path.exists("/bin/echo"):
        return None
    binary = tmp_path / name
    shutil.copyfile("/bin/echo", binary)
    binary.chmod(0o755)
    if adhoc:
        signed = subprocess.run(["/usr/bin/codesign", "-f", "-s", "-", str(binary)], capture_output=True, check=False)
        if signed.returncode != 0:
            return None
    else:
        subprocess.run(["/usr/bin/codesign", "--remove-signature", str(binary)], capture_output=True, check=False)
    return binary


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
    monkeypatch.delenv("OPENBURNBAR_APP_BUNDLE_PATHS", raising=False)
    monkeypatch.setattr(server.shutil, "which", lambda _name: None)
    monkeypatch.setattr(server, "_verify_courier_detail", lambda _path: (True, "ok"))

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
    monkeypatch.delenv("OPENBURNBAR_APP_BUNDLE_PATHS", raising=False)
    monkeypatch.setattr(server.shutil, "which", lambda _name: None)
    monkeypatch.setattr(server, "_verify_courier_detail", lambda _path: (True, "ok"))

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
    monkeypatch.delenv("OPENBURNBAR_APP_BUNDLE_PATHS", raising=False)
    monkeypatch.setattr(server.shutil, "which", lambda _name: None)
    monkeypatch.setattr(server, "_verify_courier_detail", lambda _path: (False, "stubbed rejection"))

    assert server._signed_cli_path() is None


def test_env_override_is_verified_outside_pytest(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    server = _load_server()
    impostor = _fake_executable(tmp_path / "impostor-cli")
    monkeypatch.setenv("OPENBURNBAR_CLI_PATH", str(impostor))
    monkeypatch.delenv("OPENBURNBAR_APP_BUNDLE_PATHS", raising=False)
    monkeypatch.setattr(server, "_COURIER_BUNDLE_CANDIDATES", ())
    monkeypatch.setattr(server.shutil, "which", lambda _name: None)
    monkeypatch.delenv("PYTEST_CURRENT_TEST", raising=False)
    monkeypatch.setattr(server, "_verify_courier_detail", lambda _path: (False, "stubbed rejection"))

    assert server._signed_cli_path() is None


def test_env_override_stays_monkeypatchable_under_pytest(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    server = _load_server()
    fake = _fake_executable(tmp_path / "fake-cli")
    monkeypatch.setenv("OPENBURNBAR_CLI_PATH", str(fake))
    monkeypatch.delenv("OPENBURNBAR_APP_BUNDLE_PATHS", raising=False)
    monkeypatch.setattr(server, "_COURIER_BUNDLE_CANDIDATES", ())
    monkeypatch.setattr(server.shutil, "which", lambda _name: None)
    monkeypatch.setenv("PYTEST_CURRENT_TEST", "tests/test_signed_cli_courier.py::x (call)")
    monkeypatch.setattr(server, "_verify_courier_detail", lambda _path: (False, "stubbed rejection"))

    assert server._signed_cli_path() == str(fake)


# ---------------------------------------------------------------------------
# Courier verification
# ---------------------------------------------------------------------------


def test_verify_courier_evaluates_the_requirement_instead_of_grepping_the_dr(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The regression that killed locally built installs: `-R=` must be passed."""
    server = _load_server()
    if not server._IS_MACOS:
        pytest.skip("codesign verification is macOS-only")
    binary = _fake_executable(tmp_path / "OpenBurnBarCLI")
    seen = _fake_codesign(server, monkeypatch)

    assert server._verify_courier(str(binary)) is True
    verify_argv = next(argv for argv in seen if "--verify" in argv)
    assert verify_argv[0] == "/usr/bin/codesign"
    assert "--strict" in verify_argv
    assert f"-R={server._courier_designated_requirement()}" in verify_argv
    assert str(binary) in verify_argv
    # No code path may fall back to matching the binary's self-declared DR text.
    assert not any("--requirements" in argv for argv in seen)


def test_courier_requirement_pins_team_anchor_and_identifier() -> None:
    server = _load_server()
    requirement = server._courier_designated_requirement()
    assert "anchor apple generic" in requirement
    assert f'certificate leaf[subject.OU] = "{server._COURIER_TEAM_ID}"' in requirement
    assert f'identifier "{server._COURIER_BUNDLE_IDENTIFIER}"' in requirement


def test_courier_requirement_is_valid_requirement_language(tmp_path: Path) -> None:
    """A malformed requirement must be caught here, not at runtime on a user's Mac."""
    server = _load_server()
    if not server._IS_MACOS:
        pytest.skip("codesign verification is macOS-only")
    binary = _real_codesign_fixture(tmp_path, "adhoc-syntax-probe", adhoc=True)
    if binary is None:
        pytest.skip("codesign could not produce a fixture")
    probe = subprocess.run(
        ["/usr/bin/codesign", "--verify", "--strict", f"-R={server._courier_designated_requirement()}", str(binary)],
        capture_output=True,
        check=False,
    )
    combined = (probe.stdout + probe.stderr).decode("utf-8", "replace")
    # Rejected for identity, never for syntax.
    assert "Requirement syntax error" not in combined
    assert "invalid or corrupted code requirement" not in combined


def test_verify_courier_accepts_a_developer_id_shaped_leaf(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Production shape: codesign says the requirement is satisfied -> accept."""
    server = _load_server()
    if not server._IS_MACOS:
        pytest.skip("codesign verification is macOS-only")
    binary = _fake_executable(tmp_path / "OpenBurnBarCLI")
    _fake_codesign(server, monkeypatch, satisfies=True)

    assert server._verify_courier_detail(str(binary)) == (True, "ok")


def test_verify_courier_accepts_the_real_development_signed_install() -> None:
    """
    The bug this file exists for: a locally built, Apple Development-signed
    install of the same team must be accepted, with no opt-in and no relaxation.

    Skipped where that install is absent (CI, Linux, a machine without the app).
    """
    server = _load_server()
    if not server._IS_MACOS:
        pytest.skip("codesign verification is macOS-only")
    courier = server._COURIER_BUNDLE_CANDIDATES[0]
    if not os.path.isfile(courier):
        pytest.skip(f"no installed courier at {courier}")
    described = subprocess.run(["/usr/bin/codesign", "-dvvv", courier], capture_output=True, check=False)
    text = (described.stdout + described.stderr).decode("utf-8", "replace")
    if "Apple Development" not in text:
        pytest.skip("installed courier is not development-signed")
    accepted, reason = server._verify_courier_detail(courier)
    assert accepted is True, reason


def test_verify_courier_rejects_a_foreign_team_id(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Same signature shape, different team: codesign refuses, so we refuse."""
    server = _load_server()
    if not server._IS_MACOS:
        pytest.skip("codesign verification is macOS-only")
    binary = _fake_executable(tmp_path / "OpenBurnBarCLI")
    _fake_codesign(server, monkeypatch, satisfies=False)

    accepted, reason = server._verify_courier_detail(str(binary))
    assert accepted is False
    assert "failed to satisfy" in reason


def test_verify_courier_rejects_a_really_unsigned_binary(tmp_path: Path) -> None:
    """No stubbing: a genuinely unsigned Mach-O, judged by the real codesign."""
    server = _load_server()
    if not server._IS_MACOS:
        pytest.skip("codesign verification is macOS-only")
    binary = _real_codesign_fixture(tmp_path, "unsigned-courier", adhoc=False)
    if binary is None:
        pytest.skip("codesign could not produce a fixture")

    accepted, reason = server._verify_courier_detail(str(binary))
    assert accepted is False
    assert reason


def test_verify_courier_rejects_a_really_adhoc_signed_binary(tmp_path: Path) -> None:
    """Ad-hoc signatures have no Apple anchor and no team, so they cannot pass."""
    server = _load_server()
    if not server._IS_MACOS:
        pytest.skip("codesign verification is macOS-only")
    binary = _real_codesign_fixture(tmp_path, "adhoc-courier", adhoc=True)
    if binary is None:
        pytest.skip("codesign could not produce a fixture")

    accepted, reason = server._verify_courier_detail(str(binary))
    assert accepted is False
    assert "failed to satisfy" in reason or "not signed" in reason


def test_verify_courier_rejects_a_malformed_requirement_without_crashing(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    server = _load_server()
    if not server._IS_MACOS:
        pytest.skip("codesign verification is macOS-only")
    binary = _real_codesign_fixture(tmp_path, "malformed-req-courier", adhoc=True)
    if binary is None:
        pytest.skip("codesign could not produce a fixture")
    monkeypatch.setattr(server, "_courier_designated_requirement", lambda: "this is not ( a requirement")

    accepted, reason = server._verify_courier_detail(str(binary))
    assert accepted is False
    assert reason


def test_verify_courier_rejects_a_signature_without_hardened_runtime(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Mirrors the daemon's programmatic CodeDirectory flag check."""
    server = _load_server()
    if not server._IS_MACOS:
        pytest.skip("codesign verification is macOS-only")
    binary = _fake_executable(tmp_path / "OpenBurnBarCLI")
    _fake_codesign(server, monkeypatch, flags=0x2000)

    accepted, reason = server._verify_courier_detail(str(binary))
    assert accepted is False
    assert "hardened runtime" in reason


def test_verify_courier_rejects_a_signature_without_library_validation(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    server = _load_server()
    if not server._IS_MACOS:
        pytest.skip("codesign verification is macOS-only")
    binary = _fake_executable(tmp_path / "OpenBurnBarCLI")
    _fake_codesign(server, monkeypatch, flags=0x1_0000)

    accepted, reason = server._verify_courier_detail(str(binary))
    assert accepted is False
    assert "library validation" in reason


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


def test_courier_requirement_is_a_narrowing_of_the_swift_daemon_requirement() -> None:
    """
    The Python courier pin must stay a strict subset of the daemon's own RPC peer
    requirement, so the two cannot drift apart into a hole. The daemon ORs three
    first-party identifiers; the courier only ever runs the CLI.
    """
    server = _load_server()
    swift = (
        Path(__file__).resolve().parents[3]
        / "OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/PrivilegedSocketTrust.swift"
    )
    if not swift.is_file():
        pytest.skip("PrivilegedSocketTrust.swift not present in this checkout")
    source = swift.read_text()
    assert f'teamID = "{server._COURIER_TEAM_ID}"' in source
    assert f'"{server._COURIER_BUNDLE_IDENTIFIER}"' in source
    assert 'anchor apple generic and certificate leaf[subject.OU] = "\\(teamID)"' in source
    assert server._COURIER_HARDENED_RUNTIME_FLAG == 0x1_0000
    assert server._COURIER_LIBRARY_VALIDATION_FLAG == 0x2000
    assert "hardenedRuntimeFlag: UInt32 = 0x1_0000" in source
    assert "libraryValidationFlag: UInt32 = 0x2000" in source


def test_courier_rejection_summary_names_the_candidate_and_the_mismatch(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The refusal must be diagnosable in seconds without leaking secrets."""
    server = _load_server()
    if not server._IS_MACOS:
        pytest.skip("codesign verification is macOS-only")
    impostor = _fake_executable(tmp_path / "OpenBurnBarCLI")
    monkeypatch.setattr(server, "_COURIER_BUNDLE_CANDIDATES", (str(impostor),))
    monkeypatch.delenv("OPENBURNBAR_CLI_PATH", raising=False)
    monkeypatch.delenv("OPENBURNBAR_APP_BUNDLE_PATHS", raising=False)
    monkeypatch.setattr(server.shutil, "which", lambda _name: None)
    _fake_codesign(server, monkeypatch, satisfies=False)

    assert server._signed_cli_path() is None
    summary = server._courier_rejection_summary()
    assert str(impostor) in summary
    assert "presented [" in summary
    assert "required [" in summary
    assert server._COURIER_TEAM_ID in summary


def test_courier_command_failure_is_not_reported_as_a_signature_failure(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """
    A courier that runs and gets a "no" from the daemon must surface that "no".
    Retrying over the direct socket used to swap the real answer for an
    unrelated peer-gate refusal.
    """
    server = _load_server()
    monkeypatch.setattr(server, "_signed_cli_path", lambda: "/fake/courier")

    def fake_run(args, **kwargs):
        return types.SimpleNamespace(returncode=1, stdout=b"", stderr=b"privacy_rpc_error code=-32602 message=nope\n")

    monkeypatch.setattr(server.subprocess, "run", fake_run)

    def exploding_daemon(*args, **kwargs):
        raise AssertionError("must not fall back to the direct socket after a courier answer")

    monkeypatch.setattr(server.pcm, "call_daemon", exploding_daemon)

    with pytest.raises(RuntimeError) as excinfo:
        server._DaemonReadConnection().execute("SELECT 1", ())
    assert "code-signature" not in str(excinfo.value)
    assert "nope" in str(excinfo.value)


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


def test_candidate_override_can_only_narrow_never_bypass_verification(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """
    `OPENBURNBAR_APP_BUNDLE_PATHS` redirects where the courier is looked for. It
    must never be a way to get an unverified binary trusted.
    """
    server = _load_server()
    if not server._IS_MACOS:
        pytest.skip("codesign verification is macOS-only")
    impostor = _fake_executable(tmp_path / "impostor")
    monkeypatch.delenv("OPENBURNBAR_CLI_PATH", raising=False)
    monkeypatch.delenv("PYTEST_CURRENT_TEST", raising=False)
    monkeypatch.setenv("OPENBURNBAR_APP_BUNDLE_PATHS", str(impostor))
    monkeypatch.setattr(server.shutil, "which", lambda _name: None)
    _fake_codesign(server, monkeypatch, satisfies=False)

    assert server._courier_candidates() == (str(impostor),)
    assert server._signed_cli_path() is None


def test_empty_candidate_override_searches_nowhere(monkeypatch: pytest.MonkeyPatch) -> None:
    server = _load_server()
    monkeypatch.delenv("OPENBURNBAR_CLI_PATH", raising=False)
    monkeypatch.setenv("OPENBURNBAR_APP_BUNDLE_PATHS", "")
    monkeypatch.setattr(server.shutil, "which", lambda _name: None)

    assert server._courier_candidates() == ()
    assert server._signed_cli_path() is None


def test_unset_candidate_override_uses_the_shipped_defaults(monkeypatch: pytest.MonkeyPatch) -> None:
    server = _load_server()
    monkeypatch.delenv("OPENBURNBAR_APP_BUNDLE_PATHS", raising=False)

    assert server._courier_candidates() == server._COURIER_BUNDLE_CANDIDATES


def test_courier_transport_failure_is_reported_unreachable_not_rejected(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """
    A dead socket means nothing judged the write. Reporting it as a rejection
    told callers their memory had been denied on the merits.
    """
    server = _load_server()
    monkeypatch.setattr(server, "_signed_cli_path", lambda: "/fake/courier")

    def dead_socket(args, **kwargs):
        return types.SimpleNamespace(
            returncode=1,
            stdout=b"",
            stderr=b"The operation couldn\xe2\x80\x99t be completed. No such file or directory\n",
        )

    monkeypatch.setattr(server.subprocess, "run", dead_socket)
    outcome = server._signed_memory_write_authority("daemon.memory.remember", {})
    assert outcome is not None
    assert outcome["code"] == "DAEMON_WRITE_REQUIRED"

    def daemon_refusal(args, **kwargs):
        return types.SimpleNamespace(returncode=1, stdout=b"", stderr=b"privacy_rpc_error code=-32602 message=nope\n")

    monkeypatch.setattr(server.subprocess, "run", daemon_refusal)
    refused = server._signed_memory_write_authority("daemon.memory.remember", {})
    assert refused is not None
    assert refused["code"] == "DAEMON_WRITE_REJECTED"
