"""Regression + adversarial tests for the domain-core trusted deletion guard non-deletion bypass.

Context
-------
PR #1805 merged a trusted ``pull_request_target`` deletion guard that checks out the
PR *base* SHA as trusted default-branch code and the PR *head* SHA as candidate data,
then runs ``scripts/ci/verify-domain-core-legacy-deletion.py`` with
``--base-ref <base.sha>`` against the candidate tree.

The guard calls ``require_commit(repo_root, base_ref, "base ref")`` which runs
``git merge-base --is-ancestor <base_ref> HEAD`` *inside the candidate checkout*. When
the current default branch has advanced past the commit an ordinary PR branched from,
``base_ref`` (current main) is **not** an ancestor of the candidate ``HEAD`` (the PR
branch tip). For any PR that touches none of the ledger-covered deletion surfaces that
is a false failure: the gate aborts with
``base ref: commit must exist and be an ancestor of HEAD`` before it ever classifies the
PR as non-deletion.

These tests lock the contract that a behind-base **non-deletion** PR passes, while a
behind-base candidate that removes or weakens any ledger-covered legacy target, rollback
control, policy, workflow, reviewer catalog, immutable ledger artifact, or the guard
itself **cannot** claim non-deletion and remains fail-closed.

The classification is performed by trusted default-branch code (the verifier script).
Candidate code cannot declare itself non-deletion — a candidate that touches the guard
workflow or the verifier script itself is deletion-sensitive regardless of ancestry.
"""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
from pathlib import Path
from typing import Any

import pytest


ROOT = Path(__file__).resolve().parents[1]


