#!/usr/bin/env python3
"""Record installed MAS receipt-file presence without claiming cryptographic validity."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import re
import stat
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from exclusive_json import write_exclusive_json


HEX_OBJECT_ID = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
SAFE_VERSION = re.compile(r"^[0-9A-Za-z][0-9A-Za-z._-]*$")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_owner_only_json(path: Path, value: dict[str, object]) -> None:
    write_exclusive_json(path, value)


def require_exact_keys(value: dict[str, object], keys: set[str], label: str) -> None:
    actual = set(value)
    if actual != keys:
        raise ValueError(
            f"{label} fields must be exactly {sorted(keys)!r}; found {sorted(actual)!r}"
        )


def load_processing_receipt(path: Path) -> dict[str, object]:
    if path.is_symlink() or not path.is_file():
        raise ValueError(f"App Store Connect processing receipt must be a real file: {path}")
    metadata = os.lstat(path)
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
        raise ValueError("App Store Connect processing receipt must be one regular file")
    if metadata.st_uid != os.getuid():
        raise ValueError("App Store Connect processing receipt must be owned by the current user")
    if stat.S_IMODE(metadata.st_mode) & 0o077:
        raise ValueError("App Store Connect processing receipt must not be group/world accessible")
    try:
        value = json.loads(path.read_bytes())
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"App Store Connect processing receipt is invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise ValueError("App Store Connect processing receipt must be a JSON object")
    if value.get("schemaVersion") != 1:
        raise ValueError("App Store Connect processing receipt schema version is unsupported")
    if value.get("platform") != "MAC_OS" or value.get("status") != "processed":
        raise ValueError("App Store Connect receipt must prove a processed macOS build")
    if value.get("bundleIdentifier") != "com.openburnbar.app":
        raise ValueError("App Store Connect receipt is for the wrong bundle identifier")

    app_apple_id = value.get("appAppleId")
    delivery_id = value.get("deliveryId")
    version = value.get("version")
    build = value.get("build")
    if not isinstance(app_apple_id, str) or not app_apple_id.isdigit():
        raise ValueError("App Store Connect receipt app Apple ID is invalid")
    if (
        not isinstance(delivery_id, str)
        or not delivery_id
        or "\n" in delivery_id
        or "\r" in delivery_id
    ):
        raise ValueError("App Store Connect receipt delivery ID is invalid")
    for label, candidate in (("version", version), ("build", build)):
        if not isinstance(candidate, str) or not SAFE_VERSION.fullmatch(candidate):
            raise ValueError(f"App Store Connect receipt {label} is invalid")

    candidate = value.get("candidate")
    if not isinstance(candidate, dict):
        raise ValueError("App Store Connect receipt is missing candidate identity")
    require_exact_keys(candidate, {"commit", "tree"}, "candidate identity")
    commit = candidate.get("commit")
    tree = candidate.get("tree")
    if not isinstance(commit, str) or not HEX_OBJECT_ID.fullmatch(commit):
        raise ValueError("App Store Connect receipt candidate commit is invalid")
    if not isinstance(tree, str) or not HEX_OBJECT_ID.fullmatch(tree):
        raise ValueError("App Store Connect receipt candidate tree is invalid")

    readback = value.get("readbackIdentity")
    if not isinstance(readback, dict):
        raise ValueError("App Store Connect receipt is missing returned build identity")
    expected_readback = {
        "platform": "MAC_OS",
        "appAppleId": app_apple_id,
        "bundleIdentifier": "com.openburnbar.app",
        "version": version,
        "build": build,
    }
    require_exact_keys(readback, set(expected_readback), "returned build identity")
    if readback != expected_readback:
        raise ValueError("App Store Connect returned build identity does not match the receipt")

    responses = value.get("responses")
    artifacts = value.get("artifacts")
    if not isinstance(responses, dict) or not isinstance(artifacts, dict):
        raise ValueError("App Store Connect receipt is missing response or artifact bindings")
    for key in (
        "validationSha256",
        "uploadSha256",
        "deliveryStatusSha256",
        "exactBuildReadbackSha256",
    ):
        digest = responses.get(key)
        if not isinstance(digest, str) or not SHA256.fullmatch(digest):
            raise ValueError(f"App Store Connect receipt {key} is invalid")
    for key in (
        "archiveTreeSha256",
        "hostAppTreeSha256",
        "safariExtensionTreeSha256",
        "packageSha256",
    ):
        digest = artifacts.get(key)
        if not isinstance(digest, str) or not SHA256.fullmatch(digest):
            raise ValueError(f"App Store Connect receipt {key} is invalid")
    return value


def verify(
    app: Path,
    *,
    expected_version: str,
    expected_build: str,
    candidate_commit: str,
    candidate_tree: str,
) -> dict[str, object]:
    if app.is_symlink() or not app.is_dir():
        raise ValueError(f"installed app must be a real directory: {app}")
    info_path = app / "Contents" / "Info.plist"
    receipt = app / "Contents" / "_MASReceipt" / "receipt"
    if info_path.is_symlink() or not info_path.is_file():
        raise ValueError("installed app is missing a real Contents/Info.plist")
    receipt_stat = os.lstat(receipt)
    if stat.S_ISLNK(receipt_stat.st_mode) or not stat.S_ISREG(receipt_stat.st_mode):
        raise ValueError("installed _MASReceipt/receipt must be a real regular file")
    if receipt_stat.st_size <= 0:
        raise ValueError("installed _MASReceipt/receipt is empty")
    if receipt_stat.st_nlink != 1:
        raise ValueError("installed _MASReceipt/receipt must have exactly one hard link")
    with info_path.open("rb") as file:
        info = plistlib.load(file)
    expected = {
        "CFBundleIdentifier": "com.openburnbar.app",
        "CFBundleShortVersionString": expected_version,
        "CFBundleVersion": expected_build,
    }
    for key, wanted in expected.items():
        actual = info.get(key)
        if actual != wanted:
            raise ValueError(f"installed {key} must be {wanted!r}; found {actual!r}")
    if len(candidate_commit) != 40 or any(character not in "0123456789abcdef" for character in candidate_commit):
        raise ValueError("candidate commit must be a lowercase 40-character Git object ID")
    if len(candidate_tree) != 40 or any(character not in "0123456789abcdef" for character in candidate_tree):
        raise ValueError("candidate tree must be a lowercase 40-character Git object ID")
    return {
        "schemaVersion": 1,
        "platform": "MAC_OS",
        "status": "installed-receipt-file-observed",
        "bundleIdentifier": "com.openburnbar.app",
        "version": expected_version,
        "build": expected_build,
        "candidateCommit": candidate_commit,
        "candidateTree": candidate_tree,
        "receiptFilePresent": True,
        "receiptFileSha256": sha256(receipt),
        "receiptFileSize": receipt_stat.st_size,
        "receiptCryptographicVerification": "HOLD-unavailable",
        "storeReceiptCertification": "HOLD",
    }


def verify_processed_install(app: Path, processing_receipt: Path) -> dict[str, object]:
    processing = load_processing_receipt(processing_receipt)
    candidate = processing["candidate"]
    if not isinstance(candidate, dict):
        raise ValueError("App Store Connect receipt candidate identity is invalid")
    result = verify(
        app,
        expected_version=str(processing["version"]),
        expected_build=str(processing["build"]),
        candidate_commit=str(candidate["commit"]),
        candidate_tree=str(candidate["tree"]),
    )
    artifacts = processing["artifacts"]
    if not isinstance(artifacts, dict):
        raise ValueError("App Store Connect receipt artifact bindings are invalid")
    result["appStoreConnectProcessingEvidence"] = {
        "processingReceiptSha256": sha256(processing_receipt),
        "deliveryId": processing["deliveryId"],
        "appAppleId": processing["appAppleId"],
        "processedStatus": processing["processedStatus"],
        "readbackStatus": processing["readbackStatus"],
        "packageSha256": artifacts["packageSha256"],
    }
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--processing-receipt", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    try:
        result = verify_processed_install(
            args.app,
            args.processing_receipt,
        )
        write_owner_only_json(args.output, result)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
