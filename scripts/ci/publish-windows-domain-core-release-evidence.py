#!/usr/bin/env python3
"""Publish immutable, deletion-grade Shared Rust evidence for a Windows release."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol


PREDICATE_TYPE = "https://openburnbar.dev/attestations/domain-core-release-artifact/v1"
SIGNER_WORKFLOW = ".github/workflows/openburnbar-release-windows.yml"
REPOSITORY_RE = re.compile(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$")
TAG_RE = re.compile(r"^windows-v([0-9]+\.[0-9]+\.[0-9]+)$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")


class PublishError(RuntimeError):
    pass


def canonical_sha256(value: object) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")).hexdigest()


def sha256_path(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def load_json(path: Path, label: str) -> dict[str, Any]:
    def reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        value: dict[str, Any] = {}
        for key, item in pairs:
            if key in value:
                raise PublishError(f"{label} contains duplicate JSON key {key}")
            value[key] = item
        return value

    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=reject_duplicate_keys)
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise PublishError(f"{label} is invalid JSON: {error}") from error
    if not isinstance(value, dict):
        raise PublishError(f"{label} must be a JSON object")
    return value


def require_file(path: Path, label: str) -> Path:
    if path.is_symlink() or not path.is_file() or path.stat().st_size <= 0:
        raise PublishError(f"{label} must be a non-empty regular file: {path}")
    return path


@dataclass(frozen=True)
class Evidence:
    domain: str
    predicate: Path
    bundle: Path
    asset_name: str
    expected_predicate: dict[str, Any]


@dataclass(frozen=True)
class Publication:
    repository: str
    tag: str
    version: str
    commit: str
    artifact: Path
    evidence: tuple[Evidence, ...]


class ReleaseClient(Protocol):
    def get_release(self, tag: str) -> dict[str, Any] | None: ...

    def create_release(self, tag: str, version: str) -> None: ...

    def download_asset(self, tag: str, name: str, destination: Path) -> Path: ...

    def upload_asset(self, tag: str, path: Path) -> bool: ...

    def verify_attestation(
        self,
        artifact: Path,
        bundle: Path,
        *,
        tag: str,
        commit: str,
    ) -> list[dict[str, Any]]: ...


class GhReleaseClient:
    def __init__(self, repository: str) -> None:
        self.repository = repository

    def _run(
        self,
        arguments: list[str],
        *,
        check: bool = True,
        timeout: int = 120,
    ) -> subprocess.CompletedProcess[str]:
        try:
            result = subprocess.run(
                ["gh", *arguments],
                check=False,
                capture_output=True,
                text=True,
                timeout=timeout,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise PublishError(f"cannot run gh {' '.join(arguments[:3])}: {error}") from error
        if check and result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip() or "gh command failed"
            raise PublishError(f"gh {' '.join(arguments[:3])} failed: {detail}")
        return result

    def get_release(self, tag: str) -> dict[str, Any] | None:
        result = self._run(
            ["api", f"repos/{self.repository}/releases/tags/{tag}"],
            check=False,
            timeout=30,
        )
        if result.returncode != 0:
            return None
        try:
            release = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise PublishError("GitHub returned invalid release JSON") from error
        if not isinstance(release, dict):
            raise PublishError("GitHub returned a non-object release")
        return release

    def create_release(self, tag: str, version: str) -> None:
        result = self._run(
            [
                "release",
                "create",
                tag,
                "--repo",
                self.repository,
                "--verify-tag",
                "--title",
                f"OpenBurnBar Windows {version}",
                "--notes",
                f"Signed OpenBurnBar Windows release {version}.",
                "--latest=false",
            ],
            check=False,
            timeout=60,
        )
        if result.returncode != 0 and self.get_release(tag) is None:
            detail = result.stderr.strip() or result.stdout.strip() or "release creation failed"
            raise PublishError(f"cannot create the exact Windows GitHub Release: {detail}")

    def download_asset(self, tag: str, name: str, destination: Path) -> Path:
        destination.mkdir(parents=True, exist_ok=True)
        self._run(
            [
                "release",
                "download",
                tag,
                "--repo",
                self.repository,
                "--pattern",
                name,
                "--dir",
                str(destination),
            ],
            timeout=300,
        )
        return require_file(destination / name, f"downloaded release asset {name}")

    def upload_asset(self, tag: str, path: Path) -> bool:
        result = self._run(
            ["release", "upload", tag, str(path), "--repo", self.repository],
            check=False,
            timeout=600,
        )
        return result.returncode == 0

    def verify_attestation(
        self,
        artifact: Path,
        bundle: Path,
        *,
        tag: str,
        commit: str,
    ) -> list[dict[str, Any]]:
        result = self._run(
            [
                "attestation",
                "verify",
                str(artifact),
                "--bundle",
                str(bundle),
                "--repo",
                self.repository,
                "--signer-workflow",
                f"{self.repository}/{SIGNER_WORKFLOW}",
                "--source-digest",
                commit,
                "--source-ref",
                f"refs/tags/{tag}",
                "--signer-digest",
                commit,
                "--cert-oidc-issuer",
                "https://token.actions.githubusercontent.com",
                "--deny-self-hosted-runners",
                "--predicate-type",
                PREDICATE_TYPE,
                "--format",
                "json",
            ],
            timeout=180,
        )
        try:
            verified = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise PublishError("attestation verifier returned invalid JSON") from error
        if not isinstance(verified, list) or any(not isinstance(item, dict) for item in verified):
            raise PublishError("attestation verifier returned an invalid result")
        return verified


def predicate_from_result(result: dict[str, Any]) -> dict[str, Any] | None:
    verification = result.get("verificationResult")
    statement = verification.get("statement") if isinstance(verification, dict) else None
    predicate = statement.get("predicate") if isinstance(statement, dict) else None
    return predicate if isinstance(predicate, dict) else None


def verify_exact_attestation(client: ReleaseClient, publication: Publication, evidence: Evidence, bundle: Path) -> None:
    verified = client.verify_attestation(
        publication.artifact,
        bundle,
        tag=publication.tag,
        commit=publication.commit,
    )
    if evidence.expected_predicate not in [predicate_from_result(item) for item in verified]:
        raise PublishError(
            f"verified {evidence.domain} attestation does not contain the exact Windows release predicate"
        )


def validate_release(release: dict[str, Any], tag: str) -> set[str]:
    if release.get("tag_name") != tag:
        raise PublishError("GitHub Release does not bind the exact Windows release tag")
    if release.get("draft") is not False:
        raise PublishError("Windows release evidence cannot be published to a draft release")
    if release.get("prerelease") is not False:
        raise PublishError("Windows release evidence cannot be published to a prerelease")
    assets = release.get("assets")
    if not isinstance(assets, list):
        raise PublishError("GitHub Release asset inventory is invalid")
    names: list[str] = []
    for asset in assets:
        if not isinstance(asset, dict) or not isinstance(asset.get("name"), str):
            raise PublishError("GitHub Release contains an invalid asset")
        names.append(asset["name"])
    if len(names) != len(set(names)):
        raise PublishError("GitHub Release contains duplicate asset names")
    return set(names)


def ensure_release(client: ReleaseClient, publication: Publication) -> dict[str, Any]:
    release = client.get_release(publication.tag)
    if release is None:
        client.create_release(publication.tag, publication.version)
        release = client.get_release(publication.tag)
    if release is None:
        raise PublishError("exact Windows GitHub Release is unavailable after creation")
    validate_release(release, publication.tag)
    return release


def compare_bytes(expected: Path, actual: Path, label: str) -> None:
    if expected.stat().st_size != actual.stat().st_size or sha256_path(expected) != sha256_path(actual):
        raise PublishError(f"refusing to replace non-identical immutable release asset {label}")


def publish(publication: Publication, client: ReleaseClient) -> None:
    for evidence in publication.evidence:
        verify_exact_attestation(client, publication, evidence, evidence.bundle)

    release = ensure_release(client, publication)
    existing_names = validate_release(release, publication.tag)
    with tempfile.TemporaryDirectory(prefix="openburnbar-windows-release-") as directory:
        root = Path(directory)
        existing = root / "existing"
        staged = root / "staged"
        published = root / "published"
        staged.mkdir()

        if publication.artifact.name in existing_names:
            downloaded = client.download_asset(publication.tag, publication.artifact.name, existing)
            compare_bytes(publication.artifact, downloaded, publication.artifact.name)

        staged_bundles: dict[str, Path] = {}
        for evidence in publication.evidence:
            staged_bundle = staged / evidence.asset_name
            shutil.copyfile(evidence.bundle, staged_bundle)
            staged_bundles[evidence.domain] = staged_bundle
            if evidence.asset_name in existing_names:
                downloaded = client.download_asset(publication.tag, evidence.asset_name, existing)
                verify_exact_attestation(client, publication, evidence, downloaded)

        # Bundles are intentionally public before their subject. A partial failure never exposes
        # an unattested canonical release artifact.
        for evidence in publication.evidence:
            if evidence.asset_name in existing_names:
                continue
            staged_bundle = staged_bundles[evidence.domain]
            if not client.upload_asset(publication.tag, staged_bundle):
                downloaded = client.download_asset(publication.tag, evidence.asset_name, existing)
                verify_exact_attestation(client, publication, evidence, downloaded)

        if publication.artifact.name not in existing_names and not client.upload_asset(
            publication.tag, publication.artifact
        ):
            downloaded = client.download_asset(publication.tag, publication.artifact.name, existing)
            compare_bytes(publication.artifact, downloaded, publication.artifact.name)

        downloaded_artifact = client.download_asset(publication.tag, publication.artifact.name, published)
        compare_bytes(publication.artifact, downloaded_artifact, publication.artifact.name)
        for evidence in publication.evidence:
            downloaded_bundle = client.download_asset(publication.tag, evidence.asset_name, published)
            verify_exact_attestation(client, publication, evidence, downloaded_bundle)


def expected_profile_digest(domain: str) -> str:
    return canonical_sha256(
        {
            "artifactAuthority": "signed",
            "distribution": "public",
            "rolloutChannel": None,
            "evidenceEnabled": False,
            "domain": domain,
            "mode": "rust",
        }
    )


def build_publication(arguments: argparse.Namespace) -> Publication:
    if REPOSITORY_RE.fullmatch(arguments.repository) is None:
        raise PublishError("repository must be an owner/name GitHub repository")
    tag_match = TAG_RE.fullmatch(arguments.tag)
    if tag_match is None:
        raise PublishError("tag must be an exact stable windows-vX.Y.Z tag")
    version = tag_match.group(1)
    if COMMIT_RE.fullmatch(arguments.commit) is None:
        raise PublishError("commit must be a full lowercase Git SHA")
    artifact = require_file(arguments.artifact.resolve(), "canonical Windows release artifact")
    expected_name = f"OpenBurnBar-{version}-windows-release.zip"
    if artifact.name != expected_name:
        raise PublishError(f"canonical Windows release artifact must be named {expected_name}")
    artifact_digest = sha256_path(artifact)

    raw_evidence = arguments.evidence or []
    if not raw_evidence:
        raise PublishError("at least one enabled Windows Shared Rust domain is required")
    evidence_items: list[Evidence] = []
    seen: set[str] = set()
    for domain, predicate_value, bundle_value, asset_name in raw_evidence:
        if domain not in {"quota", "cloudVault"} or domain in seen:
            raise PublishError(f"invalid or duplicate Windows Shared Rust domain: {domain}")
        seen.add(domain)
        predicate_path = require_file(Path(predicate_value).resolve(), f"{domain} predicate")
        bundle_path = require_file(Path(bundle_value).resolve(), f"{domain} attestation bundle")
        expected_asset = (
            f"OpenBurnBar-{version}-windows-release-{'cloudvault' if domain == 'cloudVault' else domain}.sigstore.json"
        )
        if asset_name != expected_asset or Path(asset_name).name != asset_name:
            raise PublishError(f"{domain} bundle asset must be named {expected_asset}")
        predicate = load_json(predicate_path, f"{domain} predicate")
        expected = {
            "schemaVersion": 1,
            "consumer": "windows",
            "artifactKind": "windows-release-bundle",
            "target": "windows-x64-arm64",
            "artifact": {"fileName": expected_name, "sha256": artifact_digest},
            "release": {
                "version": version,
                "tag": arguments.tag,
                "commit": arguments.commit,
                "publicProfileSha256": expected_profile_digest(domain),
            },
        }
        if predicate != expected:
            raise PublishError(f"{domain} predicate does not bind the exact Windows release identity")
        evidence_items.append(Evidence(domain, predicate_path, bundle_path, asset_name, expected))

    evidence_items.sort(key=lambda item: item.domain.casefold())
    return Publication(
        repository=arguments.repository,
        tag=arguments.tag,
        version=version,
        commit=arguments.commit,
        artifact=artifact,
        evidence=tuple(evidence_items),
    )


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--artifact", type=Path, required=True)
    parser.add_argument(
        "--evidence",
        action="append",
        nargs=4,
        metavar=("DOMAIN", "PREDICATE", "BUNDLE", "ASSET_NAME"),
    )
    return parser.parse_args()


def main() -> None:
    arguments = parse_arguments()
    publication = build_publication(arguments)
    publish(publication, GhReleaseClient(publication.repository))
    print(
        json.dumps(
            {
                "artifact": publication.artifact.name,
                "domains": [item.domain for item in publication.evidence],
                "release": publication.tag,
                "status": "published-and-verified",
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    try:
        main()
    except PublishError as error:
        raise SystemExit(f"ERROR: {error}") from error