def _load_gate():
    path = ROOT / "scripts/ci/verify-domain-core-legacy-deletion.py"
    spec = importlib.util.spec_from_file_location("trusted_deletion_non_deletion_bypass_gate", path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module
    spec.loader.exec_module(module)
    return module


GATE = _load_gate()

LEDGER_PATH = Path("config/domain-core-legacy-deletion.json")
REVIEWERS_PATH = Path("config/domain-core-deletion-reviewers.json")
GUARD_WORKFLOW = Path(".github/workflows/domain-core-deletion-guard.yml")
VERIFIER_SCRIPT = Path("scripts/ci/verify-domain-core-legacy-deletion.py")
IMMUTABLE_ROOTS = (
    Path("config/domain-core-legacy-deletion-receipts"),
    Path("config/domain-core-promotion-attestations"),
    Path("config/domain-core-promotion-bundles"),
    Path("config/domain-core-promotion-provenance"),
    Path("config/domain-core-release-provenance"),
    Path("config/domain-core-deletion-plans"),
)


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


def _is_ancestor(repository: Path, ancestor: str, descendant: str) -> bool:
    return (
        subprocess.run(
            ["git", "-C", str(repository), "merge-base", "--is-ancestor", ancestor, descendant],
            check=False,
            capture_output=True,
        ).returncode
        == 0
    )


def _write(repository: Path, relative: Path, contents: str) -> None:
    target = repository / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(contents)


def _remove(repository: Path, relative: Path) -> None:
    (repository / relative).unlink()


def _repository(tmp_path: Path) -> Path:
    """A fresh candidate repository with a single bootstrap commit on ``main``."""
    repository = tmp_path / "candidate"
    repository.mkdir()
    _git(repository, "init", "--initial-branch=main")
    _git(repository, "config", "user.name", "Domain Core Test")
    _git(repository, "config", "user.email", "domain-core@example.invalid")
    _write(repository, Path("README.md"), "bootstrap\n")
    _commit(repository, "bootstrap")
    return repository


def _behind_base_topology(tmp_path: Path, *, branch_commit: str) -> tuple[Path, str, str, str]:
    """Build the false-failure topology from run 29452164288 / job 87477014759.

    Returns ``(repository, older_main, branch_head, current_base)`` where:

    * ``older_main`` is the commit an ordinary PR branched from (ancestor of the head).
    * ``branch_head`` is the PR head — a descendant of ``older_main`` but **not** of
      ``current_base``.
    * ``current_base`` is the advanced default branch (= ``base.sha`` for the PR) and is
      **not** an ancestor of ``branch_head``.

    The worktree is left checked out at ``branch_head`` to mirror the candidate
    checkout at ``head.sha``.
    """
    repository = _repository(tmp_path)
    older_main = _git(repository, "rev-parse", "HEAD")

    _git(repository, "checkout", "-b", "feature")
    _write(repository, Path("mobile-qa.txt"), "ordinary mobile QA change\n")
    _commit(repository, branch_commit)
    branch_head = _git(repository, "rev-parse", "HEAD")

    _git(repository, "checkout", "main")
    _write(repository, Path("main-advance.txt"), "default branch advanced\n")
    _commit(repository, "default branch advanced past the PR branch point")
    current_base = _git(repository, "rev-parse", "HEAD")

    _git(repository, "checkout", branch_head)

    assert _is_ancestor(repository, older_main, branch_head)
    assert not _is_ancestor(repository, current_base, branch_head)
    return repository, older_main, branch_head, current_base


def _bootstrap_ledger() -> dict[str, Any]:
    return {
        "schemaVersion": 2,
        "sourceRoots": {"rust": "crates/openburnbar-domain-core"},
        "rows": [
            {
                "id": row_id,
                "state": "rollout",
                "authorityGeneration": 0,
                "receipts": {},
                "targets": [
                    {
                        "kind": "source_symbol",
                        "role": "legacy_implementation",
                        "root": "rust",
                        "path": f"crates/openburnbar-domain-core/src/legacy/{row_id}.rs",
                        "symbol": "legacy_entry",
                    }
                ],
            }
            for row_id in GATE.ROW_IDS
        ],
        "sharedTargets": [
            {
                "rowIds": ["hermes.relay_crypto", "hermes.ratchet_transforms"],
                "target": {
                    "kind": "mode_literal",
                    "role": "rollback_control",
                    "root": "rust",
                    "path": "crates/openburnbar-domain-core/src/legacy/hermes_rollback.rs",
                    "literal": "HERMES_ROLLBACK_GUARD",
                },
            }
        ],
    }


def _materialize_ledger_tree(repository: Path, ledger: dict[str, Any]) -> None:
    """Write the ledger plus every source root/target path it references so the gate can read them."""
    _write(repository, LEDGER_PATH, json.dumps(ledger, separators=(",", ":")))
    for root_path in set(ledger["sourceRoots"].values()):
        root_dir = repository / Path(root_path)
        root_dir.mkdir(parents=True, exist_ok=True)
    for row in ledger["rows"]:
        for target in row["targets"]:
            _write(repository, Path(target["path"]), f"// legacy {target['symbol']}\n")
    for shared in ledger["sharedTargets"]:
        target = shared["target"]
        _write(repository, Path(target["path"]), f"// {target['literal']} = true\n")


# ---------------------------------------------------------------------------
# Regression: the false failure on an ordinary non-deletion PR.
# ---------------------------------------------------------------------------


class TestNonDeletionBehindBaseBypass:
    """A behind-base PR that touches none of the deletion-covered surfaces must pass."""

    def test_ordinary_non_deletion_pr_passes_when_base_is_not_ancestor_of_head(self, tmp_path: Path) -> None:
        repository, _older_main, branch_head, current_base = _behind_base_topology(
            tmp_path, branch_commit="ordinary mobile QA PR"
        )

        # The reproduced production topology: current base is NOT an ancestor of the head.
        assert not _is_ancestor(repository, current_base, branch_head)

        # On unmodified main this raises "base ref: commit must exist and be an ancestor of
        # HEAD" before classifying the PR as non-deletion — a false failure.
        GATE.run_gate(repository, LEDGER_PATH, base_ref=current_base)

    def test_control_non_deletion_pr_passes_when_base_is_ancestor_of_head(self, tmp_path: Path) -> None:
        """When the base IS an ancestor of head, a non-deletion PR must also pass (no regression)."""
        repository = _repository(tmp_path)
        base = _git(repository, "rev-parse", "HEAD")

        _git(repository, "checkout", "-b", "feature")
        _write(repository, Path("docs/notes.md"), "ordinary doc change\n")
        _commit(repository, "ordinary doc PR")
        branch_head = _git(repository, "rev-parse", "HEAD")

        assert _is_ancestor(repository, base, branch_head)

        GATE.run_gate(repository, LEDGER_PATH, base_ref=base)


def _assert_malformed_trusted_base_fails_closed(
    tmp_path: Path,
    ledger: dict[str, Any],
    *,
    message: str,
) -> None:
    repository = _repository(tmp_path)

    _git(repository, "checkout", "-b", "feature")
    _write(repository, Path("docs/notes.md"), "ordinary doc change\n")
    _commit(repository, "ordinary doc PR")
    branch_head = _git(repository, "rev-parse", "HEAD")

    _git(repository, "checkout", "main")
    _write(
        repository,
        LEDGER_PATH,
        json.dumps(ledger),
    )
    current_base = _commit(repository, "malformed trusted deletion inventory")
    _git(repository, "checkout", branch_head)

    assert not _is_ancestor(repository, current_base, branch_head)
    with pytest.raises(GATE.GateError, match=message):
        GATE.run_gate(repository, LEDGER_PATH, base_ref=current_base)


def test_malformed_trusted_base_ledger_fails_closed(tmp_path: Path) -> None:
    """Invalid trusted inventory must not erase sensitive targets from classification."""
    _assert_malformed_trusted_base_fails_closed(
        tmp_path,
        {"schemaVersion": 2, "rows": "invalid", "sharedTargets": []},
        message="base manifest rows",
    )


@pytest.mark.parametrize("invalid_rows", [[], None])
def test_incomplete_trusted_row_set_fails_closed(tmp_path: Path, invalid_rows: Any) -> None:
    ledger = _bootstrap_ledger()
    ledger["rows"] = invalid_rows
    _assert_malformed_trusted_base_fails_closed(
        tmp_path,
        ledger,
        message="base manifest rows",
    )


@pytest.mark.parametrize("invalid_path", [None, "", 7, "../outside"])
def test_malformed_trusted_target_path_fails_closed(tmp_path: Path, invalid_path: Any) -> None:
    ledger = _bootstrap_ledger()
    ledger["rows"][0]["targets"][0]["path"] = invalid_path
    _assert_malformed_trusted_base_fails_closed(
        tmp_path,
        ledger,
        message="base manifest target.path",
    )


@pytest.mark.parametrize("invalid_path", [None, "", 7, "../outside"])
def test_malformed_trusted_shared_target_path_fails_closed(tmp_path: Path, invalid_path: Any) -> None:
    ledger = _bootstrap_ledger()
    ledger["sharedTargets"][0]["target"]["path"] = invalid_path
    _assert_malformed_trusted_base_fails_closed(
        tmp_path,
        ledger,
        message="base manifest sharedTarget.target.path",
    )


# ---------------------------------------------------------------------------
# Adversarial: a behind-base candidate that touches a deletion-covered surface
# cannot claim non-deletion and stays fail-closed.
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    "label, prepare",
    [
        (
            "removes-the-legacy-deletion-ledger",
            lambda repo, older: _remove(repo, LEDGER_PATH),
        ),
        (
            "removes-an-immutable-receipt-artifact",
            lambda repo, older: _remove(repo, IMMUTABLE_ROOTS[0] / "quota.claude_statusline" / "0" / "promotion.json"),
        ),
        (
            "weakens-the-deletion-reviewer-catalog",
            lambda repo, older: _write(
                repo,
                REVIEWERS_PATH,
                json.dumps({"schemaVersion": 1, "reviewers": []}),
            ),
        ),
        (
            "weakens-the-deletion-guard-workflow",
            lambda repo, older: _write(repo, GUARD_WORKFLOW, "name: weakened guard\n"),
        ),
        (
            "weakens-the-verifier-script-itself",
            lambda repo, older: _write(repo, VERIFIER_SCRIPT, "# gutted verifier\n"),
        ),
        (
            "removes-a-ledger-covered-legacy-target",
            lambda repo, older: _remove(repo, Path("crates/openburnbar-domain-core/src/legacy/quota.claude_statusline.rs")),
        ),
        (
            "weakens-a-rollback-control",
            lambda repo, older: _write(
                repo,
                Path("crates/openburnbar-domain-core/src/legacy/hermes_rollback.rs"),
                "// rollback guard removed\n",
            ),
        ),
    ],
)
class TestBehindBaseDeletionCandidateStaysFailClosed:
    """Each sensitive-surface touch must fail closed even when base is not an ancestor of head."""

    def test_behind_base_candidate_cannot_bypass(
        self, tmp_path: Path, label: str, prepare
    ) -> None:
        # Start from the false-failure topology, but seed deletion-covered surfaces on the
        # older main so the candidate has something real to remove/weaken.
        repository = _repository(tmp_path)
        _materialize_ledger_tree(repository, _bootstrap_ledger())
        # Seed an immutable receipt artifact + a reviewer catalog the candidate can attack.
        _write(
            repository,
            IMMUTABLE_ROOTS[0] / "quota.claude_statusline" / "0" / "promotion.json",
            json.dumps({"immutable": True}),
        )
        _write(
            repository,
            REVIEWERS_PATH,
            json.dumps(
                {
                    "schemaVersion": 1,
                    "reviewers": [
                        {
                            "handle": "@domain-owner",
                            "reviewClasses": ["domain_owner"],
                        },
                        {
                            "handle": "@crypto-security",
                            "reviewClasses": ["security_crypto"],
                        },
                    ],
                }
            ),
        )
        older_main = _commit(repository, "seed deletion-covered surfaces")

        # Branch from the seeded older main and apply the sensitive-surface change.
        _git(repository, "checkout", "-b", "feature")
        prepare(repository, older_main)
        _commit(repository, f"candidate: {label}")
        branch_head = _git(repository, "rev-parse", "HEAD")

        # Main advances past the branch point → current base is not an ancestor of head.
        _git(repository, "checkout", "main")
        _write(repository, Path("main-advance.txt"), "default branch advanced\n")
        _commit(repository, "default branch advanced past the PR branch point")
        current_base = _git(repository, "rev-parse", "HEAD")
        _git(repository, "checkout", branch_head)

        assert not _is_ancestor(repository, current_base, branch_head)

        with pytest.raises(GATE.GateError):
            GATE.run_gate(repository, LEDGER_PATH, base_ref=current_base)


