#!/usr/bin/env python3
"""Verify that an Xcode cloned-source cache exactly satisfies Package.resolved.

Xcode's ``-disableAutomaticPackageResolution`` flag is only safe when every
locked checkout and downloaded artifact is already present. Directory-presence
checks are not sufficient: an interrupted resolve can leave a checkout at the
wrong revision or a workspace state that names a missing binary artifact.

Exit codes:
  0   cache is complete and revision-exact
  64  Package.resolved is malformed and must be fixed in source
  78  cache state is absent, incomplete, or inconsistent and may be repaired
      by an explicit, lock-preserving package-resolution step
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys
from typing import Any, Sequence


EX_USAGE = 64
EX_CONFIG = 78


class InvalidLockfileError(ValueError):
    """Package.resolved cannot be treated as an authoritative lock."""


def _load_json(path: Path, *, label: str, invalid_lockfile: bool) -> Any:
    cause: Exception
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as error:
        message = f"{label} is missing: {path}"
        cause = error
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as error:
        message = f"{label} is unreadable or malformed at {path}: {error}"
        cause = error
    if invalid_lockfile:
        raise InvalidLockfileError(message) from cause
    raise ValueError(message) from cause


def _locked_revisions(lockfile: Path) -> dict[str, str]:
    payload = _load_json(
        lockfile,
        label="Package.resolved",
        invalid_lockfile=True,
    )
    if not isinstance(payload, dict) or not isinstance(payload.get("pins"), list):
        raise InvalidLockfileError("Package.resolved must contain a pins array")

    revisions: dict[str, str] = {}
    for index, pin in enumerate(payload["pins"]):
        if not isinstance(pin, dict):
            raise InvalidLockfileError(f"Package.resolved pin {index} is not an object")
        identity = pin.get("identity")
        state = pin.get("state")
        revision = state.get("revision") if isinstance(state, dict) else None
        if not isinstance(identity, str) or not identity:
            raise InvalidLockfileError(
                f"Package.resolved pin {index} has no non-empty identity"
            )
        if not isinstance(revision, str) or len(revision) != 40:
            raise InvalidLockfileError(
                f"Package.resolved pin {identity!r} has no 40-character revision"
            )
        normalized_identity = identity.casefold()
        if normalized_identity in revisions:
            raise InvalidLockfileError(
                f"Package.resolved contains duplicate identity {identity!r}"
            )
        revisions[normalized_identity] = revision

    if not revisions:
        raise InvalidLockfileError("Package.resolved must contain at least one pin")
    return revisions


def _workspace_inventory(
    workspace_state: Path,
) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    payload = _load_json(
        workspace_state,
        label="SwiftPM workspace state",
        invalid_lockfile=False,
    )
    if not isinstance(payload, dict):
        raise ValueError("SwiftPM workspace state root must be an object")
    workspace_object = payload.get("object")
    if not isinstance(workspace_object, dict):
        raise ValueError("SwiftPM workspace state must contain an object field")
    dependencies = workspace_object.get("dependencies")
    if not isinstance(dependencies, list):
        raise ValueError("SwiftPM workspace state must contain a dependencies array")
    artifacts = workspace_object.get("artifacts")
    if artifacts is None:
        artifacts = []
    if not isinstance(artifacts, list):
        raise ValueError("SwiftPM workspace state artifacts field must be an array")
    return (
        [dependency for dependency in dependencies if isinstance(dependency, dict)],
        [artifact for artifact in artifacts if isinstance(artifact, dict)],
    )


def _dependency_identity(dependency: dict[str, Any]) -> str | None:
    package_ref = dependency.get("packageRef")
    identity = package_ref.get("identity") if isinstance(package_ref, dict) else None
    return identity.casefold() if isinstance(identity, str) and identity else None


def _dependency_revision(dependency: dict[str, Any]) -> str | None:
    dependency_state = dependency.get("state")
    checkout_state = (
        dependency_state.get("checkoutState")
        if isinstance(dependency_state, dict)
        else None
    )
    revision = (
        checkout_state.get("revision") if isinstance(checkout_state, dict) else None
    )
    return revision if isinstance(revision, str) else None


def _safe_checkout_path(checkouts_root: Path, subpath: Any) -> Path | None:
    if not isinstance(subpath, str) or not subpath:
        return None
    relative_path = Path(subpath)
    if relative_path.is_absolute() or ".." in relative_path.parts:
        return None
    checkout_path = (checkouts_root / relative_path).resolve(strict=False)
    try:
        checkout_path.relative_to(checkouts_root.resolve(strict=False))
    except ValueError:
        return None
    return checkout_path


def _git_head(checkout_path: Path) -> str | None:
    try:
        completed = subprocess.run(
            ["git", "-C", str(checkout_path), "rev-parse", "--verify", "HEAD"],
            check=False,
            capture_output=True,
            text=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    if completed.returncode != 0:
        return None
    return completed.stdout.strip()


def validate_cache(lockfile: Path, cache_dir: Path) -> list[str]:
    """Return user-actionable incompleteness diagnostics."""

    locked_revisions = _locked_revisions(lockfile)
    workspace_state = cache_dir / "workspace-state.json"
    try:
        dependencies, artifacts = _workspace_inventory(workspace_state)
    except ValueError as error:
        return [str(error)]

    dependency_by_identity: dict[str, dict[str, Any]] = {}
    duplicate_identities: set[str] = set()
    for dependency in dependencies:
        identity = _dependency_identity(dependency)
        if identity is None:
            continue
        if identity in dependency_by_identity:
            duplicate_identities.add(identity)
        else:
            dependency_by_identity[identity] = dependency

    errors: list[str] = []
    for identity in sorted(duplicate_identities):
        if identity in locked_revisions:
            errors.append(
                f"workspace state contains duplicate entries for locked package {identity}"
            )

    checkouts_root = cache_dir / "checkouts"
    for identity, expected_revision in sorted(locked_revisions.items()):
        dependency = dependency_by_identity.get(identity)
        if dependency is None:
            errors.append(f"workspace state is missing locked package {identity}")
            continue

        state_revision = _dependency_revision(dependency)
        if state_revision != expected_revision:
            errors.append(
                f"workspace state revision mismatch for {identity}: "
                f"expected {expected_revision}, found {state_revision or 'missing'}"
            )

        checkout_path = _safe_checkout_path(
            checkouts_root,
            dependency.get("subpath"),
        )
        if checkout_path is None:
            errors.append(f"workspace state has an unsafe checkout path for {identity}")
            continue
        if not checkout_path.is_dir():
            errors.append(f"checkout is missing for {identity}: {checkout_path}")
            continue

        checkout_revision = _git_head(checkout_path)
        if checkout_revision != expected_revision:
            errors.append(
                f"checkout revision mismatch for {identity}: expected "
                f"{expected_revision}, found {checkout_revision or 'unreadable'}"
            )

    for artifact in artifacts:
        package_ref = artifact.get("packageRef")
        identity = (
            package_ref.get("identity")
            if isinstance(package_ref, dict)
            else None
        )
        artifact_identity = (
            identity.casefold()
            if isinstance(identity, str) and identity
            else "unknown-package"
        )
        artifact_path = artifact.get("path")
        if not isinstance(artifact_path, str) or not artifact_path:
            errors.append(
                f"workspace state has no path for {artifact_identity} artifact"
            )
            continue
        if not Path(artifact_path).exists():
            target_name = artifact.get("targetName")
            suffix = (
                f" target {target_name}"
                if isinstance(target_name, str) and target_name
                else ""
            )
            errors.append(
                f"artifact is missing for {artifact_identity}{suffix}: {artifact_path}"
            )

    return errors


def _parse_args(argv: Sequence[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=(
            "Verify that a cloned-source SwiftPM cache contains every revision "
            "and artifact required by Package.resolved."
        )
    )
    parser.add_argument("--lockfile", required=True, type=Path)
    parser.add_argument("--cache-dir", required=True, type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    parsed = _parse_args(argv if argv is not None else sys.argv[1:])
    try:
        errors = validate_cache(parsed.lockfile, parsed.cache_dir)
        locked_count = len(_locked_revisions(parsed.lockfile))
    except InvalidLockfileError as error:
        print(f"error: {error}", file=sys.stderr)
        return EX_USAGE

    if errors:
        for error in errors:
            print(f"INCOMPLETE: {error}", file=sys.stderr)
        return EX_CONFIG

    print(
        f"READY: SwiftPM cache satisfies all {locked_count} Package.resolved pins "
        "at their exact revisions."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
