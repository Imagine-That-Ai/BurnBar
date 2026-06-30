#!/usr/bin/env python3
"""Self-tests for the BurnBar product release preflight entrypoint."""

from __future__ import annotations

import importlib.util
import json
import sys
import tempfile
from collections.abc import Callable
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
PREFLIGHT = ROOT / "scripts/ci/check_burnbar_release_preflight.py"


def load_preflight_module():
    spec = importlib.util.spec_from_file_location("check_burnbar_release_preflight_under_test", PREFLIGHT)
    if spec is None or spec.loader is None:
        raise AssertionError(f"could not load release preflight script: {PREFLIGHT}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def write_fake_ci_modules(repo_root: Path) -> None:
    ci_dir = repo_root / "scripts" / "ci"
    ci_dir.mkdir(parents=True)
    (ci_dir / "write_burnbar_source_provenance.py").write_text(
        "\n".join(
            [
                "def build_source_provenance_manifest(*, repo_root):",
                "    return {'repoRoot': str(repo_root)}",
                "",
                "def release_preflight_blockers(manifest):",
                "    return ['runtime-blocker']",
                "",
                "def source_integrity_blockers(manifest):",
                "    return ['source-blocker']",
                "",
            ]
        ),
        encoding="utf-8",
    )
    (ci_dir / "check_agpl_legal_release_review.py").write_text(
        "\n".join(
            [
                "OWNER_ATTESTED_SOFT_APPROVAL_STATUS = 'owner_attested_soft_approval'",
                "",
                "def validate_legal_release_review(data, *, require_approved):",
                "    return []",
                "",
                "def validate_owner_attested_soft_approval(data, *, repo_root, expected_release_tag):",
                "    if expected_release_tag != 'v1.0.8':",
                "        return [f'expected release tag mismatch: {expected_release_tag}']",
                "    return []",
                "",
            ]
        ),
        encoding="utf-8",
    )


def with_shadow_scripts_package(callback: Callable[[Path], None]) -> None:
    old_path = list(sys.path)
    with tempfile.TemporaryDirectory() as tmp:
        shadow_root = Path(tmp)
        fake_repo = shadow_root / "repo"
        write_fake_ci_modules(fake_repo)
        shadow_scripts = shadow_root / "scripts"
        shadow_scripts.mkdir()
        (shadow_scripts / "__init__.py").write_text("# conflicting package on PYTHONPATH\n", encoding="utf-8")
        sys.path.insert(0, str(shadow_root))
        try:
            callback(fake_repo)
        finally:
            sys.path[:] = old_path


def test_load_ci_module_ignores_conflicting_scripts_package() -> None:
    preflight = load_preflight_module()

    def run(fake_repo: Path) -> None:
        loaded = preflight.load_ci_module(fake_repo, "write_burnbar_source_provenance")
        expected = (fake_repo / "scripts/ci/write_burnbar_source_provenance.py").resolve()
        assert Path(loaded.__file__).resolve() == expected

    with_shadow_scripts_package(run)


def test_load_ci_module_rejects_path_like_names() -> None:
    preflight = load_preflight_module()
    try:
        preflight.load_ci_module(ROOT, "../write_burnbar_source_provenance")
    except ValueError as exc:
        assert "helper name is invalid" in str(exc)
    else:
        raise AssertionError("path-like helper name was accepted")


def test_source_preflight_ignores_conflicting_scripts_package() -> None:
    preflight = load_preflight_module()

    def run(fake_repo: Path) -> None:
        blockers = preflight.source_provenance_blockers(fake_repo, include_runtime_readiness=False)
        assert blockers == ["source-blocker"]

    with_shadow_scripts_package(run)


def test_legal_preflight_ignores_conflicting_scripts_package() -> None:
    preflight = load_preflight_module()

    def run(fake_repo: Path) -> None:
        missing_evidence = fake_repo / "launch-evidence/definitely-missing-release-review.json"
        blockers = preflight.legal_review_blockers(missing_evidence, fake_repo)
        assert blockers == [f"legal release review evidence is missing: {missing_evidence}"]

    with_shadow_scripts_package(run)


def test_owner_emergency_preflight_consumes_structured_attestation() -> None:
    preflight = load_preflight_module()

    def run(fake_repo: Path) -> None:
        evidence = fake_repo / "launch-evidence/latest-agpl-store-legal-packet.json"
        evidence.parent.mkdir(parents=True)
        evidence.write_text(
            json.dumps({"status": "owner_attested_soft_approval", "ownerAttestation": {}}),
            encoding="utf-8",
        )
        blockers = preflight.legal_review_blockers(
            evidence,
            fake_repo,
            allow_owner_emergency_approval=True,
            expected_release_tag="v1.0.8",
        )
        assert blockers == []

    with_shadow_scripts_package(run)


def test_owner_emergency_preflight_rejects_stale_release_tag() -> None:
    preflight = load_preflight_module()

    def run(fake_repo: Path) -> None:
        evidence = fake_repo / "launch-evidence/latest-agpl-store-legal-packet.json"
        evidence.parent.mkdir(parents=True)
        evidence.write_text(
            json.dumps({"status": "owner_attested_soft_approval", "ownerAttestation": {}}),
            encoding="utf-8",
        )
        blockers = preflight.legal_review_blockers(
            evidence,
            fake_repo,
            allow_owner_emergency_approval=True,
            expected_release_tag="v1.0.9",
        )
        assert blockers == ["owner emergency approval: expected release tag mismatch: v1.0.9"]

    with_shadow_scripts_package(run)


def test_owner_emergency_runtime_bypass_requires_valid_attestation() -> None:
    preflight = load_preflight_module()

    def run(fake_repo: Path) -> None:
        evidence = fake_repo / "launch-evidence/latest-agpl-store-legal-packet.json"
        evidence.parent.mkdir(parents=True)
        evidence.write_text(
            json.dumps({"status": "owner_attested_soft_approval", "ownerAttestation": {}}),
            encoding="utf-8",
        )
        blockers = preflight.collect_blockers(
            repo_root=fake_repo,
            legal_evidence=evidence,
            allow_owner_emergency_approval=True,
            expected_release_tag="v1.0.9",
        )
        assert "runtime-blocker" in blockers
        assert "owner emergency approval: expected release tag mismatch: v1.0.9" in blockers

    with_shadow_scripts_package(run)


def main() -> int:
    tests = [
        test_load_ci_module_ignores_conflicting_scripts_package,
        test_load_ci_module_rejects_path_like_names,
        test_source_preflight_ignores_conflicting_scripts_package,
        test_legal_preflight_ignores_conflicting_scripts_package,
        test_owner_emergency_preflight_consumes_structured_attestation,
        test_owner_emergency_preflight_rejects_stale_release_tag,
        test_owner_emergency_runtime_bypass_requires_valid_attestation,
    ]
    for test in tests:
        test()
    print(f"PASS: {len(tests)} release preflight import tests passed")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