def test_candidate_that_adds_the_ledger_is_deletion_sensitive(tmp_path: Path) -> None:
    """A behind-base candidate that bootstraps the ledger touches a deletion-covered surface."""
    repository, _older_main, branch_head, current_base = _behind_base_topology(
        tmp_path, branch_commit="ordinary change"
    )
    # The branch introduces the ledger where none existed on the older main.
    _materialize_ledger_tree(repository, _bootstrap_ledger())
    _git(repository, "add", ".")
    _git(repository, "commit", "--amend", "--no-edit")
    branch_head = _git(repository, "rev-parse", "HEAD")
    assert not _is_ancestor(repository, current_base, branch_head)

    # Adding the ledger is deletion-sensitive: the gate must not bypass it silently. It
    # will attempt full validation of the bootstrap ledger; we only assert it does not
    # claim a free non-deletion pass. A bootstrap that fails validation stays fail-closed.
    with pytest.raises(GATE.GateError):
        GATE.run_gate(repository, LEDGER_PATH, base_ref=current_base)


# ---------------------------------------------------------------------------
# Sanity: the classifier lives in trusted code, not candidate code.
# ---------------------------------------------------------------------------


def test_self_declaration_is_not_trusted(tmp_path: Path) -> None:
    """A candidate that edits the verifier to force a non-deletion classification is itself sensitive.

    The guard runs trusted default-branch code (``verify-domain-core-legacy-deletion.py``
    checked out at ``base.sha``). A candidate that weakens the verifier script cannot
    declare its own diff non-deletion: touching the verifier is a deletion-covered
    surface, so the gate must stay fail-closed regardless of ancestry.
    """
    repository = _repository(tmp_path)
    _write(repository, VERIFIER_SCRIPT, "# original verifier\n")
    older_main = _commit(repository, "seed verifier")

    _git(repository, "checkout", "-b", "feature")
    # Candidate attempts to neuter the verifier (a deletion-covered surface).
    _write(repository, VERIFIER_SCRIPT, "print('non-deletion')\n")
    _commit(repository, "candidate weakens verifier to self-declare non-deletion")
    branch_head = _git(repository, "rev-parse", "HEAD")

    _git(repository, "checkout", "main")
    _write(repository, Path("main-advance.txt"), "default branch advanced\n")
    _commit(repository, "default branch advanced")
    current_base = _git(repository, "rev-parse", "HEAD")
    _git(repository, "checkout", branch_head)

    assert not _is_ancestor(repository, current_base, branch_head)

    with pytest.raises(GATE.GateError):
        GATE.run_gate(repository, LEDGER_PATH, base_ref=current_base)


