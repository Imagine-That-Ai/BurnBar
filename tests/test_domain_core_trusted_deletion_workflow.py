import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/domain-core-deletion-guard.yml"


def test_required_guard_is_unconditional_and_runs_only_default_branch_code() -> None:
    source = WORKFLOW.read_text()
    trigger_block = source.split("on:\n", 1)[1].split("\npermissions:", 1)[0]
    trigger_lines = [line.strip() for line in trigger_block.splitlines() if line.strip()]

    assert trigger_lines == [
        "pull_request_target:",
        "types: [opened, synchronize, reopened, ready_for_review]",
    ]
    assert "\n    if:" not in source
    for marker in (
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

    assert source.count("persist-credentials: false") == 2
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


def test_domain_core_trusted_guard_is_required_and_pr_gate_is_pending() -> None:
    governance = json.loads((ROOT / "governance/branch-protection.main.json").read_text())
    required = governance["required_status_checks"]["contexts"]
    pending = governance["_pending_required_status_checks"]["contexts"]

    assert "Domain Core Trusted Deletion Guard" in required
    assert "Domain Core Trusted Deletion Guard" not in pending
    assert "Domain Core PR Gate" not in required
    assert "Domain Core PR Gate" in pending
