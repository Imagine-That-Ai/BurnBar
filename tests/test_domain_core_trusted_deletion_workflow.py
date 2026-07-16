import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/domain-core-deletion-guard.yml"


def test_trusted_deletion_guard_runs_only_default_branch_code() -> None:
    source = WORKFLOW.read_text()

    for marker in (
        "pull_request_target:",
        "Domain Core Trusted Deletion Guard",
        "ref: ${{ github.event.pull_request.base.sha }}",
        "path: trusted",
        "ref: ${{ github.event.pull_request.head.sha }}",
        "path: candidate",
        "persist-credentials: false",
        "TRUSTED_ROOT: ${{ github.workspace }}/trusted",
        "CANDIDATE_ROOT: ${{ github.workspace }}/candidate",
        'python3 "$TRUSTED_ROOT/scripts/ci/verify-domain-core-legacy-deletion.py"',
        '--repo-root "$CANDIDATE_ROOT"',
        '--deletion-head "$HEAD_SHA"',
        "DOMAIN_CORE_EVIDENCE_CACHE: ${{ runner.temp }}/domain-core-evidence-cache",
    ):
        assert marker in source

    assert "candidate/scripts/" not in source
    assert "python3 candidate/" not in source
    assert "node candidate/" not in source
    assert "pull_request_review:" not in source


def test_trusted_deletion_guard_uses_workspace_anchored_checkout_paths() -> None:
    source = WORKFLOW.read_text()

    assert 'git -C "$TRUSTED_ROOT" rev-parse HEAD' in source
    assert 'git -C "$CANDIDATE_ROOT" rev-parse HEAD' in source
    assert "git -C trusted" not in source
    assert "git -C candidate" not in source
    assert "$GITHUB_WORKSPACE/candidate" not in source


def test_domain_core_aggregate_gates_are_required_after_the_ledger_lands() -> None:
    governance = json.loads((ROOT / "governance/branch-protection.main.json").read_text())
    required = governance["required_status_checks"]["contexts"]
    pending = governance["_pending_required_status_checks"]["contexts"]

    assert "Domain Core Trusted Deletion Guard" in required
    assert "Domain Core PR Gate" in required
    assert "Domain Core Trusted Deletion Guard" not in pending
    assert "Domain Core PR Gate" not in pending