# ---------------------------------------------------------------------------
# Adversarial: a rename of a sensitive path to an ordinary name must stay
# fail-closed. With --no-renames the classifier sees the old path as Deleted,
# so the sensitive source is detected regardless of the new destination.
# ---------------------------------------------------------------------------


def test_rename_sensitive_ledger_target_to_ordinary_name_stays_fail_closed(tmp_path: Path) -> None:
    """Renaming a ledger-covered legacy target to ordinary.txt is deletion-sensitive."""
    repository = _repository(tmp_path)
    _materialize_ledger_tree(repository, _bootstrap_ledger())
    _write(
        repository,
        REVIEWERS_PATH,
        json.dumps(
            {
                "schemaVersion": 1,
                "reviewers": [
                    {"handle": "@domain-owner", "reviewClasses": ["domain_owner"]},
                    {"handle": "@crypto-security", "reviewClasses": ["security_crypto"]},
                ],
            }
        ),
    )
    older_main = _commit(repository, "seed deletion-covered surfaces")

    _git(repository, "checkout", "-b", "feature")
    sensitive_target = Path("crates/openburnbar-domain-core/src/legacy/quota.claude_statusline.rs")
    ordinary_dest = Path("crates/openburnbar-domain-core/src/legacy/ordinary.txt")
    _git(repository, "mv", str(sensitive_target), str(ordinary_dest))
    _commit(repository, "rename sensitive target to ordinary name")
    branch_head = _git(repository, "rev-parse", "HEAD")

    _git(repository, "checkout", "main")
    _write(repository, Path("main-advance.txt"), "default branch advanced\n")
    _commit(repository, "default branch advanced")
    current_base = _git(repository, "rev-parse", "HEAD")
    _git(repository, "checkout", branch_head)

    assert not _is_ancestor(repository, current_base, branch_head)

    with pytest.raises(GATE.GateError):
        GATE.run_gate(repository, LEDGER_PATH, base_ref=current_base)


