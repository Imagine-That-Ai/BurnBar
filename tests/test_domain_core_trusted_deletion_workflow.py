from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/domain-core-deletion-guard.yml"


def test_trusted_deletion_guard_runs_only_default_branch_code() -> None:
    source = WORKFLOW.read_text()

    for marker in (
        "pull_request_target:",
        "pull_request_review:",
        "Domain Core Trusted Deletion Guard",
        "ref: ${{ github.event.pull_request.base.sha }}",
        "path: trusted",
        "ref: ${{ github.event.pull_request.head.sha }}",
        "path: candidate",
        "persist-credentials: false",
        "TRUSTED_ROOT: ${{ github.workspace }}/trusted",
        "CANDIDATE_ROOT: ${{ github.workspace }}/candidate",
        'node "$TRUSTED_ROOT/scripts/ci/verify-domain-core-default-branch-controls.mjs"',
        'python3 "$TRUSTED_ROOT/scripts/ci/verify-domain-core-legacy-deletion.py"',
        '--repo-root "$CANDIDATE_ROOT"',
        '--deletion-head "$HEAD_SHA"',
        "DOMAIN_CORE_EVIDENCE_CACHE: ${{ runner.temp }}/domain-core-evidence-cache",
    ):
        assert marker in source

    assert "candidate/scripts/" not in source
    assert "python3 candidate/" not in source
    assert "node candidate/" not in source


def test_trusted_deletion_guard_uses_workspace_anchored_checkout_paths() -> None:
    source = WORKFLOW.read_text()

    assert 'git -C "$TRUSTED_ROOT" rev-parse HEAD' in source
    assert 'git -C "$CANDIDATE_ROOT" rev-parse HEAD' in source
    assert "git -C trusted" not in source
    assert "git -C candidate" not in source
    assert "$GITHUB_WORKSPACE/candidate" not in source
