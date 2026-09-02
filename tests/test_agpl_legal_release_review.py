import hashlib
import shutil
import subprocess
from pathlib import Path

import pytest

import scripts.ci.check_agpl_legal_release_review as agpl_review


ROOT = Path(__file__).resolve().parents[1]

validate_legal_release_review = agpl_review.validate_legal_release_review
validate_owner_attested_soft_approval = agpl_review.validate_owner_attested_soft_approval
validate_owner_emergency_packet_release_binding = (
    agpl_review.validate_owner_emergency_packet_release_binding
)
marketing_version_release_tag = agpl_review.marketing_version_release_tag


def valid_review() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "reviewStatus": "approved",
        "reviewedAt": "2026-06-06T00:00:00Z",
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
        "reviewedArtifacts": [
            ".github/workflows/license-posture.yml",
            "LICENSE",
            "THIRD_PARTY_NOTICES.md",
            "docs/legal/SOURCE_AVAILABILITY.md",
            "docs/legal/DEPENDENCY_LICENSE_MANIFEST.md",
            "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md",
            "docs/legal/agpl-release-review.evidence.template.json",
            "docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md",
            "functions/package.json",
            "packages/signal-envelope-contracts/package.json",
            "scripts/ci/check_burnbar_license_posture.py",
            "scripts/ci/check_libsignal_runtime_readiness.py",
            "scripts/ci/write_burnbar_source_provenance.py",
            "scripts/verify_burnbar_mit_pr_clean.py",
            "third_party/libsignal/runtime-readiness.json",
        ],
        "notes": "Approved for this release record with counsel-reviewed AGPL and store distribution scope.",
    }


def test_validates_approved_legal_release_review() -> None:
    assert validate_legal_release_review(valid_review()) == []


def valid_owner_attestation() -> dict[str, object]:
    review = valid_review()
    review["status"] = agpl_review.OWNER_ATTESTED_SOFT_APPROVAL_STATUS
    review["reviewStatus"] = agpl_review.OWNER_ATTESTED_SOFT_APPROVAL_STATUS
    review["repo"] = {"releaseTag": "v1.0.8"}
    review["ownerAttestation"] = {
        "ownerName": "Alberto Nunez",
        "ownerGitHub": "Ajnunezg",
        "ownerRole": "release_owner",
        "attestedAt": "2026-06-30T05:33:10Z",
        "counselName": "Heather Meeker",
        "approvalType": "soft_approval",
        "emergencyReason": "Publish the current signed and notarized macOS direct-download artifact.",
        "approvalBoundary": "Emergency owner-attested soft approval for v1.0.8.",
        "ownerStatement": "As owner, Alberto Nunez attests that Heather Meeker gave soft approval.",
        "followUpRequired": True,
    }
    return review


def test_validates_owner_attested_soft_approval() -> None:
    assert validate_owner_attested_soft_approval(valid_owner_attestation(), expected_release_tag="v1.0.8") == []


def test_owner_emergency_packet_allows_forward_successor_binding(tmp_path: Path) -> None:
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    (repo_root / "project.yml").write_text('    MARKETING_VERSION: "1.0.37"\n', encoding="utf-8")

    data = valid_owner_attestation()
    data["repo"]["releaseTag"] = "v1.0.39"  # type: ignore[index]

    assert validate_owner_emergency_packet_release_binding(data, repo_root=repo_root) == []
    assert validate_owner_attested_soft_approval(data, expected_release_tag="v1.0.39") == []


def test_owner_emergency_packet_rejects_stale_binding_behind_marketing_version(
    tmp_path: Path,
) -> None:
    repo_root = tmp_path / "repo"
    repo_root.mkdir()
    (repo_root / "project.yml").write_text('    MARKETING_VERSION: "1.0.37"\n', encoding="utf-8")

    data = valid_owner_attestation()
    data["repo"]["releaseTag"] = "v1.0.36"  # type: ignore[index]

    errors = validate_owner_emergency_packet_release_binding(data, repo_root=repo_root)

    assert errors == [
        "repo.releaseTag must not be behind the committed marketing version "
        "'v1.0.37'; found stale 'v1.0.36'"
    ]


def test_owner_attested_soft_approval_is_bound_to_expected_release_tag() -> None:
    data = valid_owner_attestation()
    data["repo"]["releaseTag"] = "v1.0.7"  # type: ignore[index]

    errors = validate_owner_attested_soft_approval(data, expected_release_tag="v1.0.8")

    assert (
        "repo.releaseTag must name the current release train 'v1.0.8' "
        "(build metadata ignored), found 'v1.0.7'" in errors
    )


