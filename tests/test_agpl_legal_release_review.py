import json
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


def _prepare_temp_legal_repo(tmp_path: Path) -> Path:
    repo = tmp_path / "repo"
    for rel in (
        "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md",
        "docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md",
    ):
        dest = repo / rel
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / rel, dest)
    (repo / "launch-evidence").mkdir(parents=True, exist_ok=True)
    return repo


def _create_signed_legal_packet_inputs(repo: Path, tmp_path: Path) -> tuple[Path, Path]:
    private_key = tmp_path / "counsel-private.pem"
    public_key = repo / "launch-evidence/counsel-public.pem"
    signature = repo / "launch-evidence/agpl-release-review.sig"
    subprocess.run(["openssl", "genrsa", "-out", str(private_key), "2048"], check=True, stdout=subprocess.PIPE)
    subprocess.run(
        ["openssl", "rsa", "-in", str(private_key), "-pubout", "-out", str(public_key)],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    subprocess.run(
        [
            "openssl",
            "dgst",
            "-sha256",
            "-sign",
            str(private_key),
            "-out",
            str(signature),
            str(repo / "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md"),
        ],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return signature, public_key


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


def test_attach_legal_release_approval_verifies_signature_and_writes_packet(tmp_path):
    repo = _prepare_temp_legal_repo(tmp_path)
    signature, public_key = _create_signed_legal_packet_inputs(repo, tmp_path)
    output = repo / "launch-evidence/latest-agpl-store-legal-packet.json"

    check_result = subprocess.run(
        [
            "python3",
            "scripts/ci/attach_agpl_legal_release_approval.py",
            "--repo-root",
            str(repo),
            "--reviewer-name",
            "Example External Counsel LLP",
            "--approved-at",
            "2026-06-08T15:00:00Z",
            "--signature",
            "launch-evidence/agpl-release-review.sig",
            "--public-key",
            "launch-evidence/counsel-public.pem",
            "--use-required-channels",
            "--check",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert check_result.returncode == 0, check_result.stderr
    assert "PASS: AGPL/libsignal legal approval packet verified" in check_result.stderr
    assert not output.exists()

    write_result = subprocess.run(
        [
            "python3",
            "scripts/ci/attach_agpl_legal_release_approval.py",
            "--repo-root",
            str(repo),
            "--reviewer-name",
            "Example External Counsel LLP",
            "--approved-at",
            "2026-06-08T15:00:00Z",
            "--signature",
            "launch-evidence/agpl-release-review.sig",
            "--public-key",
            "launch-evidence/counsel-public.pem",
            "--use-required-channels",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert write_result.returncode == 0, write_result.stderr
    assert output.exists()
    packet = json.loads(output.read_text(encoding="utf-8"))
    assert packet["reviewStatus"] == "approved"
    assert packet["approval"]["signaturePath"] == "launch-evidence/agpl-release-review.sig"
    assert packet["approval"]["publicKeyPath"] == "launch-evidence/counsel-public.pem"

    verify_result = subprocess.run(
        [
            "python3",
            "scripts/ci/check_agpl_legal_release_review.py",
            "--repo-root",
            str(repo),
            "--evidence",
            "launch-evidence/latest-agpl-store-legal-packet.json",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert verify_result.returncode == 0, verify_result.stderr
    assert "signature-verified" in verify_result.stdout


def test_attach_legal_release_approval_rejects_bad_signature(tmp_path):
    repo = _prepare_temp_legal_repo(tmp_path)
    _, public_key = _create_signed_legal_packet_inputs(repo, tmp_path)
    bad_signature = repo / "launch-evidence/bad.sig"
    bad_signature.write_bytes(b"not a valid signature")

    result = subprocess.run(
        [
            "python3",
            "scripts/ci/attach_agpl_legal_release_approval.py",
            "--repo-root",
            str(repo),
            "--reviewer-name",
            "Example External Counsel LLP",
            "--approved-at",
            "2026-06-08T15:00:00Z",
            "--signature",
            "launch-evidence/bad.sig",
            "--public-key",
            "launch-evidence/counsel-public.pem",
            "--use-required-channels",
        ],
        cwd=ROOT,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )

    assert result.returncode != 0
    assert "approval signature verification failed" in result.stderr
    assert not (repo / "launch-evidence/latest-agpl-store-legal-packet.json").exists()
