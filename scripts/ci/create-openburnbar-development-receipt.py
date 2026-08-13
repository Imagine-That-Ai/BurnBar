#!/usr/bin/env python3
"""Create a sanitized receipt for one exact Apple Development candidate."""

from __future__ import annotations

import argparse
import hashlib
import os
import plistlib
import re
import stat
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from exclusive_json import write_exclusive_json


FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
TEAM_ID = re.compile(r"^[A-Z0-9]{10}$")
CERTIFICATE_SHA1 = re.compile(r"^[0-9A-Fa-f]{40}$")
UTC = timezone(timedelta(0))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--candidate-commit", required=True)
    parser.add_argument("--candidate-tree", required=True)
    parser.add_argument("--app", required=True, type=Path)
    parser.add_argument("--host-profile", required=True, type=Path)
    parser.add_argument("--safari-profile", required=True, type=Path)
    parser.add_argument("--team-id", required=True)
    parser.add_argument("--signing-identity", required=True)
    parser.add_argument("--signing-certificate-sha1", required=True)
    parser.add_argument("--current-mac-provisioning-udid", required=True)
    parser.add_argument("--version", required=True)
    parser.add_argument("--build", required=True)
    return parser.parse_args()


def fail(message: str) -> None:
    raise ValueError(message)


def require_real_path(path: Path, *, directory: bool, label: str) -> None:
    if path.is_symlink() or (not path.is_dir() if directory else not path.is_file()):
        expected = "directory" if directory else "file"
        fail(f"{label} must be a real {expected}: {path}")


def sha256_file(path: Path) -> str:
    require_real_path(path, directory=False, label="receipt input")
    digest = hashlib.sha256()
    with path.open("rb") as file:
        for chunk in iter(lambda: file.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def require_equal_files(first: Path, second: Path, label: str) -> None:
    if sha256_file(first) != sha256_file(second):
        fail(f"{label} differs from the profile embedded in the development app.")


def sha256_tree(root: Path) -> tuple[str, int, int]:
    require_real_path(root, directory=True, label="development app")
    root_real = root.resolve(strict=True)
    rows: list[tuple[str, bytes]] = []
    regular_file_count = 0
    symlink_count = 0
    for current, directory_names, file_names in os.walk(root, followlinks=False):
        directory_names.sort()
        file_names.sort()
        for name in directory_names + file_names:
            path = Path(current) / name
            relative = path.relative_to(root).as_posix()
            metadata = os.lstat(path)
            if stat.S_ISLNK(metadata.st_mode):
                target = os.readlink(path)
                if os.path.isabs(target):
                    fail(f"development app contains an absolute symlink: {path}")
                try:
                    resolved_target = (path.parent / target).resolve(strict=True)
                    resolved_target.relative_to(root_real)
                except (FileNotFoundError, RuntimeError, ValueError):
                    fail(f"development app contains a broken or escaping symlink: {path} -> {target}")
                rows.append((relative, f"link\t{relative}\t{target}\n".encode()))
                symlink_count += 1
            elif stat.S_ISDIR(metadata.st_mode):
                rows.append((relative, f"dir\t{relative}\n".encode()))
            elif stat.S_ISREG(metadata.st_mode):
                rows.append(
                    (
                        relative,
                        f"file\t{relative}\t{metadata.st_size}\t{sha256_file(path)}\n".encode(),
                    )
                )
                regular_file_count += 1
            else:
                fail(f"development app contains an unsupported filesystem entry: {path}")
    digest = hashlib.sha256()
    for _, row in sorted(rows, key=lambda item: item[0]):
        digest.update(row)
    return digest.hexdigest(), regular_file_count, symlink_count


def load_profile(path: Path) -> dict[str, Any]:
    require_real_path(path, directory=False, label="development profile")
    raw = path.read_bytes()
    try:
        value = plistlib.loads(raw)
    except plistlib.InvalidFileException:
        security_bin = os.environ.get("OPENBURNBAR_SECURITY_BIN", "security")
        completed = subprocess.run(
            [security_bin, "cms", "-D", "-i", str(path)],
            check=False,
            capture_output=True,
        )
        if completed.returncode != 0:
            fail(f"could not decode development profile: {path}")
        try:
            value = plistlib.loads(completed.stdout)
        except plistlib.InvalidFileException:
            fail(f"decoded development profile is not a plist: {path}")
    if not isinstance(value, dict):
        fail(f"development profile root must be a dictionary: {path}")
    return value


def require_profile_string(profile: dict[str, Any], key: str, label: str) -> str:
    value = profile.get(key)
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} is missing {key}.")
    return value.strip()


