#!/usr/bin/env python3
"""Create a sanitized, candidate-bound Developer ID release receipt."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from exclusive_json import write_exclusive_json


FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
NOTARY_ID = re.compile(
    r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$"
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--candidate-commit", required=True)
    parser.add_argument("--candidate-tree", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--signing-receipt", required=True, type=Path)
    parser.add_argument("--app-notary-result", required=True, type=Path)
    parser.add_argument("--app-notary-artifact-name", required=True)
    parser.add_argument("--app-notary-artifact-sha256", required=True)
    parser.add_argument("--app-notary-artifact-size", required=True, type=int)
    parser.add_argument("--dmg-notary-result", required=True, type=Path)
    parser.add_argument("--dmg-notary-artifact-name", required=True)
    parser.add_argument("--dmg-notary-artifact-sha256", required=True)
    parser.add_argument("--dmg-notary-artifact-size", required=True, type=int)
    parser.add_argument("--artifact", action="append", nargs=2, metavar=("KIND", "PATH"), default=[])
    parser.add_argument("--smoke-script", required=True)
    return parser.parse_args()


def fail(message: str) -> None:
    raise ValueError(message)


def load_json(path: Path, label: str) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        fail(f"{label} is unreadable or invalid JSON at {path}: {error}")
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object.")
    return value


def sha256(path: Path) -> str:
    if not path.is_file() or path.is_symlink():
        fail(f"release artifact must be a real file: {path}")
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sanitized_notary_result(
    path: Path,
    label: str,
    *,
    artifact_name: str,
    artifact_sha256: str,
    artifact_size: int,
) -> dict[str, Any]:
    raw = load_json(path, label)
    submission = require_dict(raw.get("submission"), f"{label} submission")
    submitted_artifact = require_dict(raw.get("artifact"), f"{label} artifact")
    status = submission.get("status")
    submission_id = submission.get("id")
    if status != "Accepted":
        fail(f"{label} status must be 'Accepted'; found {status!r}.")
    if not isinstance(submission_id, str) or not NOTARY_ID.fullmatch(submission_id):
        fail(f"{label} is missing a valid notarization submission id.")
    if not re.fullmatch(r"[0-9a-f]{64}", artifact_sha256):
        fail(f"{label} submitted artifact SHA-256 is invalid.")
    if artifact_size <= 0:
        fail(f"{label} submitted artifact size must be positive.")
    if Path(artifact_name).name != artifact_name or not artifact_name:
        fail(f"{label} submitted artifact name must be a basename.")
    expected_artifact = {
        "fileName": artifact_name,
        "sha256": artifact_sha256,
        "sizeBytes": artifact_size,
    }
    if submitted_artifact != expected_artifact:
        fail(f"{label} submitted artifact binding does not match the release inputs.")
    return {
        "id": submission_id.lower(),
        "status": status,
        "submittedArtifact": expected_artifact,
    }


def require_dict(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object.")
    return value


def sanitized_signature(value: Any, label: str, *, require_timestamp: bool) -> dict[str, Any]:
    signature = require_dict(value, label)
    result = {
        "authority": signature.get("authority"),
        "hardenedRuntime": signature.get("hardenedRuntime"),
        "libraryValidation": signature.get("libraryValidation"),
    }
    if result != {
        "authority": "Developer ID Application",
        "hardenedRuntime": True,
        "libraryValidation": True,
    }:
        fail(f"{label} does not describe a hardened Developer ID signature.")
    if require_timestamp:
        if signature.get("secureTimestamp") is not True:
            fail(f"{label} must confirm a secure timestamp.")
        result["secureTimestamp"] = True
    return result


def sanitized_component(
    value: Any,
    label: str,
    *,
    expected_bundle_id: str,
    require_timestamp: bool,
) -> dict[str, Any]:
    component = require_dict(value, label)
    profile_sha256 = component.get("profileSha256")
    profile_expiration = component.get("profileExpiration")
    if component.get("bundleIdentifier") != expected_bundle_id:
        fail(f"{label} bundle identifier does not match {expected_bundle_id}.")
    if not isinstance(profile_sha256, str) or not re.fullmatch(r"[0-9a-f]{64}", profile_sha256):
        fail(f"{label} profile SHA-256 is invalid.")
    if not isinstance(profile_expiration, str) or not profile_expiration.endswith("Z"):
        fail(f"{label} profile expiration is invalid.")
    try:
        parsed_expiration = datetime.fromisoformat(profile_expiration.replace("Z", "+00:00"))
    except ValueError as error:
        fail(f"{label} profile expiration is invalid: {error}")
    if parsed_expiration <= datetime.now(timezone.utc):
        fail(f"{label} profile expiration is not in the future.")
    return {
        "bundleIdentifier": expected_bundle_id,
        "profileExpiration": profile_expiration,
        "profileSha256": profile_sha256,
        "signature": sanitized_signature(
            component.get("signature"),
            f"{label} signature",
            require_timestamp=require_timestamp,
        ),
    }


def sanitized_signing_receipt(value: dict[str, Any], team_id: str) -> dict[str, Any]:
    if value.get("schemaVersion") != 1:
        fail("signing receipt schema version is unsupported.")
    if value.get("teamId") != team_id:
        fail("signing receipt team ID does not match the release team ID.")
    if value.get("distribution") != "developer-id":
        fail("signing receipt is not a Developer ID receipt.")
    if value.get("appGroup") != "group.com.openburnbar.app":
        fail("signing receipt App Group is invalid.")
    if value.get("keychainGroup") != f"{team_id}.com.openburnbar.app":
        fail("signing receipt Keychain group is invalid.")
    verification = require_dict(value.get("verification"), "signing receipt verification")
    expected_verification = {
        "embeddedProfilesByteEqual": True,
        "profileCertificateMembership": True,
        "strictDeepNestedSignatures": True,
        "getTaskAllow": False,
        "platform": "OSX",
    }
    if any(verification.get(key) != expected for key, expected in expected_verification.items()):
        fail("signing receipt verification claims are incomplete or invalid.")
    return {
        "schemaVersion": 1,
        "distribution": "developer-id",
        "teamId": team_id,
        "appGroup": "group.com.openburnbar.app",
        "keychainGroup": f"{team_id}.com.openburnbar.app",
        "host": sanitized_component(
            value.get("host"),
            "signing receipt host",
            expected_bundle_id="com.openburnbar.app",
            require_timestamp=True,
        ),
        "safariExtension": sanitized_component(
            value.get("safariExtension"),
            "signing receipt Safari extension",
            expected_bundle_id="com.openburnbar.app.safari-extension",
            require_timestamp=False,
        ),
        "verification": expected_verification,
    }


def main() -> int:
    args = parse_args()
    if not FULL_SHA.fullmatch(args.candidate_commit):
        fail("candidate commit must be a full lowercase Git SHA.")
    if not FULL_SHA.fullmatch(args.candidate_tree):
        fail("candidate tree must be a full lowercase Git SHA.")
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
        fail("team ID must be exactly 10 uppercase letters/digits.")
    if not args.artifact:
        fail("at least one --artifact KIND PATH is required.")
    if args.smoke_script != "scripts/ci/smoke-openburnbar-release-dmg.sh":
        fail("mounted-DMG smoke script must be the canonical release smoke verifier.")

    signing_receipt = sanitized_signing_receipt(
        load_json(args.signing_receipt, "signing receipt"),
        args.team_id,
    )

    artifacts: dict[str, dict[str, Any]] = {}
    artifact_paths: set[Path] = set()
    for kind, raw_path in args.artifact:
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*", kind):
            fail(f"release artifact kind is invalid: {kind}")
        if kind in artifacts:
            fail(f"duplicate release artifact kind: {kind}")
        path = Path(raw_path)
        resolved_path = path.resolve()
        if resolved_path in artifact_paths:
            fail(f"release artifact path is reused by multiple kinds: {path}")
        artifact_paths.add(resolved_path)
        artifacts[kind] = {
            "fileName": path.name,
            "sha256": sha256(path),
            "sizeBytes": path.stat().st_size,
        }
    if "dmg" not in artifacts:
        fail("release receipt must include the signed DMG artifact.")

    receipt = {
        "schemaVersion": 1,
        "candidate": {
            "commit": args.candidate_commit,
            "tree": args.candidate_tree,
        },
        "release": {
            "version": args.version,
            "build": args.build,
            "channel": "direct-download",
            "teamId": args.team_id,
            "createdAt": datetime.now(timezone.utc)
            .replace(microsecond=0)
            .isoformat()
            .replace("+00:00", "Z"),
        },
        "artifacts": artifacts,
        "signing": signing_receipt,
        "notarization": {
            "app": sanitized_notary_result(
                args.app_notary_result,
                "app notarization result",
                artifact_name=args.app_notary_artifact_name,
                artifact_sha256=args.app_notary_artifact_sha256,
                artifact_size=args.app_notary_artifact_size,
            ),
            "dmg": sanitized_notary_result(
                args.dmg_notary_result,
                "DMG notarization result",
                artifact_name=args.dmg_notary_artifact_name,
                artifact_sha256=args.dmg_notary_artifact_sha256,
                artifact_size=args.dmg_notary_artifact_size,
            ),
        },
        "mountedDmgSmoke": {
            "status": "passed",
            "script": args.smoke_script,
            "artifactSha256": artifacts["dmg"]["sha256"],
        },
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    write_exclusive_json(args.output, receipt)
    print(f"PASS: wrote sanitized Developer ID release receipt to {args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1) from error
