"""Negative + positive tests for counsel-approval SIGNATURE verification.

These exercise the release-gate path (``require_approved=True``) of
``validate_legal_release_review`` end to end with a real openssl keypair:

* a tampered document (sha256 mismatch) MUST fail,
* a signature made by the wrong key MUST fail,
* a public key that does not match the pinned counsel fingerprint MUST fail,
* a public key introduced in the same commit as the approval MUST fail,
* and only a correct sha256 + valid signature + pinned key + clean provenance
  passes.

The whole point of the gate is that an approval is NOT trusted on the evidence
JSON's say-so: the signing key is pinned in source and the signature is
cryptographically verified. If openssl is unavailable the suite is skipped
honestly rather than passing blind.
"""

from __future__ import annotations

import hashlib
import shutil
import subprocess
from pathlib import Path

import pytest

import scripts.ci.check_agpl_legal_release_review as gate
from scripts.ci.check_agpl_legal_release_review import validate_legal_release_review

OPENSSL = shutil.which("openssl")
GIT = shutil.which("git")

pytestmark = pytest.mark.skipif(
    OPENSSL is None or GIT is None,
    reason="signature gate tests require openssl and git on PATH",
)


def _run(*args: str, cwd: Path | None = None) -> None:
    subprocess.run(list(args), cwd=str(cwd) if cwd else None, check=True, capture_output=True)


def _gen_keypair(tmp_path: Path, stem: str) -> tuple[Path, Path]:
    """Generate an EC P-256 keypair; return (private_pem, public_pem)."""
    assert OPENSSL is not None
    priv = tmp_path / f"{stem}.key.pem"
    pub = tmp_path / f"{stem}.pub.pem"
    _run(OPENSSL, "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", str(priv))
    _run(OPENSSL, "pkey", "-in", str(priv), "-pubout", "-out", str(pub))
    return priv, pub


def _sign(private_pem: Path, document: Path, signature: Path) -> None:
    assert OPENSSL is not None
    _run(OPENSSL, "dgst", "-sha256", "-sign", str(private_pem), "-out", str(signature), str(document))


def _pubkey_fingerprint(public_pem: Path) -> str:
    assert OPENSSL is not None
    der = subprocess.run(
        [OPENSSL, "pkey", "-pubin", "-in", str(public_pem), "-outform", "DER"],
        check=True,
        capture_output=True,
    ).stdout
    return hashlib.sha256(der).hexdigest()


def _base_approval_review(*, doc_rel: str, sig_rel: str, key_rel: str, doc_sha: str) -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "reviewStatus": "approved",
        "reviewedAt": "2026-06-11T00:00:00Z",
        "reviewer": "external counsel record",
        "reviewerRole": "external_counsel",
        "scope": [
            "AGPL-3.0-only product license",
            "Signal/libsignal/SPQR product dependency",
            "corresponding source for shipped apps",
            "hosted gateway network source obligations",
            "app store and commercial distribution terms",
            "MIT-compatible Nous/Hermes upstream boundary",
        ],
        "distributionChannels": [
            "Apple App Store and TestFlight",
            "Google Play",
            "direct download",
            "hosted gateway network service",
            "commercial distribution",
        ],
        "reviewedArtifacts": ["LICENSE"],
        "notes": "Approved for this release record with counsel-reviewed scope.",
        "approval": {
            "reviewerName": "Real Counsel LLP",
            "approvedAt": "2026-06-11T00:00:00Z",
            "documentPath": doc_rel,
            "documentSha256": doc_sha,
            "signatureFormat": "openssl-sha256-ecdsa",
            "signaturePath": sig_rel,
            "publicKeyPath": key_rel,
        },
    }


def _init_repo_with_key_in_prior_commit(repo: Path, key_pub: Path, key_rel: str) -> None:
    """Lay out a git repo where the counsel key is committed BEFORE the approval.

    The approval document/signature are left uncommitted (working tree), so the
    "key introduced in the same diff" guard sees the key in HEAD~1.
    """
    _run(GIT, "init", "-q", cwd=repo)
    _run(GIT, "config", "user.email", "t@example.com", cwd=repo)
    _run(GIT, "config", "user.name", "t", cwd=repo)
    key_dest = repo / key_rel
    key_dest.parent.mkdir(parents=True, exist_ok=True)
    key_dest.write_bytes(key_pub.read_bytes())
    _run(GIT, "add", key_rel, cwd=repo)
    _run(GIT, "commit", "-q", "-m", "pin counsel key", cwd=repo)
    # A second, unrelated commit so HEAD~1 exists and does not touch the key.
    (repo / "README.md").write_text("x", encoding="utf-8")
    _run(GIT, "add", "README.md", cwd=repo)
    _run(GIT, "commit", "-q", "-m", "unrelated", cwd=repo)


