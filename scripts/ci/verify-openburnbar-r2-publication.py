#!/usr/bin/env python3
"""Verify and receipt an exact OpenBurnBar Cloudflare R2 publication."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import sys
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlsplit, urlunsplit

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "lib"))
from exclusive_json import write_exclusive_json


FULL_SHA = re.compile(r"^[0-9a-f]{40}$")
SHA256 = re.compile(r"^[0-9a-f]{64}$")
TEAM_ID = re.compile(r"^[A-Z0-9]{10}$")
SAFE_FILE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._+-]*$")
SAFE_BUCKET = re.compile(r"^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$")
NOTARY_ID = re.compile(
    r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
    r"[0-9a-f]{4}-[0-9a-f]{12}$"
)
SPARKLE_NAMESPACE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REQUIRED_ARTIFACT_KINDS = (
    "appcast",
    "checksums",
    "correspondingSource",
    "dmg",
    "latestMetadata",
    "releaseMetadata",
    "sbom",
    "zip",
)
PUBLIC_OBJECT_KINDS = (*REQUIRED_ARTIFACT_KINDS, "releaseReceipt")
CHECKSUM_BOUND_ARTIFACT_KINDS = (
    "appcast",
    "correspondingSource",
    "dmg",
    "latestMetadata",
    "sbom",
    "zip",
)
PUBLICATION_PLAN = (
    ("correspondingSource", "immutable-payload"),
    ("dmg", "immutable-payload"),
    ("sbom", "immutable-payload"),
    ("zip", "immutable-payload"),
    ("checksums", "immutable-payload"),
    ("releaseReceipt", "supporting-metadata"),
    ("releaseMetadata", "supporting-metadata"),
    ("appcast", "discovery-commit-set"),
    ("latestMetadata", "discovery-commit-set"),
)
PUBLICATION_PHASES = tuple(dict.fromkeys(phase for _, phase in PUBLICATION_PLAN))
DISCOVERY_COMMIT_KINDS = ("appcast", "latestMetadata")
IMMUTABLE_ARTIFACT_KINDS = {
    kind for kind, phase in PUBLICATION_PLAN if phase == "immutable-payload"
}


def fail(message: str) -> None:
    raise ValueError(message)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    preflight = subparsers.add_parser(
        "preflight",
        help="validate local release artifacts and write an upload manifest",
    )
    preflight.add_argument("--release-receipt", required=True, type=Path)
    preflight.add_argument("--downloads-dir", required=True, type=Path)
    preflight.add_argument("--candidate-commit", required=True)
    preflight.add_argument("--candidate-tree", required=True)
    preflight.add_argument("--bucket", required=True)
    preflight.add_argument("--public-base-url", required=True)
    preflight.add_argument("--output", required=True, type=Path)

    receipt = subparsers.add_parser(
        "receipt",
        help="compare downloaded public bytes and write a publication receipt",
    )
    receipt.add_argument("--preflight", required=True, type=Path)
    receipt.add_argument("--release-receipt", required=True, type=Path)
    receipt.add_argument("--downloads-dir", required=True, type=Path)
    receipt.add_argument("--public-download-dir", required=True, type=Path)
    receipt.add_argument("--public-header-dir", required=True, type=Path)
    receipt.add_argument("--discovery-snapshot", required=True, type=Path)
    receipt.add_argument("--platform-trust-verifier", required=True)
    receipt.add_argument(
        "--platform-trust-mode",
        choices=("canonical", "test-override"),
        required=True,
    )
    receipt.add_argument("--output", required=True, type=Path)

    verify_phase = subparsers.add_parser(
        "verify-public-phase",
        help="verify publicly downloaded bytes and headers for one publication phase",
    )
    verify_phase.add_argument("--preflight", required=True, type=Path)
    verify_phase.add_argument("--public-download-dir", required=True, type=Path)
    verify_phase.add_argument("--public-header-dir", required=True, type=Path)
    verify_phase.add_argument(
        "--phase",
        choices=PUBLICATION_PHASES,
        required=True,
    )

    snapshot = subparsers.add_parser(
        "snapshot-discovery",
        help="record the exact current public state of both discovery objects",
    )
    snapshot.add_argument("--preflight", required=True, type=Path)
    snapshot.add_argument("--public-download-dir", required=True, type=Path)
    snapshot.add_argument("--public-header-dir", required=True, type=Path)
    snapshot.add_argument("--output", required=True, type=Path)

    verify_rollback = subparsers.add_parser(
        "verify-discovery-rollback",
        help="prove both discovery objects match their pre-publication snapshot",
    )
    verify_rollback.add_argument("--snapshot", required=True, type=Path)
    verify_rollback.add_argument(
        "--public-download-dir",
        required=True,
        type=Path,
    )
    verify_rollback.add_argument(
        "--public-header-dir",
        required=True,
        type=Path,
    )

    return parser.parse_args()


def now_utc() -> str:
    return (
        datetime.now(timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z")
    )


def require_dict(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(f"{label} must be a JSON object.")
    return value


def require_list(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        fail(f"{label} must be a JSON array.")
    return value


def open_safe_file(
    path: Path,
    label: str,
    *,
    required_mode: int | None = None,
) -> tuple[int, os.stat_result]:
    path = Path(path)
    if not path.name or path.name in {".", ".."}:
        fail(f"{label} must name a file: {path}")
    parent = path.parent
    if parent.is_symlink() or not parent.is_dir():
        fail(f"{label} parent must be a real directory: {parent}")

    parent_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    parent_flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = -1
    try:
        parent_descriptor = os.open(parent, parent_flags)
        try:
            flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
            flags |= getattr(os, "O_NOFOLLOW", 0)
            descriptor = os.open(path.name, flags, dir_fd=parent_descriptor)
        finally:
            os.close(parent_descriptor)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            fail(f"{label} must be a regular file: {path}")
        if metadata.st_nlink != 1:
            fail(f"{label} must have exactly one hard link: {path}")
        if metadata.st_uid != os.geteuid():
            fail(f"{label} must be owned by the current user: {path}")
        actual_mode = stat.S_IMODE(metadata.st_mode)
        if required_mode is not None and actual_mode != required_mode:
            fail(
                f"{label} mode must be {required_mode:04o}; "
                f"found {actual_mode:04o}: {path}"
            )
        return descriptor, metadata
    except OSError as error:
        if descriptor >= 0:
            os.close(descriptor)
        fail(f"{label} is unsafe or unreadable at {path}: {error}")
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
        raise


def read_safe_bytes(
    path: Path,
    label: str,
    *,
    required_mode: int | None = None,
) -> bytes:
    descriptor, _ = open_safe_file(path, label, required_mode=required_mode)
    try:
        with os.fdopen(descriptor, "rb") as file:
            descriptor = -1
            return file.read()
    except OSError as error:
        fail(f"{label} is unreadable at {path}: {error}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def load_json(
    path: Path,
    label: str,
    *,
    required_mode: int | None = None,
) -> dict[str, Any]:
    try:
        payload = read_safe_bytes(path, label, required_mode=required_mode)
        value = json.loads(payload.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        fail(f"{label} is invalid JSON at {path}: {error}")
    return require_dict(value, label)


def require_real_directory(path: Path, label: str) -> Path:
    if not path.is_dir() or path.is_symlink():
        fail(f"{label} must be a real directory: {path}")
    resolved = path.resolve()
    metadata = resolved.stat()
    if metadata.st_uid != os.geteuid():
        fail(f"{label} must be owned by the current user: {resolved}")
    return resolved


def file_digest_and_size(
    path: Path,
    label: str,
    *,
    required_mode: int | None = None,
) -> tuple[str, int]:
    descriptor, metadata = open_safe_file(
        path,
        label,
        required_mode=required_mode,
    )
    digest = hashlib.sha256()
    try:
        with os.fdopen(descriptor, "rb") as file:
            descriptor = -1
            for chunk in iter(lambda: file.read(1024 * 1024), b""):
                digest.update(chunk)
    except OSError as error:
        fail(f"{label} is unreadable at {path}: {error}")
    finally:
        if descriptor >= 0:
            os.close(descriptor)
    return digest.hexdigest(), metadata.st_size


def sha256(
    path: Path,
    label: str,
    *,
    required_mode: int | None = None,
) -> str:
    return file_digest_and_size(
        path,
        label,
        required_mode=required_mode,
    )[0]


def safe_file_name(value: Any, label: str) -> str:
    if not isinstance(value, str) or not SAFE_FILE_NAME.fullmatch(value):
        fail(f"{label} must be a plain release artifact file name.")
    if Path(value).name != value or value in {".", ".."}:
        fail(f"{label} must not contain path traversal.")
    return value


def normalize_public_base_url(value: str) -> str:
    parsed = urlsplit(value)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
    ):
        fail(
            "public base URL must be an HTTPS origin/path without credentials, "
            "query parameters, or fragments."
        )
    path = parsed.path.rstrip("/")
    return urlunsplit((parsed.scheme, parsed.netloc, path, "", ""))


def public_url(base_url: str, file_name: str) -> str:
    return f"{base_url}/{quote(file_name, safe='._+-')}"


def content_type(file_name: str) -> str:
    if file_name.endswith(".dmg"):
        return "application/x-apple-diskimage"
    if file_name.endswith(".tar.gz"):
        return "application/gzip"
    if file_name.endswith(".zip"):
        return "application/zip"
    if file_name.endswith(".xml"):
        return "application/xml; charset=utf-8"
    if file_name.endswith(".txt") or file_name.endswith(".sha256"):
        return "text/plain; charset=utf-8"
    if file_name.endswith(".json"):
        return "application/json; charset=utf-8"
    return "application/octet-stream"


def cache_control(kind: str) -> str:
    if kind in IMMUTABLE_ARTIFACT_KINDS:
        return "public, max-age=31536000, immutable"
    return "public, max-age=300"


def normalize_content_type(value: str) -> str:
    if not value or any(character in value for character in "\r\n\0"):
        fail("observed Content-Type is empty or malformed.")
    parts = [part.strip() for part in value.split(";")]
    media_type = parts[0].lower()
    if not re.fullmatch(
        r"[a-z0-9!#$&^_.+-]+/[a-z0-9!#$&^_.+-]+",
        media_type,
    ):
        fail(f"observed Content-Type media type is invalid: {value!r}.")
    parameters = []
    for parameter in parts[1:]:
        if "=" not in parameter:
            fail(f"observed Content-Type parameter is invalid: {value!r}.")
        name, parameter_value = parameter.split("=", 1)
        name = name.strip().lower()
        parameter_value = parameter_value.strip().lower()
        if not name or not parameter_value:
            fail(f"observed Content-Type parameter is invalid: {value!r}.")
        parameters.append((name, parameter_value))
    parameters.sort()
    suffix = "".join(f"; {name}={parameter}" for name, parameter in parameters)
    return f"{media_type}{suffix}"


def normalize_cache_control(value: str) -> tuple[str, ...]:
    if not value or any(character in value for character in "\r\n\0"):
        fail("observed Cache-Control is empty or malformed.")
    directives: dict[str, str | None] = {}
    for raw_directive in value.split(","):
        directive = raw_directive.strip()
        if not directive:
            fail(f"observed Cache-Control contains an empty directive: {value!r}.")
        if "=" in directive:
            name, directive_value = directive.split("=", 1)
            name = name.strip().lower()
            directive_value = directive_value.strip().lower()
            if not directive_value:
                fail(f"observed Cache-Control directive is invalid: {value!r}.")
        else:
            name = directive.lower()
            directive_value = None
        if not re.fullmatch(r"[a-z0-9!#$%&'*+.^_`|~-]+", name):
            fail(f"observed Cache-Control directive is invalid: {value!r}.")
        if name in directives:
            fail(f"observed Cache-Control repeats directive {name!r}.")
        directives[name] = directive_value
    return tuple(
        sorted(
            name if directive_value is None else f"{name}={directive_value}"
            for name, directive_value in directives.items()
        )
    )


def parse_http_response_headers(
    path: Path,
    label: str,
    *,
    require_entity_headers: bool,
) -> dict[str, Any]:
    try:
        text = read_safe_bytes(path, label).decode("iso-8859-1")
    except UnicodeDecodeError as error:
        fail(f"{label} is not valid HTTP header bytes: {error}")

    responses: list[tuple[int, dict[str, list[str]]]] = []
    for block in re.split(r"\r?\n\r?\n", text):
        lines = block.splitlines()
        if not lines or not lines[0].startswith("HTTP/"):
            continue
        status_parts = lines[0].split()
        if len(status_parts) < 2 or not status_parts[1].isdigit():
            fail(f"{label} contains an invalid HTTP status line.")
        status_code = int(status_parts[1])
        headers: dict[str, list[str]] = {}
        for line in lines[1:]:
            if line.startswith((" ", "\t")):
                fail(f"{label} contains an obsolete folded HTTP header.")
            if ":" not in line:
                fail(f"{label} contains a malformed HTTP header line.")
            name, value = line.split(":", 1)
            normalized_name = name.strip().lower()
            if not normalized_name:
                fail(f"{label} contains an empty HTTP header name.")
            headers.setdefault(normalized_name, []).append(value.strip())
        responses.append((status_code, headers))

    if not responses:
        fail(f"{label} contains no HTTP response headers.")
    status_code, headers = responses[-1]
    observed: dict[str, Any] = {"statusCode": status_code}
    if not require_entity_headers:
        return observed
    for header_name, output_name in (
        ("content-type", "contentType"),
        ("cache-control", "cacheControl"),
    ):
        values = headers.get(header_name, [])
        if len(values) != 1 or not values[0]:
            fail(
                f"{label} must contain exactly one non-empty "
                f"{header_name} header."
            )
        observed[output_name] = values[0]
    return observed


def parse_observed_http_headers(path: Path, label: str) -> dict[str, Any]:
    observed = parse_http_response_headers(
        path,
        label,
        require_entity_headers=True,
    )
    if observed["statusCode"] != 200:
        fail(
            f"{label} final HTTP status is "
            f"{observed['statusCode']}, expected 200."
        )
    return observed


def validate_signature_receipt(value: Any, team_id: str) -> None:
    signing = require_dict(value, "Developer ID signing receipt")
    if signing.get("schemaVersion") != 1:
        fail("Developer ID signing receipt schema version is unsupported.")
    if signing.get("distribution") != "developer-id":
        fail("Developer ID signing receipt distribution is invalid.")
    if signing.get("teamId") != team_id:
        fail("Developer ID signing receipt team does not match the release.")
    verification = require_dict(
        signing.get("verification"),
        "Developer ID signing verification",
    )
    expected = {
        "embeddedProfilesByteEqual": True,
        "profileCertificateMembership": True,
        "strictDeepNestedSignatures": True,
        "getTaskAllow": False,
        "platform": "OSX",
    }
    for key, expected_value in expected.items():
        if verification.get(key) != expected_value:
            fail(f"Developer ID signing verification is missing {key}.")


def validate_notarization(value: Any, label: str) -> None:
    notarization = require_dict(value, label)
    submission_id = notarization.get("id")
    if (
        notarization.get("status") != "Accepted"
        or not isinstance(submission_id, str)
        or not NOTARY_ID.fullmatch(submission_id)
    ):
        fail(f"{label} must contain an accepted notarization submission.")
    submitted_artifact = require_dict(
        notarization.get("submittedArtifact"),
        f"{label} submitted artifact",
    )
    safe_file_name(
        submitted_artifact.get("fileName"),
        f"{label} submitted artifact file name",
    )
    submitted_sha = submitted_artifact.get("sha256")
    submitted_size = submitted_artifact.get("sizeBytes")
    if not isinstance(submitted_sha, str) or not SHA256.fullmatch(submitted_sha):
        fail(f"{label} submitted artifact SHA-256 is invalid.")
    if not isinstance(submitted_size, int) or submitted_size <= 0:
        fail(f"{label} submitted artifact size is invalid.")


def validate_release_receipt(
    path: Path,
    *,
    candidate_commit: str | None = None,
    candidate_tree: str | None = None,
) -> tuple[dict[str, Any], dict[str, dict[str, Any]]]:
    receipt = load_json(
        path,
        "Developer ID release receipt",
        required_mode=0o600,
    )
    if receipt.get("schemaVersion") != 1:
        fail("Developer ID release receipt schema version is unsupported.")

    candidate = require_dict(receipt.get("candidate"), "release receipt candidate")
    commit = candidate.get("commit")
    tree = candidate.get("tree")
    if not isinstance(commit, str) or not FULL_SHA.fullmatch(commit):
        fail("release receipt candidate commit is invalid.")
    if not isinstance(tree, str) or not FULL_SHA.fullmatch(tree):
        fail("release receipt candidate tree is invalid.")
    if candidate_commit is not None and commit != candidate_commit:
        fail("release receipt candidate commit does not match the upload candidate.")
    if candidate_tree is not None and tree != candidate_tree:
        fail("release receipt candidate tree does not match the upload candidate.")

    release = require_dict(receipt.get("release"), "release receipt release")
    version = release.get("version")
    build = release.get("build")
    team_id = release.get("teamId")
    if (
        not isinstance(version, str)
        or not version
        or not isinstance(build, str)
        or not build
    ):
        fail("release receipt version/build are invalid.")
    if release.get("channel") != "direct-download":
        fail("release receipt is not for the direct-download channel.")
    if not isinstance(team_id, str) or not TEAM_ID.fullmatch(team_id):
        fail("release receipt Apple team ID is invalid.")

    validate_signature_receipt(receipt.get("signing"), team_id)
    notarization = require_dict(
        receipt.get("notarization"),
        "release receipt notarization",
    )
    validate_notarization(notarization.get("app"), "app notarization")
    validate_notarization(notarization.get("dmg"), "DMG notarization")

    artifacts_value = require_dict(
        receipt.get("artifacts"),
        "release receipt artifacts",
    )
    missing = sorted(set(REQUIRED_ARTIFACT_KINDS) - set(artifacts_value))
    if missing:
        fail(f"release receipt is missing required artifacts: {', '.join(missing)}")
    artifacts: dict[str, dict[str, Any]] = {}
    file_names: set[str] = set()
    for kind in REQUIRED_ARTIFACT_KINDS:
        artifact = require_dict(
            artifacts_value.get(kind),
            f"release receipt artifact {kind}",
        )
        file_name = safe_file_name(
            artifact.get("fileName"),
            f"release receipt artifact {kind} file name",
        )
        artifact_sha = artifact.get("sha256")
        artifact_size = artifact.get("sizeBytes")
        if not isinstance(artifact_sha, str) or not SHA256.fullmatch(artifact_sha):
            fail(f"release receipt artifact {kind} SHA-256 is invalid.")
        if not isinstance(artifact_size, int) or artifact_size <= 0:
            fail(f"release receipt artifact {kind} size is invalid.")
        if file_name in file_names:
            fail(f"release receipt reuses artifact file name: {file_name}")
        file_names.add(file_name)
        artifacts[kind] = {
            "fileName": file_name,
            "sha256": artifact_sha,
            "sizeBytes": artifact_size,
        }

    smoke = require_dict(
        receipt.get("mountedDmgSmoke"),
        "mounted DMG smoke receipt",
    )
    if (
        smoke.get("status") != "passed"
        or smoke.get("script") != "scripts/ci/smoke-openburnbar-release-dmg.sh"
        or smoke.get("artifactSha256") != artifacts["dmg"]["sha256"]
    ):
        fail("mounted DMG smoke receipt is incomplete or not bound to the DMG.")

    return receipt, artifacts


def validate_local_artifacts(
    downloads_dir: Path,
    artifacts: dict[str, dict[str, Any]],
) -> dict[str, Path]:
    root = require_real_directory(downloads_dir, "release artifact directory")
    paths: dict[str, Path] = {}
    for kind, artifact in artifacts.items():
        path = root / artifact["fileName"]
        if path.parent != root:
            fail(f"release artifact {kind} resolved outside the release directory.")
        actual_sha, actual_size = file_digest_and_size(
            path,
            f"release artifact {kind}",
        )
        if (
            actual_sha != artifact["sha256"]
            or actual_size != artifact["sizeBytes"]
        ):
            fail(f"release artifact {kind} does not match its release receipt.")
        paths[kind] = path
    return paths


def require_metadata_value(
    value: dict[str, Any],
    key: str,
    expected: Any,
    label: str,
) -> None:
    if value.get(key) != expected:
        fail(
            f"{label} {key} must be {expected!r}; "
            f"found {value.get(key)!r}."
        )


def validate_release_metadata(
    path: Path,
    *,
    receipt: dict[str, Any],
    artifacts: dict[str, dict[str, Any]],
    release_receipt_name: str,
    base_url: str,
) -> None:
    metadata = load_json(path, "release metadata")
    candidate = require_dict(receipt["candidate"], "release receipt candidate")
    release = require_dict(receipt["release"], "release receipt release")
    expected = {
        "version": release["version"],
        "build": release["build"],
        "bundleId": "com.openburnbar.app",
        "channel": "direct-download",
        "dmg": artifacts["dmg"]["fileName"],
        "zip": artifacts["zip"]["fileName"],
        "appcast": artifacts["appcast"]["fileName"],
        "latestMetadata": artifacts["latestMetadata"]["fileName"],
        "developerIdReceipt": release_receipt_name,
        "updateBaseUrl": base_url,
        "correspondingSource": artifacts["correspondingSource"]["fileName"],
        "sparkleEdSignaturePresent": True,
        "commit": candidate["commit"],
        "tree": candidate["tree"],
    }
    for key, expected_value in expected.items():
        require_metadata_value(metadata, key, expected_value, "release metadata")


def validate_latest_metadata(
    path: Path,
    *,
    receipt: dict[str, Any],
    artifacts: dict[str, dict[str, Any]],
    base_url: str,
) -> None:
    latest = load_json(path, "latest macOS metadata")
    candidate = require_dict(receipt["candidate"], "release receipt candidate")
    release = require_dict(receipt["release"], "release receipt release")
    expected = {
        "version": release["version"],
        "build": release["build"],
        "bundleId": "com.openburnbar.app",
        "channel": "direct-download",
        "commit": candidate["commit"],
        "correspondingSource": artifacts["correspondingSource"]["fileName"],
        "dmg": artifacts["dmg"]["fileName"],
        "zip": artifacts["zip"]["fileName"],
        "downloadUrl": public_url(base_url, artifacts["dmg"]["fileName"]),
        "appcastUrl": public_url(base_url, artifacts["appcast"]["fileName"]),
        "length": artifacts["dmg"]["sizeBytes"],
        "sha256": artifacts["dmg"]["sha256"],
    }
    for key, expected_value in expected.items():
        require_metadata_value(
            latest,
            key,
            expected_value,
            "latest macOS metadata",
        )
    signature = latest.get("sparkleEdSignature")
    if not isinstance(signature, str) or not signature.strip():
        fail("latest macOS metadata must include a Sparkle EdDSA signature.")


def validate_appcast(
    path: Path,
    *,
    receipt: dict[str, Any],
    artifacts: dict[str, dict[str, Any]],
    base_url: str,
) -> None:
    try:
        root = ET.fromstring(read_safe_bytes(path, "appcast"))
    except ET.ParseError as error:
        fail(f"appcast is unreadable or malformed: {error}")
    channel = root.find("channel")
    if channel is None:
        fail("appcast has no channel.")
    items = channel.findall("item")
    if not items:
        fail("appcast has no release items.")
    release = require_dict(receipt["release"], "release receipt release")
    current = items[0]
    short_version = current.findtext(
        f"{{{SPARKLE_NAMESPACE}}}shortVersionString"
    )
    build = current.findtext(f"{{{SPARKLE_NAMESPACE}}}version")
    if short_version != release["version"] or build != release["build"]:
        fail("appcast first item does not match the exact release version/build.")
    enclosure = current.find("enclosure")
    if enclosure is None:
        fail("appcast first item has no enclosure.")
    expected_url = public_url(base_url, artifacts["dmg"]["fileName"])
    if enclosure.get("url") != expected_url:
        fail("appcast enclosure URL does not match the public R2 DMG URL.")
    if enclosure.get("length") != str(artifacts["dmg"]["sizeBytes"]):
        fail("appcast enclosure length does not match the release DMG.")
    signature = enclosure.get(f"{{{SPARKLE_NAMESPACE}}}edSignature")
    if not signature:
        fail("appcast enclosure is missing the Sparkle EdDSA signature.")


def validate_checksums(
    path: Path,
    artifacts: dict[str, dict[str, Any]],
) -> None:
    try:
        text = read_safe_bytes(path, "release checksums").decode("utf-8")
    except UnicodeDecodeError as error:
        fail(f"release checksums are not UTF-8: {error}")
    digest_tokens = set(re.findall(r"(?<![0-9a-f])[0-9a-f]{64}(?![0-9a-f])", text))
    for kind in CHECKSUM_BOUND_ARTIFACT_KINDS:
        artifact = artifacts[kind]
        if artifact["sha256"] not in digest_tokens:
            fail(f"release checksums do not contain artifact {kind}.")


def build_preflight(
    *,
    release_receipt_path: Path,
    downloads_dir: Path,
    candidate_commit: str,
    candidate_tree: str,
    bucket: str,
    public_base_url: str,
) -> dict[str, Any]:
    if not FULL_SHA.fullmatch(candidate_commit):
        fail("candidate commit must be a full lowercase Git SHA.")
    if not FULL_SHA.fullmatch(candidate_tree):
        fail("candidate tree must be a full lowercase Git SHA.")
    if not SAFE_BUCKET.fullmatch(bucket):
        fail("R2 bucket name is invalid.")
    base_url = normalize_public_base_url(public_base_url)
    receipt, artifacts = validate_release_receipt(
        release_receipt_path,
        candidate_commit=candidate_commit,
        candidate_tree=candidate_tree,
    )
    paths = validate_local_artifacts(downloads_dir, artifacts)
    validate_release_metadata(
        paths["releaseMetadata"],
        receipt=receipt,
        artifacts=artifacts,
        release_receipt_name=release_receipt_path.name,
        base_url=base_url,
    )
    validate_latest_metadata(
        paths["latestMetadata"],
        receipt=receipt,
        artifacts=artifacts,
        base_url=base_url,
    )
    validate_appcast(
        paths["appcast"],
        receipt=receipt,
        artifacts=artifacts,
        base_url=base_url,
    )
    validate_checksums(paths["checksums"], artifacts)

    release_receipt_sha, release_receipt_size = file_digest_and_size(
        release_receipt_path,
        "Developer ID release receipt",
        required_mode=0o600,
    )
    receipt_file_name = safe_file_name(
        release_receipt_path.name,
        "Developer ID release receipt file name",
    )
    if receipt_file_name in {
        artifact["fileName"] for artifact in artifacts.values()
    }:
        fail("Developer ID release receipt reuses a release artifact file name.")
    release_receipt_artifact = {
        "kind": "releaseReceipt",
        "fileName": receipt_file_name,
        "sha256": release_receipt_sha,
        "sizeBytes": release_receipt_size,
        "publicUrl": public_url(base_url, receipt_file_name),
        "contentType": content_type(receipt_file_name),
        "cacheControl": cache_control("releaseReceipt"),
        "publicationPhase": "supporting-metadata",
        "discoveryCommitSetMember": False,
    }

    manifest_artifacts = []
    for kind, phase in PUBLICATION_PLAN:
        if kind == "releaseReceipt":
            artifact = release_receipt_artifact
        else:
            release_artifact = artifacts[kind]
            artifact = {
                "kind": kind,
                **release_artifact,
                "publicUrl": public_url(
                    base_url,
                    release_artifact["fileName"],
                ),
                "contentType": content_type(release_artifact["fileName"]),
                "cacheControl": cache_control(kind),
                "publicationPhase": phase,
                "discoveryCommitSetMember": kind in DISCOVERY_COMMIT_KINDS,
            }
        manifest_artifacts.append(artifact)

    release = require_dict(receipt["release"], "release receipt release")
    return {
        "schemaVersion": 1,
        "candidate": {
            "commit": candidate_commit,
            "tree": candidate_tree,
        },
        "release": {
            "version": release["version"],
            "build": release["build"],
            "channel": "direct-download",
        },
        "destination": {
            "provider": "cloudflare-r2",
            "bucket": bucket,
            "publicBaseUrl": base_url,
        },
        "sourceReleaseReceipt": {
            "fileName": receipt_file_name,
            "sha256": release_receipt_sha,
            "sizeBytes": release_receipt_size,
            "publicUrl": public_url(base_url, receipt_file_name),
        },
        "artifacts": manifest_artifacts,
        "verification": {
            "releaseReceiptValidated": True,
            "localArtifactDigestsMatch": True,
            "releaseMetadataBound": True,
            "latestMetadataBound": True,
            "appcastBound": True,
            "sparkleSignaturePresent": True,
            "transport": "https",
        },
        "generatedAt": now_utc(),
    }


def validate_preflight(value: dict[str, Any]) -> list[dict[str, Any]]:
    if value.get("schemaVersion") != 1:
        fail("R2 upload preflight schema version is unsupported.")
    candidate = require_dict(value.get("candidate"), "R2 preflight candidate")
    if (
        not isinstance(candidate.get("commit"), str)
        or not FULL_SHA.fullmatch(candidate["commit"])
        or not isinstance(candidate.get("tree"), str)
        or not FULL_SHA.fullmatch(candidate["tree"])
    ):
        fail("R2 preflight candidate identity is invalid.")
    release = require_dict(value.get("release"), "R2 preflight release")
    if release.get("channel") != "direct-download":
        fail("R2 preflight release channel is invalid.")
    destination = require_dict(
        value.get("destination"),
        "R2 preflight destination",
    )
    if destination.get("provider") != "cloudflare-r2":
        fail("R2 preflight destination provider is invalid.")
    bucket = destination.get("bucket")
    if not isinstance(bucket, str) or not SAFE_BUCKET.fullmatch(bucket):
        fail("R2 preflight bucket is invalid.")
    base_url = destination.get("publicBaseUrl")
    if (
        not isinstance(base_url, str)
        or normalize_public_base_url(base_url) != base_url
    ):
        fail("R2 preflight public base URL is invalid.")
    source_receipt = require_dict(
        value.get("sourceReleaseReceipt"),
        "R2 preflight source release receipt",
    )
    safe_file_name(
        source_receipt.get("fileName"),
        "R2 preflight source release receipt file name",
    )
    receipt_sha = source_receipt.get("sha256")
    if not isinstance(receipt_sha, str) or not SHA256.fullmatch(receipt_sha):
        fail("R2 preflight source release receipt SHA-256 is invalid.")
    receipt_size = source_receipt.get("sizeBytes")
    if not isinstance(receipt_size, int) or receipt_size <= 0:
        fail("R2 preflight source release receipt size is invalid.")
    receipt_file_name = source_receipt["fileName"]
    if source_receipt.get("publicUrl") != public_url(
        base_url,
        receipt_file_name,
    ):
        fail("R2 preflight source release receipt public URL is invalid.")

    verification = require_dict(
        value.get("verification"),
        "R2 preflight verification",
    )
    expected_verification = {
        "releaseReceiptValidated": True,
        "localArtifactDigestsMatch": True,
        "releaseMetadataBound": True,
        "latestMetadataBound": True,
        "appcastBound": True,
        "sparkleSignaturePresent": True,
        "transport": "https",
    }
    if verification != expected_verification:
        fail("R2 preflight verification claims are incomplete.")

    artifacts = require_list(value.get("artifacts"), "R2 preflight artifacts")
    if len(artifacts) != len(PUBLIC_OBJECT_KINDS):
        fail("R2 preflight artifact count is invalid.")
    normalized: list[dict[str, Any]] = []
    observed_kinds: set[str] = set()
    observed_names: set[str] = set()
    for raw_artifact in artifacts:
        artifact = require_dict(raw_artifact, "R2 preflight artifact")
        kind = artifact.get("kind")
        if kind not in PUBLIC_OBJECT_KINDS or kind in observed_kinds:
            fail(f"R2 preflight artifact kind is invalid or duplicated: {kind!r}")
        file_name = safe_file_name(
            artifact.get("fileName"),
            f"R2 preflight artifact {kind} file name",
        )
        if file_name in observed_names:
            fail(f"R2 preflight artifact file name is duplicated: {file_name}")
        artifact_sha = artifact.get("sha256")
        artifact_size = artifact.get("sizeBytes")
        if not isinstance(artifact_sha, str) or not SHA256.fullmatch(artifact_sha):
            fail(f"R2 preflight artifact {kind} SHA-256 is invalid.")
        if not isinstance(artifact_size, int) or artifact_size <= 0:
            fail(f"R2 preflight artifact {kind} size is invalid.")
        if artifact.get("publicUrl") != public_url(base_url, file_name):
            fail(f"R2 preflight artifact {kind} public URL is invalid.")
        if artifact.get("contentType") != content_type(file_name):
            fail(f"R2 preflight artifact {kind} content type is invalid.")
        expected_cache = cache_control(kind)
        if artifact.get("cacheControl") != expected_cache:
            fail(f"R2 preflight artifact {kind} cache control is invalid.")
        expected_phase = dict(PUBLICATION_PLAN)[kind]
        if artifact.get("publicationPhase") != expected_phase:
            fail(f"R2 preflight artifact {kind} publication phase is invalid.")
        expected_commit_set_member = kind in DISCOVERY_COMMIT_KINDS
        if (
            artifact.get("discoveryCommitSetMember")
            is not expected_commit_set_member
        ):
            fail(
                f"R2 preflight artifact {kind} discovery commit-set "
                "flag is invalid."
            )
        observed_kinds.add(kind)
        observed_names.add(file_name)
        normalized.append(dict(artifact))
    if observed_kinds != set(PUBLIC_OBJECT_KINDS):
        fail("R2 preflight artifacts are incomplete.")
    expected_order = [kind for kind, _ in PUBLICATION_PLAN]
    if [artifact["kind"] for artifact in normalized] != expected_order:
        fail("R2 preflight artifacts are not in the required publication order.")
    release_receipt_artifact = next(
        artifact
        for artifact in normalized
        if artifact["kind"] == "releaseReceipt"
    )
    for key in ("fileName", "sha256", "sizeBytes", "publicUrl"):
        if release_receipt_artifact[key] != source_receipt[key]:
            fail(
                "R2 preflight release receipt artifact does not match "
                f"sourceReleaseReceipt: {key}."
            )
    return normalized


def verify_public_artifacts(
    *,
    artifacts: list[dict[str, Any]],
    public_download_dir: Path,
    public_header_dir: Path,
    phase: str | None = None,
) -> list[dict[str, Any]]:
    if phase is not None and phase not in PUBLICATION_PHASES:
        fail(f"public verification phase is invalid: {phase!r}.")
    public_root = require_real_directory(
        public_download_dir,
        "public download evidence directory",
    )
    header_root = require_real_directory(
        public_header_dir,
        "public header evidence directory",
    )
    selected = [
        artifact
        for artifact in artifacts
        if phase is None or artifact["publicationPhase"] == phase
    ]
    if phase is not None and not selected:
        fail(f"public verification phase contains no artifacts: {phase}.")

    published_artifacts: list[dict[str, Any]] = []
    for artifact in selected:
        public_path = public_root / artifact["fileName"]
        if public_path.parent != public_root:
            fail("public artifact resolved outside the evidence directory.")
        public_sha, public_size = file_digest_and_size(
            public_path,
            f"downloaded public artifact {artifact['kind']}",
        )
        if (
            public_sha != artifact["sha256"]
            or public_size != artifact["sizeBytes"]
        ):
            fail(
                f"downloaded public artifact {artifact['kind']} does not "
                "match the exact local release bytes."
            )

        header_path = header_root / f"{artifact['fileName']}.headers"
        if header_path.parent != header_root:
            fail("public header evidence resolved outside the evidence directory.")
        observed_headers = parse_observed_http_headers(
            header_path,
            f"public response headers for {artifact['kind']}",
        )
        expected_content_type = normalize_content_type(artifact["contentType"])
        observed_content_type = normalize_content_type(
            observed_headers["contentType"]
        )
        if observed_content_type != expected_content_type:
            fail(
                f"public Content-Type for {artifact['kind']} is "
                f"{observed_headers['contentType']!r}, expected "
                f"{artifact['contentType']!r}."
            )
        expected_cache_control = normalize_cache_control(
            artifact["cacheControl"]
        )
        observed_cache_control = normalize_cache_control(
            observed_headers["cacheControl"]
        )
        if observed_cache_control != expected_cache_control:
            fail(
                f"public Cache-Control for {artifact['kind']} is "
                f"{observed_headers['cacheControl']!r}, expected "
                f"{artifact['cacheControl']!r}."
            )
        published_artifacts.append(
            {
                "kind": artifact["kind"],
                "fileName": artifact["fileName"],
                "publicUrl": artifact["publicUrl"],
                "sha256": public_sha,
                "sizeBytes": public_size,
                "contentType": artifact["contentType"],
                "cacheControl": artifact["cacheControl"],
                "publicationPhase": artifact["publicationPhase"],
                "discoveryCommitSetMember": artifact[
                    "discoveryCommitSetMember"
                ],
                "observedResponse": {
                    "statusCode": observed_headers["statusCode"],
                    "contentType": observed_headers["contentType"],
                    "cacheControl": observed_headers["cacheControl"],
                },
            }
        )
    return published_artifacts


def verify_public_phase(
    *,
    preflight_path: Path,
    public_download_dir: Path,
    public_header_dir: Path,
    phase: str,
) -> None:
    preflight = load_json(
        preflight_path,
        "R2 upload preflight",
        required_mode=0o600,
    )
    artifacts = validate_preflight(preflight)
    verify_public_artifacts(
        artifacts=artifacts,
        public_download_dir=public_download_dir,
        public_header_dir=public_header_dir,
        phase=phase,
    )


def discovery_artifacts(
    artifacts: list[dict[str, Any]],
) -> list[dict[str, Any]]:
    selected = [
        artifact
        for artifact in artifacts
        if artifact["kind"] in DISCOVERY_COMMIT_KINDS
    ]
    if [artifact["kind"] for artifact in selected] != list(
        DISCOVERY_COMMIT_KINDS
    ):
        fail("R2 preflight discovery commit set is incomplete or out of order.")
    return selected


def build_discovery_snapshot(
    *,
    preflight_path: Path,
    public_download_dir: Path,
    public_header_dir: Path,
) -> dict[str, Any]:
    preflight = load_json(
        preflight_path,
        "R2 upload preflight",
        required_mode=0o600,
    )
    artifacts = validate_preflight(preflight)
    public_root = require_real_directory(
        public_download_dir,
        "discovery snapshot download directory",
    )
    header_root = require_real_directory(
        public_header_dir,
        "discovery snapshot header directory",
    )
    objects: list[dict[str, Any]] = []
    for artifact in discovery_artifacts(artifacts):
        header_path = header_root / f"{artifact['fileName']}.headers"
        if header_path.parent != header_root:
            fail("discovery snapshot header resolved outside evidence directory.")
        observed = parse_http_response_headers(
            header_path,
            f"discovery snapshot headers for {artifact['kind']}",
            require_entity_headers=False,
        )
        status_code = observed["statusCode"]
        entry: dict[str, Any] = {
            "kind": artifact["kind"],
            "fileName": artifact["fileName"],
            "publicUrl": artifact["publicUrl"],
            "statusCode": status_code,
        }
        snapshot_path = public_root / artifact["fileName"]
        if snapshot_path.parent != public_root:
            fail("discovery snapshot bytes resolved outside evidence directory.")
        if status_code == 404:
            if snapshot_path.exists():
                fail(
                    f"absent discovery snapshot unexpectedly contains bytes: "
                    f"{artifact['kind']}."
                )
            entry["state"] = "absent"
        elif status_code == 200:
            if not snapshot_path.exists():
                fail(
                    f"present discovery snapshot is missing bytes: "
                    f"{artifact['kind']}."
                )
            headers = parse_observed_http_headers(
                header_path,
                f"discovery snapshot headers for {artifact['kind']}",
            )
            snapshot_sha, snapshot_size = file_digest_and_size(
                snapshot_path,
                f"discovery snapshot bytes for {artifact['kind']}",
            )
            entry.update(
                {
                    "state": "present",
                    "sha256": snapshot_sha,
                    "sizeBytes": snapshot_size,
                    "contentType": headers["contentType"],
                    "cacheControl": headers["cacheControl"],
                }
            )
        else:
            fail(
                f"discovery snapshot for {artifact['kind']} returned "
                f"HTTP {status_code}; expected 200 or explicit 404."
            )
        objects.append(entry)
    return {
        "schemaVersion": 1,
        "candidate": preflight["candidate"],
        "destination": preflight["destination"],
        "objects": objects,
        "capturedAt": now_utc(),
    }


def validate_discovery_snapshot(value: dict[str, Any]) -> list[dict[str, Any]]:
    if value.get("schemaVersion") != 1:
        fail("discovery snapshot schema version is unsupported.")
    candidate = require_dict(
        value.get("candidate"),
        "discovery snapshot candidate",
    )
    if (
        not isinstance(candidate.get("commit"), str)
        or not FULL_SHA.fullmatch(candidate["commit"])
        or not isinstance(candidate.get("tree"), str)
        or not FULL_SHA.fullmatch(candidate["tree"])
    ):
        fail("discovery snapshot candidate identity is invalid.")
    destination = require_dict(
        value.get("destination"),
        "discovery snapshot destination",
    )
    if destination.get("provider") != "cloudflare-r2":
        fail("discovery snapshot destination provider is invalid.")
    base_url = destination.get("publicBaseUrl")
    if (
        not isinstance(base_url, str)
        or normalize_public_base_url(base_url) != base_url
    ):
        fail("discovery snapshot public base URL is invalid.")

    objects = require_list(value.get("objects"), "discovery snapshot objects")
    if len(objects) != len(DISCOVERY_COMMIT_KINDS):
        fail("discovery snapshot object count is invalid.")
    normalized: list[dict[str, Any]] = []
    for expected_kind, raw_object in zip(
        DISCOVERY_COMMIT_KINDS,
        objects,
        strict=True,
    ):
        item = require_dict(raw_object, "discovery snapshot object")
        if item.get("kind") != expected_kind:
            fail("discovery snapshot objects are incomplete or out of order.")
        file_name = safe_file_name(
            item.get("fileName"),
            f"discovery snapshot {expected_kind} file name",
        )
        if item.get("publicUrl") != public_url(base_url, file_name):
            fail(f"discovery snapshot {expected_kind} public URL is invalid.")
        state = item.get("state")
        if state == "absent":
            if item.get("statusCode") != 404:
                fail(
                    f"absent discovery snapshot {expected_kind} must record 404."
                )
        elif state == "present":
            if item.get("statusCode") != 200:
                fail(
                    f"present discovery snapshot {expected_kind} must record 200."
                )
            item_sha = item.get("sha256")
            item_size = item.get("sizeBytes")
            if not isinstance(item_sha, str) or not SHA256.fullmatch(item_sha):
                fail(f"discovery snapshot {expected_kind} SHA-256 is invalid.")
            if not isinstance(item_size, int) or item_size <= 0:
                fail(f"discovery snapshot {expected_kind} size is invalid.")
            normalize_content_type(item.get("contentType", ""))
            normalize_cache_control(item.get("cacheControl", ""))
        else:
            fail(f"discovery snapshot {expected_kind} state is invalid.")
        normalized.append(dict(item))
    return normalized


def verify_discovery_rollback(
    *,
    snapshot_path: Path,
    public_download_dir: Path,
    public_header_dir: Path,
) -> None:
    snapshot = load_json(
        snapshot_path,
        "discovery snapshot",
        required_mode=0o600,
    )
    objects = validate_discovery_snapshot(snapshot)
    public_root = require_real_directory(
        public_download_dir,
        "discovery rollback download directory",
    )
    header_root = require_real_directory(
        public_header_dir,
        "discovery rollback header directory",
    )
    for item in objects:
        public_path = public_root / item["fileName"]
        header_path = header_root / f"{item['fileName']}.headers"
        observed = parse_http_response_headers(
            header_path,
            f"discovery rollback headers for {item['kind']}",
            require_entity_headers=False,
        )
        if item["state"] == "absent":
            if observed["statusCode"] != 404:
                fail(
                    f"discovery rollback did not restore absence for "
                    f"{item['kind']}."
                )
            if public_path.exists():
                fail(
                    f"absent discovery rollback unexpectedly contains bytes: "
                    f"{item['kind']}."
                )
            continue

        if observed["statusCode"] != 200:
            fail(
                f"discovery rollback did not restore HTTP 200 for "
                f"{item['kind']}."
            )
        observed_headers = parse_observed_http_headers(
            header_path,
            f"discovery rollback headers for {item['kind']}",
        )
        public_sha, public_size = file_digest_and_size(
            public_path,
            f"discovery rollback bytes for {item['kind']}",
        )
        if public_sha != item["sha256"] or public_size != item["sizeBytes"]:
            fail(
                f"discovery rollback bytes do not match snapshot for "
                f"{item['kind']}."
            )
        if normalize_content_type(
            observed_headers["contentType"]
        ) != normalize_content_type(item["contentType"]):
            fail(
                f"discovery rollback Content-Type does not match snapshot for "
                f"{item['kind']}."
            )
        if normalize_cache_control(
            observed_headers["cacheControl"]
        ) != normalize_cache_control(item["cacheControl"]):
            fail(
                f"discovery rollback Cache-Control does not match snapshot for "
                f"{item['kind']}."
            )


def build_publication_receipt(
    *,
    preflight_path: Path,
    release_receipt_path: Path,
    downloads_dir: Path,
    public_download_dir: Path,
    public_header_dir: Path,
    discovery_snapshot_path: Path,
    platform_trust_verifier: str,
    platform_trust_mode: str,
) -> dict[str, Any]:
    preflight = load_json(
        preflight_path,
        "R2 upload preflight",
        required_mode=0o600,
    )
    artifacts = validate_preflight(preflight)
    candidate = require_dict(preflight["candidate"], "R2 preflight candidate")
    destination = require_dict(
        preflight["destination"],
        "R2 preflight destination",
    )
    rebuilt = build_preflight(
        release_receipt_path=release_receipt_path,
        downloads_dir=downloads_dir,
        candidate_commit=candidate["commit"],
        candidate_tree=candidate["tree"],
        bucket=destination["bucket"],
        public_base_url=destination["publicBaseUrl"],
    )
    for key in (
        "candidate",
        "release",
        "destination",
        "sourceReleaseReceipt",
        "artifacts",
        "verification",
    ):
        if rebuilt[key] != preflight.get(key):
            fail(f"R2 upload preflight drifted before publication: {key}.")
    discovery_snapshot = load_json(
        discovery_snapshot_path,
        "pre-publication discovery snapshot",
        required_mode=0o600,
    )
    validate_discovery_snapshot(discovery_snapshot)
    if (
        discovery_snapshot.get("candidate") != preflight["candidate"]
        or discovery_snapshot.get("destination") != preflight["destination"]
    ):
        fail("pre-publication discovery snapshot is not bound to this upload.")

    published_artifacts = verify_public_artifacts(
        artifacts=artifacts,
        public_download_dir=public_download_dir,
        public_header_dir=public_header_dir,
    )

    canonical_trust_verifier = "scripts/ci/verify-public-macos-download-trust.sh"
    if platform_trust_mode == "canonical":
        if platform_trust_verifier != canonical_trust_verifier:
            fail(
                "canonical public platform trust must use "
                f"{canonical_trust_verifier}."
            )
        public_dmg_trust_verified = True
    elif platform_trust_mode == "test-override":
        if not platform_trust_verifier:
            fail("test platform-trust override must name the test verifier.")
        public_dmg_trust_verified = False
    else:
        fail("platform trust mode is invalid.")

    return {
        "schemaVersion": 1,
        "candidate": preflight["candidate"],
        "release": preflight["release"],
        "destination": preflight["destination"],
        "sourceReleaseReceipt": preflight["sourceReleaseReceipt"],
        "prePublicationDiscovery": discovery_snapshot["objects"],
        "artifacts": published_artifacts,
        "verification": {
            "exactCandidateCleanAtUpload": True,
            "releaseReceiptRevalidated": True,
            "localArtifactsRevalidated": True,
            "publicBytesDownloaded": True,
            "publicBytesDigestEqual": True,
            "publicResponseHeadersObserved": True,
            "publicContentTypesMatch": True,
            "publicCacheControlsMatch": True,
            "immutablePayloadsVerifiedBeforeDiscovery": True,
            "discoveryCommitSet": list(DISCOVERY_COMMIT_KINDS),
            "discoverySnapshotCaptured": True,
            "discoveryCommitSetVerified": True,
            "releaseMetadataBound": True,
            "latestMetadataBound": True,
            "appcastBound": True,
            "sparkleSignaturePresent": True,
            "transport": "https",
            "publicDmgAppleTrustVerified": public_dmg_trust_verified,
            "platformTrustMode": platform_trust_mode,
            "platformTrustVerifier": platform_trust_verifier,
        },
        "publishedAt": now_utc(),
    }


def main() -> int:
    args = parse_args()
    if args.command == "preflight":
        value = build_preflight(
            release_receipt_path=args.release_receipt,
            downloads_dir=args.downloads_dir,
            candidate_commit=args.candidate_commit,
            candidate_tree=args.candidate_tree,
            bucket=args.bucket,
            public_base_url=args.public_base_url,
        )
    elif args.command == "verify-public-phase":
        verify_public_phase(
            preflight_path=args.preflight,
            public_download_dir=args.public_download_dir,
            public_header_dir=args.public_header_dir,
            phase=args.phase,
        )
        print(f"PASS: verified public R2 phase {args.phase}")
        return 0
    elif args.command == "snapshot-discovery":
        value = build_discovery_snapshot(
            preflight_path=args.preflight,
            public_download_dir=args.public_download_dir,
            public_header_dir=args.public_header_dir,
        )
    elif args.command == "verify-discovery-rollback":
        verify_discovery_rollback(
            snapshot_path=args.snapshot,
            public_download_dir=args.public_download_dir,
            public_header_dir=args.public_header_dir,
        )
        print("PASS: verified discovery rollback against exact snapshot")
        return 0
    else:
        value = build_publication_receipt(
            preflight_path=args.preflight,
            release_receipt_path=args.release_receipt,
            downloads_dir=args.downloads_dir,
            public_download_dir=args.public_download_dir,
            public_header_dir=args.public_header_dir,
            discovery_snapshot_path=args.discovery_snapshot,
            platform_trust_verifier=args.platform_trust_verifier,
            platform_trust_mode=args.platform_trust_mode,
        )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    write_exclusive_json(args.output, value)
    print(f"PASS: wrote {args.command} evidence to {args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ValueError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        raise SystemExit(1) from error
