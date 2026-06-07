import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def test_pending_legal_template_is_valid_but_not_approval():
    result = subprocess.run(
        [
            "python3",
            "scripts/ci/check_agpl_legal_release_review.py",
            "--evidence",
            "docs/legal/agpl-release-review.evidence.template.json",
            "--allow-pending",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert "PASS" in result.stdout
    assert "NOT release-approved" in result.stdout


def test_pending_legal_template_fails_release_approval():
    result = subprocess.run(
        [
            "python3",
            "scripts/ci/check_agpl_legal_release_review.py",
            "--evidence",
            "docs/legal/agpl-release-review.evidence.template.json",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert result.returncode != 0
    assert "legal review is not approved" in result.stderr


def test_forged_approved_legal_evidence_requires_detached_signature(tmp_path):
    evidence = tmp_path / "forged-legal.json"
    evidence.write_text(
        json.dumps(
            {
                "schemaVersion": 1,
                "reviewStatus": "approved",
                "reviewerRole": "external_counsel",
                "distributionChannels": ["Mac App Store", "hosted service"],
                "approval": {
                    "reviewerName": "Totally Fake Counsel LLP",
                    "approvedAt": "2026-06-07T00:00:00Z",
                    "documentPath": "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md",
                    "documentSha256": "0" * 64,
                    "signatureFormat": "openssl-sha256-rsa",
                },
            }
        ),
        encoding="utf-8",
    )

    result = subprocess.run(
        ["python3", "scripts/ci/check_agpl_legal_release_review.py", "--evidence", str(evidence)],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert result.returncode != 0
    assert "approval.signaturePath is required" in result.stderr
    assert "approval.publicKeyPath is required" in result.stderr
