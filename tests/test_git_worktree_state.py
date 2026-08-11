from __future__ import annotations

import importlib.util
import subprocess
from pathlib import Path


SCRIPT_PATH = Path(__file__).parents[1] / "scripts" / "lib" / "git_worktree_state.py"
SPEC = importlib.util.spec_from_file_location("git_worktree_state", SCRIPT_PATH)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def git(repo: Path, *args: str) -> None:
    subprocess.run(
        ["git", *args],
        cwd=repo,
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


def make_repository(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    repo.mkdir()
    git(repo, "init", "--quiet")
    git(repo, "config", "user.email", "tests@openburnbar.local")
    git(repo, "config", "user.name", "OpenBurnBar Tests")
    (repo / "tracked.txt").write_text("baseline\n", encoding="utf-8")
    git(repo, "add", "tracked.txt")
    git(repo, "commit", "--quiet", "-m", "baseline")
    return repo


def test_clean_repository_reports_clean(tmp_path: Path) -> None:
    repo = make_repository(tmp_path)

    assert MODULE.detect_worktree_state(repo, timeout_seconds=2) == "clean"


def test_tracked_change_reports_dirty(tmp_path: Path) -> None:
    repo = make_repository(tmp_path)
    (repo / "tracked.txt").write_text("changed\n", encoding="utf-8")

    assert MODULE.detect_worktree_state(repo, timeout_seconds=2) == "dirty"


def test_untracked_change_reports_dirty(tmp_path: Path) -> None:
    repo = make_repository(tmp_path)
    (repo / "untracked.txt").write_text("new\n", encoding="utf-8")

    assert MODULE.detect_worktree_state(repo, timeout_seconds=2) == "dirty"


def test_timeout_fails_conservative(monkeypatch, tmp_path: Path) -> None:
    repo = make_repository(tmp_path)

    def timeout(*args, **kwargs):
        raise subprocess.TimeoutExpired(cmd=["git", "status"], timeout=0.01)

    monkeypatch.setattr(MODULE.subprocess, "run", timeout)

    assert MODULE.detect_worktree_state(repo, timeout_seconds=0.01) == "dirty"
