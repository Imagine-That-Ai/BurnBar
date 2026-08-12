#!/usr/bin/env python3
"""Verify and atomically stage the pinned SQLCipher framework for SwiftPM tests.

SwiftPM/Xcode 27 can build OpenBurnBar's macOS XCTest products without copying
the downloaded SQLCipher binary framework into the products directory that the
test executable already names in its runtime search paths. This helper closes
that packaging gap without weakening dependency identity:

* the consumer lockfile and SwiftPM workspace must resolve SQLCipher 4.16.0 at
  the reviewed revision;
* the checked-out binary-target manifest and archive checksum are pinned;
* the framework bundle identifier, universal architectures, executable hash,
  Developer ID team, and sealed signature are verified;
* staging is restricted to the selected SwiftPM scratch tree and is performed
  through an adjacent temporary directory with rollback on replacement failure;
* an already-identical verified destination is retained byte-for-byte so
  incremental Xcode builds do not invalidate their explicit module graph;
* plan mode lets the caller clean an existing SwiftPM build graph before a
  different framework tree is installed.

The script intentionally does not download, re-sign, or mutate the source
artifact. It only stages the exact artifact SwiftPM already resolved.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import plistlib
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable, Iterable


EXPECTED_PACKAGE_IDENTITY = "sqlcipher.swift"
EXPECTED_PACKAGE_LOCATION = "https://github.com/sqlcipher/SQLCipher.swift.git"
EXPECTED_PACKAGE_VERSION = "4.16.0"
EXPECTED_PACKAGE_REVISION = "07bf6bc2191a063d6f1e7c3b5f276a3fadfe36b7"
EXPECTED_PACKAGE_MANIFEST_SHA256 = (
    "84a837b9cc4f2894bf7eed6f558338553127d7c5230d07e721fe6414a24a97d8"
)
EXPECTED_ARCHIVE_CHECKSUM = (
    "510fd00fa51fb017909a159bb1cc233b012e8ce18dc9c2f09014fe47f557c1a6"
)
EXPECTED_FRAMEWORK_IDENTIFIER = "net.zetetic.SQLCipher"
EXPECTED_FRAMEWORK_TEAM_ID = "PD7G6HRMGV"
EXPECTED_FRAMEWORK_AUTHORITY = "Developer ID Application: Zetetic LLC (PD7G6HRMGV)"
EXPECTED_FRAMEWORK_EXECUTABLE_SHA256 = (
    "ad0441e7c7b83ef506c94149bd3dab520a40846259824895a1b981d4fac491a3"
)
EXPECTED_FRAMEWORK_ARCHITECTURES = frozenset({"arm64", "x86_64"})


class StageError(RuntimeError):
    """Raised when SQLCipher identity or staging safety cannot be proved."""


@dataclass(frozen=True)
class PackageIdentity:
    version: str
    revision: str
    checkout_subpath: str | None


@dataclass(frozen=True)
class FrameworkIdentity:
    bundle_identifier: str
    architectures: tuple[str, ...]
    executable_sha256: str
    tree_sha256: str
    team_identifier: str
    authority: str
    cdhash: str


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def tree_sha256(root: Path) -> str:
    """Hash paths, file contents, and symlink targets deterministically."""

    digest = hashlib.sha256()
    entries = sorted(root.rglob("*"), key=lambda item: item.relative_to(root).as_posix())
    for entry in entries:
        relative = entry.relative_to(root).as_posix().encode("utf-8")
        if entry.is_symlink():
            digest.update(b"L\0" + relative + b"\0")
            digest.update(os.readlink(entry).encode("utf-8") + b"\0")
        elif entry.is_file():
            digest.update(b"F\0" + relative + b"\0")
            with entry.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    digest.update(chunk)
        elif entry.is_dir():
            digest.update(b"D\0" + relative + b"\0")
        else:
            raise StageError(f"unsupported framework entry type: {entry}")
    return digest.hexdigest()


def load_json(path: Path) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as error:
        raise StageError(f"cannot read valid JSON from {path}: {error}") from error


def _matching_resolved_pins(document: Any) -> list[dict[str, Any]]:
    pins = document.get("pins") if isinstance(document, dict) else None
    if not isinstance(pins, list):
        raise StageError("Package.resolved does not contain a pins array")
    return [
        pin
        for pin in pins
        if isinstance(pin, dict)
        and str(pin.get("identity", "")).casefold() == EXPECTED_PACKAGE_IDENTITY
    ]


def validate_resolved_pin(path: Path) -> PackageIdentity:
    matches = _matching_resolved_pins(load_json(path))
    if len(matches) != 1:
        raise StageError(
            f"{path} must contain exactly one {EXPECTED_PACKAGE_IDENTITY} pin; "
            f"found {len(matches)}"
        )

    pin = matches[0]
    state = pin.get("state")
    if not isinstance(state, dict):
        raise StageError(f"{path} SQLCipher pin has no state object")

    location = str(pin.get("location", ""))
    version = str(state.get("version", ""))
    revision = str(state.get("revision", ""))
    if location != EXPECTED_PACKAGE_LOCATION:
        raise StageError(f"unexpected SQLCipher package location in {path}: {location}")
    if version != EXPECTED_PACKAGE_VERSION:
        raise StageError(f"unexpected SQLCipher package version in {path}: {version}")
    if revision != EXPECTED_PACKAGE_REVISION:
        raise StageError(f"unexpected SQLCipher package revision in {path}: {revision}")

    return PackageIdentity(version=version, revision=revision, checkout_subpath=None)


def _workspace_dependencies(document: Any) -> list[dict[str, Any]]:
    if not isinstance(document, dict):
        raise StageError("workspace-state.json root must be an object")
    root = document.get("object", document)
    dependencies = root.get("dependencies") if isinstance(root, dict) else None
    if not isinstance(dependencies, list):
        raise StageError("workspace-state.json does not contain a dependencies array")
    return [dependency for dependency in dependencies if isinstance(dependency, dict)]


def validate_workspace_dependency(path: Path) -> PackageIdentity:
    matches: list[dict[str, Any]] = []
    for dependency in _workspace_dependencies(load_json(path)):
        package_ref = dependency.get("packageRef")
        identity = package_ref.get("identity") if isinstance(package_ref, dict) else None
        if str(identity or "").casefold() == EXPECTED_PACKAGE_IDENTITY:
            matches.append(dependency)

    if len(matches) != 1:
        raise StageError(
            f"{path} must contain exactly one {EXPECTED_PACKAGE_IDENTITY} dependency; "
            f"found {len(matches)}"
        )

    dependency = matches[0]
    package_ref = dependency.get("packageRef")
    state = dependency.get("state")
    checkout_state = state.get("checkoutState") if isinstance(state, dict) else None
    if not isinstance(package_ref, dict) or not isinstance(checkout_state, dict):
        raise StageError(f"{path} SQLCipher dependency is not a source-control checkout")

    location = str(package_ref.get("location", ""))
    version = str(checkout_state.get("version", ""))
    revision = str(checkout_state.get("revision", ""))
    subpath = str(dependency.get("subpath", ""))
    if location != EXPECTED_PACKAGE_LOCATION:
        raise StageError(f"unexpected SQLCipher workspace location in {path}: {location}")
    if version != EXPECTED_PACKAGE_VERSION:
        raise StageError(f"unexpected SQLCipher workspace version in {path}: {version}")
    if revision != EXPECTED_PACKAGE_REVISION:
        raise StageError(f"unexpected SQLCipher workspace revision in {path}: {revision}")
    if not subpath or Path(subpath).name != "SQLCipher.swift":
        raise StageError(f"unexpected SQLCipher checkout subpath in {path}: {subpath}")

    return PackageIdentity(version=version, revision=revision, checkout_subpath=subpath)


def validate_sqlcipher_manifest(path: Path) -> None:
    actual_hash = sha256_file(path)
    if actual_hash != EXPECTED_PACKAGE_MANIFEST_SHA256:
        raise StageError(
            f"SQLCipher Package.swift hash mismatch: expected "
            f"{EXPECTED_PACKAGE_MANIFEST_SHA256}, got {actual_hash} ({path})"
        )

    contents = path.read_text(encoding="utf-8")
    expected_url = (
        "https://github.com/sqlcipher/SQLCipher.swift/releases/download/"
        f"{EXPECTED_PACKAGE_VERSION}/SQLCipher.xcframework.zip"
    )
    if expected_url not in contents:
        raise StageError(f"SQLCipher binary target URL is not pinned as expected in {path}")
    checksum_match = re.search(r'checksum:\s*"([0-9a-f]{64})"', contents)
    if not checksum_match or checksum_match.group(1) != EXPECTED_ARCHIVE_CHECKSUM:
        actual = checksum_match.group(1) if checksum_match else "<missing>"
        raise StageError(
            f"SQLCipher binary archive checksum mismatch in {path}: {actual}"
        )


def validate_package_identity(package_path: Path, scratch_path: Path) -> PackageIdentity:
    root_manifest = package_path / "Package.swift"
    if not root_manifest.is_file():
        raise StageError(f"package manifest is missing: {root_manifest}")

    # The codec policy also stages the framework while testing the SQLCipher
    # package itself. In that case the exact root manifest is the package proof.
    if sha256_file(root_manifest) == EXPECTED_PACKAGE_MANIFEST_SHA256:
        validate_sqlcipher_manifest(root_manifest)
        return PackageIdentity(
            version=EXPECTED_PACKAGE_VERSION,
            revision=EXPECTED_PACKAGE_REVISION,
            checkout_subpath=None,
        )

    resolved_identity = validate_resolved_pin(package_path / "Package.resolved")
    workspace_identity = validate_workspace_dependency(scratch_path / "workspace-state.json")
    if (
        resolved_identity.version != workspace_identity.version
        or resolved_identity.revision != workspace_identity.revision
    ):
        raise StageError("Package.resolved and workspace-state.json disagree on SQLCipher")

    checkout_manifest = (
        scratch_path
        / "checkouts"
        / str(workspace_identity.checkout_subpath)
        / "Package.swift"
    )
    validate_sqlcipher_manifest(checkout_manifest)
    return workspace_identity


def discover_framework(scratch_path: Path) -> Path:
    artifacts_root = scratch_path / "artifacts"
    candidates = sorted(
        {
            candidate.resolve(strict=True)
            for candidate in artifacts_root.glob(
                "**/SQLCipher/SQLCipher.xcframework/"
                "macos-arm64_x86_64/SQLCipher.framework"
            )
            if candidate.is_dir()
            and candidate.parts[-5].casefold() == EXPECTED_PACKAGE_IDENTITY
        }
    )
    if len(candidates) != 1:
        rendered = ", ".join(str(candidate) for candidate in candidates) or "<none>"
        raise StageError(
            "expected exactly one resolved SQLCipher macOS framework under "
            f"{artifacts_root}; found {len(candidates)}: {rendered}"
        )
    return candidates[0]


def _run_checked(command: Iterable[str]) -> subprocess.CompletedProcess[str]:
    try:
        return subprocess.run(
            list(command),
            check=True,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        stderr = getattr(error, "stderr", "") or ""
        stdout = getattr(error, "stdout", "") or ""
        detail = (stderr + "\n" + stdout).strip()
        raise StageError(f"command failed: {' '.join(command)}\n{detail}") from error


def _plist_path(framework: Path) -> Path:
    candidates = [framework / "Resources" / "Info.plist", framework / "Info.plist"]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise StageError(f"SQLCipher framework Info.plist is missing: {framework}")


def _executable_path(framework: Path) -> Path:
    candidates = [framework / "Versions" / "A" / "SQLCipher", framework / "SQLCipher"]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    raise StageError(f"SQLCipher framework executable is missing: {framework}")


def _detail_value(details: str, key: str) -> str:
    prefix = f"{key}="
    for line in details.splitlines():
        if line.startswith(prefix):
            return line[len(prefix) :].strip()
    raise StageError(f"codesign details do not contain {key}")


def validate_framework(framework: Path) -> FrameworkIdentity:
    if platform.system() != "Darwin":
        raise StageError("SQLCipher framework verification requires macOS")
    if not framework.is_dir() or framework.is_symlink():
        raise StageError(f"SQLCipher framework must be a real directory: {framework}")

    try:
        with _plist_path(framework).open("rb") as handle:
            info = plistlib.load(handle)
    except (OSError, plistlib.InvalidFileException) as error:
        raise StageError(f"cannot read SQLCipher framework Info.plist: {error}") from error

    bundle_identifier = str(info.get("CFBundleIdentifier", ""))
    if bundle_identifier != EXPECTED_FRAMEWORK_IDENTIFIER:
        raise StageError(
            f"unexpected SQLCipher framework identifier: {bundle_identifier or '<missing>'}"
        )

    executable = _executable_path(framework)
    executable_hash = sha256_file(executable)
    if executable_hash != EXPECTED_FRAMEWORK_EXECUTABLE_SHA256:
        raise StageError(
            "SQLCipher executable hash mismatch: expected "
            f"{EXPECTED_FRAMEWORK_EXECUTABLE_SHA256}, got {executable_hash}"
        )

    architecture_output = _run_checked(["/usr/bin/lipo", "-archs", str(executable)]).stdout
    architectures = tuple(sorted(architecture_output.split()))
    if frozenset(architectures) != EXPECTED_FRAMEWORK_ARCHITECTURES:
        raise StageError(
            "SQLCipher framework architectures mismatch: "
            f"expected {sorted(EXPECTED_FRAMEWORK_ARCHITECTURES)}, got {list(architectures)}"
        )

    _run_checked(
        ["/usr/bin/codesign", "--verify", "--deep", "--strict", "--verbose=4", str(framework)]
    )
    detail_process = _run_checked(
        ["/usr/bin/codesign", "-dv", "--verbose=4", str(framework)]
    )
    details = detail_process.stdout + detail_process.stderr
    signed_identifier = _detail_value(details, "Identifier")
    team_identifier = _detail_value(details, "TeamIdentifier")
    cdhash = _detail_value(details, "CDHash")
    authorities = [
        line.removeprefix("Authority=").strip()
        for line in details.splitlines()
        if line.startswith("Authority=")
    ]
    if signed_identifier != EXPECTED_FRAMEWORK_IDENTIFIER:
        raise StageError(f"unexpected signed SQLCipher identifier: {signed_identifier}")
    if team_identifier != EXPECTED_FRAMEWORK_TEAM_ID:
        raise StageError(f"unexpected SQLCipher signing team: {team_identifier}")
    if EXPECTED_FRAMEWORK_AUTHORITY not in authorities:
        raise StageError(
            "SQLCipher framework is not signed by the expected Developer ID authority"
        )

    return FrameworkIdentity(
        bundle_identifier=bundle_identifier,
        architectures=architectures,
        executable_sha256=executable_hash,
        tree_sha256=tree_sha256(framework),
        team_identifier=team_identifier,
        authority=EXPECTED_FRAMEWORK_AUTHORITY,
        cdhash=cdhash,
    )


def ensure_destination_within_scratch(destination: Path, scratch_path: Path) -> Path:
    if destination.name != "SQLCipher.framework":
        raise StageError(
            f"SQLCipher destination must end in SQLCipher.framework: {destination}"
        )
    scratch = scratch_path.resolve(strict=True)
    resolved = destination.resolve(strict=False)
    try:
        resolved.relative_to(scratch)
    except ValueError as error:
        raise StageError(
            f"SQLCipher destination escapes SwiftPM scratch path {scratch}: {resolved}"
        ) from error
    if destination.is_symlink():
        raise StageError(f"SQLCipher destination must not be a symlink: {destination}")
    return resolved


def _fsync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_replace_tree(
    source: Path,
    destination: Path,
    verify_staged: Callable[[Path], Any] | None = None,
) -> None:
    """Copy a tree beside its destination and replace with rollback semantics."""

    destination.parent.mkdir(parents=True, exist_ok=True)
    staging_root = Path(
        tempfile.mkdtemp(prefix=".sqlcipher-stage-", dir=destination.parent)
    )
    staged = staging_root / destination.name
    backup: Path | None = None
    destination_moved = False

    try:
        shutil.copytree(source, staged, symlinks=True, copy_function=shutil.copy2)
        if verify_staged is not None:
            verify_staged(staged)

        if destination.exists():
            if destination.is_symlink():
                raise StageError(
                    f"refusing to replace symlinked SQLCipher destination: {destination}"
                )
            backup = destination.parent / (
                f".sqlcipher-previous-{uuid.uuid4().hex}-{destination.name}"
            )
            os.replace(destination, backup)
            destination_moved = True

        try:
            os.replace(staged, destination)
            _fsync_directory(destination.parent)
        except BaseException:
            if destination_moved and backup is not None and backup.exists():
                os.replace(backup, destination)
                _fsync_directory(destination.parent)
                destination_moved = False
            raise

        if backup is not None and backup.exists():
            shutil.rmtree(backup)
            _fsync_directory(destination.parent)
    finally:
        if staged.exists():
            shutil.rmtree(staged)
        if staging_root.exists():
            shutil.rmtree(staging_root)
        if (
            destination_moved
            and backup is not None
            and backup.exists()
            and not destination.exists()
        ):
            os.replace(backup, destination)
            _fsync_directory(destination.parent)


def stage_verified_framework(
    source: Path,
    destination: Path,
    source_identity: FrameworkIdentity,
    *,
    validate: Callable[[Path], FrameworkIdentity] = validate_framework,
    replace: Callable[..., None] = atomic_replace_tree,
) -> tuple[FrameworkIdentity, str]:
    """Retain an identical destination or atomically install the verified source."""

    if destination.exists():
        try:
            existing_identity = validate(destination)
        except StageError:
            existing_identity = None
        if existing_identity == source_identity:
            return existing_identity, "retained"

    replace(source, destination, verify_staged=validate)
    staged_identity = validate(destination)
    if source_identity != staged_identity:
        raise StageError("staged SQLCipher framework identity differs from its source")
    return staged_identity, "installed"


def planned_staging_disposition(
    destination: Path,
    source_identity: FrameworkIdentity,
    *,
    validate: Callable[[Path], FrameworkIdentity] = validate_framework,
) -> str:
    """Report whether staging can retain the destination without mutating it."""

    if destination.exists():
        try:
            if validate(destination) == source_identity:
                return "retained"
        except StageError:
            pass
    return "install-required"


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--package-path", required=True, type=Path)
    parser.add_argument("--scratch-path", required=True, type=Path)
    parser.add_argument("--bin-path", type=Path)
    parser.add_argument("--framework-source", type=Path)
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--report-path", type=Path)
    parser.add_argument(
        "--plan-only",
        action="store_true",
        help=(
            "verify source and destination identity without changing the destination; "
            "prints retained or install-required"
        ),
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    package_path = arguments.package_path.resolve(strict=True)
    scratch_path = arguments.scratch_path.resolve(strict=True)

    if arguments.destination is not None:
        destination = arguments.destination
    else:
        if arguments.bin_path is None:
            raise StageError("--bin-path is required when --destination is omitted")
        # `swift build --show-bin-path` is available before compilation and may
        # point at a product directory that has not been created yet. Resolve
        # lexically so the framework can be staged before Xcode constructs its
        # explicit module graph.
        bin_path = arguments.bin_path.resolve(strict=False)
        try:
            bin_path.relative_to(scratch_path)
        except ValueError as error:
            raise StageError(
                f"SwiftPM bin path escapes scratch path {scratch_path}: {bin_path}"
            ) from error
        destination = bin_path / "PackageFrameworks" / "SQLCipher.framework"

    destination = ensure_destination_within_scratch(destination, scratch_path)
    package_identity = validate_package_identity(package_path, scratch_path)
    source = (
        arguments.framework_source.resolve(strict=True)
        if arguments.framework_source is not None
        else discover_framework(scratch_path)
    )
    source_identity = validate_framework(source)

    if arguments.plan_only:
        staged_identity = source_identity
        staging_disposition = planned_staging_disposition(
            destination,
            source_identity,
        )
    else:
        staged_identity, staging_disposition = stage_verified_framework(
            source,
            destination,
            source_identity,
        )

    report = {
        "schemaVersion": 1,
        "operation": "plan" if arguments.plan_only else "stage",
        "package": {
            "identity": EXPECTED_PACKAGE_IDENTITY,
            "location": EXPECTED_PACKAGE_LOCATION,
            "version": package_identity.version,
            "revision": package_identity.revision,
            "manifestSha256": EXPECTED_PACKAGE_MANIFEST_SHA256,
            "archiveChecksum": EXPECTED_ARCHIVE_CHECKSUM,
        },
        "framework": {
            "source": str(source),
            "destination": str(destination),
            "bundleIdentifier": staged_identity.bundle_identifier,
            "architectures": list(staged_identity.architectures),
            "executableSha256": staged_identity.executable_sha256,
            "treeSha256": staged_identity.tree_sha256,
            "teamIdentifier": staged_identity.team_identifier,
            "authority": staged_identity.authority,
            "cdhash": staged_identity.cdhash,
            "stagingDisposition": staging_disposition,
        },
    }
    if arguments.report_path is not None:
        report_path = arguments.report_path.resolve(strict=False)
        report_path.parent.mkdir(parents=True, exist_ok=True)
        temporary = report_path.with_name(f".{report_path.name}.{uuid.uuid4().hex}.tmp")
        temporary.write_text(
            json.dumps(report, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, report_path)

    if arguments.plan_only:
        print(staging_disposition)
    else:
        print(
            f"PASS: {staging_disposition} verified SQLCipher "
            f"{EXPECTED_PACKAGE_VERSION} framework at {destination} "
            f"(sha256 {staged_identity.executable_sha256})"
        )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except StageError as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1) from error