@pytest.fixture()
def signed_release(tmp_path, monkeypatch):
    """A repo with a valid signed approval whose key is pinned + prior-committed."""
    repo = tmp_path / "repo"
    repo.mkdir()
    priv, pub = _gen_keypair(tmp_path, "counsel")

    key_rel = "docs/legal/counsel-signing-key.pub.pem"
    doc_rel = "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md"
    sig_rel = "docs/legal/approval.sig"

    _init_repo_with_key_in_prior_commit(repo, pub, key_rel)

    document = repo / doc_rel
    document.parent.mkdir(parents=True, exist_ok=True)
    document.write_text("Counsel approves this AGPL release posture.\n", encoding="utf-8")
    signature = repo / sig_rel
    _sign(priv, document, signature)
    doc_sha = hashlib.sha256(document.read_bytes()).hexdigest()

    monkeypatch.setattr(gate, "COUNSEL_PUBLIC_KEY_SHA256", _pubkey_fingerprint(pub))

    review = _base_approval_review(doc_rel=doc_rel, sig_rel=sig_rel, key_rel=key_rel, doc_sha=doc_sha)
    return {
        "repo": repo,
        "review": review,
        "priv": priv,
        "document": document,
        "signature": signature,
        "doc_rel": doc_rel,
        "sig_rel": sig_rel,
        "key_rel": key_rel,
    }


def _approval_errors(errors: list[str]) -> list[str]:
    # The crypto gate lives entirely under the `approval.*`/signature/document
    # surface; required-artifact/scope checks are orthogonal and covered by the
    # sibling test module, so this isolates the signature behaviour under test.
    keys = ("approval", "signature", "documentSha256", "counsel signing key", "pinned counsel")
    return [e for e in errors if any(k in e for k in keys)]


def test_valid_signed_approval_passes(signed_release):
    errors = validate_legal_release_review(
        signed_release["review"], repo_root=signed_release["repo"], require_approved=True
    )
    assert _approval_errors(errors) == [], errors


def test_tampered_document_fails_sha256(signed_release):
    # Document changes AFTER the recorded sha256 / signature -> integrity break.
    signed_release["document"].write_text("Counsel approves NOTHING.\n", encoding="utf-8")
    errors = validate_legal_release_review(
        signed_release["review"], repo_root=signed_release["repo"], require_approved=True
    )
    assert any("documentSha256 does not match" in e for e in errors), errors


def test_wrong_signature_fails_verification(signed_release):
    # Re-sign with a different key but keep the pinned key + correct sha256.
    other_priv, _ = _gen_keypair(signed_release["repo"].parent, "impostor")
    _sign(other_priv, signed_release["document"], signed_release["signature"])
    errors = validate_legal_release_review(
        signed_release["review"], repo_root=signed_release["repo"], require_approved=True
    )
    assert any("signature failed verification" in e for e in errors), errors


def test_unpinned_key_is_rejected(signed_release):
    # Swap the on-disk public key for one whose fingerprint is not pinned.
    impostor_priv, impostor_pub = _gen_keypair(signed_release["repo"].parent, "impostor2")
    (signed_release["repo"] / signed_release["key_rel"]).write_bytes(impostor_pub.read_bytes())
    # The impostor even signs the document, so only the PIN stops them.
    _sign(impostor_priv, signed_release["document"], signed_release["signature"])
    errors = validate_legal_release_review(
        signed_release["review"], repo_root=signed_release["repo"], require_approved=True
    )
    assert any("does not match the pinned counsel signing key" in e for e in errors), errors


def test_key_introduced_in_same_diff_is_rejected(signed_release):
    repo = signed_release["repo"]
    # Modify the pinned key file and commit it together with the approval state,
    # so HEAD touches publicKeyPath: a self-certifying approval.
    key_path = repo / signed_release["key_rel"]
    key_path.write_bytes(key_path.read_bytes())  # rewrite same bytes -> tracked change requires content change
    key_path.write_text(key_path.read_text(encoding="utf-8") + "\n", encoding="utf-8")
    _run(GIT, "add", signed_release["key_rel"], cwd=repo)
    _run(GIT, "commit", "-q", "-m", "approval + key in one diff", cwd=repo)
    errors = validate_legal_release_review(
        signed_release["review"], repo_root=repo, require_approved=True
    )
    assert any("same commit as this" in e for e in errors), errors


def test_placeholder_pin_fails_closed(signed_release, monkeypatch):
    # Until counsel pins a real fingerprint, no approval can pass — fail-closed,
    # never green-while-blind.
    monkeypatch.setattr(gate, "COUNSEL_PUBLIC_KEY_SHA256", gate.COUNSEL_KEY_PLACEHOLDER)
    errors = validate_legal_release_review(
        signed_release["review"], repo_root=signed_release["repo"], require_approved=True
    )
    assert any("counsel signing key is not pinned" in e for e in errors), errors