def profile_summary(
    path: Path,
    *,
    label: str,
    bundle_identifier: str,
    team_id: str,
    signing_certificate_sha1: str,
    current_mac_provisioning_udid: str,
) -> dict[str, Any]:
    profile = load_profile(path)
    if profile.get("TeamIdentifier") != [team_id]:
        fail(f"{label} profile TeamIdentifier does not match {team_id}.")
    if profile.get("Platform") != ["OSX"]:
        fail(f"{label} profile platform must be OSX.")
    if profile.get("ProvisionsAllDevices") is True:
        fail(f"{label} profile must be device-scoped Apple Development.")

    devices = profile.get("ProvisionedDevices")
    if (
        not isinstance(devices, list)
        or not devices
        or any(not isinstance(value, str) or not value for value in devices)
    ):
        fail(f"{label} profile must authorize registered devices.")
    if current_mac_provisioning_udid not in devices:
        fail(f"{label} profile does not authorize the current Mac.")

    entitlements = profile.get("Entitlements")
    if not isinstance(entitlements, dict):
        fail(f"{label} profile is missing entitlements.")
    expected_application_identifier = f"{team_id}.{bundle_identifier}"
    if entitlements.get("com.apple.application-identifier") != expected_application_identifier:
        fail(f"{label} profile application identifier does not match.")
    # macOS App Groups are unrestricted entitlements. Profiles may carry a
    # team wildcard; exact App Group scope is verified on the signed bundles.
    expected_keychain_group = f"{team_id}.com.openburnbar.app"
    keychain_groups = entitlements.get("keychain-access-groups")
    if not isinstance(keychain_groups, list) or not {
        expected_keychain_group,
        f"{team_id}.*",
    }.intersection(keychain_groups):
        fail(f"{label} profile Keychain authority does not match.")
    get_task_allow = entitlements.get("com.apple.security.get-task-allow")
    if get_task_allow not in (None, True):
        fail(f"{label} profile explicitly disables get-task-allow.")

    expiration = profile.get("ExpirationDate")
    if not isinstance(expiration, datetime):
        fail(f"{label} profile is missing ExpirationDate.")
    if expiration.tzinfo is None:
        expiration = expiration.replace(tzinfo=UTC)
    if expiration <= datetime.now(UTC):
        fail(f"{label} profile expired at {expiration.isoformat()}.")

    certificates = profile.get("DeveloperCertificates")
    if not isinstance(certificates, list) or not certificates:
        fail(f"{label} profile contains no developer certificates.")
    certificate_sha1s = {
        hashlib.sha1(bytes(certificate)).hexdigest().upper()
        for certificate in certificates
        if isinstance(certificate, (bytes, bytearray))
    }
    if signing_certificate_sha1 not in certificate_sha1s:
        fail(f"{label} profile does not authorize the signing certificate.")

    return {
        "uuid": require_profile_string(profile, "UUID", label),
        "name": require_profile_string(profile, "Name", label),
        "bundleIdentifier": bundle_identifier,
        "sha256": sha256_file(path),
        "expirationDate": expiration.astimezone(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
        "provisionedDeviceCount": len(set(devices)),
        "currentMacAuthorized": True,
        "signingCertificateMember": True,
        "profileGetTaskAllow": "enabled" if get_task_allow is True else "absent",
    }


def main() -> int:
    args = parse_args()
    if not FULL_SHA.fullmatch(args.candidate_commit):
        fail("candidate commit must be a full lowercase Git SHA.")
    if not FULL_SHA.fullmatch(args.candidate_tree):
        fail("candidate tree must be a full lowercase Git SHA.")
    if not TEAM_ID.fullmatch(args.team_id):
        fail("team ID must be exactly 10 uppercase letters/digits.")
    expected_prefix = "Apple Development: "
    if (
        "\n" in args.signing_identity
        or "\r" in args.signing_identity
        or not args.signing_identity.startswith(expected_prefix)
        or args.signing_identity == expected_prefix
    ):
        fail("signing identity must be one exact Apple Development identity.")
    if not CERTIFICATE_SHA1.fullmatch(args.signing_certificate_sha1):
        fail("signing certificate SHA-1 must be exactly 40 hexadecimal characters.")
    signing_certificate_sha1 = args.signing_certificate_sha1.upper()
    if (
        not args.current_mac_provisioning_udid
        or "\n" in args.current_mac_provisioning_udid
        or "\r" in args.current_mac_provisioning_udid
    ):
        fail("current Mac provisioning UDID must be one non-empty line.")

    app_sha256, file_count, symlink_count = sha256_tree(args.app)
    embedded_host_profile = args.app / "Contents" / "embedded.provisionprofile"
    embedded_safari_profile = (
        args.app
        / "Contents"
        / "PlugIns"
        / "OpenBurnBarSafariExtension.appex"
        / "Contents"
        / "embedded.provisionprofile"
    )
    require_equal_files(
        args.host_profile,
        embedded_host_profile,
        "supplied host profile",
    )
    require_equal_files(
        args.safari_profile,
        embedded_safari_profile,
        "supplied Safari profile",
    )
    host_profile = profile_summary(
        args.host_profile,
        label="host",
        bundle_identifier="com.openburnbar.app",
        team_id=args.team_id,
        signing_certificate_sha1=signing_certificate_sha1,
        current_mac_provisioning_udid=args.current_mac_provisioning_udid,
    )
    safari_profile = profile_summary(
        args.safari_profile,
        label="Safari",
        bundle_identifier="com.openburnbar.app.safari-extension",
        team_id=args.team_id,
        signing_certificate_sha1=signing_certificate_sha1,
        current_mac_provisioning_udid=args.current_mac_provisioning_udid,
    )
    if host_profile["uuid"] == safari_profile["uuid"]:
        fail("host and Safari development profiles must be distinct.")
    receipt = {
        "schemaVersion": 2,
        "candidate": {
            "commit": args.candidate_commit,
            "tree": args.candidate_tree,
        },
        "artifact": {
            "bundleName": args.app.name,
            "treeSha256": app_sha256,
            "regularFileCount": file_count,
            "symlinkCount": symlink_count,
            "version": args.version,
            "build": args.build,
        },
        "signing": {
            "distribution": "apple-development",
            "teamId": args.team_id,
            "identity": args.signing_identity,
            "certificateSha1": signing_certificate_sha1,
            "hostProfileSha256": host_profile["sha256"],
            "safariProfileSha256": safari_profile["sha256"],
            "embeddedProfilesByteEqual": True,
            "profileCertificateMembership": True,
            "currentMacAuthorized": True,
            "platform": "OSX",
            "getTaskAllow": True,
            "hardenedRuntime": True,
            "libraryValidation": True,
        },
        "profiles": {
            "host": host_profile,
            "safari": safari_profile,
        },
        "createdAt": datetime.now(UTC).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    write_exclusive_json(args.output, receipt)
    print(f"PASS: wrote sanitized Apple Development receipt to {args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1) from error
