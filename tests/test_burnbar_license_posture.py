import pytest

from scripts.ci.check_burnbar_license_posture import FORBIDDEN_PRODUCT_CLAIMS, ROOT, all_checks


def is_burnbar_agpl_product_tree() -> bool:
    license_path = ROOT / "LICENSE"
    readiness_path = ROOT / "third_party/libsignal/runtime-readiness.json"
    libsignal_license_path = ROOT / "Vendor/libsignal/LICENSE"
    return (
        license_path.is_file()
        and "GNU AFFERO GENERAL PUBLIC LICENSE" in license_path.read_text(encoding="utf-8")
        and readiness_path.is_file()
        and libsignal_license_path.is_file()
    )


def test_burnbar_agpl_product_license_posture_is_complete() -> None:
    if not is_burnbar_agpl_product_tree():
        pytest.skip("BurnBar AGPL product posture checks only run in the product tree")

    checks = all_checks()

    failures = [f"{check.name}: {check.details}" for check in checks if not check.ok]

    assert failures == []


def test_license_posture_workflow_runs_all_release_gates() -> None:
    workflow = (ROOT / ".github/workflows/license-posture.yml").read_text(encoding="utf-8")

    assert "actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2" in workflow
    assert "actions/setup-python@a309ff8b426b58ec0e2a45f0f869d46889d02405 # v5" in workflow
    assert "python scripts/ci/check_burnbar_license_posture.py" in workflow
    assert "python scripts/ci/check_libsignal_runtime_readiness.py" in workflow
    assert "python scripts/ci/write_burnbar_source_provenance.py --check" in workflow
    # The posture lane must check out the libsignal submodule (or product-tree
    # detection silently skips every gate) and must actually run the
    # compliance test suite.
    assert "submodules: true" in workflow
    assert "python -m pytest tests/ -q" in workflow
    assert "python scripts/verify_burnbar_mit_pr_clean.py --base" in workflow
    assert "Detect BurnBar AGPL product tree" in workflow
    assert "third_party/libsignal/runtime-readiness.json" in workflow
    assert "Vendor/libsignal/LICENSE" in workflow
    assert "third_party/libsignal/manifest.json" not in workflow
    assert "run_product_checks=true" in workflow
    assert "steps.product-tree.outputs.run_product_checks == 'true'" in workflow

    # The MIT upstream scan must stay gated; running it on the BurnBar product
    # tree would correctly flag the AGPL Signal lane and make every product PR
    # fail for the wrong reason.
    assert "github.event.pull_request.base.repo.full_name == 'NousResearch/hermes-agent'" in workflow
    assert "inputs.run_mit_upstream_scan == 'true'" in workflow


def test_product_claim_hygiene_blocks_signal_class_language() -> None:
    signal_class_rules = [
        name for name, pattern in FORBIDDEN_PRODUCT_CLAIMS if pattern.search("Signal-class recovery")
    ]

    assert signal_class_rules == ["Signal-class claim"]


# ---------------------------------------------------------------------------
# MIT upstream graft boundary: root manifests are upstream territory.
# Absence is only acceptable when README deliberately declares the boundary;
# a present-but-wrong manifest must always fail.
# ---------------------------------------------------------------------------

import json as _json  # noqa: E402

import scripts.ci.check_burnbar_license_posture as posture  # noqa: E402


def _graft_root(tmp_path, *, boundary_line: bool):
    readme = tmp_path / "README.md"
    if boundary_line:
        readme.write_text(
            "BurnBar is AGPL-3.0-only. The Nous/Hermes gateway contribution path remains MIT-compatible.\n",
            encoding="utf-8",
        )
    else:
        readme.write_text("BurnBar is AGPL-3.0-only.\n", encoding="utf-8")
    return tmp_path


def test_absent_root_manifests_pass_only_with_declared_graft_boundary(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(posture, "ROOT", _graft_root(tmp_path, boundary_line=True))

    assert posture.check_pyproject_license().ok
    assert posture.check_package_license().ok
    assert posture.check_package_lock_license().ok


def test_absent_root_manifests_fail_without_declared_graft_boundary(tmp_path, monkeypatch) -> None:
    monkeypatch.setattr(posture, "ROOT", _graft_root(tmp_path, boundary_line=False))

    assert not posture.check_pyproject_license().ok
    assert not posture.check_package_license().ok
    assert not posture.check_package_lock_license().ok


def test_present_root_manifests_must_declare_agpl_even_at_graft_root(tmp_path, monkeypatch) -> None:
    root = _graft_root(tmp_path, boundary_line=True)
    (root / "pyproject.toml").write_text('[project]\nname = "x"\nlicense = "MIT"\n', encoding="utf-8")
    (root / "package.json").write_text(_json.dumps({"license": "MIT"}), encoding="utf-8")
    (root / "package-lock.json").write_text(
        _json.dumps({"packages": {"": {"license": "MIT", "workspaces": ["packages/*"]}}}), encoding="utf-8"
    )
    monkeypatch.setattr(posture, "ROOT", root)

    assert not posture.check_pyproject_license().ok
    assert not posture.check_package_license().ok
    assert not posture.check_package_lock_license().ok


def test_app_legal_surface_skips_only_when_surface_tree_is_absent(tmp_path, monkeypatch) -> None:
    root = _graft_root(tmp_path, boundary_line=True)
    monkeypatch.setattr(posture, "ROOT", root)

    by_name = {check.name: check for check in posture.check_app_legal_surfaces()}
    desktop = by_name["apps/desktop/README.md legal surface"]
    assert desktop.ok
    assert "skipped" in desktop.details

    # The moment the surface tree exists, a missing README is a hard failure.
    (root / "apps/desktop").mkdir(parents=True)
    by_name = {check.name: check for check in posture.check_app_legal_surfaces()}
    assert not by_name["apps/desktop/README.md legal surface"].ok
