from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest


ROOT = Path(__file__).resolve().parents[1]


def _load_gate():
    path = ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py"
    spec = importlib.util.spec_from_file_location("trusted_deletion_bootstrap_gate", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


GATE = _load_gate()


def _git(repository: Path, *arguments: str) -> str:
    return subprocess.run(
        ["git", "-C", str(repository), *arguments],
        check=True,
        capture_output=True,
        text=True,
    ).stdout.strip()


def _commit(repository: Path, message: str) -> str:
    _git(repository, "add", ".")
    _git(repository, "commit", "-m", message)
    return _git(repository, "rev-parse", "HEAD")


def _repository(tmp_path: Path) -> Path:
    repository = tmp_path / "candidate"
    repository.mkdir()
    _git(repository, "init", "--initial-branch=main")
    _git(repository, "config", "user.name", "Domain Core Test")
    _git(repository, "config", "user.email", "domain-core@example.invalid")
    (repository / "README.md").write_text("bootstrap\n")
    _commit(repository, "bootstrap")
    return repository


def test_pre_ledger_candidate_is_an_advisory_pass(tmp_path: Path) -> None:
    repository = _repository(tmp_path)
    base = _git(repository, "rev-parse", "HEAD")

    GATE.run_gate(
        repository,
        Path("config/domain-core-legacy-deletion.json"),
        base_ref=base,
    )


def test_candidate_cannot_remove_a_ledger_that_exists_on_base(tmp_path: Path) -> None:
    repository = _repository(tmp_path)
    ledger = repository / "config/domain-core-legacy-deletion.json"
    ledger.parent.mkdir()
    ledger.write_text(json.dumps({"schemaVersion": 2}))
    base = _commit(repository, "add ledger")
    ledger.unlink()
    _commit(repository, "remove ledger")

    with pytest.raises(GATE.GateError, match="cannot remove the legacy deletion ledger"):
        GATE.run_gate(
            repository,
            Path("config/domain-core-legacy-deletion.json"),
            base_ref=base,
        )
