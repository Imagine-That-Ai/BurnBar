#!/usr/bin/env python3
"""Validate App Store Connect delivery evidence and create a sanitized MAS receipt."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from exclusive_json import write_exclusive_json


TERMINAL_SUCCESS_STATES = {
    "accepted",
    "complete",
    "completed",
    "processed",
    "processing complete",
    "success",
    "succeeded",
    "valid",
}
TERMINAL_FAILURE_STATES = {
    "error",
    "failed",
    "failure",
    "invalid",
    "rejected",
}
STATUS_KEYS = {
    "buildstatus",
    "deliverystatus",
    "processingstate",
    "state",
    "status",
}
DELIVERY_ID_KEYS = {"deliveryid", "deliveryuuid"}
REQUEST_ID_KEYS = {"requestid", "requestuuid"}
SUCCESS_MESSAGE_KEYS = {"successmessage"}
APP_APPLE_ID_KEYS = {"adamid", "appappleid", "appleid", "applicationappleid"}
BUNDLE_IDENTIFIER_KEYS = {"bundleid", "bundleidentifier"}
BUNDLE_SHORT_VERSION_KEYS = {
    "bundleshortversion",
    "bundleshortversionstring",
    "cfbundleshortversionstring",
}
BUNDLE_VERSION_KEYS = {"buildnumber", "bundleversion", "cfbundleversion"}
PLATFORM_KEYS = {"platform"}
HEX_OBJECT_ID = re.compile(r"^[0-9a-f]{40}$")


def normalized_key(value: str) -> str:
    return "".join(character for character in value.casefold() if character.isalnum())


def json_bytes(path: Path) -> tuple[bytes, Any]:
    raw = path.read_bytes()
    if not raw:
        raise ValueError(f"App Store Connect response is empty: {path}")
    return raw, json.loads(raw)


def values_for_keys(value: Any, expected_keys: set[str]) -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            if normalized_key(key) in expected_keys and isinstance(child, (str, int)):
                rendered = str(child).strip()
                if rendered:
                    found.append(rendered)
            found.extend(values_for_keys(child, expected_keys))
    elif isinstance(value, list):
        for child in value:
            found.extend(values_for_keys(child, expected_keys))
    return found


def error_messages(value: Any) -> list[str]:
    found: list[str] = []
    if isinstance(value, dict):
        for key, child in value.items():
            key_name = normalized_key(key)
            if key_name in {"error", "errors"}:
                if isinstance(child, str) and child.strip():
                    found.append(child.strip())
                elif isinstance(child, (list, dict)) and child:
                    found.append(json.dumps(child, sort_keys=True))
            elif key_name in {"errormessage", "failuremessage"} and isinstance(child, str) and child.strip():
                found.append(child.strip())
            found.extend(error_messages(child))
    elif isinstance(value, list):
        for child in value:
            found.extend(error_messages(child))
    return found


def unique_value(values: list[str], label: str, *, required: bool) -> str | None:
    unique = sorted(set(values))
    if not unique:
        if required:
            raise ValueError(f"App Store Connect response contained no {label}")
        return None
    if len(unique) != 1:
        raise ValueError(f"App Store Connect response contained ambiguous {label} values: {unique!r}")
    return unique[0]


def validate_upload(path: Path) -> dict[str, str]:
    raw, value = json_bytes(path)
    errors = error_messages(value)
    if errors:
        raise ValueError(f"App Store Connect upload response contains errors: {errors!r}")
    statuses = [status.casefold() for status in values_for_keys(value, STATUS_KEYS)]
    failures = [status for status in statuses if status in TERMINAL_FAILURE_STATES]
    if failures:
        raise ValueError(f"App Store Connect upload response contains failure status: {failures!r}")
    delivery_id = unique_value(
        values_for_keys(value, DELIVERY_ID_KEYS),
        "delivery ID",
        required=True,
    )
    request_id = unique_value(
        values_for_keys(value, REQUEST_ID_KEYS),
        "request ID",
        required=False,
    )
    result = {
        "deliveryId": delivery_id,
        "uploadResponseSha256": hashlib.sha256(raw).hexdigest(),
    }
    if request_id is not None:
        result["requestId"] = request_id
    return result


def validate_submission_response(path: Path, label: str) -> dict[str, str]:
    raw, value = json_bytes(path)
    errors = error_messages(value)
    if errors:
        raise ValueError(f"{label} response contains errors: {errors!r}")
    statuses = [status.casefold() for status in values_for_keys(value, STATUS_KEYS)]
    failures = [status for status in statuses if status in TERMINAL_FAILURE_STATES]
    if failures:
        raise ValueError(f"{label} response contains failure status: {failures!r}")
    success_messages = values_for_keys(value, SUCCESS_MESSAGE_KEYS)
    successes = [status for status in statuses if status in TERMINAL_SUCCESS_STATES]
    nonterminal = [
        status
        for status in statuses
        if status not in TERMINAL_SUCCESS_STATES and status not in TERMINAL_FAILURE_STATES
    ]
    if nonterminal or (not successes and not success_messages):
        raise ValueError(
            f"{label} response contains no unambiguous success signal; "
            f"found statuses={statuses!r}"
        )
    return {"responseSha256": hashlib.sha256(raw).hexdigest()}


def validate_terminal_status(path: Path, label: str) -> dict[str, str]:
    raw, value = json_bytes(path)
    errors = error_messages(value)
    if errors:
        raise ValueError(f"{label} response contains errors: {errors!r}")
    statuses = [status.casefold() for status in values_for_keys(value, STATUS_KEYS)]
    if not statuses:
        raise ValueError(f"{label} response contains no status")
    failures = [status for status in statuses if status in TERMINAL_FAILURE_STATES]
    nonterminal = [
        status
        for status in statuses
        if status not in TERMINAL_SUCCESS_STATES and status not in TERMINAL_FAILURE_STATES
    ]
    successes = [status for status in statuses if status in TERMINAL_SUCCESS_STATES]
    if failures or nonterminal or not successes:
        raise ValueError(
            f"{label} response must contain only accepted/processed terminal statuses; "
            f"found statuses={statuses!r}"
        )
    return {
        "processedStatus": sorted(set(successes))[0],
        "responseSha256": hashlib.sha256(raw).hexdigest(),
    }


def normalized_platform(value: str) -> str:
    normalized = normalized_key(value)
    if normalized in {"macos", "macosx", "osx"}:
        return "MAC_OS"
    return value.strip().upper()


def validate_exact_build_readback(
    path: Path,
    *,
    expected_app_apple_id: str,
    expected_bundle_identifier: str,
    expected_version: str,
    expected_build: str,
    expected_platform: str,
) -> dict[str, str]:
    status = validate_terminal_status(path, "exact-build readback")
    _, value = json_bytes(path)
    app_apple_id = unique_value(
        values_for_keys(value, APP_APPLE_ID_KEYS),
        "app Apple ID",
        required=True,
    )
    bundle_identifier = unique_value(
        values_for_keys(value, BUNDLE_IDENTIFIER_KEYS),
        "bundle identifier",
        required=True,
    )
    version = unique_value(
        values_for_keys(value, BUNDLE_SHORT_VERSION_KEYS),
        "bundle short version",
        required=True,
    )
    build = unique_value(
        values_for_keys(value, BUNDLE_VERSION_KEYS),
        "bundle version",
        required=True,
    )
    raw_platform = unique_value(
        values_for_keys(value, PLATFORM_KEYS),
        "platform",
        required=True,
    )
    platform = normalized_platform(raw_platform)
    expected_identity = {
        "appAppleId": expected_app_apple_id,
        "bundleIdentifier": expected_bundle_identifier,
        "version": expected_version,
        "build": expected_build,
        "platform": expected_platform,
    }
    actual_identity = {
        "appAppleId": app_apple_id,
        "bundleIdentifier": bundle_identifier,
        "version": version,
        "build": build,
        "platform": platform,
    }
    mismatches = {
        key: {"expected": expected_identity[key], "actual": actual_identity[key]}
        for key in expected_identity
        if actual_identity[key] != expected_identity[key]
    }
    if mismatches:
        raise ValueError(
            "exact-build readback identity does not match the requested OpenBurnBar build: "
            f"{mismatches!r}"
        )
    return {**status, **actual_identity}


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_tree(path: Path) -> str:
    if path.is_symlink() or not path.is_dir():
        raise ValueError(f"tree artifact must be a real directory: {path}")
    digest = hashlib.sha256()
    for entry in sorted(path.rglob("*"), key=lambda candidate: candidate.relative_to(path).as_posix()):
        relative = entry.relative_to(path).as_posix().encode()
        metadata = os.lstat(entry)
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(stat.S_IMODE(metadata.st_mode).to_bytes(4, "big"))
        if stat.S_ISLNK(metadata.st_mode):
            target = os.readlink(entry).encode()
            digest.update(b"L")
            digest.update(len(target).to_bytes(8, "big"))
            digest.update(target)
        elif stat.S_ISDIR(metadata.st_mode):
            digest.update(b"D")
        elif stat.S_ISREG(metadata.st_mode):
            digest.update(b"F")
            digest.update(metadata.st_size.to_bytes(8, "big"))
            with entry.open("rb") as file:
                for chunk in iter(lambda: file.read(1024 * 1024), b""):
                    digest.update(chunk)
        else:
            raise ValueError(f"tree artifact contains unsupported filesystem entry: {entry}")
    return digest.hexdigest()


def verify_object_id(value: str, label: str) -> None:
    if not HEX_OBJECT_ID.fullmatch(value):
        raise ValueError(f"{label} must be a lowercase 40-character Git object ID")


def require_descendant(path: Path, parent: Path, label: str) -> Path:
    if path.is_symlink() or parent.is_symlink():
        raise ValueError(f"{label} must not traverse a symlink")
    absolute_path = Path(os.path.abspath(path))
    absolute_parent = Path(os.path.abspath(parent))
    try:
        relative = absolute_path.relative_to(absolute_parent)
    except ValueError as error:
        raise ValueError(
            f"{label} must be contained by {absolute_parent}: {absolute_path}"
        ) from error
    current = absolute_parent
    for component in relative.parts:
        current /= component
        if current.is_symlink():
            raise ValueError(f"{label} must not traverse a symlink: {current}")
    return current.resolve()


def safari_extension(app: Path, label: str) -> Path:
    if app.is_symlink() or not app.is_dir():
        raise ValueError(f"{label} must be a real app directory: {app}")
    appex = app / "Contents" / "PlugIns" / "OpenBurnBarSafariExtension.appex"
    if appex.is_symlink() or not appex.is_dir():
        raise ValueError(f"{label} is missing a real Safari extension bundle: {appex}")
    return appex


def run_artifact_verifier(
    verifier: Path,
    *,
    app: Path,
    team_id: str,
    version: str,
    build: str,
    pkg: Path | None,
    label: str,
) -> None:
    command = [
        "bash",
        str(verifier),
        str(app),
        team_id,
        version,
        build,
    ]
    if pkg is not None:
        command.append(str(pkg))
    completed = subprocess.run(
        command,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        details = completed.stderr.strip() or completed.stdout.strip() or "no verifier output"
        raise ValueError(
            f"{label} failed with exit {completed.returncode}: {details}"
        )


def create_artifact_receipt(args: argparse.Namespace) -> dict[str, Any]:
    verify_object_id(args.candidate_commit, "candidate commit")
    verify_object_id(args.candidate_tree, "candidate tree")
    if not re.fullmatch(r"[A-Z0-9]{10}", args.team_id):
        raise ValueError("team ID must be exactly 10 uppercase letters/digits")
    if args.archive.is_symlink() or not args.archive.is_dir():
        raise ValueError(f"Mac App Store archive must be a real directory: {args.archive}")
    if args.export_inspection.is_symlink() or not args.export_inspection.is_dir():
        raise ValueError(
            "Mac App Store package expansion must be a real directory: "
            f"{args.export_inspection}"
        )
    if args.pkg.is_symlink() or not args.pkg.is_file():
        raise ValueError(f"exported package must be a real file: {args.pkg}")
    expected_archive_app = Path(os.path.abspath(
        args.archive / "Products" / "Applications" / "OpenBurnBar.app"
    ))
    if Path(os.path.abspath(args.archive_app)) != expected_archive_app:
        raise ValueError(
            "archive host app must be the canonical OpenBurnBar.app inside the "
            f"selected archive: expected {expected_archive_app}, found "
            f"{Path(os.path.abspath(args.archive_app))}"
        )
    require_descendant(args.archive_app, args.archive, "archive host app")
    require_descendant(
        args.exported_app,
        args.export_inspection,
        "exported host app",
    )

    canonical_verifier = Path(__file__).with_name(
        "verify-openburnbar-mas-artifact.sh"
    ).resolve()
    if (
        args.artifact_verifier.is_symlink()
        or not args.artifact_verifier.is_file()
        or args.artifact_verifier.resolve() != canonical_verifier
    ):
        raise ValueError(
            "artifact verifier must be the canonical "
            "scripts/ci/verify-openburnbar-mas-artifact.sh"
        )

    archive_appex = safari_extension(args.archive_app, "archive host app")
    exported_appex = safari_extension(args.exported_app, "exported host app")
    run_artifact_verifier(
        canonical_verifier,
        app=args.archive_app,
        team_id=args.team_id,
        version=args.version,
        build=args.build,
        pkg=None,
        label="archive artifact verification",
    )
    run_artifact_verifier(
        canonical_verifier,
        app=args.exported_app,
        team_id=args.team_id,
        version=args.version,
        build=args.build,
        pkg=args.pkg,
        label="exported package verification",
    )

    return {
        "schemaVersion": 1,
        "platform": "MAC_OS",
        "status": "archive-export-verified",
        "candidate": {
            "commit": args.candidate_commit,
            "tree": args.candidate_tree,
        },
        "release": {
            "channel": "mac-app-store",
            "version": args.version,
            "build": args.build,
            "teamId": args.team_id,
            "createdAt": datetime.now(timezone.utc)
            .replace(microsecond=0)
            .isoformat()
            .replace("+00:00", "Z"),
        },
        "artifacts": {
            "archiveTreeSha256": sha256_tree(args.archive),
            "archiveHostAppTreeSha256": sha256_tree(args.archive_app),
            "archiveSafariExtensionTreeSha256": sha256_tree(archive_appex),
            "exportInspectionTreeSha256": sha256_tree(args.export_inspection),
            "exportedHostAppTreeSha256": sha256_tree(args.exported_app),
            "exportedSafariExtensionTreeSha256": sha256_tree(exported_appex),
            "packageSha256": sha256_file(args.pkg),
            "packageSize": args.pkg.stat().st_size,
        },
        "verification": {
            "artifactVerifier": "scripts/ci/verify-openburnbar-mas-artifact.sh",
            "archiveHostStatus": "passed",
            "exportedPackageStatus": "passed",
            "nestedSafariExtension": True,
            "profileCertificateMembership": True,
            "strictDeepNestedSignatures": True,
            "installerSignature": True,
            "gatekeeperInstallAssessment": True,
            "platform": "OSX",
            "getTaskAllow": False,
            "appSandbox": True,
        },
    }


def create_receipt(args: argparse.Namespace) -> dict[str, Any]:
    verify_object_id(args.candidate_commit, "candidate commit")
    verify_object_id(args.candidate_tree, "candidate tree")
    if not args.pkg.is_file() or args.pkg.is_symlink():
        raise ValueError(f"exported package must be a real file: {args.pkg}")
    appex = safari_extension(args.app, "exported app")
    validation = validate_submission_response(args.validation_response, "validation")
    upload = validate_upload(args.upload_response)
    delivery = validate_terminal_status(args.delivery_status, "delivery status")
    readback = validate_exact_build_readback(
        args.build_readback,
        expected_app_apple_id=args.app_apple_id,
        expected_bundle_identifier="com.openburnbar.app",
        expected_version=args.version,
        expected_build=args.build,
        expected_platform="MAC_OS",
    )
    if upload["deliveryId"] != args.delivery_id:
        raise ValueError(
            f"upload delivery ID {upload['deliveryId']!r} does not match queried delivery ID {args.delivery_id!r}"
        )
    return {
        "schemaVersion": 1,
        "platform": "MAC_OS",
        "status": "processed",
        "processedStatus": delivery["processedStatus"],
        "readbackStatus": readback["processedStatus"],
        "deliveryId": upload["deliveryId"],
        **({"requestId": upload["requestId"]} if "requestId" in upload else {}),
        "appAppleId": args.app_apple_id,
        "bundleIdentifier": "com.openburnbar.app",
        "version": args.version,
        "build": args.build,
        "candidate": {
            "commit": args.candidate_commit,
            "tree": args.candidate_tree,
        },
        "artifacts": {
            "archiveTreeSha256": sha256_tree(args.archive),
            "hostAppTreeSha256": sha256_tree(args.app),
            "safariExtensionTreeSha256": sha256_tree(appex),
            "packageSha256": sha256_file(args.pkg),
            "packageSize": args.pkg.stat().st_size,
        },
        "responses": {
            "validationSha256": validation["responseSha256"],
            "uploadSha256": upload["uploadResponseSha256"],
            "deliveryStatusSha256": delivery["responseSha256"],
            "exactBuildReadbackSha256": readback["responseSha256"],
        },
        "readbackQuery": {
            "platform": "macos",
            "appleId": args.app_apple_id,
            "bundleShortVersionString": args.version,
            "bundleVersion": args.build,
        },
        "readbackIdentity": {
            "platform": readback["platform"],
            "appAppleId": readback["appAppleId"],
            "bundleIdentifier": readback["bundleIdentifier"],
            "version": readback["version"],
            "build": readback["build"],
        },
    }


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    upload_parser = subparsers.add_parser("upload", help="validate upload JSON")
    upload_parser.add_argument("--response", required=True, type=Path)
    upload_parser.add_argument("--output", required=True, type=Path)

    validation_parser = subparsers.add_parser("validation", help="validate validation JSON")
    validation_parser.add_argument("--response", required=True, type=Path)
    validation_parser.add_argument("--output", required=True, type=Path)

    artifact_parser = subparsers.add_parser(
        "artifact-receipt",
        help="verify and receipt one candidate-bound MAS archive/export",
    )
    artifact_parser.add_argument("--candidate-commit", required=True)
    artifact_parser.add_argument("--candidate-tree", required=True)
    artifact_parser.add_argument("--team-id", required=True)
    artifact_parser.add_argument("--version", required=True)
    artifact_parser.add_argument("--build", required=True)
    artifact_parser.add_argument("--archive", required=True, type=Path)
    artifact_parser.add_argument("--archive-app", required=True, type=Path)
    artifact_parser.add_argument("--export-inspection", required=True, type=Path)
    artifact_parser.add_argument("--exported-app", required=True, type=Path)
    artifact_parser.add_argument("--pkg", required=True, type=Path)
    artifact_parser.add_argument("--artifact-verifier", required=True, type=Path)
    artifact_parser.add_argument("--output", required=True, type=Path)

    receipt_parser = subparsers.add_parser("receipt", help="create sanitized candidate-bound receipt")
    receipt_parser.add_argument("--validation-response", required=True, type=Path)
    receipt_parser.add_argument("--upload-response", required=True, type=Path)
    receipt_parser.add_argument("--delivery-status", required=True, type=Path)
    receipt_parser.add_argument("--build-readback", required=True, type=Path)
    receipt_parser.add_argument("--delivery-id", required=True)
    receipt_parser.add_argument("--app-apple-id", required=True)
    receipt_parser.add_argument("--version", required=True)
    receipt_parser.add_argument("--build", required=True)
    receipt_parser.add_argument("--candidate-commit", required=True)
    receipt_parser.add_argument("--candidate-tree", required=True)
    receipt_parser.add_argument("--archive", required=True, type=Path)
    receipt_parser.add_argument("--app", required=True, type=Path)
    receipt_parser.add_argument("--pkg", required=True, type=Path)
    receipt_parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def write_json(path: Path, value: dict[str, Any]) -> None:
    write_exclusive_json(path, value)


def main() -> int:
    args = parse_args()
    try:
        if args.command == "upload":
            result: dict[str, Any] = validate_upload(args.response)
        elif args.command == "validation":
            result = validate_submission_response(args.response, "validation")
        elif args.command == "artifact-receipt":
            result = create_artifact_receipt(args)
        else:
            result = create_receipt(args)
        write_json(args.output, result)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
