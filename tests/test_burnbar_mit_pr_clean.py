"""Behavioral tests for the BurnBar MIT PR cleanliness scan.

Run: python3 -m pytest tests/test_burnbar_mit_pr_clean.py
 or: python3 tests/test_burnbar_mit_pr_clean.py
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from scripts.verify_burnbar_mit_pr_clean import (  # noqa: E402
    collect_changed_files,
    scan_path,
    scan_repo,
    scan_text,
)


def test_allows_normal_signal_messenger_adapter_reference() -> None:
    """Plain 'Signal' (the messenger, e.g. an adapter list) is NOT a violation."""
    text = "Supported messenger adapters: Signal, WhatsApp, Telegram.\nSignal support is stable.\n"
    assert scan_text("docs/adapters.md", text) == []


def test_blocks_mit_lane_overclaims() -> None:
    """Signal-grade/-quality/-class and 'Signal Protocol' claims may not ride the MIT lane."""
    for phrase in (
        "Signal-grade encryption for everyone",
        "Signal-quality privacy guarantees",
        "a Signal-class ratchet",
        "implements the Signal Protocol",
    ):
        violations = scan_text("README.md", phrase)
        assert violations, f"expected an overclaim violation for {phrase!r}"
        assert any(v.rule == "MIT-lane Signal overclaim" for v in violations)


def test_blocks_mit_lane_post_quantum_recovery_claim() -> None:
    violations = scan_text("README.md", "our gateway adds post-quantum recovery to every session")
    assert any(v.rule == "post-quantum recovery claim" for v in violations)


def test_blocks_official_libsignal_npm_dependency() -> None:
    violations = scan_text("package.json", '"@signalapp/libsignal-client": "0.94.4"')
    assert any(v.rule == "official libsignal npm dependency" for v in violations)


def test_blocks_agpl_signal_lane_paths() -> None:
    assert scan_path("Vendor/libsignal/Cargo.toml")
    assert scan_path("packages/libsignal-bridge/lib/index.js")
    assert scan_path("src/gateway/hardening.ts") == []


def test_working_tree_scan_includes_untracked_files() -> None:
    """--include-working-tree must surface UNTRACKED files (ls-files --others)."""
    with tempfile.TemporaryDirectory() as tmp:
        repo = Path(tmp)
        run = lambda *args: subprocess.run(  # noqa: E731
            ["git", "-C", str(repo), *args], check=True, capture_output=True, text=True
        )
        run("init", "--initial-branch=main")
        run("config", "user.email", "test@example.com")
        run("config", "user.name", "test")
        (repo / "clean.md").write_text("Signal adapter docs\n", encoding="utf-8")
        run("add", "clean.md")
        run("commit", "-m", "base")

        # An UNTRACKED file smuggling the official libsignal dependency.
        (repo / "sneaky.json").write_text('{"@signalapp/libsignal-client": "0.94.4"}\n', encoding="utf-8")

        without = collect_changed_files(repo, "HEAD", include_working_tree=False)
        assert "sneaky.json" not in without

        with_tree = collect_changed_files(repo, "HEAD", include_working_tree=True)
        assert "sneaky.json" in with_tree

        violations = scan_repo(repo, "HEAD", include_working_tree=True)
        assert any(
            v.path == "sneaky.json" and v.rule == "official libsignal npm dependency"
            for v in violations
        )


if __name__ == "__main__":
    failures = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"PASS {name}")
            except AssertionError as exc:
                failures += 1
                print(f"FAIL {name}: {exc}")
    sys.exit(1 if failures else 0)