def test_owner_attested_soft_approval_accepts_any_build_of_the_bound_train() -> None:
    """A packet bound to v1.0.8 authorizes v1.0.8+repair.N without a rebind
    commit; a packet from another train still fails closed."""
    data = valid_owner_attestation()
    data["repo"]["releaseTag"] = "v1.0.8"  # type: ignore[index]

    assert (
        validate_owner_attested_soft_approval(
            data, expected_release_tag="v1.0.8+repair.3"
        )
        == []
    )

    data["repo"]["releaseTag"] = "v1.0.8+repair.1"  # type: ignore[index]
    assert (
        validate_owner_attested_soft_approval(
            data, expected_release_tag="v1.0.8+repair.9"
        )
        == []
    )

    data["repo"]["releaseTag"] = "v1.0.9"  # type: ignore[index]
    errors = validate_owner_attested_soft_approval(
        data, expected_release_tag="v1.0.8+repair.3"
    )
    assert errors, "a packet from a different train must fail closed"


def test_owner_attested_soft_approval_is_not_signed_counsel_approval() -> None:
    errors = validate_legal_release_review(valid_owner_attestation(), require_approved=True)

    assert "reviewStatus must be 'approved'" in errors


def test_owner_attested_soft_approval_requires_named_owner_and_counsel() -> None:
    data = valid_owner_attestation()
    data["ownerAttestation"]["ownerGitHub"] = "someone-else"  # type: ignore[index]
    data["ownerAttestation"]["counselName"] = "Other Counsel"  # type: ignore[index]

    errors = validate_owner_attested_soft_approval(data, expected_release_tag="v1.0.8")

    assert "ownerAttestation.ownerGitHub must be 'Ajnunezg'" in errors
    assert "ownerAttestation.counselName must be 'Heather Meeker'" in errors


def test_rejects_non_approved_or_placeholder_review() -> None:
    data = valid_review()
    data["reviewStatus"] = "pending"
    data["notes"] = "Not legal advice; placeholder only."

    errors = validate_legal_release_review(data)

    assert "reviewStatus must be 'approved'" in errors
    assert "notes must record the review outcome, not a placeholder disclaimer" in errors


def test_requires_external_counsel_role() -> None:
    data = valid_review()
    data["reviewerRole"] = "internal_engineer"

    errors = validate_legal_release_review(data)

    assert "reviewerRole must be 'external_counsel'" in errors


def test_requires_store_gateway_source_and_mit_boundary_scope() -> None:
    data = valid_review()
    data["scope"] = ["AGPL-3.0-only product license"]

    errors = validate_legal_release_review(data)

    assert (
        "scope missing required item(s): MIT-compatible Nous/Hermes upstream boundary, "
        "Signal/libsignal/SPQR product dependency, app store and commercial distribution terms, "
        "corresponding source for shipped apps, hosted gateway network source obligations"
    ) in errors


def test_requires_distribution_channel_coverage() -> None:
    data = valid_review()
    data["distributionChannels"] = ["direct download"]

    errors = validate_legal_release_review(data)

    assert (
        "distributionChannels missing required item(s): Apple App Store and TestFlight, Google Play, "
        "commercial distribution, hosted gateway network service"
    ) in errors


def test_requires_review_of_load_bearing_release_artifacts() -> None:
    data = valid_review()
    data["reviewedArtifacts"] = ["LICENSE"]

    errors = validate_legal_release_review(data)

    assert len(errors) == 1
    assert errors[0].startswith("reviewedArtifacts missing required artifact(s): ")
    assert ".github/workflows/license-posture.yml" in errors[0]
    assert "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md" in errors[0]
    assert "docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md" in errors[0]
    assert "scripts/ci/check_burnbar_license_posture.py" in errors[0]
    assert "scripts/verify_burnbar_mit_pr_clean.py" in errors[0]


def test_validates_reviewed_artifact_paths_exist_when_repo_root_is_supplied(tmp_path) -> None:
    errors = validate_legal_release_review(valid_review(), repo_root=tmp_path)

    assert "reviewedArtifacts path does not exist: .github/workflows/license-posture.yml" in errors
    assert "reviewedArtifacts path does not exist: scripts/ci/check_burnbar_license_posture.py" in errors


