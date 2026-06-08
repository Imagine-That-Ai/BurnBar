#!/usr/bin/env python3
"""Verify BurnBar's AGPL product license posture.

This check is intentionally separate from
``scripts/verify_burnbar_mit_pr_clean.py``:

* this script proves the BurnBar product tree is AGPL-compliant enough to ship
  the Signal/libsignal-backed lane;
* the MIT clean-room script proves a Nous/Hermes upstream PR does not include
  BurnBar's AGPL Signal lane.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tomllib
import zipfile
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


@dataclass(frozen=True)
class Check:
    name: str
    ok: bool
    details: str


FORBIDDEN_PRODUCT_CLAIMS = [
    ("absolute quantum security claim", re.compile(r"\bquantum[- ]proof\b", re.IGNORECASE)),
    ("PQ3 equivalence claim", re.compile(r"\bPQ3[- ]equivalent\b", re.IGNORECASE)),
    ("Signal-class claim", re.compile(r"\bSignal[- ]class\b", re.IGNORECASE)),
]


def read_text(rel_path: str) -> str:
    return (ROOT / rel_path).read_text(encoding="utf-8")


def check_file_contains(rel_path: str, needle: str, name: str) -> Check:
    path = ROOT / rel_path
    if not path.is_file():
        return Check(name, False, f"{rel_path} is missing")
    text = path.read_text(encoding="utf-8")
    if needle not in text:
        return Check(name, False, f"{rel_path} does not contain {needle!r}")
    return Check(name, True, f"{rel_path} contains {needle!r}")


def check_root_license() -> Check:
    return check_file_contains("LICENSE", "GNU AFFERO GENERAL PUBLIC LICENSE", "root AGPL license text")


def check_pyproject_license() -> Check:
    path = ROOT / "pyproject.toml"
    if not path.is_file():
        return Check("pyproject AGPL license", True, "skipped (root has no Python package metadata)")
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    license_expr = data.get("project", {}).get("license")
    if license_expr != "AGPL-3.0-only":
        return Check("pyproject AGPL license", False, f"expected AGPL-3.0-only, found {license_expr!r}")
    return Check("pyproject AGPL license", True, "pyproject.toml declares AGPL-3.0-only")


def check_package_license() -> Check:
    path = ROOT / "package.json"
    if not path.is_file():
        return Check("package AGPL license", True, "skipped (root has no npm package metadata)")
    data = json.loads(path.read_text(encoding="utf-8"))
    license_expr = data.get("license")
    if license_expr != "AGPL-3.0-only":
        return Check("package AGPL license", False, f"expected AGPL-3.0-only, found {license_expr!r}")
    return Check("package AGPL license", True, "package.json declares AGPL-3.0-only")


def check_package_lock_license() -> Check:
    path = ROOT / "package-lock.json"
    if not path.is_file():
        return Check("package-lock AGPL license", True, "skipped (root has no npm lockfile)")
    data = json.loads(path.read_text(encoding="utf-8"))
    root = data.get("packages", {}).get("", {})
    license_expr = root.get("license")
    if license_expr != "AGPL-3.0-only":
        return Check("package-lock AGPL license", False, f"expected AGPL-3.0-only, found {license_expr!r}")
    workspaces = root.get("workspaces", [])
    if "packages/*" not in workspaces:
        return Check("package-lock AGPL license", False, "package-lock.json does not include packages/* workspace")
    return Check("package-lock AGPL license", True, "package-lock.json declares AGPL root and product packages workspace")


def check_readme_license() -> Check:
    text = read_text("README.md")
    if "AGPL-3.0-only" not in text:
        return Check("README AGPL posture", False, "README.md does not declare AGPL-3.0-only")
    if "License-MIT" in text or "License: MIT" in text or re.search(r"^MIT [—-] see", text, re.MULTILINE):
        return Check("README AGPL posture", False, "README.md still contains the old MIT badge/summary")
    if "Nous/Hermes gateway contribution path remains MIT-compatible" not in text:
        return Check("README AGPL posture", False, "README.md does not document the MIT upstream boundary")
    return Check("README AGPL posture", True, "README.md declares AGPL product posture and MIT upstream boundary")


def check_app_legal_surfaces() -> list[Check]:
    surfaces = {
        "services/hosted-mcp/src/sourceMetadata.ts": ['license: "AGPL-3.0-only"'],
        "services/hermes-realtime-relay/src/sourceMetadata.ts": ['license: "AGPL-3.0-only"'],
        "functions/src/sourceMetadata.ts": ['license: "AGPL-3.0-only"'],
    }
    checks: list[Check] = []
    for rel_path, needles in surfaces.items():
        path = ROOT / rel_path
        if not path.is_file():
            checks.append(Check(f"{rel_path} legal surface", False, f"{rel_path} is missing"))
            continue
        text = path.read_text(encoding="utf-8")
        missing = [needle for needle in needles if needle not in text]
        if missing:
            checks.append(Check(f"{rel_path} legal surface", False, f"missing {missing!r}"))
        elif "License-MIT" in text or "License: MIT" in text or re.search(r"^MIT [—-] see", text, re.MULTILINE):
            checks.append(Check(f"{rel_path} legal surface", False, "still contains stale MIT product summary"))
        else:
            checks.append(Check(f"{rel_path} legal surface", True, "AGPL product posture is present"))
    return checks


def check_signal_agpl_evidence() -> list[Check]:
    checks = [
        check_file_contains("Vendor/libsignal/LICENSE", "GNU AFFERO GENERAL PUBLIC LICENSE", "libsignal AGPL license"),
        check_file_contains("Vendor/libsignal/Cargo.toml", 'license = "AGPL-3.0-only"', "libsignal Cargo license"),
        check_file_contains("Vendor/libsignal/node/package.json", '"license": "AGPL-3.0-only"', "libsignal npm license"),
        check_file_contains("Vendor/libsignal/Cargo.toml", "SparsePostQuantumRatchet", "Signal SPQR dependency pin"),
    ]
    package_requirements = {
        "packages/libsignal-bridge/package.json": [
            '"name": "@openburnbar/libsignal-bridge"',
            '"license": "AGPL-3.0-only"',
            '"@signalapp/libsignal-client": "0.94.4"',
        ],
        "packages/libsignal-protocol/package.json": [
            '"name": "@openburnbar/libsignal-protocol"',
            '"license": "AGPL-3.0-only"',
            '"@openburnbar/libsignal-bridge": "file:../libsignal-bridge"',
            '"@openburnbar/signal-envelope-contracts": "file:../signal-envelope-contracts"',
        ],
        "packages/signal-envelope-contracts/package.json": [
            '"name": "@openburnbar/signal-envelope-contracts"',
            '"license": "AGPL-3.0-only"',
        ],
        "packages/signal-envelope-contracts/fixtures/binding-aad-vectors.json": [
            "OpenBurnBar-Signal-AAD-v1|",
            "non-ascii-nfc-uid",
        ],
        "packages/e2ee-backend-policy/package.json": [
            '"name": "@openburnbar/e2ee-backend-policy"',
            '"license": "MIT"',
        ],
        "packages/e2ee-backend-policy/lib/index.js": [
            "resolveCryptoBackend",
            "burnbar-signal-unavailable",
            "explicit-fallback",
            "PLATFORM_CRYPTO_CAPABILITIES",
            "PLATFORMS",
            "CHANNELS",
            "resolvePlatformCryptoModel",
        ],
        "packages/e2ee-backend-policy/lib/index.test.js": [
            "MIT upstream mode uses the gateway v5 backend without Signal packages",
            "Signal-required mode refuses fallback",
            "BurnBar auto mode fails closed without Signal unless fallback is explicit",
        ],
    }
    for rel_path, needles in package_requirements.items():
        for needle in needles:
            checks.append(check_file_contains(rel_path, needle, f"{rel_path} contains {needle}"))
    return checks


def check_signal_boundary() -> Check:
    allowed_direct_imports = {
        "packages/libsignal-bridge/lib/index.js",
        "packages/libsignal-bridge/lib/index.test.js",
        "packages/libsignal-bridge/lib/protocolHarness.js",
        "packages/libsignal-bridge/lib/protocolHarness.test.js",
    }
    direct_import = re.compile(
        r"\bfrom\s+['\"]@signalapp/libsignal-client['\"]|\bimport\s+[^;\n]+['\"]@signalapp/libsignal-client['\"]",
        re.IGNORECASE,
    )
    violations: list[str] = []
    for root in ("packages/libsignal-protocol", "packages/signal-envelope-contracts"):
        for path in sorted((ROOT / root).rglob("*")):
            if not path.is_file() or "node_modules" in path.parts:
                continue
            rel_path = path.relative_to(ROOT).as_posix()
            try:
                text = path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            if direct_import.search(text) and rel_path not in allowed_direct_imports:
                violations.append(rel_path)
    if violations:
        return Check(
            "Signal bridge boundary",
            False,
            "official libsignal is imported outside packages/libsignal-bridge: " + ", ".join(violations),
        )
    return Check("Signal bridge boundary", True, "only the BurnBar libsignal bridge imports official libsignal directly")


def check_libsignal_runtime_readiness() -> Check:
    if str(ROOT) not in sys.path:
        sys.path.insert(0, str(ROOT))
    from scripts.ci.check_libsignal_runtime_readiness import DEFAULT_MANIFEST, check_manifest, load_manifest

    errors = check_manifest(DEFAULT_MANIFEST, repo_root=ROOT)
    if errors:
        return Check("libsignal runtime readiness manifest", False, "; ".join(errors))

    data = load_manifest(DEFAULT_MANIFEST)
    status = data.get("status")
    if status != "not_ready":
        return Check(
            "libsignal runtime readiness manifest",
            False,
            f"expected fail-closed not_ready status until native/runtime gates are complete, found {status!r}",
        )
    complete = sum(1 for gate in data["gates"].values() if gate.get("status") == "complete")
    total = len(data["gates"])
    return Check(
        "libsignal runtime readiness manifest",
        True,
        f"runtime readiness is fail-closed ({complete}/{total} gates complete)",
    )


def check_source_provenance_process() -> list[Check]:
    required = {
        "scripts/ci/write_burnbar_source_provenance.py": [
            "build_source_provenance_manifest",
            "release_preflight_blockers",
            "--release-check",
            "requiredSourceFiles",
            "runtimeReadiness",
        ],
        "scripts/ci/attach_libsignal_runtime_evidence.py": [
            "attach_runtime_evidence",
            "validatorResult",
            "sha256",
            "--allow-pending",
            "check_signal_envelope_contract_runtime.py",
            "write_manifest_atomic",
            "check_manifest",
            "run_validators=postcheck_validators",
        ],
        "scripts/ci/attach_agpl_legal_release_approval.py": [
            "build_approval_packet",
            "validate_legal_release_review",
            "SIGNATURE_FORMAT",
            "--use-required-channels",
            "repo-relative",
            "explicitApprovalBoundary",
        ],
        "scripts/ci/check_hermes_gateway_migration_drain.py": [
            "validate_drain_evidence",
            "aggregate_counts_only_no_document_values_or_identifiers",
            "deployedCommit",
            "sourceLocation",
            "dependencyLocks",
            "signalRequired",
            "legacyRelayWritesEnabled",
            "burnbarhermesgateway",
            "enqueuehermesgatewayevent",
        ],
        "scripts/ci/write_hermes_gateway_migration_drain_evidence.js": [
            "collectLiveEvidence",
            "classifyGatewayDocument",
            "aggregate_counts_only_no_document_values_or_identifiers",
            "functions/node_modules/firebase-admin",
            "--deployed-commit",
            "--source-location",
            "--runtime-mode-from-gcloud",
            "gcloud run services describe",
            "gcloud run revisions describe",
            "status.conditions",
            "readyRevision",
        ],
        "docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md": [
            "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true",
            "rollout_hermes_gateway_signal_required.js",
            "enable-hermes-gateway-signal-required",
            "rollback-hermes-gateway-signal-required",
            "--deployed-commit",
            "--source-location",
            "OPENBURNBAR_SOURCE_COMMIT",
            "OPENBURNBAR_CORRESPONDING_SOURCE_URL",
            "Cloud Functions gen2 source redeploy",
            "write_hermes_gateway_migration_drain_evidence.js",
            "drain_hermes_gateway_legacy_records.js",
            "--confirm delete-legacy-hermes-gateway-records",
            "--live-production-acknowledgement",
            "--predelete-export",
            "--quarantine-output",
            "check_hermes_gateway_migration_drain.py",
            "attach_libsignal_runtime_evidence.py",
            "write_signal_envelope_contract_runtime_evidence.py",
            "validatorResult",
            "node_contracts",
            "aggregate_counts_only_no_document_values_or_identifiers",
        ],
        "scripts/ci/rollout_hermes_gateway_signal_required.js": [
            "enable-hermes-gateway-signal-required",
            "rollback-hermes-gateway-signal-required",
            "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true",
            "OPENBURNBAR_SOURCE_COMMIT",
            "OPENBURNBAR_CORRESPONDING_SOURCE_URL",
            "--deployed-commit",
            "--source-location",
            "--remove-env-vars",
            "mutatesCloudRun",
            "dry_run",
            "gcloud",
        ],
        "scripts/ci/drain_hermes_gateway_legacy_records.js": [
            "delete-legacy-hermes-gateway-records",
            "--runtime-mode-evidence",
            "--live-production-acknowledgement",
            "--predelete-export",
            "--quarantine-output",
            "runtimeModeEvidenceErrors",
            "aggregate_counts_only_no_document_values_or_identifiers",
            "bulkWriter",
        ],
        "scripts/ci/restore_hermes_gateway_legacy_records.js": [
            "restore-hermes-gateway-predelete-export",
            "--live-production-acknowledgement",
            "private_export_contains_document_values_do_not_commit",
            "bulkWriter",
        ],
        "scripts/ci/check_agpl_legal_release_review.py": [
            "validate_legal_release_review",
            "validate_approval_signature",
            "app store and commercial distribution terms",
            "external_counsel",
            "reviewStatus",
            "distributionChannels",
            "openssl-sha256-rsa",
            "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md",
            "docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md",
            "check_burnbar_license_posture.py",
        ],
        "scripts/ci/check_burnbar_release_preflight.py": [
            "BurnBar product release preflight",
            "collect_blockers",
            "source_provenance_blockers",
            "legal_review_blockers",
            "HOLD: BurnBar product release preflight is not ready",
            "release_preflight_blockers",
            "validate_legal_release_review",
            "latest-agpl-store-legal-packet.json",
        ],
        "scripts/ci/post-deploy-health-gate.sh": [
            "EXPECTED_SOURCE_COMMIT",
            "source_metadata_ok",
            "run_source_metadata_self_test",
            "unknown source commit was accepted",
        ],
        "scripts/ci/verify-agpl-compliance.sh": [
            "verify-package-license-policy.mjs",
            "verify-libsignal-pin.sh",
            "verify-corresponding-source-archive.sh",
            "PASS: AGPL compliance gate",
        ],
        "scripts/ci/verify-ops-readiness.sh": [
            "DEPLOY_HEALTH_FUNCTIONS_SELF_TEST=1",
            "post-deploy health gate script",
            "PASS: ops readiness",
        ],
        "scripts/ci/verify-package-license-policy.mjs": [
            "validatePackageLicensePolicy",
            "PACKAGE_LICENSE_OVERRIDES",
            "@openburnbar/e2ee-backend-policy",
            "MIT upstream-boundary package must stay libsignal-free",
            "@signalapp/libsignal-client",
        ],
        "scripts/ops/deploy-health-functions.sh": [
            "OPENBURNBAR_SOURCE_COMMIT",
            "OPENBURNBAR_CORRESPONDING_SOURCE_URL",
            "DEPLOY_HEALTH_FUNCTIONS_SELF_TEST",
            "validate_deploy_metadata",
            "40-character git commit",
            "EXPECTED_SOURCE_COMMIT",
            "deploy-health-functions source metadata self-test",
        ],
        "scripts/ci/check_cloudvault_at_rest_runtime.py": [
            "validate_cloudvault_at_rest_evidence",
            "_registry_signal_at_rest_enablement",
            "signalAtRestEnablement",
            "sourceSha256",
            "proof_only_no_plaintext_keys_ciphertext_or_document_identifiers",
            "REQUIRED_COMMAND_FRAGMENTS",
            "scripts/ci/check_functions_cloudvault_runtime.js",
            "tests/test_signal_envelope_contracts_cjs_exports.py",
        ],
        "scripts/ci/write_cloudvault_at_rest_runtime_evidence.py": [
            "build_cloudvault_at_rest_runtime_evidence",
            "detect_signal_at_rest_enablement",
            "signalAtRestWritesEnabled",
            "sourceSha256",
            "proof_only_no_plaintext_keys_ciphertext_or_document_identifiers",
            "scripts/ci/check_functions_cloudvault_runtime.js",
        ],
        "scripts/ci/check_functions_cloudvault_runtime.js": [
            "runSignalAtRestWriteSmoke",
            "runPrivacyBackfillSmoke",
            "compiled Functions CloudVault runtime smoke passed",
        ],
        "scripts/ci/check_signal_envelope_contract_runtime.py": [
            "validate_signal_envelope_contract_runtime_evidence",
            "proof_only_no_plaintext_keys_ciphertext_or_user_data",
            "REQUIRED_COMMAND_FRAGMENTS",
            "npm ci --prefix packages/signal-envelope-contracts",
            "npm test --prefix packages/signal-envelope-contracts",
            "npm ci --prefix services/hosted-mcp",
            "npm test --prefix services/hosted-mcp",
            "npm test --prefix services/hermes-realtime-relay",
        ],
        "scripts/ci/write_signal_envelope_contract_runtime_evidence.py": [
            "build_signal_envelope_contract_runtime_evidence",
            "proof_only_no_plaintext_keys_ciphertext_or_user_data",
            '"npm", "ci", "--prefix", "packages/signal-envelope-contracts"',
            '"npm", "test", "--prefix", "packages/signal-envelope-contracts"',
            '"npm", "ci", "--prefix", "functions"',
            '"npm", "run", "build", "--prefix", "functions"',
            "services/hermes-realtime-relay",
        ],
        "scripts/ci/check_native_signal_runtime_evidence.py": [
            "validate_native_signal_runtime_evidence",
            "proof_only_no_plaintext_keys_or_user_data",
            "commandEvidence",
        ],
        "scripts/ci/run_android_signal_runtime_tests.py": [
            "ensure_unit_test_google_services",
            "unit-test-google-services-json",
            "SIGNAL_RUNTIME_GRADLE_ARGS",
            ":app:testDebugUnitTest",
        ],
        "scripts/ci/write_native_signal_runtime_evidence.py": [
            "build_native_signal_runtime_evidence",
            "proof_only_no_plaintext_keys_or_user_data",
            "commandEvidence",
        ],
        "tests/test_burnbar_source_provenance.py": [
            "test_source_provenance_manifest_covers_agpl_signal_release_inputs",
            "scripts/ci/attach_libsignal_runtime_evidence.py",
            "third_party/libsignal/runtime-readiness.json",
        ],
        "tests/test_burnbar_license_posture.py": [
            "test_android_firebase_config_guard_fails_when_file_is_tracked",
            "check_android_firebase_config_untracked",
        ],
        "scripts/ci/verify-package-license-policy.test.mjs": [
            "allows the documented MIT upstream-boundary package",
            "rejects undocumented MIT packages",
            "rejects Signal dependencies in the MIT boundary package",
        ],
        "tests/test_libsignal_runtime_evidence_attach.py": [
            "test_attach_replaces_legacy_self_reported_gate_with_typed_evidence",
            "test_attach_refuses_failed_validator_without_mutating_manifest",
            "test_attach_rejects_legal_allow_pending_validator_before_running",
            "test_attach_node_contracts_uses_dedicated_artifact_validator",
        ],
        "tests/test_signal_envelope_contract_runtime.py": [
            "test_validates_node_signal_envelope_contract_runtime_evidence",
            "test_failed_command_does_not_count_assertions_as_proof",
            "test_rejects_raw_output_and_stale_evidence",
        ],
        "tests/test_signal_envelope_contract_runtime_writer.py": [
            "test_writer_generates_release_ready_shape_when_commands_pass",
            "test_writer_failed_command_does_not_count_assertions_as_proof",
        ],
        "tests/test_cloudvault_at_rest_runtime.py": [
            "test_rejects_forged_signal_enablement_against_current_registry",
            "signalAtRestEnablement",
        ],
        "docs/legal/SOURCE_AVAILABILITY.md": [
            "write_burnbar_source_provenance.py --output",
            "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md",
            "docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md",
        ],
        "tests/test_native_signal_runtime_evidence.py": [
            "test_validates_swift_native_runtime_evidence",
            "test_validates_kotlin_android_native_runtime_evidence",
            "test_native_evidence_rejects_self_reported_platform_status_without_command_evidence",
        ],
        "tests/test_native_signal_runtime_evidence_writer.py": [
            "test_swift_writer_generates_release_ready_shape_when_commands_pass",
            "test_rust_writer_failed_command_does_not_count_assertions_as_proof",
        ],
        "tests/test_cloudvault_at_rest_runtime_writer.py": [
            "test_writer_keeps_release_gate_closed_when_signal_is_not_enabled",
            "test_writer_failed_command_does_not_count_assertions_as_proof",
        ],
    }
    checks: list[Check] = []
    for rel_path, needles in required.items():
        path = ROOT / rel_path
        if not path.is_file():
            checks.append(Check(f"{rel_path} source provenance process", False, f"{rel_path} is missing"))
            continue
        text = path.read_text(encoding="utf-8")
        missing = [needle for needle in needles if needle not in text]
        if missing:
            checks.append(Check(f"{rel_path} source provenance process", False, f"missing {missing!r}"))
        else:
            checks.append(Check(f"{rel_path} source provenance process", True, "source provenance process is present"))
    return checks


def check_legal_docs() -> list[Check]:
    required = {
        "THIRD_PARTY_NOTICES.md": [
            "Nous Hermes / MIT-Origin Code",
            "Signal / libsignal / Sparse Post-Quantum Ratchet",
            "AGPL-3.0-only",
        ],
        "docs/legal/SOURCE_AVAILABILITY.md": [
            "corresponding source",
            "Signal-enabled BurnBar build",
            "libsignal runtime-readiness manifest",
            "MIT Upstream Boundary",
            "AGPL_RELEASE_REVIEW_PACKET.md",
            "HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md",
        ],
        "docs/legal/DEPENDENCY_LICENSE_MANIFEST.md": [
            "BurnBar shipped product",
            "Nous/Hermes MIT PR",
            "Signal libsignal",
            "Runtime readiness manifest",
            "AGPL release review packet",
            "Gateway Signal-required rollout runbook",
        ],
        "docs/legal/AGPL_RELEASE_REVIEW_PACKET.md": [
            "Signal/libsignal/SPQR-backed E2EE",
            "MIT-compatible encrypted gateway hardening only",
            "Required Review Scope",
            "Required Distribution Channels",
            "Required Artifacts For Counsel",
            "external_counsel",
            "Do not market a Signal-enabled BurnBar release as fully cleared",
            "HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md",
        ],
        "docs/legal/agpl-release-review.evidence.template.json": [
            "\"reviewStatus\": \"pending\"",
            "\"reviewerRole\": \"external_counsel\"",
            "\"AGPL-3.0-only product license\"",
            "\"MIT-compatible Nous/Hermes upstream boundary\"",
            "\"docs/legal/AGPL_RELEASE_REVIEW_PACKET.md\"",
            "\"docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md\"",
        ],
        "docs/legal/HERMES_GATEWAY_SIGNAL_REQUIRED_ROLLOUT.md": [
            "explicit release-owner approval",
            "rollout_hermes_gateway_signal_required.js",
            "OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED=true",
            "gcloud run services update burnbarhermesgateway",
            "gcloud run services update enqueuehermesgatewayevent",
            "--runtime-mode-from-gcloud",
            "enable-hermes-gateway-signal-required",
            "rollback-hermes-gateway-signal-required",
            "--execute",
            "--confirm delete-legacy-hermes-gateway-records",
            "--remove-env-vars OPENBURNBAR_GATEWAY_SIGNAL_REQUIRED",
        ],
    }
    checks: list[Check] = []
    for rel_path, needles in required.items():
        path = ROOT / rel_path
        if not path.is_file():
            checks.append(Check(f"{rel_path} exists", False, f"{rel_path} is missing"))
            continue
        text = path.read_text(encoding="utf-8")
        missing = [needle for needle in needles if needle not in text]
        if missing:
            checks.append(Check(f"{rel_path} content", False, f"missing {missing!r}"))
        else:
            checks.append(Check(f"{rel_path} content", True, "required compliance language is present"))
    return checks


def check_mit_upstream_boundary_process() -> list[Check]:
    required = {
        "scripts/verify_burnbar_mit_pr_clean.py": [
            "BurnBar MIT PR cleanliness scan",
            "official libsignal npm dependency",
            "post-quantum recovery claim",
            "ls-files",
            "--others",
            "--exclude-standard",
        ],
        "tests/test_burnbar_mit_pr_clean.py": [
            "test_allows_normal_signal_messenger_adapter_reference",
            "test_blocks_mit_lane_overclaims",
            "test_blocks_mit_lane_post_quantum_recovery_claim",
            "test_working_tree_scan_includes_untracked_files",
        ],
        ".github/workflows/license-posture.yml": [
            "Nous/Hermes MIT upstream boundary",
            "run_mit_upstream_scan",
            "verify_burnbar_mit_pr_clean.py",
        ],
    }
    checks: list[Check] = []
    for rel_path, needles in required.items():
        path = ROOT / rel_path
        if not path.is_file():
            checks.append(Check(f"{rel_path} MIT upstream boundary", False, f"{rel_path} is missing"))
            continue
        text = path.read_text(encoding="utf-8")
        missing = [needle for needle in needles if needle not in text]
        if missing:
            checks.append(Check(f"{rel_path} MIT upstream boundary", False, f"missing {missing!r}"))
        else:
            checks.append(Check(f"{rel_path} MIT upstream boundary", True, "MIT upstream boundary process is present"))
    return checks


def check_license_workflow_product_detection() -> Check:
    rel_path = ".github/workflows/license-posture.yml"
    path = ROOT / rel_path
    if not path.is_file():
        return Check("license posture workflow product detection", False, f"{rel_path} is missing")
    text = path.read_text(encoding="utf-8")
    required = [
        "Detect BurnBar AGPL product tree",
        "third_party/libsignal/runtime-readiness.json",
        "Vendor/libsignal/LICENSE",
        "run_product_checks=true",
        "python scripts/ci/check_burnbar_license_posture.py",
        "python scripts/ci/check_libsignal_runtime_readiness.py",
        "python scripts/ci/write_burnbar_source_provenance.py --check",
    ]
    missing = [needle for needle in required if needle not in text]
    if missing:
        return Check("license posture workflow product detection", False, f"missing {missing!r}")
    if "third_party/libsignal/manifest.json" in text:
        return Check(
            "license posture workflow product detection",
            False,
            "workflow still checks obsolete third_party/libsignal/manifest.json",
        )
    return Check(
        "license posture workflow product detection",
        True,
        "workflow detects the live BurnBar AGPL product tree before running product gates",
    )


def check_android_firebase_config_untracked() -> Check:
    rel_path = "android/app/google-services.json"
    try:
        result = subprocess.run(
            ["git", "ls-files", "--error-unmatch", rel_path],
            cwd=ROOT,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except OSError as exc:
        return Check("Android Firebase config source-control guard", False, f"unable to run git: {exc}")
    if result.returncode == 0:
        return Check(
            "Android Firebase config source-control guard",
            False,
            f"{rel_path} is tracked; remove it from git and keep only android/app/google-services.json.template",
        )
    return Check(
        "Android Firebase config source-control guard",
        True,
        f"{rel_path} is not tracked",
    )


_IOS_LIBSIGNAL_PATTERN = re.compile(r"libsignal|signal_ffi", re.IGNORECASE)


def _iter_ios_artifacts() -> list[Path]:
    """Locate built iOS app artifacts: any build/**/*.ipa, or *.app bundles
    sitting under an iphoneos products directory.

    The iOS App Store satellite is a hard libsignal-FREE guarantee, so this
    only inspects artifacts that would actually ship to a device.
    """
    build_root = ROOT / "build"
    if not build_root.is_dir():
        return []
    artifacts: list[Path] = []
    seen: set[str] = set()
    for ipa in build_root.rglob("*.ipa"):
        if ipa.is_file():
            key = ipa.resolve().as_posix()
            if key not in seen:
                seen.add(key)
                artifacts.append(ipa)
    for app in build_root.rglob("*.app"):
        if not app.is_dir():
            continue
        # Only release/archive iphoneos products, never simulator builds, Mac
        # apps, or ad-hoc Debug-iphoneos device builds left by local testing.
        if not any("iphoneos" in part.lower() for part in app.parts):
            continue
        if not any("release-iphoneos" in part.lower() or "archive" in part.lower() for part in app.parts):
            continue
        key = app.resolve().as_posix()
        if key not in seen:
            seen.add(key)
            artifacts.append(app)
    return sorted(artifacts, key=lambda p: p.as_posix())


def _ios_artifact_libsignal_hits(artifact: Path) -> list[str]:
    """Return libsignal/signal_ffi matches embedded in an iOS artifact.

    For an .ipa we read the zip central directory (file paths + Frameworks
    entries) without extracting. For an .app bundle we walk every embedded
    file path. Any match means official libsignal leaked into the App-Store
    satellite, which must fail the build.
    """
    hits: list[str] = []
    if artifact.suffix == ".ipa":
        try:
            with zipfile.ZipFile(artifact) as archive:
                names = archive.namelist()
        except (zipfile.BadZipFile, OSError) as exc:
            return [f"unreadable ipa ({exc})"]
        for name in names:
            if _IOS_LIBSIGNAL_PATTERN.search(name):
                hits.append(name)
    else:
        for member in artifact.rglob("*"):
            rel = member.relative_to(artifact).as_posix()
            if _IOS_LIBSIGNAL_PATTERN.search(rel):
                hits.append(rel)
    return hits


def check_ios_libsignal_free() -> Check:
    name = "iOS App Store libsignal-free guarantee"
    artifacts = _iter_ios_artifacts()
    if not artifacts:
        return Check(name, True, "skipped (no iOS artifact)")
    violations: list[str] = []
    for artifact in artifacts:
        rel_artifact = artifact.relative_to(ROOT).as_posix()
        hits = _ios_artifact_libsignal_hits(artifact)
        if hits:
            sample = ", ".join(hits[:5])
            suffix = "" if len(hits) <= 5 else f" (+{len(hits) - 5} more)"
            violations.append(f"{rel_artifact}: {sample}{suffix}")
    if violations:
        return Check(
            name,
            False,
            "iOS satellite artifact embeds libsignal/signal_ffi: " + "; ".join(violations),
        )
    inspected = ", ".join(a.relative_to(ROOT).as_posix() for a in artifacts)
    return Check(
        name,
        True,
        f"no libsignal/signal_ffi in {len(artifacts)} iOS artifact(s): {inspected}",
    )


def check_claim_hygiene() -> Check:
    scanned_roots = [
        "README.md",
        "apps/desktop/README.md",
        "apps/console",
        "docs",
        "plugins/platforms/burnbar",
        "website/src",
        "OpenBurnBarMobile",
        "android",
    ]
    excluded = {
        "docs/legal/DEPENDENCY_LICENSE_MANIFEST.md",
        "docs/legal/SOURCE_AVAILABILITY.md",
    }
    excluded_dirs = {
        ".gradle",
        ".next",
        ".nuxt",
        "build",
        "dist",
        "node_modules",
        "Pods",
    }
    violations: list[str] = []
    for root in scanned_roots:
        path = ROOT / root
        if not path.exists():
            continue
        files = [path] if path.is_file() else sorted(path.rglob("*"))
        for file_path in files:
            if not file_path.is_file():
                continue
            rel_path = file_path.relative_to(ROOT).as_posix()
            if any(part in excluded_dirs for part in file_path.relative_to(ROOT).parts):
                continue
            if rel_path in excluded or rel_path.startswith("docs/legal/"):
                continue
            try:
                text = file_path.read_text(encoding="utf-8")
            except UnicodeDecodeError:
                continue
            for name, pattern in FORBIDDEN_PRODUCT_CLAIMS:
                match = pattern.search(text)
                if match:
                    line = text.count("\n", 0, match.start()) + 1
                    violations.append(f"{rel_path}:{line}: {name}")
    if violations:
        return Check("docs claim hygiene", False, "; ".join(violations))
    return Check("docs claim hygiene", True, "no forbidden product/security overclaims found")


def all_checks() -> list[Check]:
    return [
        check_root_license(),
        check_pyproject_license(),
        check_package_license(),
        check_package_lock_license(),
        check_readme_license(),
        *check_app_legal_surfaces(),
        *check_signal_agpl_evidence(),
        check_signal_boundary(),
        check_libsignal_runtime_readiness(),
        *check_source_provenance_process(),
        *check_legal_docs(),
        *check_mit_upstream_boundary_process(),
        check_license_workflow_product_detection(),
        check_android_firebase_config_untracked(),
        check_ios_libsignal_free(),
        check_claim_hygiene(),
    ]


def main() -> int:
    checks = all_checks()
    failed = [check for check in checks if not check.ok]
    for check in checks:
        status = "PASS" if check.ok else "FAIL"
        print(f"{status}: {check.name} - {check.details}")
    if failed:
        print(f"\nBurnBar license posture failed {len(failed)} check(s).", file=sys.stderr)
        return 1
    print(f"\nPASS: BurnBar AGPL product license posture verified ({len(checks)} checks).")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