def test_rename_immutable_artifact_to_ordinary_name_stays_fail_closed(tmp_path: Path) -> None:
    """Renaming an immutable receipt artifact to an ordinary path is deletion-sensitive."""
    repository = _repository(tmp_path)
    _materialize_ledger_tree(repository, _bootstrap_ledger())
    immutable_artifact = IMMUTABLE_ROOTS[0] / "quota.claude_statusline" / "0" / "promotion.json"
    _write(repository, immutable_artifact, json.dumps({"immutable": True}))
    _write(
        repository,
        REVIEWERS_PATH,
        json.dumps(
            {
                "schemaVersion": 1,
                "reviewers": [
                    {"handle": "@domain-owner", "reviewClasses": ["domain_owner"]},
                    {"handle": "@crypto-security", "reviewClasses": ["security_crypto"]},
                ],
            }
        ),
    )
    older_main = _commit(repository, "seed immutable artifact")

    _git(repository, "checkout", "-b", "feature")
    ordinary_dest = Path("config/ordinary.txt")
    _git(repository, "mv", str(immutable_artifact), str(ordinary_dest))
    _commit(repository, "rename immutable artifact to ordinary name")
    branch_head = _git(repository, "rev-parse", "HEAD")

    _git(repository, "checkout", "main")
    _write(repository, Path("main-advance.txt"), "default branch advanced\n")
    _commit(repository, "default branch advanced")
    current_base = _git(repository, "rev-parse", "HEAD")
    _git(repository, "checkout", branch_head)

    assert not _is_ancestor(repository, current_base, branch_head)

    with pytest.raises(GATE.GateError):
        GATE.run_gate(repository, LEDGER_PATH, base_ref=current_base)