def _materialize_required_artifacts(repo_root: Path) -> None:
    for rel_path in agpl_review.REQUIRED_ARTIFACTS:
        path = repo_root / rel_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(f"reviewed artifact: {rel_path}\n", encoding="utf-8")


def _signed_approval_review(repo_root: Path) -> tuple[dict[str, object], Path]:
    openssl = shutil.which("openssl")
    if openssl is None:
        pytest.skip("openssl is required for AGPL approval signature tests")

    _materialize_required_artifacts(repo_root)
    document = repo_root / "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md"
    document.write_text("Counsel reviewed and approved this release packet.\n", encoding="utf-8")

    private_key = repo_root / "docs/legal/counsel-private.pem"
    public_key = repo_root / "docs/legal/counsel-public.pem"
    signature = repo_root / "docs/legal/agpl-release-review.sig"
    subprocess.run(
        [openssl, "genpkey", "-algorithm", "RSA", "-pkeyopt", "rsa_keygen_bits:2048", "-out", str(private_key)],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        [openssl, "pkey", "-in", str(private_key), "-pubout", "-out", str(public_key)],
        check=True,
        capture_output=True,
    )
    subprocess.run(
        [openssl, "dgst", "-sha256", "-sign", str(private_key), "-out", str(signature), str(document)],
        check=True,
        capture_output=True,
    )

    review = valid_review()
    review["approval"] = {
        "reviewerName": "External Counsel LLP",
        "approvedAt": "2026-06-07T00:00:00Z",
        "documentPath": "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md",
        "documentSha256": hashlib.sha256(document.read_bytes()).hexdigest(),
        "signatureFormat": "openssl-sha256-rsa",
        "signaturePath": "docs/legal/agpl-release-review.sig",
        "publicKeyPath": "docs/legal/counsel-public.pem",
    }
    return review, public_key


def test_require_approved_accepts_valid_signature_under_pinned_counsel_key(tmp_path, monkeypatch) -> None:
    review, public_key = _signed_approval_review(tmp_path)
    fingerprint = agpl_review._public_key_fingerprint(public_key)
    assert fingerprint is not None
    monkeypatch.setattr(agpl_review, "COUNSEL_PUBLIC_KEY_SHA256", fingerprint)
    monkeypatch.setattr(agpl_review, "_approval_diff_touches_public_key", lambda *_args: False)

    errors = validate_legal_release_review(review, repo_root=tmp_path, require_approved=True)

    assert errors == []


def test_require_approved_rejects_unpinned_counsel_key(tmp_path, monkeypatch) -> None:
    review, _public_key = _signed_approval_review(tmp_path)
    monkeypatch.setattr(agpl_review, "_approval_diff_touches_public_key", lambda *_args: False)

    errors = validate_legal_release_review(review, repo_root=tmp_path, require_approved=True)

    assert any("counsel signing key is not pinned" in error for error in errors)


def test_require_approved_rejects_tampered_signed_document(tmp_path, monkeypatch) -> None:
    review, public_key = _signed_approval_review(tmp_path)
    fingerprint = agpl_review._public_key_fingerprint(public_key)
    assert fingerprint is not None
    monkeypatch.setattr(agpl_review, "COUNSEL_PUBLIC_KEY_SHA256", fingerprint)
    monkeypatch.setattr(agpl_review, "_approval_diff_touches_public_key", lambda *_args: False)

    document = tmp_path / "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md"
    document.write_text("Tampered after counsel signed.\n", encoding="utf-8")
    errors = validate_legal_release_review(review, repo_root=tmp_path, require_approved=True)

    assert any("approval.documentSha256 does not match" in error for error in errors)
    assert any("approval signature failed verification" in error for error in errors)


def test_require_approved_rejects_public_key_added_with_approval(tmp_path, monkeypatch) -> None:
    review, public_key = _signed_approval_review(tmp_path)
    fingerprint = agpl_review._public_key_fingerprint(public_key)
    assert fingerprint is not None
    monkeypatch.setattr(agpl_review, "COUNSEL_PUBLIC_KEY_SHA256", fingerprint)
    monkeypatch.setattr(agpl_review, "_approval_diff_touches_public_key", lambda *_args: True)

    errors = validate_legal_release_review(review, repo_root=tmp_path, require_approved=True)

    assert any("approval.publicKeyPath was added or modified in the same commit" in error for error in errors)
