from scripts.ci.check_agpl_legal_release_review import validate_legal_release_review


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
