#!/usr/bin/env python3
"""Fail-closed source gate for shared-Rust legacy implementation deletion."""

from __future__ import annotations

import argparse
import base64
import binascii
import hashlib
import io
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import tarfile
import tomllib
import zipfile
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import quote, urlsplit
from urllib.request import Request, urlopen


ROW_IDS = (
    "quota.claude_statusline",
    "quota.codex_usage",
    "quota.cursor_usage",
    "quota.anthropic_headers",
    "cloudvault.portable_primitives",
    "cloudvault.document_rewrap",
    "cloudvault.search",
    "hermes.relay_crypto",
    "hermes.ratchet_transforms",
    "pricing.token_cost",
    "pricing.kimi_historical",
)
STATES = {
    "rollout",
    "promotion_approved",
    "activation_annulled",
    "rust_authoritative_with_rollback",
    "deletion_approved",
    "rollback_active",
    "legacy_deleted",
}
PROFILE_DOMAIN_ROWS = {
    "quota": (
        "quota.claude_statusline",
        "quota.codex_usage",
        "quota.cursor_usage",
        "quota.anthropic_headers",
    ),
    "cloudVault": ("cloudvault.portable_primitives",),
    "cloudVaultRewrap": ("cloudvault.document_rewrap",),
    "cloudVaultSearch": ("cloudvault.search",),
    "hermes": ("hermes.relay_crypto", "hermes.ratchet_transforms"),
    "pricing": ("pricing.token_cost", "pricing.kimi_historical"),
}
TARGET_KINDS = {"source_symbol", "mode_literal", "path"}
ATOMIC_DELETION_GROUPS = (
    frozenset(
        {
            "quota.claude_statusline",
            "quota.codex_usage",
            "quota.cursor_usage",
            "quota.anthropic_headers",
        }
    ),
    frozenset(
        {
            "cloudvault.portable_primitives",
            "cloudvault.document_rewrap",
            "cloudvault.search",
        }
    ),
    frozenset({"hermes.relay_crypto", "hermes.ratchet_transforms"}),
    frozenset({"pricing.token_cost", "pricing.kimi_historical"}),
)
POST_DELETION_PRIMITIVE_RULES = (
    (
        "swift-cloudvault-crypto",
        frozenset(
            {
                "cloudvault.portable_primitives",
                "cloudvault.document_rewrap",
                "cloudvault.search",
            }
        ),
        "OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels/CloudVaultCrypto.swift",
        re.compile(
            r"PlatformCrypto\.(?:sha256(?:Hex)?|hmacSHA256|deriveHKDFSHA256(?:Key|KeyData)?|sealAESGCM|openAESGCM)|"
            r"OpenBurnBar-CloudVault-(?:AAD|HMAC|CloudSearch)|\blegacy\s*:\s*\{"
        ),
    ),
    (
        "android-cloudvault-crypto",
        frozenset(
            {
                "cloudvault.portable_primitives",
                "cloudvault.document_rewrap",
                "cloudvault.search",
            }
        ),
        "android/app/src/main/java/com/openburnbar/data/cloud",
        re.compile(
            r"(?:Mac\.getInstance\(\"HmacSHA256\"\)|MessageDigest\.getInstance\(\"SHA-256\"\)|"
            r"Cipher\.getInstance\(\"AES/GCM|CloudVaultSearchDomainCore\.[A-Za-z0-9_]+\([^\n]*\)\s*\{)"
        ),
    ),
    (
        "android-subscription-doc-id",
        frozenset({"cloudvault.portable_primitives", "cloudvault.search"}),
        "android/app/src/main/java/com/openburnbar/data/square/AgentSubscriptionTopicStore.kt",
        re.compile(r"CloudVaultCryptoSearch\.hkdfSha256|Mac\.getInstance\(\"HmacSHA256\"\)"),
    ),
    (
        "windows-cloudvault-crypto",
        frozenset(
            {
                "cloudvault.portable_primitives",
                "cloudvault.document_rewrap",
                "cloudvault.search",
            }
        ),
        "windows/cloudsync/OpenBurnBar.CloudSync.Crypto",
        re.compile(r"SHA256\.HashData|HMACSHA256|HKDF\.DeriveKey|\bAesGcm\b|=>\s*Legacy[A-Za-z0-9_]*\("),
    ),
    (
        "swift-hermes-crypto",
        frozenset({"hermes.relay_crypto", "hermes.ratchet_transforms"}),
        "OpenBurnBarCore/Sources/OpenBurnBarKernel/SharedModels",
        re.compile(
            r"HermesDomainCoreAdapter\.[A-Za-z0-9_]+\([^)]*\)\s*\{|"
            r"OpenBurnBar-HermesRelay-v1\||PlatformCrypto\.(?:hmacSHA256|sealAESGCM|openAESGCM)"
        ),
    ),
    (
        "android-hermes-crypto",
        frozenset({"hermes.relay_crypto", "hermes.ratchet_transforms"}),
        "android/app/src/main/java/com/openburnbar/data/hermes/relay",
        re.compile(
            r"Mac\.getInstance\(\"HmacSHA256\"\)|Cipher\.getInstance\(\"AES/GCM|"
            r"HermesDomainCoreAdapter\.[A-Za-z0-9_]+\([^\n]*\)\s*\{"
        ),
    ),
    (
        "swift-codex-quota-decoder",
        frozenset(
            {
                "quota.claude_statusline",
                "quota.codex_usage",
                "quota.cursor_usage",
                "quota.anthropic_headers",
            }
        ),
        "OpenBurnBarCore/Sources/OpenBurnBarQuota/ProviderQuota",
        re.compile(r"additional_rate_limits|primary_window|secondary_window|used_percent|\blegacy\s*:\s*\{"),
    ),
    (
        "functions-pricing",
        frozenset({"pricing.token_cost", "pricing.kimi_historical"}),
        "functions/src/pricing.ts",
        re.compile(r"legacyTokenCost|priceLegacyKimiEvent|LEGACY_KIMI_WIRE"),
    ),
)
RECEIPT_TRANSITIONS = {
    "promotion": "promotion",
    "activationAnnulment": "annulment",
    "stableRelease": "stable_release",
    "rollback": "rollback",
    "deletionReview": "deletion_review",
}
RECEIPT_ROOT = "config/domain-core-legacy-deletion-receipts"
ATTESTATION_ROOT = "config/domain-core-promotion-attestations"
PROMOTION_BUNDLE_ROOT = "config/domain-core-promotion-bundles"
PROMOTION_PROVENANCE_ROOT = "config/domain-core-promotion-provenance"
RELEASE_PROVENANCE_ROOT = "config/domain-core-release-provenance"
DELETION_PLAN_ROOT = "config/domain-core-deletion-plans"
DELETION_REVIEWERS_PATH = "config/domain-core-deletion-reviewers.json"
BUILD_PROFILE_PATH = "config/domain-core-build-profiles.json"
CONTROL_PLANE_MANIFEST_PATH = "config/domain-core-control-plane-manifest.json"
PROMOTION_SCOPES = {
    "quota": "quota",
    "cloudVault": "cloudvault",
    "cloudVaultRewrap": "cloudvault-rewrap",
    "cloudVaultSearch": "cloudvault-search",
    "hermes": "hermes",
    "pricing": "pricing",
}
ROW_RELEASE_CONSUMERS = {
    "quota.claude_statusline": {"apple", "linux", "windows"},
    "quota.codex_usage": {"apple", "linux", "windows"},
    "quota.cursor_usage": {"apple", "linux", "windows"},
    "quota.anthropic_headers": {"apple", "linux", "windows"},
    "cloudvault.portable_primitives": {
        "apple",
        "ios",
        "linux",
        "android",
        "windows",
        "console",
    },
    "cloudvault.document_rewrap": {"apple", "ios", "linux", "android"},
    "cloudvault.search": {"apple", "ios", "linux", "android"},
    "hermes.relay_crypto": {"apple", "ios", "linux", "android"},
    "hermes.ratchet_transforms": {"apple", "ios", "linux", "android"},
    "pricing.token_cost": {"apple", "linux", "functions"},
    "pricing.kimi_historical": {"functions"},
}
PROMOTION_POLICY_PATH = "config/domain-core-promotion-policy.json"
PROMOTION_EVALUATOR_PATH = "scripts/lib/domain-core-deterministic-candidate-bundle.mjs"
PROMOTION_SIGNER_WORKFLOW = ".github/workflows/domain-core-promotion-proof.yml"
PROMOTION_SIGNER_JOB = "protected-domain-core-signer"
SOURCE_WORKFLOW = ".github/workflows/domain-core.yml"
RELEASE_SIGNER_WORKFLOWS = {
    "apple": ".github/workflows/release.yml",
    "ios": ".github/workflows/domain-core-ios-release-evidence.yml",
    "linux": ".github/workflows/linux-release.yml",
    "android": ".github/workflows/release.yml",
    "windows": ".github/workflows/openburnbar-release-windows.yml",
    "console": ".github/workflows/domain-core-console-release-evidence.yml",
    "functions": ".github/workflows/domain-core-functions-release-evidence.yml",
}
ROLLBACK_ACTION_WORKFLOWS = {
    "console": ".github/workflows/deploy-hosting.yml",
    "functions": ".github/workflows/deploy-production.yml",
}
ROLLBACK_COMPLETION_ROOT = "config/domain-core-rollback-completions"
RELEASE_PREDICATE_TYPES = {
    consumer: "https://openburnbar.dev/attestations/domain-core-release-artifact/v2"
    for consumer in RELEASE_SIGNER_WORKFLOWS
}
ROLLBACK_PREDICATE_TYPE = "https://openburnbar.dev/attestations/domain-core-rollback-artifact/v1"
ROLLBACK_PAYLOAD_IDENTITIES = {
    "apple": ("apple-rollback-settings", "macos-arm64"),
    "ios": ("ios-rollback-settings", "ios-universal"),
    "linux": ("linux-rollback-settings", "linux-x64-arm64"),
    "android": ("android-rollback-settings", "android-universal"),
    "windows": ("windows-rollback-settings", "windows-x64-arm64"),
    "console": ("console-rollback-settings", "firebase-hosting-production"),
    "functions": ("functions-rollback-settings", "firebase-functions-production"),
}
RELEASE_ARTIFACT_IDENTITIES = {
    "apple": ("macos-dmg", "macos-arm64"),
    "ios": ("ios-app-store-archive", "ios-universal"),
    "linux": ("linux-release-bundle", "linux-x64-arm64"),
    "android": ("android-aab", "android-universal"),
    "windows": ("windows-release-bundle", "windows-x64-arm64"),
    "console": ("console-deployment-receipt", "firebase-hosting-production"),
    "functions": ("functions-deployment-receipt", "firebase-functions-production"),
}
ACTIVATION_ALLOWED_EXACT_PATHS = {
    BUILD_PROFILE_PATH,
    CONTROL_PLANE_MANIFEST_PATH,
    "config/domain-core-legacy-deletion.json",
}
ACTIVATION_ALLOWED_PREFIXES = (
    f"{RECEIPT_ROOT}/",
    f"{ATTESTATION_ROOT}/",
    f"{PROMOTION_BUNDLE_ROOT}/",
    f"{PROMOTION_PROVENANCE_ROOT}/",
    f"{ROLLBACK_COMPLETION_ROOT}/",
    "docs/runbooks/shared-rust-",
    "docs/SHARED_RUST_DOMAIN_",
)
GUARD_WORKFLOW_PATH = ".github/workflows/domain-core-deletion-guard.yml"
GUARD_VERIFIER_PATH = "scripts/ci/verify-domain-core-legacy-deletion.py"
SENSITIVE_EXACT_PATHS = frozenset(
    {
        "config/domain-core-legacy-deletion.json",
        DELETION_REVIEWERS_PATH,
        PROMOTION_POLICY_PATH,
        BUILD_PROFILE_PATH,
        PROMOTION_EVALUATOR_PATH,
        PROMOTION_SIGNER_WORKFLOW,
        SOURCE_WORKFLOW,
        GUARD_WORKFLOW_PATH,
        GUARD_VERIFIER_PATH,
    }
    | set(RELEASE_SIGNER_WORKFLOWS.values())
    | ACTIVATION_ALLOWED_EXACT_PATHS
)
SENSITIVE_PREFIXES = (
    f"{RECEIPT_ROOT}/",
    f"{ATTESTATION_ROOT}/",
    f"{PROMOTION_BUNDLE_ROOT}/",
    f"{PROMOTION_PROVENANCE_ROOT}/",
    f"{RELEASE_PROVENANCE_ROOT}/",
    f"{DELETION_PLAN_ROOT}/",
    f"{ROLLBACK_COMPLETION_ROOT}/",
)
SECURITY_REVIEW_ROWS = {
    "cloudvault.portable_primitives",
    "cloudvault.document_rewrap",
    "cloudvault.search",
    "hermes.relay_crypto",
    "hermes.ratchet_transforms",
}
ID_RE = re.compile(r"^[a-z][a-z0-9-]*$")
ROW_ID_RE = re.compile(r"^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$")
SYMBOL_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")
MODE_LITERAL_RE = re.compile(r"^[A-Z][A-Z0-9_]{2,127}$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
DIGEST_RE = re.compile(r"^[0-9a-f]{64}$")
VERSION_RE = re.compile(r"^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$")
TAG_RE = re.compile(r"^v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$")
RECEIPT_ACTOR_RE = re.compile(r"^@[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?$")
RFC3339_UTC_RE = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d{1,6})?Z$")


class GateError(ValueError):
    pass


def _no_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise GateError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path, label: str) -> Any:
    try:
        with path.open("r", encoding="utf-8") as handle:
            return json.load(handle, object_pairs_hook=_no_duplicate_keys)
    except (OSError, json.JSONDecodeError, UnicodeError, GateError) as error:
        raise GateError(f"{label}: invalid JSON: {error}") from error


def require_object(value: Any, label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise GateError(f"{label}: expected object")
    return value


def require_array(value: Any, label: str) -> list[Any]:
    if not isinstance(value, list):
        raise GateError(f"{label}: expected array")
    return value


def exact_keys(value: dict[str, Any], allowed: set[str], required: set[str], label: str) -> None:
    unknown = sorted(set(value) - allowed)
    missing = sorted(required - set(value))
    if unknown:
        raise GateError(f"{label}: unknown fields: {', '.join(unknown)}")
    if missing:
        raise GateError(f"{label}: missing fields: {', '.join(missing)}")


def canonical_json_sha256(value: Any) -> str:
    return hashlib.sha256(
        json.dumps(value, separators=(",", ":"), sort_keys=True, ensure_ascii=True).encode()
    ).hexdigest()


def repository_path(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise GateError(f"{label}: expected non-empty repository-relative path")
    if "\\" in value or value.startswith("/") or value.endswith("/"):
        raise GateError(f"{label}: path must be canonical POSIX repository-relative form")
    path = PurePosixPath(value)
    if str(path) != value or any(part in {"", ".", ".."} for part in path.parts):
        raise GateError(f"{label}: path must be canonical POSIX repository-relative form")
    return value


def _inside_repo(repo_root: Path, candidate: Path, label: str) -> None:
    try:
        candidate.relative_to(repo_root)
    except ValueError as error:
        raise GateError(f"{label}: path escapes repository root") from error


def secure_path(repo_root: Path, relative: str, label: str, *, must_exist: bool) -> Path:
    lexical = repo_root.joinpath(*PurePosixPath(relative).parts)
    _inside_repo(repo_root, lexical, label)
    current = repo_root
    for part in PurePosixPath(relative).parts:
        current = current / part
        try:
            mode = current.lstat().st_mode
        except FileNotFoundError:
            break
        except OSError as error:
            raise GateError(f"{label}: cannot inspect path: {error}") from error
        if stat.S_ISLNK(mode):
            raise GateError(f"{label}: symlink components are forbidden: {relative}")
    if must_exist and not lexical.exists():
        raise GateError(f"{label}: required path is missing: {relative}")
    if lexical.exists():
        try:
            resolved = lexical.resolve(strict=True)
        except OSError as error:
            raise GateError(f"{label}: cannot resolve path: {error}") from error
        _inside_repo(repo_root, resolved, label)
    return lexical


def parse_rfc3339_utc(value: Any, label: str) -> datetime:
    if not isinstance(value, str) or not RFC3339_UTC_RE.fullmatch(value):
        raise GateError(f"{label}: expected RFC3339 UTC timestamp")
    try:
        parsed = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise GateError(f"{label}: expected RFC3339 UTC timestamp") from error
    if parsed.tzinfo != UTC:
        raise GateError(f"{label}: expected RFC3339 UTC timestamp")
    return parsed


def sha256_path(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_digest(value: Any, label: str) -> str:
    if not isinstance(value, str) or not DIGEST_RE.fullmatch(value):
        raise GateError(f"{label}: expected lowercase SHA-256 digest")
    return value


def require_commit(repo_root: Path, value: Any, label: str) -> str:
    if not isinstance(value, str) or not COMMIT_RE.fullmatch(value):
        raise GateError(f"{label}: commit must be a full lowercase Git SHA")
    try:
        result = subprocess.run(
            ["git", "merge-base", "--is-ancestor", value, "HEAD"],
            cwd=repo_root,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GateError(f"{label}: cannot verify Git ancestry: {error}") from error
    if result.returncode != 0:
        raise GateError(f"{label}: commit must exist and be an ancestor of HEAD")
    return value


def require_ancestor(repo_root: Path, ancestor: str, descendant: str, label: str) -> None:
    try:
        result = subprocess.run(
            ["git", "merge-base", "--is-ancestor", ancestor, descendant],
            cwd=repo_root,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GateError(f"{label}: cannot verify Git ancestry: {error}") from error
    if result.returncode != 0:
        raise GateError(f"{label}: {ancestor} must be an ancestor of {descendant}")


def git_output(repo_root: Path, arguments: list[str], label: str) -> str:
    try:
        result = subprocess.run(
            ["git", *arguments],
            cwd=repo_root,
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GateError(f"{label}: cannot run Git: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip() or "Git command failed"
        raise GateError(f"{label}: {detail}")
    return result.stdout


def load_json_bytes(contents: bytes, label: str) -> Any:
    try:
        return json.loads(contents.decode("utf-8"), object_pairs_hook=_no_duplicate_keys)
    except (json.JSONDecodeError, UnicodeError, GateError) as error:
        raise GateError(f"{label}: invalid JSON: {error}") from error


def git_file(repo_root: Path, revision: str, relative: str, label: str) -> bytes:
    repository_path(relative, label)
    try:
        result = subprocess.run(
            ["git", "show", f"{revision}:{relative}"],
            cwd=repo_root,
            check=False,
            capture_output=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GateError(f"{label}: cannot read historical file: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise GateError(f"{label}: historical file is unavailable: {detail}")
    return result.stdout


def git_file_exists(repo_root: Path, revision: str, relative: str, label: str) -> bool:
    repository_path(relative, label)
    try:
        result = subprocess.run(
            ["git", "cat-file", "-e", f"{revision}:{relative}"],
            cwd=repo_root,
            check=False,
            capture_output=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GateError(f"{label}: cannot inspect historical file: {error}") from error
    return result.returncode == 0


def load_deletion_reviewers(
    repo_root: Path,
    revision: str | None = None,
    *,
    allow_missing: bool = False,
) -> dict[str, set[str]]:
    label = "domain-core deletion reviewers"
    if revision is None:
        path = secure_path(repo_root, DELETION_REVIEWERS_PATH, label, must_exist=not allow_missing)
        if not path.exists():
            return {"domain_owner": set(), "security_crypto": set()}
        value = load_json(path, label)
    else:
        try:
            value = load_json_bytes(git_file(repo_root, revision, DELETION_REVIEWERS_PATH, label), label)
        except GateError:
            if allow_missing:
                return {"domain_owner": set(), "security_crypto": set()}
            raise
    catalog = require_object(value, label)
    exact_keys(catalog, {"schemaVersion", "reviewers"}, {"schemaVersion", "reviewers"}, label)
    if catalog["schemaVersion"] != 1 or isinstance(catalog["schemaVersion"], bool):
        raise GateError(f"{label}: schemaVersion must be 1")
    raw_reviewers = require_array(catalog["reviewers"], f"{label}.reviewers")
    if not raw_reviewers:
        if allow_missing:
            return {"domain_owner": set(), "security_crypto": set()}
        raise GateError(f"{label}.reviewers: at least one qualified reviewer is required")
    reviewers = {"domain_owner": set(), "security_crypto": set()}
    seen_handles: set[str] = set()
    previous: str | None = None
    for index, raw_reviewer in enumerate(raw_reviewers):
        reviewer = require_object(raw_reviewer, f"{label}.reviewers[{index}]")
        exact_keys(
            reviewer,
            {"handle", "reviewClasses"},
            {"handle", "reviewClasses"},
            f"{label}.reviewers[{index}]",
        )
        handle = reviewer["handle"]
        if not isinstance(handle, str) or not RECEIPT_ACTOR_RE.fullmatch(handle):
            raise GateError(f"{label}.reviewers[{index}].handle: expected GitHub handle")
        normalized = handle.casefold()
        if normalized in seen_handles:
            raise GateError(f"{label}: duplicate reviewer {handle}")
        if previous is not None and normalized <= previous:
            raise GateError(f"{label}: reviewers must be sorted case-insensitively")
        classes = require_array(reviewer["reviewClasses"], f"{label}.reviewers[{index}].reviewClasses")
        if not classes or classes != sorted(set(classes)) or any(value not in reviewers for value in classes):
            raise GateError(f"{label}.reviewers[{index}].reviewClasses: expected sorted unique deletion review classes")
        for review_class in classes:
            reviewers[review_class].add(normalized)
        seen_handles.add(normalized)
        previous = normalized
    missing_classes = sorted(review_class for review_class, handles in reviewers.items() if not handles)
    if missing_classes and not allow_missing:
        raise GateError(f"{label}: no qualified reviewer covers {', '.join(missing_classes)}")
    return reviewers


class SignedEvidenceVerifier:
    repository = "Imagine-That-Ai/BurnBar"

    def __init__(self, cache_root: Path | None = None) -> None:
        configured = os.environ.get("DOMAIN_CORE_EVIDENCE_CACHE")
        self.cache_root = cache_root or (Path(configured) if configured else None)
        if self.cache_root is not None:
            self.cache_root.mkdir(parents=True, exist_ok=True, mode=0o700)
        self._github_cache: dict[str, dict[str, Any]] = {}
        self._github_list_cache: dict[str, list[Any]] = {}
        self._attestation_cache: dict[tuple[str, ...], list[dict[str, Any]]] = {}

    def _cached_artifact(self, uri: str, expected_sha256: str, label: str) -> Path:
        if self.cache_root is not None:
            destination = self.cache_root / expected_sha256
            if destination.exists():
                if not destination.is_file() or destination.is_symlink() or sha256_path(destination) != expected_sha256:
                    raise GateError(f"{label}: cached artifact is not the declared immutable bytes")
                return destination
        else:
            destination = Path(tempfile.mkdtemp(prefix="openburnbar-domain-evidence-")) / "artifact"
        try:
            request = Request(uri, headers={"User-Agent": "OpenBurnBar-domain-core-gate/1"})
            with urlopen(request, timeout=60) as response:
                validate_release_download_redirect(response.geturl())
                remaining = 2 * 1024 * 1024 * 1024
                temporary = destination.with_name(f".{destination.name}.{os.getpid()}.tmp")
                with temporary.open("xb") as output:
                    while chunk := response.read(min(1024 * 1024, remaining + 1)):
                        remaining -= len(chunk)
                        if remaining < 0:
                            raise GateError(f"{label}: artifact exceeds the 2 GiB verification limit")
                        output.write(chunk)
                if sha256_path(temporary) != expected_sha256:
                    temporary.unlink(missing_ok=True)
                    raise GateError(f"{label}: artifact SHA-256 does not match published bytes")
                temporary.chmod(0o600)
                try:
                    os.link(temporary, destination)
                except FileExistsError:
                    if sha256_path(destination) != expected_sha256:
                        raise GateError(f"{label}: cache collision for immutable artifact") from None
                finally:
                    temporary.unlink(missing_ok=True)
        except (OSError, ValueError) as error:
            raise GateError(f"{label}: artifact download failed: {error}") from error
        return destination

    def _verify_bundle(
        self,
        artifact: Path,
        bundle: Path,
        *,
        signer_workflow: str,
        source_digest: str,
        source_ref: str | None,
        predicate_type: str,
        signer_digest: str | None,
        label: str,
    ) -> list[dict[str, Any]]:
        arguments = [
            "attestation",
            "verify",
            str(artifact),
            "--bundle",
            str(bundle),
            "--repo",
            self.repository,
            "--signer-workflow",
            f"{self.repository}/{signer_workflow}",
            "--source-digest",
            source_digest,
            "--cert-oidc-issuer",
            "https://token.actions.githubusercontent.com",
            "--deny-self-hosted-runners",
            "--predicate-type",
            predicate_type,
            "--format",
            "json",
        ]
        if source_ref is not None:
            arguments.extend(["--source-ref", source_ref])
        if signer_digest is not None:
            arguments.extend(["--signer-digest", signer_digest])
        cache_key = (
            sha256_path(artifact),
            sha256_path(bundle),
            signer_workflow,
            source_digest,
            source_ref or "",
            predicate_type,
            signer_digest or "",
        )
        if cache_key in self._attestation_cache:
            return self._attestation_cache[cache_key]
        try:
            result = subprocess.run(
                ["gh", *arguments],
                check=False,
                capture_output=True,
                text=True,
                timeout=120,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise GateError(f"{label}: cannot verify signed provenance: {error}") from error
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip() or "gh attestation verification failed"
            raise GateError(f"{label}: signed provenance verification failed: {detail}")
        try:
            verified = json.loads(result.stdout)
        except json.JSONDecodeError as error:
            raise GateError(f"{label}: attestation verifier returned invalid JSON") from error
        if not isinstance(verified, list) or not verified:
            raise GateError(f"{label}: no valid signed provenance statement was returned")
        if any(not isinstance(item, dict) for item in verified):
            raise GateError(f"{label}: attestation verifier returned an invalid verification result")
        self._attestation_cache[cache_key] = verified
        return verified

    def _github_json(self, path: str, label: str) -> dict[str, Any]:
        if path in self._github_cache:
            return self._github_cache[path]
        try:
            result = subprocess.run(
                ["gh", "api", path],
                check=False,
                capture_output=True,
                text=True,
                timeout=30,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise GateError(f"{label}: cannot query GitHub: {error}") from error
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip() or "GitHub API request failed"
            raise GateError(f"{label}: GitHub query failed: {detail}")
        try:
            value = require_object(json.loads(result.stdout), label)
            self._github_cache[path] = value
            return value
        except json.JSONDecodeError as error:
            raise GateError(f"{label}: GitHub query returned invalid JSON") from error

    def _github_list(self, path: str, label: str) -> list[Any]:
        if path in self._github_list_cache:
            return self._github_list_cache[path]
        try:
            result = subprocess.run(
                ["gh", "api", "--paginate", "--slurp", path],
                check=False,
                capture_output=True,
                text=True,
                timeout=30,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise GateError(f"{label}: cannot query GitHub: {error}") from error
        if result.returncode != 0:
            detail = result.stderr.strip() or result.stdout.strip() or "GitHub API request failed"
            raise GateError(f"{label}: GitHub query failed: {detail}")
        try:
            pages = require_array(json.loads(result.stdout), f"{label} pages")
            value = [
                item
                for page_index, page in enumerate(pages)
                for item in require_array(page, f"{label} pages[{page_index}]")
            ]
        except json.JSONDecodeError as error:
            raise GateError(f"{label}: GitHub query returned invalid JSON") from error
        self._github_list_cache[path] = value
        return value

    def verify_candidate_bundle(
        self,
        artifact: Path,
        bundle: Path,
        *,
        trusted_main_commit: str,
        source_run_id: int,
        source_run_attempt: int,
        signer_run_id: int,
        signer_run_attempt: int,
        candidate_commit: str,
    ) -> None:
        self._verify_bundle(
            artifact,
            bundle,
            signer_workflow=PROMOTION_SIGNER_WORKFLOW,
            source_digest=trusted_main_commit,
            source_ref="refs/heads/main",
            predicate_type="https://slsa.dev/provenance/v1",
            signer_digest=trusted_main_commit,
            label="deterministic candidate bundle",
        )
        source = self._github_json(
            f"repos/{self.repository}/actions/runs/{source_run_id}/attempts/{source_run_attempt}",
            "domain-core source run",
        )
        expected_source = {
            "event": "push",
            "path": SOURCE_WORKFLOW,
            "head_branch": "main",
            "head_sha": candidate_commit,
            "status": "completed",
            "conclusion": "success",
            "run_attempt": source_run_attempt,
        }
        for key, expected in expected_source.items():
            if source.get(key) != expected:
                raise GateError(f"domain-core source run.{key} must equal {expected!r}")
        if (
            require_object(source.get("repository"), "domain-core source run.repository").get("full_name")
            != self.repository
        ):
            raise GateError("domain-core source run repository is not trusted")
        signer = self._github_json(
            f"repos/{self.repository}/actions/runs/{signer_run_id}/attempts/{signer_run_attempt}",
            "domain-core signer run",
        )
        expected_signer = {
            "event": "workflow_dispatch",
            "path": PROMOTION_SIGNER_WORKFLOW,
            "head_branch": "main",
            "head_sha": trusted_main_commit,
            "status": "completed",
            "conclusion": "success",
            "run_attempt": signer_run_attempt,
        }
        for key, expected in expected_signer.items():
            if signer.get(key) != expected:
                raise GateError(f"domain-core signer run.{key} must equal {expected!r}")
        if (
            require_object(signer.get("repository"), "domain-core signer run.repository").get("full_name")
            != self.repository
        ):
            raise GateError("domain-core signer run repository is not trusted")

    def verify_release(
        self,
        item: dict[str, Any],
        bundle: Path,
        expected_sha256: str,
        domain: str,
    ) -> None:
        artifact = self._cached_artifact(item["artifactUri"], expected_sha256, "release artifact")
        try:
            verified = self._verify_bundle(
                artifact,
                bundle,
                signer_workflow=RELEASE_SIGNER_WORKFLOWS[item["consumer"]],
                source_digest=item["commit"],
                source_ref=f"refs/tags/{item['tag']}",
                predicate_type=RELEASE_PREDICATE_TYPES[item["consumer"]],
                signer_digest=item["commit"],
                label=f"{item['consumer']} release artifact",
            )
            expected_predicate = {
                "schemaVersion": 2,
                "predicateType": RELEASE_PREDICATE_TYPES[item["consumer"]],
                "consumer": item["consumer"],
                "domain": domain,
                "artifactKind": item["artifactKind"],
                "target": item["target"],
                "publicProfile": {
                    "profile": "public-production",
                    "domain": domain,
                    "mode": "rust",
                    "sha256": item["publicProfileSha256"],
                },
                "candidate": item["candidate"],
                "activation": item["activation"],
                "artifact": {
                    "fileName": expected_release_asset_name(item["consumer"], item["version"]),
                    "sha256": expected_sha256,
                },
                "release": {
                    "version": item["version"],
                    "tag": item["tag"],
                    "commit": item["commit"],
                    "publicProfileSha256": item["publicProfileSha256"],
                },
            }
            predicates = []
            for result in verified:
                verification = result.get("verificationResult")
                statement = verification.get("statement") if isinstance(verification, dict) else None
                predicate = statement.get("predicate") if isinstance(statement, dict) else None
                if isinstance(predicate, dict):
                    predicates.append(predicate)
            matching = [
                predicate
                for predicate in predicates
                if all(predicate.get(key) == value for key, value in expected_predicate.items())
                and require_object(predicate.get("sourceRun"), "signed release predicate.sourceRun").get("repository")
                == self.repository
                and predicate["sourceRun"].get("workflowPath") == SOURCE_WORKFLOW
                and predicate["sourceRun"].get("headSha") == item["candidate"]["candidateCommit"]
                and require_object(
                    predicate.get("promotionProof"),
                    "signed release predicate.promotionProof",
                ).get("signerWorkflow")
                == PROMOTION_SIGNER_WORKFLOW
                and predicate["promotionProof"].get("predicateType") == "https://slsa.dev/provenance/v1"
                and require_object(
                    predicate.get("rollbackArtifact"),
                    "signed release predicate.rollbackArtifact",
                ).get("candidate")
                == item["candidate"]
                and predicate["rollbackArtifact"].get("activation") == item["activation"]
                and (
                    "_retainedRollbackSha256" not in item
                    or predicate["rollbackArtifact"].get("sha256") == item["_retainedRollbackSha256"]
                )
            ]
            if item["consumer"] == "ios":
                matching = [
                    predicate
                    for predicate in matching
                    if ios_app_store_receipt_matches(predicate, item, expected_sha256)
                ]
            if not matching:
                raise GateError(
                    f"{item['consumer']} release artifact: signed predicate does not bind the declared consumer identity"
                )
        finally:
            if self.cache_root is None:
                artifact.unlink(missing_ok=True)
                artifact.parent.rmdir()

    def verify_rollback_completion(
        self,
        item: dict[str, Any],
        artifact: Path,
        bundle: Path,
        *,
        candidate: dict[str, Any],
        activation: dict[str, Any],
        source_run: dict[str, Any],
        promotion_signer: dict[str, Any],
        candidate_bundle_sha256: str,
        retained_rollback_sha256: str,
        domain: str,
    ) -> datetime:
        consumer = item["consumer"]
        label = f"{consumer} rollback completion"
        artifact_digest = require_digest(item["artifactSha256"], f"{label}.artifactSha256")
        bundle_digest = require_digest(item["provenanceSha256"], f"{label}.provenanceSha256")
        if sha256_path(artifact) != artifact_digest or sha256_path(bundle) != bundle_digest:
            raise GateError(f"{label}: committed completion evidence digest does not match its bytes")
        release = item["release"]
        signer = item["signer"]
        action_run = item["actionRun"]
        verified = self._verify_bundle(
            artifact,
            bundle,
            signer_workflow=RELEASE_SIGNER_WORKFLOWS[consumer],
            source_digest=activation["activationCommit"],
            source_ref=f"refs/tags/{release['tag']}",
            predicate_type=RELEASE_PREDICATE_TYPES[consumer],
            signer_digest=activation["activationCommit"],
            label=label,
        )
        expected_public_profile = {
            "profile": "public-production-rollback",
            "domain": domain,
            "mode": "legacy",
            "sha256": item["rollbackProfileSha256"],
        }
        expected_release = {
            "version": release["version"],
            "tag": release["tag"],
            "commit": activation["activationCommit"],
            "publicProfileSha256": item["rollbackProfileSha256"],
        }
        expected_artifact_identity = RELEASE_ARTIFACT_IDENTITIES[consumer]
        predicates: list[dict[str, Any]] = []
        invocations: set[tuple[int, int]] = set()
        invocation_prefix = f"https://github.com/{self.repository}/actions/runs/"
        for result in verified:
            verification = result.get("verificationResult")
            if not isinstance(verification, dict):
                continue
            statement = verification.get("statement")
            predicate = statement.get("predicate") if isinstance(statement, dict) else None
            if isinstance(predicate, dict):
                predicates.append(predicate)
            signature = verification.get("signature")
            certificate = signature.get("certificate") if isinstance(signature, dict) else None
            invocation = certificate.get("runInvocationURI") if isinstance(certificate, dict) else None
            if isinstance(invocation, str) and invocation.startswith(invocation_prefix):
                match = re.fullmatch(r"([1-9][0-9]*)/attempts/([1-9][0-9]*)", invocation[len(invocation_prefix) :])
                if match is not None:
                    invocations.add((int(match.group(1)), int(match.group(2))))
        signer_identity = (
            positive_integer(signer["runId"], f"{label}.signer.runId"),
            positive_integer(signer["runAttempt"], f"{label}.signer.runAttempt"),
        )
        if invocations != {signer_identity}:
            raise GateError(f"{label}: signed provenance does not bind the exact signer run and attempt")
        matching: list[dict[str, Any]] = []
        for predicate in predicates:
            if (
                predicate.get("schemaVersion") != 2
                or predicate.get("predicateType") != RELEASE_PREDICATE_TYPES[consumer]
                or predicate.get("consumer") != consumer
                or predicate.get("domain") != domain
                or (predicate.get("artifactKind"), predicate.get("target")) != expected_artifact_identity
                or predicate.get("candidate") != candidate
                or predicate.get("activation") != activation
                or predicate.get("publicProfile") != expected_public_profile
                or predicate.get("release") != expected_release
                or require_object(predicate.get("artifact"), f"{label} predicate.artifact").get("sha256")
                != artifact_digest
                or predicate.get("sourceRun") != source_run
            ):
                continue
            promotion = require_object(predicate.get("promotionProof"), f"{label} predicate.promotionProof")
            subject = require_object(
                promotion.get("attestationSubject"),
                f"{label} predicate.promotionProof.attestationSubject",
            )
            promotion_run = require_object(
                promotion.get("signerRun"),
                f"{label} predicate.promotionProof.signerRun",
            )
            rollback_artifact = require_object(
                predicate.get("rollbackArtifact"),
                f"{label} predicate.rollbackArtifact",
            )
            if (
                promotion.get("signerWorkflow") != PROMOTION_SIGNER_WORKFLOW
                or promotion.get("predicateType") != "https://slsa.dev/provenance/v1"
                or subject.get("sha256") != candidate_bundle_sha256
                or promotion_run.get("runId") != promotion_signer["runId"]
                or promotion_run.get("runAttempt") != promotion_signer["runAttempt"]
                or rollback_artifact.get("sha256") != retained_rollback_sha256
                or rollback_artifact.get("candidate") != candidate
                or rollback_artifact.get("activation") != activation
            ):
                continue
            deployment = predicate.get("deployment")
            if consumer in ROLLBACK_ACTION_WORKFLOWS:
                if not isinstance(deployment, dict) or deployment.get("status") != "healthy":
                    continue
                deploy_run = deployment.get("deployRun")
                if not isinstance(deploy_run, dict) or deploy_run != action_run:
                    continue
                if deployment.get("deployedArtifact", {}).get("sha256") != item["deployedArtifactSha256"]:
                    continue
                if deployment.get("healthArtifactSha256") != item["healthArtifactSha256"]:
                    continue
            elif action_run != {
                "repository": self.repository,
                "workflowPath": RELEASE_SIGNER_WORKFLOWS[consumer],
                "runId": signer_identity[0],
                "runAttempt": signer_identity[1],
                "event": action_run.get("event"),
                "ref": f"refs/tags/{release['tag']}",
                "headSha": activation["activationCommit"],
            }:
                continue
            matching.append(predicate)
        if len(matching) != 1:
            raise GateError(f"{label}: expected exactly one signed predicate for the completed rollback target")

        signer_run = self._github_json(
            f"repos/{self.repository}/actions/runs/{signer_identity[0]}/attempts/{signer_identity[1]}",
            f"{label} signer run",
        )
        expected_signer_run = {
            "path": RELEASE_SIGNER_WORKFLOWS[consumer],
            "head_sha": activation["activationCommit"],
            "status": "completed",
            "conclusion": "success",
            "run_attempt": signer_identity[1],
            "head_branch": release["tag"],
        }
        for key, expected in expected_signer_run.items():
            if signer_run.get(key) != expected:
                raise GateError(f"{label} signer run.{key} must equal {expected!r}")
        if (
            require_object(signer_run.get("repository"), f"{label} signer run.repository").get("full_name")
            != self.repository
        ):
            raise GateError(f"{label}: signer run repository is not trusted")
        if consumer in ROLLBACK_ACTION_WORKFLOWS:
            action_run_id = positive_integer(action_run.get("runId"), f"{label}.actionRun.runId")
            action_run_attempt = positive_integer(
                action_run.get("runAttempt"),
                f"{label}.actionRun.runAttempt",
            )
            authoritative_run = self._github_json(
                f"repos/{self.repository}/actions/runs/{action_run_id}/attempts/{action_run_attempt}",
                f"{label} action run",
            )
            expected_action_run = {
                "path": ROLLBACK_ACTION_WORKFLOWS[consumer],
                "event": "workflow_dispatch",
                "head_sha": activation["activationCommit"],
                "status": "completed",
                "conclusion": "success",
                "run_attempt": action_run_attempt,
                "head_branch": release["tag"],
            }
            for key, expected in expected_action_run.items():
                if authoritative_run.get(key) != expected:
                    raise GateError(f"{label} action run.{key} must equal {expected!r}")
        else:
            authoritative_run = signer_run
        if (
            require_object(authoritative_run.get("repository"), f"{label} action run.repository").get("full_name")
            != self.repository
        ):
            raise GateError(f"{label}: action run repository is not trusted")
        completed_at = parse_rfc3339_utc(authoritative_run.get("updated_at"), f"{label} action run.updated_at")
        if completed_at != parse_rfc3339_utc(item["completedAt"], f"{label}.completedAt"):
            raise GateError(f"{label}: completion timestamp does not match the authoritative action run")
        return completed_at

    def verify_rollback_artifact(
        self,
        item: dict[str, Any],
        bundle: Path,
        expected_sha256: str,
    ) -> None:
        artifact = self._cached_artifact(item["artifactUri"], expected_sha256, "rollback artifact")
        try:
            try:
                with zipfile.ZipFile(artifact) as archive:
                    base_entries = [
                        "manifest.json",
                        "domain-core-public-production-rollback.json",
                        "rollback.env",
                        "rollback-payloads.json",
                        "legacy-source.tar.gz",
                    ]
                    if any(info.is_dir() or info.flag_bits & 1 for info in archive.infolist()):
                        raise GateError("rollback artifact contains an unsafe or encrypted entry")
                    manifest = require_object(
                        json.loads(archive.read("manifest.json")),
                        "rollback artifact manifest",
                    )
                    profile = require_object(
                        json.loads(archive.read("domain-core-public-production-rollback.json")),
                        "rollback artifact profile",
                    )
                    environment = archive.read("rollback.env")
                    payload_manifest = require_object(
                        json.loads(archive.read("rollback-payloads.json")),
                        "rollback payload manifest",
                    )
                    source_archive = archive.read("legacy-source.tar.gz")
                    raw_payloads = require_array(
                        payload_manifest.get("payloads"),
                        "rollback payload manifest.payloads",
                    )
                    payload_entries: list[str] = []
                    embedded_payload_bytes: dict[tuple[str, str], bytes] = {}
                    for payload_value in raw_payloads:
                        payload = require_object(payload_value, "rollback payload manifest payload")
                        consumer = payload.get("consumer")
                        if consumer not in ROLLBACK_PAYLOAD_IDENTITIES:
                            raise GateError("rollback payload manifest contains an unknown consumer")
                        for path_key, kind in (("payloadPath", "artifact"), ("provenancePath", "provenance")):
                            entry = payload.get(path_key)
                            expected_entry = f"payloads/{consumer}/" + (
                                "rollback-settings.json" if kind == "artifact" else "provenance.json"
                            )
                            if entry != expected_entry:
                                raise GateError(f"rollback payload {consumer}.{path_key} is not canonical")
                            payload_entries.append(entry)
                            embedded_payload_bytes[(consumer, kind)] = archive.read(entry)
                    expected_entries = base_entries + payload_entries
                    if archive.namelist() != expected_entries:
                        raise GateError("rollback artifact does not contain the exact retained restoration payload")
            except (OSError, ValueError, KeyError, json.JSONDecodeError, zipfile.BadZipFile) as error:
                raise GateError(f"rollback artifact restoration payload is unreadable: {error}") from error
            modes = require_object(profile.get("modes"), "rollback artifact profile.modes")
            if (
                profile.get("name") != "public-production-rollback"
                or profile.get("artifactAuthority") != "signed"
                or profile.get("distribution") != "public"
                or profile.get("candidateIdentity") != item["candidate"]
                or set(modes) != set(PROFILE_DOMAIN_ROWS)
                or any(mode != "legacy" for mode in modes.values())
            ):
                raise GateError("rollback artifact does not contain the exact all-legacy signed profile")
            restoration = require_object(manifest.get("restoration"), "rollback artifact restoration")
            source = require_object(restoration.get("sourceArchive"), "rollback artifact source archive")
            settings = require_object(restoration.get("environment"), "rollback artifact environment")
            payload_inventory = require_object(
                restoration.get("payloadInventory"),
                "rollback artifact payload inventory",
            )
            profile_identity = {
                "name": "public-production-rollback",
                "sha256": canonical_json_sha256(profile),
            }
            exact_keys(
                payload_manifest,
                {"schemaVersion", "candidate", "profile", "payloads"},
                {"schemaVersion", "candidate", "profile", "payloads"},
                "rollback payload manifest",
            )
            payloads = require_array(payload_manifest["payloads"], "rollback payload manifest.payloads")
            if (
                manifest.get("schemaVersion") != 1
                or manifest.get("artifactKind") != "legacy-rollback-bundle"
                or manifest.get("target") != "all-supported-consumers"
                or manifest.get("candidate") != item["candidate"]
                or manifest.get("activation") != item["activation"]
                or manifest.get("release")
                != {
                    "version": item["version"],
                    "tag": item["tag"],
                    "commit": item["commit"],
                }
                or manifest.get("retentionPolicy") != item["retentionPolicy"]
                or manifest.get("contents") != expected_entries
                or restoration.get("sourceCommit") != item["candidate"]["candidateCommit"]
                or source.get("path") != "legacy-source.tar.gz"
                or source.get("sha256") != hashlib.sha256(source_archive).hexdigest()
                or source.get("size") != len(source_archive)
                or settings.get("path") != "rollback.env"
                or settings.get("sha256") != hashlib.sha256(environment).hexdigest()
                or settings.get("allDomainModes") != "legacy"
                or payload_manifest.get("schemaVersion") != 1
                or payload_manifest.get("candidate") != item["candidate"]
                or payload_manifest.get("profile") != profile_identity
                or payload_inventory.get("path") != "rollback-payloads.json"
                or payload_inventory.get("sha256") != canonical_json_sha256(payload_manifest)
                or payload_inventory.get("consumers") != list(ROLLBACK_PAYLOAD_IDENTITIES)
            ):
                raise GateError("rollback artifact manifest does not bind usable legacy source, settings, and payloads")
            if len(payloads) != len(ROLLBACK_PAYLOAD_IDENTITIES):
                raise GateError("rollback payload manifest must cover the exact seven consumers")
            payload_fields = {
                "consumer",
                "artifactKind",
                "target",
                "payloadPath",
                "payloadSha256",
                "size",
                "provenancePath",
                "provenanceSha256",
            }
            for index, payload_value in enumerate(payloads):
                payload = require_object(payload_value, f"rollback payloads[{index}]")
                exact_keys(payload, payload_fields, payload_fields, f"rollback payloads[{index}]")
                consumer = payload.get("consumer")
                if consumer != list(ROLLBACK_PAYLOAD_IDENTITIES)[index]:
                    raise GateError("rollback payloads must cover the exact canonical consumer order")
                artifact_kind, target = ROLLBACK_PAYLOAD_IDENTITIES[consumer]
                if payload.get("artifactKind") != artifact_kind or payload.get("target") != target:
                    raise GateError(f"rollback payload {consumer}: artifact identity is not canonical")
                payload_sha256 = require_digest(
                    payload.get("payloadSha256"),
                    f"rollback payload {consumer}.payloadSha256",
                )
                provenance_sha256 = require_digest(
                    payload.get("provenanceSha256"),
                    f"rollback payload {consumer}.provenanceSha256",
                )
                size = payload.get("size")
                if isinstance(size, bool) or not isinstance(size, int) or size < 1:
                    raise GateError(f"rollback payload {consumer}.size must be a positive integer")
                embedded_artifact = embedded_payload_bytes[(consumer, "artifact")]
                embedded_provenance = embedded_payload_bytes[(consumer, "provenance")]
                if (
                    hashlib.sha256(embedded_artifact).hexdigest() != payload_sha256
                    or len(embedded_artifact) != size
                    or hashlib.sha256(embedded_provenance).hexdigest() != provenance_sha256
                ):
                    raise GateError(f"rollback payload {consumer}: embedded bytes differ from the manifest")
                try:
                    settings_payload = require_object(
                        json.loads(embedded_artifact), f"rollback payload {consumer} settings"
                    )
                    provenance_payload = require_object(
                        json.loads(embedded_provenance), f"rollback payload {consumer} provenance"
                    )
                except (UnicodeDecodeError, json.JSONDecodeError) as error:
                    raise GateError(f"rollback payload {consumer}: settings or provenance is unreadable") from error
                expected_release = {"version": item["version"], "tag": item["tag"], "commit": item["commit"]}
                expected_settings = {
                    "schemaVersion": 1,
                    "action": "rebuild_and_redeploy_legacy",
                    "consumer": consumer,
                    "artifactKind": artifact_kind,
                    "target": target,
                    "candidate": item["candidate"],
                    "activation": item["activation"],
                    "profile": profile_identity,
                    "release": expected_release,
                    "environment": environment.decode("ascii").splitlines(),
                }
                expected_provenance = {
                    "schemaVersion": 1,
                    "predicateType": "https://openburnbar.dev/attestations/domain-core-rollback-settings/v1",
                    "consumer": consumer,
                    "subject": {
                        "path": payload["payloadPath"],
                        "sha256": payload_sha256,
                        "size": size,
                    },
                    "candidate": item["candidate"],
                    "profile": profile_identity,
                    "release": expected_release,
                }
                if settings_payload != expected_settings or provenance_payload != expected_provenance:
                    raise GateError(
                        f"rollback payload {consumer}: bytes do not encode the exact usable legacy settings"
                    )
            try:
                settings_text = environment.decode("ascii")
            except UnicodeDecodeError as error:
                raise GateError("rollback artifact environment is not canonical ASCII") from error
            if (
                "OPENBURNBAR_DOMAIN_CORE_BUILD_PROFILE=public-production-rollback\n" not in settings_text
                or "OPENBURNBAR_DOMAIN_CORE_CANDIDATE_COMMIT=" + item["candidate"]["candidateCommit"] + "\n"
                not in settings_text
                or sum(line.endswith("_MODE=legacy") for line in settings_text.splitlines()) != len(modes)
            ):
                raise GateError("rollback artifact environment cannot restore every legacy domain")
            try:
                with tarfile.open(fileobj=io.BytesIO(source_archive), mode="r:gz") as source_tar:
                    source_members = source_tar.getmembers()
            except (OSError, tarfile.TarError) as error:
                raise GateError(f"rollback artifact legacy source is unreadable: {error}") from error
            if not source_members or any(
                member.issym()
                or member.islnk()
                or PurePosixPath(member.name).is_absolute()
                or ".." in PurePosixPath(member.name).parts
                for member in source_members
            ):
                raise GateError("rollback artifact legacy source contains unsafe entries")
            source_names = {member.name for member in source_members if member.isfile()}
            required_suffixes = {
                "config/domain-core-build-profiles.json",
                "crates/openburnbar-domain-core/Cargo.toml",
            }
            if any(not any(name.endswith(suffix) for name in source_names) for suffix in required_suffixes):
                raise GateError("rollback artifact legacy source omits required build inputs")
            verified = self._verify_bundle(
                artifact,
                bundle,
                signer_workflow=".github/workflows/release.yml",
                source_digest=item["commit"],
                source_ref=f"refs/tags/{item['tag']}",
                predicate_type=ROLLBACK_PREDICATE_TYPE,
                signer_digest=item["commit"],
                label="dedicated legacy rollback artifact",
            )
            expected_predicate = {
                "schemaVersion": 1,
                "artifactKind": "legacy-rollback-bundle",
                "target": "all-supported-consumers",
                "artifact": {
                    "fileName": item["artifactUri"].rsplit("/", 1)[-1],
                    "sha256": expected_sha256,
                },
                "release": {
                    "version": item["version"],
                    "tag": item["tag"],
                    "commit": item["commit"],
                    "candidate": item["candidate"],
                    "activation": item["activation"],
                    "retentionPolicy": item["retentionPolicy"],
                },
            }
            predicates = []
            for result in verified:
                verification = result.get("verificationResult")
                statement = verification.get("statement") if isinstance(verification, dict) else None
                predicate = statement.get("predicate") if isinstance(statement, dict) else None
                if isinstance(predicate, dict):
                    predicates.append(predicate)
            if expected_predicate not in predicates:
                raise GateError(
                    "rollback artifact: signed predicate does not bind the exact candidate and retention policy"
                )
        finally:
            if self.cache_root is None:
                artifact.unlink(missing_ok=True)
                artifact.parent.rmdir()

    def verify_deletion_review(
        self,
        review: dict[str, Any],
        bound_files: dict[str, str] | None = None,
        expected_descendant_commit: str | None = None,
    ) -> None:
        parsed = urlsplit(review["reviewUri"])
        match = re.fullmatch(r"/Imagine-That-Ai/BurnBar/pull/([1-9][0-9]*)", parsed.path)
        if parsed.hostname != "github.com" or parsed.port not in {None, 443} or match is None:
            raise GateError("deletion review URI must identify an OpenBurnBar pull request")
        pull_number = match.group(1)

        def api(path: str, label: str, *, paginate: bool = False) -> Any:
            command = ["gh", "api"]
            if paginate:
                command.extend(["--paginate", "--slurp"])
            command.append(path)
            try:
                result = subprocess.run(
                    command,
                    check=False,
                    capture_output=True,
                    text=True,
                    timeout=30,
                )
            except (OSError, subprocess.TimeoutExpired) as error:
                raise GateError(f"{label}: cannot query GitHub review state: {error}") from error
            if result.returncode != 0:
                detail = result.stderr.strip() or result.stdout.strip() or "GitHub API request failed"
                raise GateError(f"{label}: GitHub review query failed: {detail}")
            try:
                return json.loads(result.stdout)
            except json.JSONDecodeError as error:
                raise GateError(f"{label}: GitHub review query returned invalid JSON") from error

        pull = require_object(
            api(f"repos/{self.repository}/pulls/{pull_number}", "deletion review"),
            "deletion review pull request",
        )
        head_object = require_object(pull.get("head"), "deletion review pull request.head")
        head = head_object.get("sha")
        head_repository = require_object(head_object.get("repo"), "deletion review pull request.head.repo").get(
            "full_name"
        )
        base_object = require_object(pull.get("base"), "deletion review pull request.base")
        base_repository = require_object(base_object.get("repo"), "deletion review pull request.base.repo").get(
            "full_name"
        )
        author = require_object(pull.get("user"), "deletion review pull request.user").get("login")
        reviewer = review["reviewer"].removeprefix("@")
        reviewed_commit = review["reviewedCommit"]
        if (
            pull.get("draft") is True
            or pull.get("merged") is not True
            or not isinstance(pull.get("merged_at"), str)
            or head != reviewed_commit
            or head_repository != self.repository
            or base_repository != self.repository
            or base_object.get("ref") != "main"
        ):
            raise GateError(
                "deletion review pull request must be merged, non-draft, same-repository, target main, and match reviewedCommit"
            )
        merge_commit = pull.get("merge_commit_sha")
        if expected_descendant_commit is not None:
            if not isinstance(merge_commit, str) or not COMMIT_RE.fullmatch(merge_commit):
                raise GateError("deletion review pull request must expose its merged commit")
            comparison = self._github_json(
                f"repos/{self.repository}/compare/{merge_commit}...{expected_descendant_commit}",
                "deletion review merged ancestry",
            )
            if comparison.get("status") not in {"ahead", "identical"}:
                raise GateError("deletion review merged commit must be an ancestor of the receipt commit")
        if not isinstance(author, str) or author.casefold() == reviewer.casefold():
            raise GateError("deletion review must be independent from the pull request author")
        review_pages = require_array(
            api(
                f"repos/{self.repository}/pulls/{pull_number}/reviews?per_page=100",
                "deletion reviews",
                paginate=True,
            ),
            "deletion review pages",
        )
        reviews = [
            review
            for page_index, page in enumerate(review_pages)
            for review in require_array(page, f"deletion review pages[{page_index}]")
        ]
        decisive_reviews: list[tuple[datetime, int, str]] = []
        for index, item in enumerate(reviews):
            if not isinstance(item, dict) or item.get("commit_id") != reviewed_commit:
                continue
            user = item.get("user")
            if not isinstance(user, dict) or str(user.get("login", "")).casefold() != reviewer.casefold():
                continue
            state = item.get("state")
            if state not in {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}:
                continue
            submitted_at = parse_rfc3339_utc(item.get("submitted_at"), f"deletion reviews[{index}].submitted_at")
            review_id = item.get("id")
            if not isinstance(review_id, int) or isinstance(review_id, bool) or review_id < 1:
                raise GateError(f"deletion reviews[{index}].id: expected positive integer")
            decisive_reviews.append((submitted_at, review_id, state))
        if not decisive_reviews or max(decisive_reviews)[2] != "APPROVED":
            raise GateError(
                "deletion review requires the declared reviewer's latest decisive review on reviewedCommit to be APPROVED"
            )
        for path, expected_digest in sorted((bound_files or {}).items()):
            encoded_path = quote(path, safe="/")
            content = require_object(
                api(
                    f"repos/{self.repository}/contents/{encoded_path}?ref={reviewed_commit}",
                    f"reviewed deletion file {path}",
                ),
                f"reviewed deletion file {path}",
            )
            encoded = content.get("content")
            if content.get("encoding") != "base64" or not isinstance(encoded, str):
                raise GateError(f"reviewed deletion file {path}: GitHub did not return base64 file contents")
            try:
                contents = base64.b64decode("".join(encoded.split()), validate=True)
            except (ValueError, binascii.Error) as error:
                raise GateError(f"reviewed deletion file {path}: invalid GitHub content encoding") from error
            if hashlib.sha256(contents).hexdigest() != expected_digest:
                raise GateError(f"reviewed deletion file {path}: digest does not match approved PR head")

    def verify_deletion_head(
        self,
        *,
        pull_number: int,
        deletion_head: str,
        reviewer: str,
    ) -> None:
        pull = self._github_json(
            f"repos/{self.repository}/pulls/{positive_integer(pull_number, 'deletion pull request number')}",
            "actual deletion pull request",
        )
        head = require_object(pull.get("head"), "actual deletion pull request.head")
        base = require_object(pull.get("base"), "actual deletion pull request.base")
        author = require_object(pull.get("user"), "actual deletion pull request.user").get("login")
        normalized = reviewer.removeprefix("@").casefold()
        if (
            pull.get("draft") is True
            or pull.get("merged") is True
            or pull.get("state") != "open"
            or head.get("sha") != deletion_head
            or require_object(head.get("repo"), "actual deletion pull request.head.repo").get("full_name")
            != self.repository
            or base.get("ref") != "main"
            or require_object(base.get("repo"), "actual deletion pull request.base.repo").get("full_name")
            != self.repository
            or not isinstance(author, str)
            or author.casefold() == normalized
        ):
            raise GateError(
                "actual deletion approval must be on the current non-draft same-repository PR head targeting official main"
            )
        reviews = self._github_list(
            f"repos/{self.repository}/pulls/{pull_number}/reviews?per_page=100",
            "actual deletion reviews",
        )
        decisive: list[tuple[datetime, int, str]] = []
        for index, item in enumerate(reviews):
            if not isinstance(item, dict) or item.get("commit_id") != deletion_head:
                continue
            user = item.get("user")
            if not isinstance(user, dict) or str(user.get("login", "")).casefold() != normalized:
                continue
            if item.get("state") not in {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}:
                continue
            decisive.append(
                (
                    parse_rfc3339_utc(
                        item.get("submitted_at"),
                        f"actual deletion reviews[{index}].submitted_at",
                    ),
                    positive_integer(item.get("id"), f"actual deletion reviews[{index}].id"),
                    item["state"],
                )
            )
        if not decisive or max(decisive)[2] != "APPROVED":
            raise GateError("qualified reviewer must approve the exact current deletion PR head")


@dataclass(frozen=True)
class Receipt:
    path: str
    transition: str
    generation: int
    approved_at: datetime
    commit: str
    digest: str
    evidence: tuple[str, ...]
    payload: dict[str, Any]
    approved_by: str = ""


def validate_receipt(
    repo_root: Path,
    receipt_path: str,
    row_id: str,
    generation: int,
    transition: str,
    seen_receipts: set[str],
) -> Receipt:
    expected_path = f"{RECEIPT_ROOT}/{row_id}/{generation}/{transition}.json"
    if receipt_path != expected_path:
        raise GateError(f"receipt for {row_id}/{transition} must use exact path {expected_path}")
    if receipt_path in seen_receipts:
        raise GateError(f"receipt path is referenced more than once: {receipt_path}")
    seen_receipts.add(receipt_path)
    path = secure_path(repo_root, receipt_path, f"receipt {receipt_path}", must_exist=True)
    if not path.is_file():
        raise GateError(f"receipt {receipt_path}: expected regular file")
    receipt = require_object(load_json(path, f"receipt {receipt_path}"), f"receipt {receipt_path}")
    exact_keys(
        receipt,
        {
            "schemaVersion",
            "rowId",
            "authorityGeneration",
            "transition",
            "status",
            "evidence",
            "approvedBy",
            "approvedAt",
            "commit",
            "promotionAttestation",
            "activationAnnulment",
            "release",
            "rollback",
            "deletionReview",
        },
        {
            "schemaVersion",
            "rowId",
            "authorityGeneration",
            "transition",
            "status",
            "evidence",
            "approvedBy",
            "approvedAt",
            "commit",
        },
        f"receipt {receipt_path}",
    )
    if receipt["schemaVersion"] != 2 or isinstance(receipt["schemaVersion"], bool):
        raise GateError(f"receipt {receipt_path}: schemaVersion must be 2")
    if receipt["rowId"] != row_id:
        raise GateError(f"receipt {receipt_path}: rowId must be {row_id}")
    if receipt["authorityGeneration"] != generation or isinstance(receipt["authorityGeneration"], bool):
        raise GateError(f"receipt {receipt_path}: authorityGeneration must be {generation}")
    if receipt["transition"] != transition:
        raise GateError(f"receipt {receipt_path}: transition must be {transition}")
    if receipt["status"] != "active":
        raise GateError(f"receipt {receipt_path}: status must be active")
    evidence = require_array(receipt["evidence"], f"receipt {receipt_path}.evidence")
    if not evidence:
        raise GateError(f"receipt {receipt_path}: evidence must be a non-empty unique array")
    for index, uri in enumerate(evidence):
        validate_https_uri(uri, f"receipt {receipt_path}.evidence[{index}]")
    if len(evidence) != len(set(evidence)):
        raise GateError(f"receipt {receipt_path}: evidence must be a non-empty unique array")
    approved_by = receipt["approvedBy"]
    if not isinstance(approved_by, str) or not RECEIPT_ACTOR_RE.fullmatch(approved_by):
        raise GateError(f"receipt {receipt_path}: approvedBy must be a GitHub handle")
    approved_at = parse_rfc3339_utc(receipt["approvedAt"], f"receipt {receipt_path}.approvedAt")
    if approved_at > datetime.now(UTC):
        raise GateError(f"receipt {receipt_path}: approvedAt cannot be in the future")
    commit = require_commit(repo_root, receipt["commit"], f"receipt {receipt_path}")
    transition_fields = {
        "promotion": "promotionAttestation",
        "annulment": "activationAnnulment",
        "stable_release": "release",
        "rollback": "rollback",
        "deletion_review": "deletionReview",
    }
    expected_field = transition_fields[transition]
    supplied_fields = {field for field in transition_fields.values() if field in receipt}
    if supplied_fields != {expected_field}:
        raise GateError(f"receipt {receipt_path}: transition payload must be exactly {expected_field}")
    return Receipt(
        path=receipt_path,
        transition=transition,
        generation=generation,
        approved_at=approved_at,
        commit=commit,
        digest=sha256_path(path),
        evidence=tuple(evidence),
        payload=require_object(receipt[expected_field], f"receipt {receipt_path}.{expected_field}"),
        approved_by=approved_by,
    )


@dataclass(frozen=True)
class Target:
    kind: str
    role: str
    root: str
    path: str
    value: str | None

    @property
    def identity(self) -> tuple[str, str, str]:
        return (self.kind, self.path, self.value or "")


@dataclass(frozen=True)
class Row:
    state: str
    generation: int
    receipts: dict[str, Receipt]
    targets: list[Target]


def validate_atomic_deletion_groups(rows: dict[str, Row]) -> None:
    deleted = {row_id for row_id, row in rows.items() if row.state == "legacy_deleted"}
    for group in ATOMIC_DELETION_GROUPS:
        selected = deleted & group
        if selected and selected != group:
            raise GateError("coupled legacy rows must enter legacy_deleted atomically: " + ", ".join(sorted(group)))


def verify_post_deletion_primitives(repo_root: Path, rows: dict[str, Row]) -> None:
    deleted = {row_id for row_id, row in rows.items() if row.state == "legacy_deleted"}
    for label, required_rows, relative, pattern in POST_DELETION_PRIMITIVE_RULES:
        if not required_rows.issubset(deleted):
            continue
        path = secure_path(repo_root, relative, label, must_exist=False)
        if not path.exists():
            continue
        sources = (
            [path]
            if path.is_file()
            else [
                child
                for child in path.rglob("*")
                if child.is_file() and not child.is_symlink() and child.suffix in {".cs", ".kt", ".swift", ".ts"}
            ]
        )
        for source in sources:
            contents = source.read_text(encoding="utf-8", errors="replace")
            match = pattern.search(contents)
            if match is not None:
                line = contents.count("\n", 0, match.start()) + 1
                raise GateError(
                    f"{label}: forbidden hand-ported primitive remains after legacy deletion "
                    f"at {source.relative_to(repo_root)}:{line}"
                )


def parse_target(raw: Any, label: str, roots: dict[str, str]) -> Target:
    value = require_object(raw, label)
    kind = value.get("kind")
    if not isinstance(kind, str) or kind not in TARGET_KINDS:
        raise GateError(f"{label}: unknown target kind: {kind!r}")
    required = {"kind", "role", "root", "path"}
    allowed = set(required)
    if kind == "source_symbol":
        required.add("symbol")
        allowed.add("symbol")
    elif kind == "mode_literal":
        required.add("literal")
        allowed.add("literal")
    exact_keys(value, allowed, required, label)
    role = value["role"]
    if role not in {"legacy_implementation", "rollback_control"}:
        raise GateError(f"{label}.role: unknown target role")
    root_id = value["root"]
    if not isinstance(root_id, str) or root_id not in roots:
        raise GateError(f"{label}: unknown source root: {root_id!r}")
    path = repository_path(value["path"], f"{label}.path")
    root_path = roots[root_id]
    if path != root_path and not path.startswith(root_path + "/"):
        raise GateError(f"{label}: target path is outside declared source root {root_id}")
    target_value: str | None = None
    if kind == "source_symbol":
        target_value = value["symbol"]
        if not isinstance(target_value, str) or not SYMBOL_RE.fullmatch(target_value):
            raise GateError(f"{label}.symbol: expected exact source identifier")
    elif kind == "mode_literal":
        target_value = value["literal"]
        if not isinstance(target_value, str) or not MODE_LITERAL_RE.fullmatch(target_value):
            raise GateError(f"{label}.literal: expected exact uppercase mode identifier")
    return Target(kind=kind, role=role, root=root_id, path=path, value=target_value)


def target_present(repo_root: Path, target: Target, label: str) -> bool:
    path = secure_path(repo_root, target.path, label, must_exist=False)
    if not path.exists():
        return False
    if target.kind == "path":
        mode = path.lstat().st_mode
        if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
            raise GateError(f"{label}: path target must be a regular file or directory")
        return True
    if not path.is_file():
        raise GateError(f"{label}: source target must be a regular file")
    try:
        source = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise GateError(f"{label}: cannot read UTF-8 source: {error}") from error
    if target.kind == "mode_literal":
        return target.value in source
    assert target.value is not None
    return re.search(rf"(?<![A-Za-z0-9_]){re.escape(target.value)}(?![A-Za-z0-9_])", source) is not None


def required_receipts(state: str) -> set[str]:
    if state == "rollout":
        return set()
    if state == "promotion_approved":
        return {"promotion"}
    if state == "activation_annulled":
        return {"promotion", "activationAnnulment"}
    if state == "rust_authoritative_with_rollback":
        return {"promotion", "stableRelease"}
    if state == "rollback_active":
        return {"promotion", "stableRelease", "rollback"}
    return {"promotion", "stableRelease", "deletionReview"}


def allowed_receipts(state: str) -> set[str]:
    required = required_receipts(state)
    if state == "rollback_active":
        return required | {"deletionReview"}
    return required


def profile_domain_for_row(row_id: str) -> str:
    for domain, row_ids in PROFILE_DOMAIN_ROWS.items():
        if row_id in row_ids:
            return domain
    raise GateError(f"row has no public profile domain: {row_id}")


def release_consumers_for_row(row_id: str) -> set[str]:
    profile_domain = profile_domain_for_row(row_id)
    return set().union(*(ROW_RELEASE_CONSUMERS[mapped] for mapped in PROFILE_DOMAIN_ROWS[profile_domain]))


def validate_https_uri(value: Any, label: str) -> str:
    if not isinstance(value, str):
        raise GateError(f"{label}: expected HTTPS URI")
    try:
        parsed = urlsplit(value)
        _ = parsed.port
        unsafe = (
            parsed.scheme != "https"
            or not parsed.netloc
            or parsed.hostname is None
            or parsed.username is not None
            or parsed.password is not None
            or bool(parsed.query)
            or bool(parsed.fragment)
        )
    except ValueError:
        unsafe = True
    if unsafe:
        raise GateError(f"{label}: expected credential-free HTTPS URI without query or fragment")
    return value


def validate_release_uri(value: Any, label: str) -> str:
    uri = validate_https_uri(value, label)
    parsed = urlsplit(uri)
    prefix = "/Imagine-That-Ai/BurnBar/releases/download/"
    if parsed.hostname != "github.com" or parsed.port not in {None, 443} or not parsed.path.startswith(prefix):
        raise GateError(f"{label}: expected a canonical OpenBurnBar GitHub Release asset URI")
    suffix = parsed.path[len(prefix) :]
    if len(suffix.split("/")) != 2 or any(not part for part in suffix.split("/")):
        raise GateError(f"{label}: release asset URI must contain one tag and one asset name")
    return uri


def validate_release_download_redirect(value: str) -> None:
    parsed = urlsplit(value)
    hostname = parsed.hostname or ""
    trusted = hostname == "github.com" or hostname.endswith(".githubusercontent.com")
    if parsed.scheme != "https" or not trusted or parsed.username is not None or parsed.password is not None:
        raise GateError("release artifact redirected outside trusted GitHub download infrastructure")


def expected_release_asset_name(consumer: str, version: str) -> str:
    names = {
        "apple": f"OpenBurnBar-{version}-macOS.dmg",
        "ios": f"OpenBurnBar-{version}-iOS.xcarchive.zip",
        "linux": f"OpenBurnBar-{version}-linux-release.tar.zst",
        "android": f"OpenBurnBar-{version}-Android.aab",
        "windows": f"OpenBurnBar-{version}-windows-release.zip",
        "console": f"OpenBurnBar-{version}-console-deployment.json",
        "functions": f"OpenBurnBar-{version}-functions-deployment.json",
    }
    return names[consumer]


def validate_ios_app_store_receipt(
    value: Any,
    item: dict[str, Any],
    archive_sha256: str,
) -> None:
    receipt = require_object(value, "signed iOS App Store Connect receipt")
    fields = {
        "schemaVersion",
        "status",
        "processedStatus",
        "deliveryId",
        "archiveSha256",
        "ipaSha256",
        "uploadResponseSha256",
        "statusResponseSha256",
        "release",
        "candidate",
        "activation",
        "loadedRustIdentity",
    }
    exact_keys(receipt, fields, fields, "signed iOS App Store Connect receipt")
    release = require_object(receipt["release"], "signed iOS App Store Connect receipt.release")
    loaded = require_object(receipt["loadedRustIdentity"], "signed iOS loaded Rust identity")
    loaded_fields = {
        "schemaVersion",
        "verificationKind",
        "bundleId",
        "version",
        "buildNumber",
        "executable",
        "architectures",
        "executableSha256",
        "identitySectionSha256",
        "identitySymbols",
        "candidate",
        "observed",
    }
    exact_keys(loaded, loaded_fields, loaded_fields, "signed iOS loaded Rust identity")
    observed = require_object(loaded.get("observed"), "signed iOS loaded Rust identity.observed")
    expected_observed = {
        "candidateCommit": item["candidate"]["candidateCommit"],
        "coreVersion": item["candidate"]["coreVersion"],
        "abiVersion": item["candidate"]["abiVersion"],
        "sourceSha256": item["candidate"]["sourceSha256"],
    }
    expected_symbols = sorted(
        {
            "OPENBURNBAR_DOMAIN_CORE_IDENTITY_V1",
            "uniffi_openburnbar_domain_ffi_fn_func_domain_core_abi_version",
            "uniffi_openburnbar_domain_ffi_fn_func_domain_core_candidate_commit",
            "uniffi_openburnbar_domain_ffi_fn_func_domain_core_source_fingerprint",
            "uniffi_openburnbar_domain_ffi_fn_func_domain_core_version",
        }
    )
    invalid = (
        receipt["schemaVersion"] != 1
        or receipt["status"] != "processed"
        or receipt["processedStatus"]
        not in {"complete", "completed", "processed", "processing complete", "success", "succeeded"}
        or not isinstance(receipt["deliveryId"], str)
        or not receipt["deliveryId"]
        or receipt["archiveSha256"] != archive_sha256
        or require_digest(receipt["ipaSha256"], "signed iOS IPA SHA-256") != receipt["ipaSha256"]
        or require_digest(receipt["uploadResponseSha256"], "signed iOS upload response SHA-256")
        != receipt["uploadResponseSha256"]
        or require_digest(receipt["statusResponseSha256"], "signed iOS status response SHA-256")
        != receipt["statusResponseSha256"]
        or release != {"version": item["version"], "tag": item["tag"], "commit": item["commit"]}
        or receipt["candidate"] != item["candidate"]
        or receipt["activation"] != item["activation"]
        or loaded.get("schemaVersion") != 1
        or loaded.get("verificationKind") != "ios-loaded-rust-slice-identity"
        or not isinstance(loaded.get("bundleId"), str)
        or not loaded.get("bundleId")
        or loaded.get("version") != item["version"]
        or not isinstance(loaded.get("buildNumber"), str)
        or not loaded.get("buildNumber")
        or loaded.get("executable") != "OpenBurnBarMobile"
        or loaded.get("architectures") != ["arm64"]
        or loaded.get("identitySymbols") != expected_symbols
        or loaded.get("candidate") != item["candidate"]
        or observed != expected_observed
        or require_digest(loaded.get("executableSha256"), "signed iOS executable SHA-256")
        != loaded.get("executableSha256")
        or require_digest(loaded.get("identitySectionSha256"), "signed iOS identity-section SHA-256")
        != loaded.get("identitySectionSha256")
    )
    if invalid:
        raise GateError(
            "signed iOS App Store Connect receipt does not bind the exact processed IPA and loaded Rust slice"
        )


def ios_app_store_receipt_matches(
    predicate: dict[str, Any],
    item: dict[str, Any],
    archive_sha256: str,
) -> bool:
    try:
        validate_ios_app_store_receipt(
            predicate.get("appStoreConnectReceipt"),
            item,
            archive_sha256,
        )
    except GateError:
        return False
    return True


def validate_superseded_authority(
    repo_root: Path,
    row_id: str,
    generation: int,
    value: Any,
    approved_at: datetime,
    candidate: str,
) -> datetime:
    link = require_object(value, "promotionAttestation.supersedes")
    exact_keys(
        link,
        {"transition", "path", "sha256"},
        {"transition", "path", "sha256"},
        "promotionAttestation.supersedes",
    )
    transition = link["transition"]
    names = {
        "annulment": "annulment.json",
        "rollback": "rollback.json",
        "stable_release": "stable_release.json",
    }
    if transition not in names:
        raise GateError("promotionAttestation.supersedes.transition must be annulment, rollback, or stable_release")
    expected_path = f"{RECEIPT_ROOT}/{row_id}/{generation - 1}/{names[transition]}"
    path_value = repository_path(link["path"], "promotionAttestation.supersedes.path")
    if path_value != expected_path:
        raise GateError(f"promotionAttestation.supersedes.path must be {expected_path}")
    path = secure_path(
        repo_root,
        path_value,
        "promotionAttestation.supersedes",
        must_exist=True,
    )
    expected_digest = require_digest(link["sha256"], "promotionAttestation.supersedes.sha256")
    if sha256_path(path) != expected_digest:
        raise GateError("promotionAttestation.supersedes.sha256 does not match the previous authority receipt")
    previous = require_object(load_json(path, "previous authority receipt"), "previous authority receipt")
    if (
        previous.get("schemaVersion") != 2
        or previous.get("rowId") != row_id
        or previous.get("authorityGeneration") != generation - 1
        or previous.get("transition") != transition
        or previous.get("status") != "active"
    ):
        raise GateError("promotionAttestation.supersedes does not identify the previous active authority")
    previous_approved = parse_rfc3339_utc(previous.get("approvedAt"), "previous authority receipt.approvedAt")
    if previous_approved >= approved_at:
        raise GateError("promotion approval must be later than the superseded authority")
    if transition == "annulment":
        annulment_payload = require_object(
            previous.get("activationAnnulment"),
            "previous annulment receipt.activationAnnulment",
        )
        annulled_candidate = require_commit(
            repo_root,
            require_object(
                annulment_payload.get("candidate"),
                "previous annulment receipt.activationAnnulment.candidate",
            ).get("candidateCommit"),
            "previous annulment receipt annulled candidate",
        )
        advanced_main = require_commit(
            repo_root,
            annulment_payload.get("advancedMainCommit"),
            "previous annulment receipt.activationAnnulment.advancedMainCommit",
        )
        if candidate == annulled_candidate:
            raise GateError("promotion after annulment must attest a fresh replacement candidate")
        require_ancestor(
            repo_root,
            advanced_main,
            candidate,
            "promotion after annulment replacement candidate",
        )
    if transition == "rollback":
        activated_at = parse_rfc3339_utc(
            require_object(previous.get("rollback"), "previous rollback receipt.rollback").get("activatedAt"),
            "previous rollback receipt.rollback.activatedAt",
        )
        if activated_at > previous_approved:
            raise GateError("previous rollback activation cannot follow rollback approval")
        return activated_at
    return previous_approved


def positive_integer(value: Any, label: str) -> int:
    if not isinstance(value, int) or isinstance(value, bool) or value < 1:
        raise GateError(f"{label}: expected positive integer")
    return value


def candidate_identity_at_commit(repo_root: Path, commit: str) -> dict[str, Any]:
    relative = "crates/openburnbar-domain-core/union-abi-manifest.json"
    manifest = require_object(
        load_json_bytes(
            git_file(repo_root, commit, relative, "candidate union ABI manifest"),
            "candidate union ABI manifest",
        ),
        "candidate union ABI manifest",
    )
    core_version = manifest.get("coreVersion")
    abi_version = manifest.get("abiVersion")
    if not isinstance(core_version, str) or not VERSION_RE.fullmatch(core_version):
        raise GateError("candidate union ABI manifest.coreVersion is invalid")
    positive_integer(abi_version, "candidate union ABI manifest.abiVersion")
    source_sha256 = require_digest(manifest.get("sourceSha256"), "candidate union ABI manifest.sourceSha256")
    if core_version != core_version_at_commit(repo_root, commit):
        raise GateError("candidate union ABI manifest version does not match Cargo manifest")
    return {
        "candidateCommit": commit,
        "coreVersion": core_version,
        "abiVersion": abi_version,
        "sourceSha256": source_sha256,
    }


def file_sha256_at_commit(repo_root: Path, commit: str, relative: str, label: str) -> str:
    return hashlib.sha256(git_file(repo_root, commit, relative, label)).hexdigest()


def validate_github_provenance_bundle(contents: bytes, label: str) -> None:
    value = require_object(load_json_bytes(contents, label), label)
    if "verificationKind" in value or "promotionAuthorized" in value:
        raise GateError(f"{label}: protected-verification output is not provenance authority")
    media_type = value.get("mediaType")
    if (
        not isinstance(media_type, str)
        or not media_type.startswith("application/vnd.dev.sigstore.bundle")
        or not isinstance(value.get("verificationMaterial"), dict)
        or not isinstance(value.get("dsseEnvelope"), dict)
    ):
        raise GateError(f"{label}: expected an official Sigstore/GitHub provenance bundle")


def validate_unsigned_candidate_bundle(
    bundle: Any,
    expected_identity: dict[str, Any],
    source_run_id: int,
    source_run_attempt: int,
    label: str,
) -> datetime:
    value = require_object(bundle, label)
    required = {
        "schemaVersion",
        "bundleKind",
        "status",
        "proofComplete",
        "eligibleForAttestation",
        "promotionAuthorized",
        "trust",
        "generatedAt",
        "candidate",
        "policySha256",
        "workflow",
        "suites",
        "coverage",
        "artifacts",
        "benchmarks",
        "rollback",
    }
    exact_keys(value, required, required, label)
    if value["schemaVersion"] != 1 or isinstance(value["schemaVersion"], bool):
        raise GateError(f"{label}: schemaVersion must be 1")
    if (
        value["bundleKind"] != "unsigned-domain-core-candidate"
        or value["status"] != "eligible_for_attestation"
        or value["proofComplete"] is not True
        or value["eligibleForAttestation"] is not True
        or value["promotionAuthorized"] is not False
    ):
        raise GateError(f"{label}: unsigned bundle is not eligible for protected attestation")
    candidate = require_object(value["candidate"], f"{label}.candidate")
    exact_keys(candidate, set(expected_identity), set(expected_identity), f"{label}.candidate")
    if candidate != expected_identity:
        raise GateError(f"{label}: candidate identity does not match the exact candidate checkout")
    trust = require_object(value["trust"], f"{label}.trust")
    trust_fields = {
        "authority",
        "attestationRequired",
        "requiredSigner",
        "verificationSteps",
    }
    exact_keys(trust, trust_fields, trust_fields, f"{label}.trust")
    if (
        trust["authority"] != "none"
        or trust["attestationRequired"] is not True
        or trust["requiredSigner"] != PROMOTION_SIGNER_JOB
    ):
        raise GateError(f"{label}: unsigned bundle must disclaim authority and require the protected signer")
    workflow = require_object(value["workflow"], f"{label}.workflow")
    if (
        workflow.get("repository") != SignedEvidenceVerifier.repository
        or workflow.get("workflowPath") != SOURCE_WORKFLOW
        or workflow.get("event") != "push"
        or workflow.get("ref") != "refs/heads/main"
        or workflow.get("headSha") != expected_identity["candidateCommit"]
        or workflow.get("runId") != source_run_id
        or workflow.get("runAttempt") != source_run_attempt
    ):
        raise GateError(f"{label}: workflow does not bind the exact successful main push run")
    return parse_rfc3339_utc(value["generatedAt"], f"{label}.generatedAt")


def validate_promotion_attestation(
    repo_root: Path,
    row_id: str,
    generation: int,
    promotion: Receipt,
    evidence_verifier: SignedEvidenceVerifier | Any | None,
) -> tuple[str, str, str]:
    scope = PROMOTION_SCOPES[profile_domain_for_row(row_id)]
    pointer = promotion.payload
    pointer_fields = {"path", "sha256", "supersedes"}
    exact_keys(pointer, pointer_fields, pointer_fields, f"row {row_id} promotionAttestation")
    expected_path = f"{ATTESTATION_ROOT}/{scope}/{generation}.json"
    path_value = repository_path(pointer["path"], f"row {row_id} promotionAttestation.path")
    if path_value != expected_path:
        raise GateError(f"row {row_id}: promotion attestation must use exact path {expected_path}")
    path = secure_path(repo_root, path_value, f"row {row_id} promotion attestation", must_exist=True)
    if not path.is_file() or require_digest(
        pointer["sha256"], f"row {row_id} promotionAttestation.sha256"
    ) != sha256_path(path):
        raise GateError(f"row {row_id}: promotion attestation digest does not match committed bytes")
    attestation = require_object(
        load_json(path, f"row {row_id} promotion attestation"),
        f"row {row_id} promotion attestation",
    )
    fields = {
        "schemaVersion",
        "authorityScope",
        "authorityGeneration",
        "candidate",
        "unsignedBundle",
        "provenance",
        "status",
        "generatedAt",
        "evidenceUri",
    }
    exact_keys(attestation, fields, fields, f"row {row_id} promotion attestation")
    if attestation["schemaVersion"] != 2 or isinstance(attestation["schemaVersion"], bool):
        raise GateError(f"row {row_id}: promotion attestation schemaVersion must be 2")
    if attestation["authorityScope"] != scope or attestation["authorityGeneration"] != generation:
        raise GateError(f"row {row_id}: promotion attestation scope or generation is incorrect")
    if attestation["status"] != "attested":
        raise GateError(f"row {row_id}: deterministic promotion status must be attested")
    evidence_uri = validate_https_uri(attestation["evidenceUri"], f"row {row_id} promotion attestation.evidenceUri")
    parsed_evidence_uri = urlsplit(evidence_uri)
    if (
        parsed_evidence_uri.hostname != "github.com"
        or re.fullmatch(
            r"/Imagine-That-Ai/BurnBar/attestations/[1-9][0-9]*",
            parsed_evidence_uri.path,
        )
        is None
    ):
        raise GateError(f"row {row_id}: promotion evidence must be an official OpenBurnBar GitHub attestation")
    if evidence_uri not in promotion.evidence:
        raise GateError(f"row {row_id}: official attestation URI must be listed in receipt evidence")

    candidate_object = require_object(attestation["candidate"], f"row {row_id} promotion candidate")
    identity_fields = {"candidateCommit", "coreVersion", "abiVersion", "sourceSha256"}
    exact_keys(
        candidate_object,
        identity_fields,
        identity_fields,
        f"row {row_id} promotion candidate",
    )
    candidate = require_commit(
        repo_root,
        candidate_object["candidateCommit"],
        f"row {row_id} promotion candidate",
    )
    if candidate != promotion.commit:
        raise GateError(f"row {row_id}: promotion receipt commit must equal the exact attested candidate")
    expected_identity = candidate_identity_at_commit(repo_root, candidate)
    if candidate_object != expected_identity:
        raise GateError(f"row {row_id}: promotion candidate tuple does not match committed Rust identity")

    unsigned = require_object(attestation["unsignedBundle"], f"row {row_id} promotion unsignedBundle")
    unsigned_fields = {"path", "sha256", "sourceRunId", "sourceRunAttempt"}
    exact_keys(
        unsigned,
        unsigned_fields,
        unsigned_fields,
        f"row {row_id} promotion unsignedBundle",
    )
    source_run_id = positive_integer(unsigned["sourceRunId"], f"row {row_id} promotion unsignedBundle.sourceRunId")
    source_run_attempt = positive_integer(
        unsigned["sourceRunAttempt"],
        f"row {row_id} promotion unsignedBundle.sourceRunAttempt",
    )
    expected_bundle_path = f"{PROMOTION_BUNDLE_ROOT}/{scope}/{generation}.json"
    bundle_path_value = repository_path(unsigned["path"], f"row {row_id} promotion unsignedBundle.path")
    if bundle_path_value != expected_bundle_path:
        raise GateError(f"row {row_id}: unsigned candidate bundle must use exact path {expected_bundle_path}")
    bundle_path = secure_path(
        repo_root,
        bundle_path_value,
        f"row {row_id} unsigned candidate bundle",
        must_exist=True,
    )
    bundle_digest = require_digest(unsigned["sha256"], f"row {row_id} promotion unsignedBundle.sha256")
    if not bundle_path.is_file() or sha256_path(bundle_path) != bundle_digest:
        raise GateError(f"row {row_id}: unsigned candidate bundle digest does not match committed bytes")
    bundle_generated_at = validate_unsigned_candidate_bundle(
        load_json(bundle_path, f"row {row_id} unsigned candidate bundle"),
        expected_identity,
        source_run_id,
        source_run_attempt,
        f"row {row_id} unsigned candidate bundle",
    )

    provenance = require_object(attestation["provenance"], f"row {row_id} promotion provenance")
    provenance_fields = {
        "path",
        "sha256",
        "signerWorkflow",
        "signerRunId",
        "signerRunAttempt",
        "trustedMainCommit",
        "policySha256",
        "evaluatorSha256",
    }
    exact_keys(
        provenance,
        provenance_fields,
        provenance_fields,
        f"row {row_id} promotion provenance",
    )
    if provenance["signerWorkflow"] != PROMOTION_SIGNER_WORKFLOW:
        raise GateError(f"row {row_id}: promotion provenance must name the protected signer workflow")
    signer_run_id = positive_integer(provenance["signerRunId"], f"row {row_id} promotion provenance.signerRunId")
    signer_run_attempt = positive_integer(
        provenance["signerRunAttempt"],
        f"row {row_id} promotion provenance.signerRunAttempt",
    )
    trusted_main = require_commit(
        repo_root,
        provenance["trustedMainCommit"],
        f"row {row_id} trusted-main evaluator",
    )
    require_ancestor(repo_root, candidate, trusted_main, f"row {row_id} trusted-main evaluator")
    expected_policy_digest = file_sha256_at_commit(
        repo_root, trusted_main, PROMOTION_POLICY_PATH, "trusted-main promotion policy"
    )
    expected_evaluator_digest = file_sha256_at_commit(
        repo_root,
        trusted_main,
        PROMOTION_EVALUATOR_PATH,
        "trusted-main promotion evaluator",
    )
    if (
        provenance["policySha256"] != expected_policy_digest
        or provenance["evaluatorSha256"] != expected_evaluator_digest
    ):
        raise GateError(f"row {row_id}: provenance does not bind the trusted-main policy and evaluator")
    expected_provenance_path = f"{PROMOTION_PROVENANCE_ROOT}/{scope}/{generation}.json"
    provenance_path_value = repository_path(provenance["path"], f"row {row_id} promotion provenance.path")
    if provenance_path_value != expected_provenance_path:
        raise GateError(f"row {row_id}: provenance bundle must use exact path {expected_provenance_path}")
    provenance_path = secure_path(
        repo_root,
        provenance_path_value,
        f"row {row_id} promotion provenance",
        must_exist=True,
    )
    provenance_digest = require_digest(provenance["sha256"], f"row {row_id} promotion provenance.sha256")
    if not provenance_path.is_file() or sha256_path(provenance_path) != provenance_digest:
        raise GateError(f"row {row_id}: provenance bundle digest does not match committed bytes")
    validate_github_provenance_bundle(provenance_path.read_bytes(), f"row {row_id} promotion provenance")
    if evidence_verifier is None:
        raise GateError(f"row {row_id}: official GitHub provenance verification is required")
    evidence_verifier.verify_candidate_bundle(
        bundle_path,
        provenance_path,
        trusted_main_commit=trusted_main,
        source_run_id=source_run_id,
        source_run_attempt=source_run_attempt,
        signer_run_id=signer_run_id,
        signer_run_attempt=signer_run_attempt,
        candidate_commit=candidate,
    )
    generated_at = parse_rfc3339_utc(attestation["generatedAt"], f"row {row_id} promotion attestation.generatedAt")
    if bundle_generated_at > generated_at or generated_at > promotion.approved_at:
        raise GateError(f"row {row_id}: bundle, attestation, and approval timestamps are inconsistent")
    if generation == 1:
        if pointer["supersedes"] is not None:
            raise GateError(f"row {row_id}: first authority generation cannot supersede prior authority")
    else:
        validate_superseded_authority(
            repo_root,
            row_id,
            generation,
            pointer["supersedes"],
            promotion.approved_at,
            candidate,
        )
    return candidate, bundle_digest, expected_identity["coreVersion"]


def validate_deletion_review_receipt(
    repo_root: Path,
    row_id: str,
    generation: int,
    deletion: Receipt,
    stable: Receipt,
    targets: list[Target],
    deletion_reviewers: dict[str, set[str]] | None,
    evidence_verifier: SignedEvidenceVerifier | Any | None,
) -> None:
    """Validate a deletionReview receipt's authority, plan digest, and ancestry.

    Pure shared verifier extracted from validate_receipt_chain so that the
    post-deletion completion gate can reuse the exact same fail-closed checks
    without duplicating a weaker parser.  Enforces:

    * deletionReview payload binds the current stable receipt digest
    * review URI, reviewer handle, review class, and outcome are canonical
    * reviewer is qualified by the trusted base catalog
    * approved deletion plan binds the exact row, generation, stable receipt,
      reviewer, review class, and legacy target inventory digest
    * reviewedCommit is a valid commit and an ancestor of the deletion receipt commit
    * live independent deletion review verification is performed (fail-closed)
    """
    payload = deletion.payload
    fields = {
        "stableReceiptSha256",
        "reviewUri",
        "reviewedCommit",
        "reviewer",
        "reviewClass",
        "outcome",
        "planPath",
        "planSha256",
    }
    exact_keys(payload, fields, fields, f"row {row_id} deletionReview")
    require_ancestor(
        repo_root,
        stable.commit,
        deletion.commit,
        f"row {row_id} deletionReview.commit",
    )
    if payload["stableReceiptSha256"] != stable.digest:
        raise GateError(f"row {row_id}: deletion review does not bind the current stable receipt")
    validate_https_uri(payload["reviewUri"], f"row {row_id} deletionReview.reviewUri")
    if not isinstance(payload["reviewer"], str) or not RECEIPT_ACTOR_RE.fullmatch(payload["reviewer"]):
        raise GateError(f"row {row_id}: deletion reviewer must be a GitHub handle")
    expected_review_class = "security_crypto" if row_id in SECURITY_REVIEW_ROWS else "domain_owner"
    if payload["reviewClass"] != expected_review_class or payload["outcome"] != "approved":
        raise GateError(f"row {row_id}: deletion review class or outcome is invalid")
    qualified = (deletion_reviewers or {}).get(expected_review_class, set())
    if payload["reviewer"].casefold() not in qualified:
        raise GateError(f"row {row_id}: {expected_review_class} reviewer is not qualified by the trusted base catalog")
    expected_plan_path = f"{DELETION_PLAN_ROOT}/{row_id}/{generation}.json"
    plan_path_value = repository_path(payload["planPath"], f"row {row_id} deletionReview.planPath")
    if plan_path_value != expected_plan_path:
        raise GateError(f"row {row_id}: deletion plan must use exact path {expected_plan_path}")
    plan_path = secure_path(repo_root, plan_path_value, f"row {row_id} deletion plan", must_exist=True)
    plan_digest = require_digest(payload["planSha256"], f"row {row_id} deletionReview.planSha256")
    if not plan_path.is_file() or sha256_path(plan_path) != plan_digest:
        raise GateError(f"row {row_id}: deletion plan digest does not match committed bytes")
    reviewed_commit = payload["reviewedCommit"]
    reviewed_commit = require_commit(repo_root, reviewed_commit, f"row {row_id} deletion reviewedCommit")
    require_ancestor(
        repo_root,
        reviewed_commit,
        deletion.commit,
        f"row {row_id} deletion reviewedCommit",
    )
    plan = require_object(
        load_json(plan_path, f"row {row_id} deletion plan"),
        f"row {row_id} deletion plan",
    )
    plan_fields = {
        "schemaVersion",
        "rowId",
        "authorityGeneration",
        "stableReceiptSha256",
        "reviewer",
        "reviewClass",
        "legacyTargetsSha256",
        "requestedAction",
    }
    exact_keys(plan, plan_fields, plan_fields, f"row {row_id} deletion plan")
    target_digest = canonical_json_sha256(
        [
            {
                "kind": target.kind,
                "role": target.role,
                "root": target.root,
                "path": target.path,
                "value": target.value,
            }
            for target in sorted(targets, key=lambda item: item.identity)
        ]
    )
    expected_plan = {
        "schemaVersion": 1,
        "rowId": row_id,
        "authorityGeneration": generation,
        "stableReceiptSha256": stable.digest,
        "reviewer": payload["reviewer"],
        "reviewClass": expected_review_class,
        "legacyTargetsSha256": target_digest,
        "requestedAction": "approve_legacy_deletion",
    }
    if plan != expected_plan:
        raise GateError(f"row {row_id}: deletion plan does not match the exact reviewed row and target inventory")
    if evidence_verifier is None:
        raise GateError(f"row {row_id}: live independent deletion review verification is required")
    evidence_verifier.verify_deletion_review(
        payload,
        {plan_path_value: plan_digest, stable.path: stable.digest},
        expected_descendant_commit=deletion.commit,
    )


def rollback_authority_binding(
    repo_root: Path,
    row_id: str,
    generation: int,
    promotion: Receipt,
    stable: Receipt,
) -> dict[str, Any]:
    pointer = require_object(promotion.payload, f"row {row_id} promotionAttestation")
    attestation_path = secure_path(
        repo_root,
        repository_path(pointer["path"], f"row {row_id} promotionAttestation.path"),
        f"row {row_id} promotion attestation",
        must_exist=True,
    )
    attestation = require_object(
        load_json(attestation_path, f"row {row_id} promotion attestation"),
        f"row {row_id} promotion attestation",
    )
    unsigned = require_object(attestation.get("unsignedBundle"), f"row {row_id} promotion unsignedBundle")
    provenance = require_object(attestation.get("provenance"), f"row {row_id} promotion provenance")
    release = stable.payload
    candidate = require_object(release.get("candidate"), f"row {row_id} release.candidate")
    activation = require_object(release.get("activation"), f"row {row_id} release.activation")
    retained = require_object(release.get("rollbackArtifact"), f"row {row_id} release.rollbackArtifact")
    return {
        "candidate": candidate,
        "activation": activation,
        "candidateBundleSha256": require_digest(
            unsigned.get("sha256"),
            f"row {row_id} promotion unsignedBundle.sha256",
        ),
        "sourceRun": {
            "repository": SignedEvidenceVerifier.repository,
            "workflowPath": SOURCE_WORKFLOW,
            "runId": positive_integer(
                unsigned.get("sourceRunId"),
                f"row {row_id} promotion unsignedBundle.sourceRunId",
            ),
            "runAttempt": positive_integer(
                unsigned.get("sourceRunAttempt"),
                f"row {row_id} promotion unsignedBundle.sourceRunAttempt",
            ),
            "event": "push",
            "ref": "refs/heads/main",
            "headSha": candidate["candidateCommit"],
        },
        "promotionSigner": {
            "workflowPath": PROMOTION_SIGNER_WORKFLOW,
            "runId": positive_integer(
                provenance.get("signerRunId"),
                f"row {row_id} promotion provenance.signerRunId",
            ),
            "runAttempt": positive_integer(
                provenance.get("signerRunAttempt"),
                f"row {row_id} promotion provenance.signerRunAttempt",
            ),
            "trustedMainCommit": require_commit(
                repo_root,
                provenance.get("trustedMainCommit"),
                f"row {row_id} promotion provenance.trustedMainCommit",
            ),
            "provenanceSha256": require_digest(
                provenance.get("sha256"),
                f"row {row_id} promotion provenance.sha256",
            ),
        },
        "retainedRollbackArtifact": {
            "artifactUri": retained["artifactUri"],
            "artifactSha256": require_digest(
                retained["artifactSha256"],
                f"row {row_id} release.rollbackArtifact.artifactSha256",
            ),
            "provenanceSha256": require_digest(
                retained["provenanceSha256"],
                f"row {row_id} release.rollbackArtifact.provenanceSha256",
            ),
            "retentionPolicy": retained["retentionPolicy"],
        },
    }


def validate_rollback_receipt(
    repo_root: Path,
    row_id: str,
    generation: int,
    rollback: Receipt,
    promotion: Receipt,
    stable: Receipt,
    evidence_verifier: SignedEvidenceVerifier | Any | None,
) -> datetime:
    payload = rollback.payload
    fields = {
        "stableReceiptSha256",
        "issueUri",
        "activatedAt",
        "candidate",
        "activation",
        "authority",
        "retainedRollbackArtifact",
        "approverAuthority",
        "completionEvidence",
    }
    exact_keys(payload, fields, fields, f"row {row_id} rollback")
    require_ancestor(repo_root, stable.commit, rollback.commit, f"row {row_id} rollback.commit")
    if payload["stableReceiptSha256"] != stable.digest:
        raise GateError(f"row {row_id}: rollback does not bind the current stable receipt")
    issue_uri = validate_https_uri(payload["issueUri"], f"row {row_id} rollback.issueUri")
    parsed_issue = urlsplit(issue_uri)
    if (
        parsed_issue.hostname != "github.com"
        or re.fullmatch(r"/Imagine-That-Ai/BurnBar/issues/[1-9][0-9]*", parsed_issue.path) is None
    ):
        raise GateError(f"row {row_id}: rollback issue must be an exact OpenBurnBar GitHub issue")
    expected_authority = rollback_authority_binding(repo_root, row_id, generation, promotion, stable)
    if payload["candidate"] != expected_authority["candidate"]:
        raise GateError(f"row {row_id}: rollback candidate does not match the governed promotion")
    if payload["activation"] != expected_authority["activation"]:
        raise GateError(f"row {row_id}: rollback activation does not match the governed stable release")
    authority = require_object(payload["authority"], f"row {row_id} rollback.authority")
    authority_fields = {"candidateBundleSha256", "sourceRun", "promotionSigner"}
    exact_keys(authority, authority_fields, authority_fields, f"row {row_id} rollback.authority")
    if authority != {key: expected_authority[key] for key in ("candidateBundleSha256", "sourceRun", "promotionSigner")}:
        raise GateError(f"row {row_id}: rollback does not bind the exact source and promotion authority")
    retained = require_object(
        payload["retainedRollbackArtifact"],
        f"row {row_id} rollback.retainedRollbackArtifact",
    )
    retained_fields = {"artifactUri", "artifactSha256", "provenanceSha256", "retentionPolicy"}
    exact_keys(
        retained,
        retained_fields,
        retained_fields,
        f"row {row_id} rollback.retainedRollbackArtifact",
    )
    if retained != expected_authority["retainedRollbackArtifact"]:
        raise GateError(f"row {row_id}: rollback does not bind the exact retained rollback artifact")
    approver = require_object(payload["approverAuthority"], f"row {row_id} rollback.approverAuthority")
    approver_fields = {"reviewClass", "catalogSha256", "trustedMainCommit"}
    exact_keys(approver, approver_fields, approver_fields, f"row {row_id} rollback.approverAuthority")
    review_class = "security_crypto" if row_id in SECURITY_REVIEW_ROWS else "domain_owner"
    trusted_approver_commit = expected_authority["promotionSigner"]["trustedMainCommit"]
    if approver["reviewClass"] != review_class or approver["trustedMainCommit"] != trusted_approver_commit:
        raise GateError(f"row {row_id}: rollback approver authority is not bound to protected trusted main")
    catalog_sha256 = hashlib.sha256(
        git_file(
            repo_root,
            trusted_approver_commit,
            DELETION_REVIEWERS_PATH,
            "rollback approver catalog",
        )
    ).hexdigest()
    if approver["catalogSha256"] != catalog_sha256:
        raise GateError(f"row {row_id}: rollback approver catalog digest does not match trusted main")
    qualified = load_deletion_reviewers(repo_root, trusted_approver_commit)[review_class]
    approved_by = rollback.approved_by
    if not isinstance(approved_by, str) or approved_by.casefold() not in qualified:
        raise GateError(f"row {row_id}: rollback approver is not qualified by trusted main")

    if evidence_verifier is None:
        raise GateError(f"row {row_id}: independent signed rollback completion verification is required")
    completions = require_array(payload["completionEvidence"], f"row {row_id} rollback.completionEvidence")
    consumers: set[str] = set()
    completion_times: list[datetime] = []
    domain = profile_domain_for_row(row_id)
    for index, raw_completion in enumerate(completions):
        label = f"row {row_id} rollback.completionEvidence[{index}]"
        completion = require_object(raw_completion, label)
        completion_fields = {
            "consumer",
            "domain",
            "artifactPath",
            "artifactSha256",
            "provenancePath",
            "provenanceSha256",
            "rollbackProfileSha256",
            "release",
            "signer",
            "actionRun",
            "deployedArtifactSha256",
            "healthArtifactSha256",
            "completedAt",
        }
        exact_keys(completion, completion_fields, completion_fields, label)
        consumer = completion["consumer"]
        if consumer not in RELEASE_ARTIFACT_IDENTITIES or consumer in consumers:
            raise GateError(f"{label}: consumer must be known and unique")
        consumers.add(consumer)
        if completion["domain"] != domain:
            raise GateError(f"{label}: domain does not match the governed row")
        require_digest(completion["rollbackProfileSha256"], f"{label}.rollbackProfileSha256")
        release = require_object(completion["release"], f"{label}.release")
        exact_keys(release, {"version", "tag", "commit"}, {"version", "tag", "commit"}, f"{label}.release")
        expected_release_tag = (
            f"windows-v{release['version']}"
            if consumer == "windows"
            else f"linux-v{release['version']}"
            if consumer == "linux"
            else f"v{release['version']}"
        )
        if (
            not isinstance(release["version"], str)
            or not VERSION_RE.fullmatch(release["version"])
            or release["tag"] != expected_release_tag
            or release["commit"] != expected_authority["activation"]["activationCommit"]
        ):
            raise GateError(f"{label}: release identity does not match activation P")
        signer = require_object(completion["signer"], f"{label}.signer")
        signer_fields = {"workflowPath", "runId", "runAttempt", "runInvocationUri"}
        exact_keys(signer, signer_fields, signer_fields, f"{label}.signer")
        if signer["workflowPath"] != RELEASE_SIGNER_WORKFLOWS[consumer]:
            raise GateError(f"{label}: signer workflow is not the governed consumer signer")
        signer_id = positive_integer(signer["runId"], f"{label}.signer.runId")
        signer_attempt = positive_integer(signer["runAttempt"], f"{label}.signer.runAttempt")
        if signer["runInvocationUri"] != (
            f"https://github.com/{SignedEvidenceVerifier.repository}/actions/runs/{signer_id}/attempts/{signer_attempt}"
        ):
            raise GateError(f"{label}: signer invocation URI does not bind the exact run attempt")
        action_run = require_object(completion["actionRun"], f"{label}.actionRun")
        action_fields = {
            "repository",
            "workflowPath",
            "runId",
            "runAttempt",
            "event",
            "ref",
            "headSha",
        }
        if consumer in ROLLBACK_ACTION_WORKFLOWS:
            action_fields.add("jobSetSha256")
        exact_keys(action_run, action_fields, action_fields, f"{label}.actionRun")
        if (
            action_run["repository"] != SignedEvidenceVerifier.repository
            or action_run["workflowPath"] != ROLLBACK_ACTION_WORKFLOWS.get(consumer, RELEASE_SIGNER_WORKFLOWS[consumer])
            or action_run["ref"] != f"refs/tags/{release['tag']}"
            or action_run["headSha"] != release["commit"]
        ):
            raise GateError(f"{label}: action run does not bind the exact rollback target")
        if consumer in ROLLBACK_ACTION_WORKFLOWS:
            require_digest(action_run["jobSetSha256"], f"{label}.actionRun.jobSetSha256")
            require_digest(completion["deployedArtifactSha256"], f"{label}.deployedArtifactSha256")
            require_digest(completion["healthArtifactSha256"], f"{label}.healthArtifactSha256")
        elif (
            completion["deployedArtifactSha256"] != completion["artifactSha256"]
            or completion["healthArtifactSha256"] is not None
        ):
            raise GateError(
                f"{label}: native completion must bind its signed release artifact without fake health evidence"
            )
        artifact_relative = repository_path(completion["artifactPath"], f"{label}.artifactPath")
        provenance_relative = repository_path(completion["provenancePath"], f"{label}.provenancePath")
        expected_artifact_relative = f"{ROLLBACK_COMPLETION_ROOT}/{row_id}/{generation}/{consumer}.json"
        expected_provenance_relative = f"{ROLLBACK_COMPLETION_ROOT}/{row_id}/{generation}/{consumer}.sigstore.json"
        if artifact_relative != expected_artifact_relative or provenance_relative != expected_provenance_relative:
            raise GateError(f"{label}: completion evidence must use its exact immutable repository path")
        artifact_path = secure_path(repo_root, artifact_relative, f"{label}.artifactPath", must_exist=True)
        provenance_path = secure_path(repo_root, provenance_relative, f"{label}.provenancePath", must_exist=True)
        for path_value, digest_key, file_label in (
            (artifact_path, "artifactSha256", "artifact"),
            (provenance_path, "provenanceSha256", "provenance"),
        ):
            digest = require_digest(completion[digest_key], f"{label}.{digest_key}")
            if sha256_path(path_value) != digest:
                raise GateError(f"{label}: committed {file_label} digest does not match working bytes")
            if (
                hashlib.sha256(
                    git_file(
                        repo_root,
                        rollback.commit,
                        path_value.relative_to(repo_root).as_posix(),
                        f"{label} {file_label}",
                    )
                ).hexdigest()
                != digest
            ):
                raise GateError(f"{label}: {file_label} bytes are not immutable at trusted main")
        completed_at = evidence_verifier.verify_rollback_completion(
            completion,
            artifact_path,
            provenance_path,
            candidate=expected_authority["candidate"],
            activation=expected_authority["activation"],
            source_run=expected_authority["sourceRun"],
            promotion_signer=expected_authority["promotionSigner"],
            candidate_bundle_sha256=expected_authority["candidateBundleSha256"],
            retained_rollback_sha256=expected_authority["retainedRollbackArtifact"]["artifactSha256"],
            domain=domain,
        )
        if completed_at < stable.approved_at or completed_at > rollback.approved_at:
            raise GateError(
                f"{label}: rollback action must complete after stable approval and before rollback approval"
            )
        completion_times.append(completed_at)
    if consumers != release_consumers_for_row(row_id):
        raise GateError(f"row {row_id}: rollback completion must cover the exact governed consumer set")
    if not completion_times:
        raise GateError(f"row {row_id}: rollback cannot be activated from a plan without completion evidence")
    activated_at = parse_rfc3339_utc(payload["activatedAt"], f"row {row_id} rollback.activatedAt")
    if activated_at != max(completion_times):
        raise GateError(f"row {row_id}: rollback activation must equal the last verified completion")
    return activated_at


def validate_activation_annulment_receipt(
    repo_root: Path,
    row_id: str,
    generation: int,
    annulment: Receipt,
    promotion: Receipt,
    base_ref: str | None = None,
) -> None:
    payload = annulment.payload
    fields = {
        "promotionReceiptSha256",
        "candidate",
        "activation",
        "advancedMainCommit",
        "reason",
        "replacementCandidateRequired",
    }
    exact_keys(payload, fields, fields, f"row {row_id} activationAnnulment")
    if payload["promotionReceiptSha256"] != promotion.digest:
        raise GateError(f"row {row_id}: activation annulment does not bind the current promotion receipt")
    if annulment.approved_at <= promotion.approved_at:
        raise GateError(f"row {row_id}: activation annulment approval must follow promotion approval")
    if (
        payload["reason"] != "release_train_advanced_before_stable_receipt"
        or payload["replacementCandidateRequired"] is not True
    ):
        raise GateError(f"row {row_id}: activation annulment must require a replacement exact-main candidate")

    candidate = require_commit(
        repo_root,
        require_object(payload["candidate"], f"row {row_id} activationAnnulment.candidate").get("candidateCommit"),
        f"row {row_id} activationAnnulment.candidate",
    )
    expected_candidate = candidate_identity_at_commit(repo_root, candidate)
    if payload["candidate"] != expected_candidate or candidate != promotion.commit:
        raise GateError(f"row {row_id}: activation annulment candidate does not match the promoted candidate")

    activation = require_object(payload["activation"], f"row {row_id} activationAnnulment.activation")
    activation_fields = {
        "candidateCommit",
        "activationCommit",
        "coreVersion",
        "abiVersion",
        "sourceSha256",
        "changedPathsSha256",
    }
    exact_keys(
        activation,
        activation_fields,
        activation_fields,
        f"row {row_id} activationAnnulment.activation",
    )
    activation_commit = require_commit(
        repo_root,
        activation["activationCommit"],
        f"row {row_id} activationAnnulment.activation.activationCommit",
    )
    if activation != validate_activation_closure(repo_root, candidate, activation_commit):
        raise GateError(f"row {row_id}: activation annulment does not bind the exact stale activation")

    advanced_main = require_commit(
        repo_root,
        payload["advancedMainCommit"],
        f"row {row_id} activationAnnulment.advancedMainCommit",
    )
    if annulment.commit != advanced_main:
        raise GateError(f"row {row_id}: activation annulment commit must equal advancedMainCommit")
    require_ancestor(repo_root, activation_commit, advanced_main, f"row {row_id} activation annulment")
    head = require_commit(
        repo_root,
        git_output(repo_root, ["rev-parse", "HEAD"], "activation annulment checkout").strip(),
        "activation annulment checkout",
    )
    require_ancestor(repo_root, advanced_main, head, f"row {row_id} activation annulment checkout")
    if base_ref is None:
        trusted_main_tip = head
    else:
        trusted_main_tip = git_output(
            repo_root,
            ["rev-parse", f"{base_ref}^{{commit}}"],
            f"row {row_id} activation annulment protected main",
        ).strip()
        if not COMMIT_RE.fullmatch(trusted_main_tip):
            raise GateError(f"row {row_id}: activation annulment cannot resolve the protected main base")
    require_ancestor(
        repo_root,
        advanced_main,
        trusted_main_tip,
        f"row {row_id} activation annulment protected main",
    )
    if advanced_main == activation_commit:
        raise GateError(f"row {row_id}: activation annulment requires main to advance beyond activation P")

    changed = [
        line
        for line in git_output(
            repo_root,
            ["diff", "--name-only", "--diff-filter=ACDMRTUXB", f"{activation_commit}..{advanced_main}"],
            f"row {row_id} activation annulment main advance",
        ).splitlines()
        if line
    ]
    incidental = sorted(
        path
        for path in changed
        if path not in ACTIVATION_ALLOWED_EXACT_PATHS
        and not any(path.startswith(prefix) for prefix in ACTIVATION_ALLOWED_PREFIXES)
    )
    if not incidental:
        raise GateError(
            f"row {row_id}: activation annulment requires an incidental main advance outside the activation path set"
        )

    activation_modes, _ = public_production_profile_at_commit(repo_root, activation_commit)
    if activation_modes[profile_domain_for_row(row_id)] != "rust":
        raise GateError(f"row {row_id}: annulled activation did not contain the Rust public profile")
    stable_tags = [
        tag
        for tag in git_output(
            repo_root,
            ["tag", "--points-at", activation_commit],
            f"row {row_id} activation release tags",
        ).splitlines()
        if re.fullmatch(r"(?:linux-|windows-)?v\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?", tag)
    ]
    if stable_tags:
        raise GateError(
            f"row {row_id}: activation with a stable release tag cannot be annulled: {', '.join(sorted(stable_tags))}"
        )
    for transition in ("stable_release", "rollback", "deletion_review"):
        relative = f"{RECEIPT_ROOT}/{row_id}/{generation}/{transition}.json"
        if secure_path(
            repo_root,
            relative,
            f"row {row_id} activation annulment {transition}",
            must_exist=False,
        ).exists():
            raise GateError(f"row {row_id}: activation cannot be annulled after {transition} authority exists")


def validate_receipt_chain(
    repo_root: Path,
    row_id: str,
    state: str,
    generation: int,
    receipts: dict[str, Receipt],
    evidence_verifier: SignedEvidenceVerifier | Any | None = None,
    targets: list[Target] | None = None,
    deletion_reviewers: dict[str, set[str]] | None = None,
    base_ref: str | None = None,
) -> tuple[str, str, str] | None:
    if state == "rollout":
        if generation != 0:
            raise GateError(f"row {row_id}: rollout authorityGeneration must be 0")
        return None
    if generation < 1 or isinstance(generation, bool):
        raise GateError(f"row {row_id}: promoted authorityGeneration must be at least 1")

    promotion = receipts["promotion"]
    candidate, report_digest, core_version = validate_promotion_attestation(
        repo_root, row_id, generation, promotion, evidence_verifier
    )

    annulment = receipts.get("activationAnnulment")
    if annulment is not None:
        validate_activation_annulment_receipt(
            repo_root,
            row_id,
            generation,
            annulment,
            promotion,
            base_ref,
        )

    stable = receipts.get("stableRelease")
    if stable is not None:
        release = stable.payload
        release_fields = {
            "promotionReceiptSha256",
            "publicProfileSha256",
            "candidate",
            "activation",
            "consumerReleases",
            "rollbackArtifact",
        }
        exact_keys(release, release_fields, release_fields, f"row {row_id} release")
        if release["promotionReceiptSha256"] != promotion.digest:
            raise GateError(f"row {row_id}: release does not bind the current promotion receipt")
        if stable.approved_at <= promotion.approved_at:
            raise GateError(f"row {row_id}: stable release approval must be later than promotion approval")
        expected_identity = candidate_identity_at_commit(repo_root, candidate)
        release_candidate = require_object(release["candidate"], f"row {row_id} release.candidate")
        if release_candidate != expected_identity:
            raise GateError(f"row {row_id}: stable release must bind the exact promoted candidate tuple")
        activation = require_object(release["activation"], f"row {row_id} release.activation")
        activation_fields = {
            "candidateCommit",
            "activationCommit",
            "coreVersion",
            "abiVersion",
            "sourceSha256",
            "changedPathsSha256",
        }
        exact_keys(
            activation,
            activation_fields,
            activation_fields,
            f"row {row_id} release.activation",
        )
        activation_commit = require_commit(
            repo_root,
            activation.get("activationCommit"),
            f"row {row_id} release.activation.activationCommit",
        )
        expected_activation = validate_activation_closure(repo_root, candidate, activation_commit)
        if activation != expected_activation:
            raise GateError(f"row {row_id}: activation proof does not match the exact candidate-to-release closure")
        candidate_modes, _ = public_production_profile_at_commit(repo_root, candidate)
        profile_domain = profile_domain_for_row(row_id)
        supersedes = promotion.payload["supersedes"]
        reattests_stable_authority = isinstance(supersedes, dict) and supersedes.get("transition") == "stable_release"
        expected_candidate_mode = "rust" if reattests_stable_authority else "legacy"
        if candidate_modes[profile_domain] != expected_candidate_mode:
            raise GateError(
                f"row {row_id}: protected candidate mode must be {expected_candidate_mode} "
                "for this authority transition"
            )
        require_ancestor(repo_root, activation_commit, stable.commit, f"row {row_id} stable receipt")
        releases = require_array(release["consumerReleases"], f"row {row_id} release.consumerReleases")
        consumers: set[str] = set()
        artifact_uris: set[str] = set()
        for index, raw_consumer_release in enumerate(releases):
            label = f"row {row_id} release.consumerReleases[{index}]"
            item = require_object(raw_consumer_release, label)
            fields = {
                "consumer",
                "artifactKind",
                "target",
                "version",
                "tag",
                "commit",
                "publishedAt",
                "artifactUri",
                "artifactSha256",
                "publicProfileSha256",
                "candidate",
                "activation",
                "provenancePath",
                "provenanceSha256",
            }
            exact_keys(item, fields, fields, label)
            consumer = item["consumer"]
            if not isinstance(consumer, str) or consumer in consumers:
                raise GateError(f"{label}: consumer must be unique")
            consumers.add(consumer)
            if consumer not in RELEASE_ARTIFACT_IDENTITIES:
                raise GateError(f"{label}: unknown release consumer")
            if (item["artifactKind"], item["target"]) != RELEASE_ARTIFACT_IDENTITIES[consumer]:
                raise GateError(f"{label}: artifact kind and target do not match consumer {consumer}")
            version = item["version"]
            if not isinstance(version, str) or not VERSION_RE.fullmatch(version) or "-" in version.split("+", 1)[0]:
                raise GateError(f"{label}: version must be a stable semantic version")
            expected_tag = (
                f"windows-v{version}"
                if consumer == "windows"
                else f"linux-v{version}"
                if consumer == "linux"
                else f"v{version}"
            )
            if item["tag"] != expected_tag:
                raise GateError(f"{label}: tag must be {expected_tag}")
            release_commit = require_commit(repo_root, item["commit"], f"{label}.commit")
            if release_commit != activation_commit:
                raise GateError(f"{label}: stable release must tag the exact activation commit")
            require_ancestor(repo_root, release_commit, stable.commit, f"{label}.commit")
            resolved_tag = git_output(
                repo_root,
                ["rev-parse", f"refs/tags/{expected_tag}^{{commit}}"],
                f"{label}.tag",
            ).strip()
            if resolved_tag != release_commit:
                raise GateError(f"{label}: tag does not resolve to the declared release commit")
            historical_modes, historical_digests = public_production_profile_at_commit(repo_root, release_commit)
            if historical_modes[profile_domain] != "rust":
                raise GateError(f"{label}: release commit did not contain the Rust public profile")
            if release["publicProfileSha256"] != historical_digests[profile_domain]:
                raise GateError(f"row {row_id}: release does not bind the historical public Rust profile")
            if item["publicProfileSha256"] != release["publicProfileSha256"]:
                raise GateError(f"{label}: signed artifact profile digest must equal the stable release profile")
            if item["candidate"] != expected_identity:
                raise GateError(f"{label}: signed release candidate tuple must equal the promotion tuple")
            if item["activation"] != expected_activation:
                raise GateError(f"{label}: signed release activation must equal the candidate-to-release closure")
            published_at = parse_rfc3339_utc(item["publishedAt"], f"{label}.publishedAt")
            if published_at < promotion.approved_at or published_at > stable.approved_at:
                raise GateError(f"{label}: release must be published after promotion and before stable approval")
            artifact_uri = validate_release_uri(item["artifactUri"], f"{label}.artifactUri")
            expected_uri_prefix = f"https://github.com/Imagine-That-Ai/BurnBar/releases/download/{expected_tag}/"
            if not artifact_uri.startswith(expected_uri_prefix) or artifact_uri in artifact_uris:
                raise GateError(f"{label}: artifact URI must be unique and bound to the declared release tag")
            if artifact_uri.rsplit("/", 1)[-1] != expected_release_asset_name(consumer, version):
                raise GateError(f"{label}: release asset name does not match the declared consumer and artifact class")
            artifact_uris.add(artifact_uri)
            if artifact_uri not in stable.evidence:
                raise GateError(f"{label}: artifact URI must be listed in receipt evidence")
            artifact_digest = require_digest(item["artifactSha256"], f"{label}.artifactSha256")
            expected_provenance_path = f"{RELEASE_PROVENANCE_ROOT}/{row_id}/{generation}/{consumer}.json"
            provenance_path_value = repository_path(item["provenancePath"], f"{label}.provenancePath")
            if provenance_path_value != expected_provenance_path:
                raise GateError(f"{label}: provenance must use exact path {expected_provenance_path}")
            provenance_path = secure_path(
                repo_root,
                provenance_path_value,
                f"{label}.provenancePath",
                must_exist=True,
            )
            provenance_digest = require_digest(item["provenanceSha256"], f"{label}.provenanceSha256")
            if not provenance_path.is_file() or sha256_path(provenance_path) != provenance_digest:
                raise GateError(f"{label}: provenance digest does not match committed bytes")
            if evidence_verifier is None:
                raise GateError(f"{label}: signed release evidence verification is required")
            verification_item = dict(item)
            verification_item["_retainedRollbackSha256"] = require_digest(
                require_object(
                    release["rollbackArtifact"],
                    f"row {row_id} release.rollbackArtifact",
                ).get("artifactSha256"),
                f"row {row_id} release.rollbackArtifact.artifactSha256",
            )
            evidence_verifier.verify_release(
                verification_item,
                provenance_path,
                artifact_digest,
                profile_domain,
            )
        if consumers != release_consumers_for_row(row_id):
            raise GateError(f"row {row_id}: stable receipt must cover the exact applicable consumer set")
        rollback_item = require_object(release["rollbackArtifact"], f"row {row_id} release.rollbackArtifact")
        rollback_fields = {
            "artifactKind",
            "target",
            "version",
            "tag",
            "commit",
            "publishedAt",
            "artifactUri",
            "artifactSha256",
            "candidate",
            "activation",
            "retentionPolicy",
            "provenancePath",
            "provenanceSha256",
        }
        exact_keys(
            rollback_item,
            rollback_fields,
            rollback_fields,
            f"row {row_id} release.rollbackArtifact",
        )
        if (
            rollback_item["artifactKind"] != "legacy-rollback-bundle"
            or rollback_item["target"] != "all-supported-consumers"
        ):
            raise GateError(f"row {row_id}: stable release requires the dedicated cross-consumer rollback artifact")
        if rollback_item["retentionPolicy"] != "retain_until_legacy_deletion_complete":
            raise GateError(f"row {row_id}: rollback artifact must be retained until legacy deletion completes")
        if rollback_item["candidate"] != expected_identity:
            raise GateError(f"row {row_id}: rollback artifact candidate tuple must equal the promotion tuple")
        if rollback_item["activation"] != expected_activation:
            raise GateError(f"row {row_id}: rollback artifact must bind the exact activation closure")
        if (
            require_commit(
                repo_root,
                rollback_item["commit"],
                f"row {row_id} rollback artifact.commit",
            )
            != activation_commit
        ):
            raise GateError(f"row {row_id}: rollback artifact must be produced by the exact activation commit")
        if (
            not isinstance(rollback_item["version"], str)
            or not VERSION_RE.fullmatch(rollback_item["version"])
            or "-" in rollback_item["version"].split("+", 1)[0]
        ):
            raise GateError(f"row {row_id}: rollback artifact version must be a stable semantic version")
        if rollback_item["tag"] != f"v{rollback_item['version']}":
            raise GateError(f"row {row_id}: rollback artifact tag must match its stable version")
        rollback_tag_commit = git_output(
            repo_root,
            ["rev-parse", f"refs/tags/{rollback_item['tag']}^{{commit}}"],
            f"row {row_id} rollback artifact.tag",
        ).strip()
        if rollback_tag_commit != activation_commit:
            raise GateError(f"row {row_id}: rollback artifact tag must resolve to the exact activation commit")
        rollback_published_at = parse_rfc3339_utc(
            rollback_item["publishedAt"],
            f"row {row_id} release.rollbackArtifact.publishedAt",
        )
        if rollback_published_at < promotion.approved_at or rollback_published_at > stable.approved_at:
            raise GateError(f"row {row_id}: rollback artifact must be published during the stable release interval")
        rollback_uri = validate_release_uri(
            rollback_item["artifactUri"],
            f"row {row_id} release.rollbackArtifact.artifactUri",
        )
        expected_rollback_uri = (
            f"https://github.com/Imagine-That-Ai/BurnBar/releases/download/{rollback_item['tag']}/"
            f"OpenBurnBar-{rollback_item['version']}-legacy-rollback.zip"
        )
        if rollback_uri != expected_rollback_uri:
            raise GateError(f"row {row_id}: rollback artifact URI must match the exact tag and canonical asset name")
        if rollback_uri not in stable.evidence or rollback_uri in artifact_uris:
            raise GateError(f"row {row_id}: rollback artifact URI must be unique and listed in stable evidence")
        rollback_digest = require_digest(
            rollback_item["artifactSha256"],
            f"row {row_id} release.rollbackArtifact.artifactSha256",
        )
        rollback_provenance_relative = f"{RELEASE_PROVENANCE_ROOT}/{row_id}/{generation}/rollback.json"
        rollback_provenance_value = repository_path(
            rollback_item["provenancePath"],
            f"row {row_id} release.rollbackArtifact.provenancePath",
        )
        if rollback_provenance_value != rollback_provenance_relative:
            raise GateError(f"row {row_id}: rollback provenance must use exact path {rollback_provenance_relative}")
        rollback_provenance_path = secure_path(
            repo_root,
            rollback_provenance_value,
            f"row {row_id} rollback provenance",
            must_exist=True,
        )
        rollback_provenance_digest = require_digest(
            rollback_item["provenanceSha256"],
            f"row {row_id} release.rollbackArtifact.provenanceSha256",
        )
        if (
            not rollback_provenance_path.is_file()
            or sha256_path(rollback_provenance_path) != rollback_provenance_digest
        ):
            raise GateError(f"row {row_id}: rollback provenance digest does not match committed bytes")
        if evidence_verifier is None:
            raise GateError(f"row {row_id}: signed rollback artifact verification is required")
        evidence_verifier.verify_rollback_artifact(rollback_item, rollback_provenance_path, rollback_digest)

    rollback = receipts.get("rollback")
    rollback_activated_at: datetime | None = None
    if rollback is not None:
        assert stable is not None
        rollback_activated_at = validate_rollback_receipt(
            repo_root,
            row_id,
            generation,
            rollback,
            promotion,
            stable,
            evidence_verifier,
        )

    deletion = receipts.get("deletionReview")
    if deletion is not None:
        assert stable is not None
        if targets is None:
            raise GateError(f"row {row_id}: deletion plan validation requires the row target inventory")
        validate_deletion_review_receipt(
            repo_root,
            row_id,
            generation,
            deletion,
            stable,
            targets,
            deletion_reviewers,
            evidence_verifier,
        )
        if rollback is not None:
            require_ancestor(
                repo_root,
                deletion.commit,
                rollback.commit,
                f"row {row_id} rollback.commit",
            )
            assert rollback_activated_at is not None
            if rollback_activated_at < deletion.approved_at:
                raise GateError(f"row {row_id}: rollback after deletion approval must follow that approval")

    return candidate, report_digest, core_version


def receipt_file_names(receipt_keys: set[str]) -> set[str]:
    return {f"{RECEIPT_TRANSITIONS[key]}.json" for key in receipt_keys}


def validate_rollback_history(
    repo_root: Path,
    row: Row,
    row_id: str,
    evidence_verifier: SignedEvidenceVerifier | Any | None,
    deletion_reviewers: dict[str, set[str]],
) -> None:
    relative = f"{RECEIPT_ROOT}/{row_id}"
    root = secure_path(repo_root, relative, f"row {row_id} receipt history", must_exist=False)
    if row.generation == 0:
        if root.exists():
            raise GateError(f"row {row_id}: rollout rows cannot retain authority receipt history")
        return
    if not root.exists() or not root.is_dir() or root.is_symlink():
        raise GateError(f"row {row_id}: promoted rows require a regular receipt history directory")
    generation_dirs: dict[int, Path] = {}
    for child in root.iterdir():
        if child.is_symlink() or not child.is_dir() or re.fullmatch(r"[1-9][0-9]*", child.name) is None:
            raise GateError(f"row {row_id} receipt history contains an invalid generation directory")
        numeric_generation = int(child.name)
        if numeric_generation in generation_dirs:
            raise GateError(f"row {row_id} receipt history contains a duplicate generation directory")
        generation_dirs[numeric_generation] = child
    expected_generations = set(range(1, row.generation + 1))
    if set(generation_dirs) != expected_generations:
        raise GateError(f"row {row_id}: receipt history generations must be contiguous from 1 through {row.generation}")
    for generation, directory in sorted(generation_dirs.items()):
        actual_files: set[str] = set()
        for child in directory.iterdir():
            if child.is_symlink() or not child.is_file():
                raise GateError(f"row {row_id} generation {generation}: receipt entries must be regular files")
            actual_files.add(child.name)
        stable_files = receipt_file_names(required_receipts("rust_authoritative_with_rollback"))
        stable_after_deletion_files = stable_files | {"deletion_review.json"}
        rollback_files = receipt_file_names(required_receipts("rollback_active"))
        rollback_after_deletion_files = rollback_files | {"deletion_review.json"}
        annulment_files = receipt_file_names(required_receipts("activation_annulled"))
        valid_files = (
            {
                frozenset(annulment_files),
                frozenset(stable_files),
                frozenset(stable_after_deletion_files),
                frozenset(rollback_files),
                frozenset(rollback_after_deletion_files),
            }
            if generation < row.generation
            else {frozenset(receipt_file_names(set(row.receipts)))}
        )
        if frozenset(actual_files) not in valid_files:
            raise GateError(
                f"row {row_id} generation {generation}: receipt files must be exactly a valid set for its authority state"
            )
        if generation >= row.generation:
            continue
        seen: set[str] = set()
        historical: dict[str, Receipt] = {
            "promotion": validate_receipt(
                repo_root,
                f"{relative}/{generation}/promotion.json",
                row_id,
                generation,
                "promotion",
                seen,
            ),
        }
        if "annulment.json" in actual_files:
            historical["activationAnnulment"] = validate_receipt(
                repo_root,
                f"{relative}/{generation}/annulment.json",
                row_id,
                generation,
                "annulment",
                seen,
            )
        else:
            historical["stableRelease"] = validate_receipt(
                repo_root,
                f"{relative}/{generation}/stable_release.json",
                row_id,
                generation,
                "stable_release",
                seen,
            )
        if "rollback.json" in actual_files:
            historical["rollback"] = validate_receipt(
                repo_root,
                f"{relative}/{generation}/rollback.json",
                row_id,
                generation,
                "rollback",
                seen,
            )
        if "deletion_review.json" in actual_files:
            historical["deletionReview"] = validate_receipt(
                repo_root,
                f"{relative}/{generation}/deletion_review.json",
                row_id,
                generation,
                "deletion_review",
                seen,
            )
        validate_receipt_chain(
            repo_root,
            row_id,
            (
                "activation_annulled"
                if "activationAnnulment" in historical
                else "rollback_active"
                if "rollback" in historical
                else "rust_authoritative_with_rollback"
            ),
            generation,
            historical,
            evidence_verifier,
            row.targets,
            deletion_reviewers,
        )


@dataclass(frozen=True)
class DeletionSensitivityInventory:
    target_paths: frozenset[str]
    legacy_roots: frozenset[str]
    deleted_legacy_roots: tuple[tuple[str, tuple[str, ...]], ...]


def _deletion_sensitivity_inventory(repo_root: Path, revision: str) -> DeletionSensitivityInventory:
    """Load the trusted deletion paths and root ownership used to classify a PR."""
    relative = "config/domain-core-legacy-deletion.json"
    if not git_file_exists(repo_root, revision, relative, "base legacy deletion ledger"):
        return DeletionSensitivityInventory(frozenset(), frozenset(), ())

    manifest = require_object(
        load_json_bytes(git_file(repo_root, revision, relative, "base legacy deletion ledger"), relative),
        relative,
    )
    raw_rows = require_array(manifest.get("rows"), "base manifest rows")
    seen_row_ids: set[str] = set()
    row_states: dict[str, str] = {}
    target_records: list[tuple[str, dict[str, Any]]] = []
    target_paths: set[str] = set()
    for raw_row in raw_rows:
        row = require_object(raw_row, "base manifest row")
        row_id = row.get("id")
        if not isinstance(row_id, str) or row_id not in ROW_IDS:
            raise GateError(f"base manifest row: invalid stable row id: {row_id!r}")
        if row_id in seen_row_ids:
            raise GateError(f"base manifest row: duplicate stable row id: {row_id}")
        seen_row_ids.add(row_id)
        state = row.get("state")
        if not isinstance(state, str) or state not in STATES:
            raise GateError(f"base manifest row {row_id}: invalid state: {state!r}")
        row_states[row_id] = state
        raw_targets = require_array(row.get("targets"), f"base manifest row {row_id} targets")
        if not raw_targets:
            raise GateError(f"base manifest row {row_id} targets must not be empty")
        for raw_target in raw_targets:
            target = require_object(raw_target, "base manifest target")
            target_paths.add(repository_path(target.get("path"), "base manifest target.path"))
            target_records.append((row_id, target))
    if seen_row_ids != set(ROW_IDS) or len(raw_rows) != len(ROW_IDS):
        missing = sorted(set(ROW_IDS) - seen_row_ids)
        raise GateError(f"base manifest rows must contain the stable row set; missing={missing}")

    for raw_shared in require_array(manifest.get("sharedTargets"), "base manifest sharedTargets"):
        shared = require_object(raw_shared, "base manifest sharedTarget")
        target = require_object(shared.get("target"), "base manifest sharedTarget.target")
        target_paths.add(repository_path(target.get("path"), "base manifest sharedTarget.target.path"))

    raw_roots = require_object(manifest.get("sourceRoots"), "base manifest sourceRoots")
    if not raw_roots:
        raise GateError("base manifest sourceRoots must not be empty")
    source_roots: dict[str, str] = {}
    seen_root_paths: set[str] = set()
    for root_id, raw_path in raw_roots.items():
        if not isinstance(root_id, str) or not ID_RE.fullmatch(root_id):
            raise GateError(f"base manifest sourceRoots: invalid root id: {root_id!r}")
        root_path = repository_path(raw_path, f"base manifest sourceRoots.{root_id}")
        if root_path in seen_root_paths:
            raise GateError(f"base manifest sourceRoots: duplicate root path: {root_path}")
        seen_root_paths.add(root_path)
        source_roots[root_id] = root_path

    legacy_root_rows: dict[str, set[str]] = {}
    for row_id, target in target_records:
        root_id = target.get("root")
        if not isinstance(root_id, str) or root_id not in source_roots:
            raise GateError(f"base manifest target.root: unknown source root: {root_id!r}")
        role = target.get("role")
        if role not in {"legacy_implementation", "rollback_control"}:
            raise GateError(f"base manifest target.role: invalid role: {role!r}")
        target_path = repository_path(target.get("path"), "base manifest target.path")
        root_path = source_roots[root_id]
        if target_path != root_path and not target_path.startswith(root_path + "/"):
            raise GateError(f"base manifest target.path must be inside source root {root_id}")
        if role == "legacy_implementation":
            legacy_root_rows.setdefault(root_path, set()).add(row_id)

    deleted_legacy_roots = tuple(
        (root_path, tuple(sorted(row_id for row_id in row_ids if row_states[row_id] == "legacy_deleted")))
        for root_path, row_ids in sorted(legacy_root_rows.items())
        if any(row_states[row_id] == "legacy_deleted" for row_id in row_ids)
    )
    return DeletionSensitivityInventory(
        target_paths=frozenset(target_paths),
        legacy_roots=frozenset(legacy_root_rows),
        deleted_legacy_roots=deleted_legacy_roots,
    )


def _sensitive_target_paths(repo_root: Path, revision: str) -> set[str]:
    """Extract ledger-covered target paths from the manifest at a trusted revision."""
    return set(_deletion_sensitivity_inventory(repo_root, revision).target_paths)


def _post_deletion_primitive_paths() -> set[str]:
    """Collect the source paths the post-deletion primitive rules guard."""
    return {rule[2] for rule in POST_DELETION_PRIMITIVE_RULES}


def _path_is_within_root(path: str, root: str) -> bool:
    return path == root or path.startswith(root + "/")


def _is_sensitive_path(
    path: str,
    target_paths: set[str] | frozenset[str],
    root_paths: set[str] | frozenset[str] = frozenset(),
) -> bool:
    """Return True if a repository-relative path touches a deletion-covered surface."""
    if path in SENSITIVE_EXACT_PATHS:
        return True
    if any(path.startswith(prefix) for prefix in SENSITIVE_PREFIXES):
        return True
    if path in target_paths:
        return True
    if any(_path_is_within_root(path, target_path) for target_path in target_paths):
        return True
    return any(_path_is_within_root(path, root_path) for root_path in root_paths)


def _candidate_changed_paths(repo_root: Path, base_ref: str) -> frozenset[str]:
    """Return every source and destination path changed since the PR fork point.

    ``--find-copies-harder`` is intentional. A pure copy leaves its source path
    unchanged, but copying code out of an immutable deleted legacy root is still
    deletion-sensitive. Name-status output retains both paths for copies and
    renames; NUL delimiters preserve unusual but valid Git path names.
    """
    fork_point = git_output(
        repo_root,
        ["merge-base", base_ref, "HEAD"],
        "non-deletion classification fork point",
    ).strip()
    if not COMMIT_RE.fullmatch(fork_point):
        raise GateError("non-deletion classification: cannot determine fork point")

    fields = git_output(
        repo_root,
        [
            "diff",
            "--name-status",
            "-z",
            "--find-renames=50%",
            "--find-copies=50%",
            "--find-copies-harder",
            "--diff-filter=ACDMRTUXB",
            f"{fork_point}..HEAD",
        ],
        "non-deletion classification diff",
    ).split("\0")

    changed_paths: set[str] = set()
    field_index = 0
    while field_index < len(fields):
        status = fields[field_index]
        field_index += 1
        if not status:
            if field_index == len(fields):
                break
            raise GateError("non-deletion classification: malformed empty diff status")
        if status[0] not in "ACDMRTUXB":
            raise GateError(f"non-deletion classification: unsupported diff status: {status!r}")

        path_count = 2 if status[0] in "CR" else 1
        if field_index + path_count > len(fields):
            raise GateError("non-deletion classification: truncated name-status diff")
        for _ in range(path_count):
            path = fields[field_index]
            field_index += 1
            changed_paths.add(repository_path(path, "non-deletion classification path"))

    return frozenset(changed_paths)


def _ensure_base_ref_available(repo_root: Path, base_ref: str, trusted_root: Path | None) -> None:
    """Ensure ``base_ref`` is fetchable into the candidate repo for merge-base.

    In CI, the candidate checkout (``fetch-depth: 0``) may lack the current main
    SHA when the PR branch is behind. The trusted checkout at ``trusted_root``
    always has it (checked out at ``base.sha``). When the candidate cannot reach
    ``base_ref``, fetch it from the trusted checkout so ``merge-base`` can
    compute the fork point. Both checkouts are local and credential-free.
    """
    try:
        result = subprocess.run(
            ["git", "cat-file", "-e", f"{base_ref}^{{commit}}"],
            cwd=repo_root,
            check=False,
            capture_output=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GateError(f"base ref: cannot verify commit availability: {error}") from error
    if result.returncode == 0:
        return
    if trusted_root is None:
        return
    trusted_root = trusted_root.resolve(strict=True)
    try:
        subprocess.run(
            ["git", "fetch", str(trusted_root), base_ref],
            cwd=repo_root,
            check=False,
            capture_output=True,
            timeout=30,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GateError(f"base ref: cannot fetch trusted commit: {error}") from error
    try:
        result = subprocess.run(
            ["git", "cat-file", "-e", f"{base_ref}^{{commit}}"],
            cwd=repo_root,
            check=False,
            capture_output=True,
            timeout=10,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise GateError(f"base ref: cannot verify commit availability: {error}") from error
    if result.returncode != 0:
        raise GateError("base ref: trusted commit is unavailable in both candidate and trusted checkouts")


def classify_deletion_sensitivity(
    repo_root: Path,
    base_ref: str,
    *,
    inventory: DeletionSensitivityInventory | None = None,
    changed_paths: frozenset[str] | None = None,
) -> bool:
    """Classify whether the candidate diff touches any deletion-covered surface.

    Uses trusted default-branch code and inventory only. The fork point
    (``merge-base(base_ref, HEAD)``) isolates the PR author's own changes from
    main's independent advance, so a behind-base ordinary PR whose diff touches
    none of the sensitive surfaces is classified non-deletion and may bypass the
    current-base ancestry requirement. Every path below a trusted legacy source
    root is sensitive, including a newly added nested path that was never named as
    a target. Rename detection is disabled so both sides of a rename remain visible.

    Returns ``True`` if deletion-sensitive, ``False`` if non-deletion.
    """
    if not COMMIT_RE.fullmatch(base_ref):
        raise GateError("base ref must be a full lowercase Git SHA")
    if inventory is None:
        inventory = _deletion_sensitivity_inventory(repo_root, base_ref)
    if changed_paths is None:
        changed_paths = _candidate_changed_paths(repo_root, base_ref)
    static_target_paths = _post_deletion_primitive_paths()
    return any(
        _is_sensitive_path(path, static_target_paths)
        or _is_sensitive_path(path, inventory.target_paths, inventory.legacy_roots)
        for path in changed_paths
    )


def verify_post_deletion_root_changes(
    repo_root: Path,
    base_ref: str,
    *,
    inventory: DeletionSensitivityInventory | None = None,
    changed_paths: frozenset[str] | None = None,
) -> None:
    """Reject every PR-authored change below a root with a deleted legacy owner."""
    if inventory is None:
        inventory = _deletion_sensitivity_inventory(repo_root, base_ref)
    if not inventory.deleted_legacy_roots:
        return
    if changed_paths is None:
        changed_paths = _candidate_changed_paths(repo_root, base_ref)
    violations = sorted(
        (path, root_path, row_ids)
        for path in changed_paths
        for root_path, row_ids in inventory.deleted_legacy_roots
        if _path_is_within_root(path, root_path)
    )
    if not violations:
        return
    details = "; ".join(
        f"{path} (root {root_path}; legacy_deleted rows {', '.join(row_ids)})"
        for path, root_path, row_ids in violations
    )
    raise GateError(f"post-deletion governed legacy roots are immutable: {details}")


def verify_append_only_artifacts(repo_root: Path, base_ref: str | None) -> None:
    """Verify immutable artifacts at the PR fork point are unchanged in the candidate.

    The append-only baseline is the fork point ``merge-base(base_ref, HEAD)`` — the
    commit the candidate actually branched from — rather than ``base_ref`` itself.
    When the default branch has advanced past the PR branch point, ``base_ref`` is no
    longer an ancestor of ``HEAD`` and ``require_commit`` would false-fail before any
    artifact comparison runs. The fork point is always an ancestor of ``HEAD`` and
    isolates the PR author's own changes from main's independent advance, so comparing
    the fork point's immutable artifact tree against the candidate working tree enforces
    the same append-only invariant without the false ancestry gate.
    """
    if base_ref is None:
        return
    if not COMMIT_RE.fullmatch(base_ref):
        raise GateError("base ref must be a full lowercase Git SHA")
    fork_point = git_output(
        repo_root,
        ["merge-base", base_ref, "HEAD"],
        "append-only artifact fork point",
    ).strip()
    if not COMMIT_RE.fullmatch(fork_point):
        raise GateError("append-only artifact baseline: cannot determine fork point")
    roots = (
        RECEIPT_ROOT,
        ATTESTATION_ROOT,
        PROMOTION_BUNDLE_ROOT,
        PROMOTION_PROVENANCE_ROOT,
        RELEASE_PROVENANCE_ROOT,
        DELETION_PLAN_ROOT,
    )
    raw = git_output(
        repo_root,
        ["ls-tree", "-r", "-z", fork_point, "--", *roots],
        "base artifact inventory",
    )
    for entry in raw.split("\0"):
        if not entry:
            continue
        try:
            metadata, relative = entry.split("\t", 1)
            mode, object_type, _object_id = metadata.split(" ", 2)
        except ValueError as error:
            raise GateError("base artifact inventory: malformed git ls-tree output") from error
        repository_path(relative, "base artifact path")
        if object_type != "blob" or mode != "100644" or not relative.endswith(".json"):
            raise GateError(f"base artifact inventory: unsupported immutable entry {relative}")
        current = secure_path(repo_root, relative, f"immutable artifact {relative}", must_exist=True)
        if not current.is_file():
            raise GateError(f"immutable artifact {relative}: expected regular file")
        if current.stat().st_mode & 0o111:
            raise GateError(f"immutable artifact {relative}: executable mode cannot change")
        if current.read_bytes() != git_file(repo_root, fork_point, relative, f"immutable artifact {relative}"):
            raise GateError(f"immutable artifact {relative}: committed history cannot be rewritten")


def validate_receipt_root_layout(repo_root: Path) -> None:
    root = secure_path(repo_root, RECEIPT_ROOT, "receipt history root", must_exist=False)
    if not root.exists():
        return
    if root.is_symlink() or not root.is_dir():
        raise GateError("receipt history root must be a regular directory")
    for child in root.iterdir():
        if child.is_symlink() or not child.is_dir() or child.name not in ROW_IDS:
            raise GateError(f"receipt history root contains an unknown row directory: {child.name}")


def validate_ledger_transition(repo_root: Path, base_ref: str | None, current_manifest: dict[str, Any]) -> None:
    if base_ref is None:
        return
    relative = "config/domain-core-legacy-deletion.json"
    if not git_file_exists(repo_root, base_ref, relative, "base legacy deletion ledger"):
        rows = require_array(current_manifest.get("rows"), "manifest.rows")
        safe_bootstrap = all(
            isinstance(row, dict)
            and row.get("state") == "rollout"
            and row.get("authorityGeneration") == 0
            and row.get("receipts") == {}
            for row in rows
        )
        if len(rows) != len(ROW_IDS) or not safe_bootstrap:
            raise GateError("initial legacy deletion ledger must bootstrap every row in empty generation-0 rollout")
        return
    base_manifest = require_object(
        load_json_bytes(
            git_file(repo_root, base_ref, relative, "base legacy deletion ledger"),
            "base legacy deletion ledger",
        ),
        "base legacy deletion ledger",
    )
    base_rows_raw = require_array(base_manifest.get("rows"), "base legacy deletion ledger.rows")
    current_rows_raw = require_array(current_manifest.get("rows"), "manifest.rows")
    if base_manifest.get("schemaVersion") != current_manifest.get("schemaVersion"):
        raise GateError("legacy deletion ledger schemaVersion is immutable")
    base_roots = require_object(base_manifest.get("sourceRoots"), "base legacy deletion ledger.sourceRoots")
    current_roots = require_object(current_manifest.get("sourceRoots"), "manifest.sourceRoots")
    for root, path in base_roots.items():
        if current_roots.get(root) != path:
            raise GateError(f"source root {root}: existing mapping is immutable")
    base_shared = require_array(base_manifest.get("sharedTargets"), "base legacy deletion ledger.sharedTargets")
    current_shared = require_array(current_manifest.get("sharedTargets"), "manifest.sharedTargets")
    base_shared_by_digest = {canonical_json_sha256(item): item for item in base_shared}
    current_shared_by_digest = {canonical_json_sha256(item): item for item in current_shared}
    missing_shared = sorted(set(base_shared_by_digest) - set(current_shared_by_digest))
    if missing_shared:
        raise GateError("shared target inventory is monotonic: existing entries cannot be removed or relabeled")
    base_rows = {
        row.get("id"): row for raw in base_rows_raw for row in [require_object(raw, "base legacy deletion ledger row")]
    }
    current_rows = {row.get("id"): row for raw in current_rows_raw for row in [require_object(raw, "manifest row")]}
    if set(base_rows) != set(ROW_IDS) or set(current_rows) != set(ROW_IDS):
        raise GateError("legacy deletion ledger transition requires the exact stable row set at base and HEAD")
    allowed = {
        "rollout": {"rollout", "promotion_approved"},
        "promotion_approved": {
            "promotion_approved",
            "activation_annulled",
            "rust_authoritative_with_rollback",
        },
        "activation_annulled": {
            "activation_annulled",
            "promotion_approved",
        },
        "rust_authoritative_with_rollback": {
            "rust_authoritative_with_rollback",
            "promotion_approved",
            "rollback_active",
            "deletion_approved",
        },
        "rollback_active": {"rollback_active", "promotion_approved"},
        "deletion_approved": {"deletion_approved", "rollback_active", "legacy_deleted"},
        "legacy_deleted": {"legacy_deleted"},
    }
    added_target_roots: set[str] = set()
    for row_id in ROW_IDS:
        base_row = base_rows[row_id]
        current_row = current_rows[row_id]
        immutable_row_fields = {
            key: value
            for key, value in base_row.items()
            if key not in {"state", "authorityGeneration", "receipts", "targets"}
        }
        current_immutable_row_fields = {
            key: value
            for key, value in current_row.items()
            if key not in {"state", "authorityGeneration", "receipts", "targets"}
        }
        if immutable_row_fields != current_immutable_row_fields:
            raise GateError(f"row {row_id}: every non-lifecycle field other than monotonic targets is immutable")
        base_targets = require_array(base_row.get("targets"), f"row {row_id}: base targets")
        current_targets = require_array(current_row.get("targets"), f"row {row_id}: current targets")
        base_targets_by_digest = {canonical_json_sha256(item): item for item in base_targets}
        current_targets_by_digest = {canonical_json_sha256(item): item for item in current_targets}
        if set(base_targets_by_digest) - set(current_targets_by_digest):
            raise GateError(
                f"row {row_id}: target inventory is monotonic and cannot remove or relabel an existing target"
            )
        added_targets = [
            current_targets_by_digest[key] for key in set(current_targets_by_digest) - set(base_targets_by_digest)
        ]
        if base_row.get("state") in {"deletion_approved", "legacy_deleted"} and added_targets:
            raise GateError(f"row {row_id}: target inventory is frozen after deletion approval")
        for target in added_targets:
            added_target_roots.add(require_object(target, f"row {row_id}: added target").get("root"))
        base_state = base_row.get("state")
        current_state = current_row.get("state")
        if base_state not in allowed or current_state not in allowed[base_state]:
            raise GateError(f"row {row_id}: illegal ledger transition {base_state!r} -> {current_state!r}")
        base_generation = base_row.get("authorityGeneration", 0 if base_state == "rollout" else None)
        current_generation = current_row.get("authorityGeneration")
        if not isinstance(base_generation, int) or isinstance(base_generation, bool):
            raise GateError(f"row {row_id}: base authority generation is invalid")
        starts_new_generation = (
            base_state
            in {
                "activation_annulled",
                "rollback_active",
                "rust_authoritative_with_rollback",
            }
            and current_state == "promotion_approved"
        )
        expected_generation = base_generation + 1 if starts_new_generation else base_generation
        if base_state == "rollout" and current_state == "promotion_approved":
            expected_generation = 1
        if current_generation != expected_generation or isinstance(current_generation, bool):
            raise GateError(
                f"row {row_id}: transition {base_state} -> {current_state} requires authority generation {expected_generation}"
            )
        base_receipts = require_object(base_row.get("receipts"), f"row {row_id}: base receipts")
        current_receipts = require_object(current_row.get("receipts"), f"row {row_id}: current receipts")
        if current_generation == base_generation:
            for receipt_kind, pointer in base_receipts.items():
                if current_receipts.get(receipt_kind) != pointer:
                    raise GateError(
                        f"row {row_id}: receipt pointer {receipt_kind} is immutable within authority generation {base_generation}"
                    )
    for digest in set(current_shared_by_digest) - set(base_shared_by_digest):
        shared = require_object(current_shared_by_digest[digest], "added shared target")
        row_ids = require_array(shared.get("rowIds"), "added shared target.rowIds")
        if any(base_rows.get(row_id, {}).get("state") in {"deletion_approved", "legacy_deleted"} for row_id in row_ids):
            raise GateError("shared target inventory is frozen for rows after deletion approval")
        added_target_roots.add(require_object(shared.get("target"), "added shared target.target").get("root"))
    new_roots = set(current_roots) - set(base_roots)
    if new_roots != (added_target_roots - set(base_roots)):
        raise GateError("new source roots must be introduced exactly by newly added targets")


def source_fingerprint(repo_root: Path) -> str:
    relative = "crates/openburnbar-domain-core/union-abi-manifest.json"
    path = secure_path(repo_root, relative, "domain-core union ABI manifest", must_exist=True)
    manifest = require_object(
        load_json(path, "domain-core union ABI manifest"),
        "domain-core union ABI manifest",
    )
    return require_digest(manifest.get("sourceSha256"), "domain-core union ABI manifest.sourceSha256")


def source_fingerprint_at_commit(repo_root: Path, commit: str) -> str:
    relative = "crates/openburnbar-domain-core/union-abi-manifest.json"
    manifest = require_object(
        load_json_bytes(
            git_file(repo_root, commit, relative, "candidate union ABI manifest"),
            "candidate union ABI manifest",
        ),
        "candidate union ABI manifest",
    )
    return require_digest(manifest.get("sourceSha256"), "candidate union ABI manifest.sourceSha256")


def core_version_at_commit(repo_root: Path, commit: str) -> str:
    relative = "crates/openburnbar-domain-core/Cargo.toml"
    try:
        cargo = tomllib.loads(
            git_file(repo_root, commit, relative, "candidate domain-core Cargo manifest").decode("utf-8")
        )
    except (UnicodeError, tomllib.TOMLDecodeError) as error:
        raise GateError(f"candidate domain-core Cargo manifest: invalid TOML: {error}") from error
    version = cargo.get("workspace", {}).get("package", {}).get("version")
    if not isinstance(version, str) or not VERSION_RE.fullmatch(version):
        raise GateError("candidate domain-core Cargo manifest: workspace.package.version is invalid")
    return version


def activation_changed_paths(repo_root: Path, candidate_commit: str, activation_commit: str) -> list[str]:
    require_ancestor(repo_root, candidate_commit, activation_commit, "domain-core activation")
    if candidate_commit == activation_commit:
        raise GateError("domain-core activation commit must be distinct from the candidate commit")
    activation_commits = [
        line
        for line in git_output(
            repo_root,
            ["rev-list", "--first-parent", "--reverse", f"{candidate_commit}..{activation_commit}"],
            "domain-core activation first-parent history",
        ).splitlines()
        if line
    ]
    activation_base = candidate_commit
    for commit in activation_commits:
        commit_lineage = git_output(
            repo_root,
            ["rev-list", "--parents", "-n", "1", commit],
            "domain-core activation parent",
        ).split()
        if len(commit_lineage) < 2:
            raise GateError("domain-core activation commit must have a parent")
        commit_paths = [
            line
            for line in git_output(
                repo_root,
                [
                    "diff",
                    "--name-only",
                    "--diff-filter=ACDMRTUXB",
                    f"{commit_lineage[1]}..{commit}",
                ],
                "domain-core activation commit diff",
            ).splitlines()
            if line
        ]
        commit_forbidden = sorted(
            path
            for path in commit_paths
            if path not in ACTIVATION_ALLOWED_EXACT_PATHS
            and not any(path.startswith(prefix) for prefix in ACTIVATION_ALLOWED_PREFIXES)
        )
        if commit_forbidden:
            if commit == activation_commit:
                raise GateError(
                    "domain-core activation may change only profile, trusted manifest, append-only authority artifacts, and runbooks: "
                    + ", ".join(commit_forbidden)
                )
            activation_base = commit
    # Protected merge queues may advance main before applying an activation
    # squash. Keep the contiguous allowed suffix after the latest incidental
    # commit, while still supporting activation evidence written in several
    # allowed commits.
    changed = [
        line
        for line in git_output(
            repo_root,
            [
                "diff",
                "--name-only",
                "--diff-filter=ACDMRTUXB",
                f"{activation_base}..{activation_commit}",
            ],
            "domain-core activation diff",
        ).splitlines()
        if line
    ]
    if not changed:
        raise GateError("domain-core activation commit must change the committed authority profile and receipts")
    forbidden = sorted(
        path
        for path in changed
        if path not in ACTIVATION_ALLOWED_EXACT_PATHS
        and not any(path.startswith(prefix) for prefix in ACTIVATION_ALLOWED_PREFIXES)
    )
    if forbidden:
        raise GateError(
            "domain-core activation may change only profile, trusted manifest, append-only authority artifacts, and runbooks: "
            + ", ".join(forbidden)
        )
    if BUILD_PROFILE_PATH not in changed or "config/domain-core-legacy-deletion.json" not in changed:
        raise GateError("domain-core activation must atomically change the public profile and authority ledger")
    return sorted(changed)


def validate_activation_closure(
    repo_root: Path,
    candidate_commit: str,
    activation_commit: str,
) -> dict[str, Any]:
    candidate = candidate_identity_at_commit(repo_root, candidate_commit)
    activation = candidate_identity_at_commit(repo_root, activation_commit)
    activation_identity = {**activation, "candidateCommit": candidate_commit}
    if activation_identity != candidate:
        raise GateError("domain-core activation changed the attested core version, ABI, or source fingerprint")
    changed_paths = activation_changed_paths(repo_root, candidate_commit, activation_commit)
    return {
        "candidateCommit": candidate_commit,
        "activationCommit": activation_commit,
        "coreVersion": candidate["coreVersion"],
        "abiVersion": candidate["abiVersion"],
        "sourceSha256": candidate["sourceSha256"],
        "changedPathsSha256": canonical_json_sha256(changed_paths),
    }


def validate_deterministic_promotion_policy(repo_root: Path) -> None:
    path = secure_path(
        repo_root,
        PROMOTION_POLICY_PATH,
        "domain-core promotion policy",
        must_exist=True,
    )
    policy = require_object(load_json(path, "domain-core promotion policy"), "domain-core promotion policy")
    if policy.get("schemaVersion") != 3 or isinstance(policy.get("schemaVersion"), bool):
        raise GateError("domain-core promotion policy schemaVersion must be 3")
    if (
        policy.get("authority") != "unsigned-candidate-evaluation"
        or policy.get("promotionAuthority") is not False
        or policy.get("protectedAttestationRequired") is not True
        or policy.get("oneStableReleaseBeforeDeletion") is not True
        or policy.get("rollbackRequired") is not True
    ):
        raise GateError(
            "domain-core promotion policy must remain deterministic, protected, rollback-capable, and stable-release gated"
        )
    workflow = require_object(policy.get("workflow"), "domain-core promotion policy.workflow")
    if (
        workflow.get("repository") != SignedEvidenceVerifier.repository
        or workflow.get("workflowPath") != SOURCE_WORKFLOW
        or workflow.get("allowedEvents") != ["push"]
        or workflow.get("requiredRef") != "refs/heads/main"
    ):
        raise GateError("domain-core promotion policy workflow trust boundary is invalid")


def validate_build_profile_catalog(
    catalog_value: Any,
) -> tuple[dict[str, str], dict[str, str]]:
    catalog = require_object(catalog_value, "domain-core build profiles")
    exact_keys(
        catalog,
        {"schemaVersion", "defaultReleaseProfile", "domains", "profiles"},
        {"schemaVersion", "defaultReleaseProfile", "domains", "profiles"},
        "domain-core build profiles",
    )
    expected_domains = list(PROFILE_DOMAIN_ROWS)
    if catalog["schemaVersion"] != 1 or isinstance(catalog["schemaVersion"], bool):
        raise GateError("domain-core build profiles: schemaVersion must be 1")
    if catalog["defaultReleaseProfile"] != "public-production":
        raise GateError("domain-core build profiles: defaultReleaseProfile must be public-production")
    if catalog["domains"] != expected_domains:
        raise GateError("domain-core build profiles: domains must match the exact canonical order")
    profiles = require_object(catalog.get("profiles"), "domain-core build profiles.profiles")
    exact_keys(
        profiles,
        {
            "developer",
            "public-production",
            "public-production-rollback",
            "internal",
            "beta",
        },
        {
            "developer",
            "public-production",
            "public-production-rollback",
            "internal",
            "beta",
        },
        "domain-core build profiles.profiles",
    )
    expected_profile_fields = {
        "artifactAuthority",
        "distribution",
        "rolloutChannel",
        "evidenceEnabled",
        "modes",
    }
    expected_modes = {
        "developer": ("development", "development", None, False, "legacy"),
        "internal": ("signed", "internal", "internal", True, "shadow"),
        "beta": ("signed", "beta", "beta", True, "shadow"),
        "public-production-rollback": ("signed", "public", None, False, "legacy"),
    }
    for profile_name, expected in expected_modes.items():
        profile = require_object(
            profiles[profile_name],
            f"domain-core build profiles.profiles.{profile_name}",
        )
        exact_keys(
            profile,
            expected_profile_fields,
            expected_profile_fields,
            f"domain-core build profiles.profiles.{profile_name}",
        )
        authority, distribution, channel, evidence, mode = expected
        if (
            profile["artifactAuthority"] != authority
            or profile["distribution"] != distribution
            or profile["rolloutChannel"] != channel
            or profile["evidenceEnabled"] is not evidence
        ):
            raise GateError(f"domain-core build profiles: {profile_name} authority metadata is not canonical")
        profile_modes = require_object(
            profile["modes"],
            f"domain-core build profiles.profiles.{profile_name}.modes",
        )
        exact_keys(
            profile_modes,
            set(expected_domains),
            set(expected_domains),
            f"domain-core build profiles.profiles.{profile_name}.modes",
        )
        if any(value != mode for value in profile_modes.values()):
            raise GateError(f"domain-core build profiles: {profile_name} modes must all be {mode}")
    public = require_object(
        profiles.get("public-production"),
        "domain-core build profiles.profiles.public-production",
    )
    exact_keys(
        public,
        expected_profile_fields,
        expected_profile_fields,
        "domain-core build profiles.profiles.public-production",
    )
    if (
        public["artifactAuthority"] != "signed"
        or public["distribution"] != "public"
        or public["rolloutChannel"] is not None
        or public["evidenceEnabled"] is not False
    ):
        raise GateError("domain-core build profiles: public-production authority metadata is not canonical")
    modes = require_object(
        public.get("modes"),
        "domain-core build profiles.profiles.public-production.modes",
    )
    expected_domain_set = set(expected_domains)
    exact_keys(modes, expected_domain_set, expected_domain_set, "public-production.modes")
    result: dict[str, str] = {}
    for domain in PROFILE_DOMAIN_ROWS:
        mode = modes[domain]
        if mode not in {"legacy", "rust"}:
            raise GateError(f"public-production.modes.{domain}: public promotion mode must be legacy or rust")
        result[domain] = mode
    digests = {
        domain: canonical_json_sha256(
            {
                "artifactAuthority": public["artifactAuthority"],
                "distribution": public["distribution"],
                "rolloutChannel": public["rolloutChannel"],
                "evidenceEnabled": public["evidenceEnabled"],
                "domain": domain,
                "mode": "rust",
            }
        )
        for domain in expected_domains
    }
    return result, digests


def public_production_profile(repo_root: Path) -> tuple[dict[str, str], dict[str, str]]:
    path = secure_path(repo_root, BUILD_PROFILE_PATH, "domain-core build profiles", must_exist=True)
    return validate_build_profile_catalog(load_json(path, "domain-core build profiles"))


def public_production_profile_at_commit(repo_root: Path, commit: str) -> tuple[dict[str, str], dict[str, str]]:
    contents = git_file(repo_root, commit, BUILD_PROFILE_PATH, "release build profiles")
    return validate_build_profile_catalog(load_json_bytes(contents, "release build profiles"))


def validate_public_profile_transitions(
    rows: dict[str, Row],
    modes: dict[str, str],
    promotion_bindings: dict[str, tuple[str, str, str] | None],
) -> None:
    for domain, row_ids in PROFILE_DOMAIN_ROWS.items():
        mode = modes[domain]
        states = {row_id: rows[row_id].state for row_id in row_ids}
        generations = {rows[row_id].generation for row_id in row_ids}
        if len(set(states.values())) != 1 or len(generations) != 1:
            raise GateError(f"public-production {domain}: mapped rows must move atomically in one state and generation")
        stable_receipts = [rows[row_id].receipts.get("stableRelease") for row_id in row_ids]
        if any(receipt is not None for receipt in stable_receipts):
            if any(receipt is None for receipt in stable_receipts):
                raise GateError(f"public-production {domain}: mapped rows must share stable-release evidence")

            def release_identity(receipt: Receipt) -> dict[str, Any]:
                releases = []
                for release in receipt.payload["consumerReleases"]:
                    releases.append({key: value for key, value in release.items() if key != "provenancePath"})
                return {
                    "publicProfileSha256": receipt.payload["publicProfileSha256"],
                    "candidate": receipt.payload["candidate"],
                    "activation": receipt.payload["activation"],
                    "consumerReleases": releases,
                    "rollbackArtifact": {
                        key: value
                        for key, value in receipt.payload["rollbackArtifact"].items()
                        if key != "provenancePath"
                    },
                }

            stable_bindings = {
                canonical_json_sha256(release_identity(receipt)) for receipt in stable_receipts if receipt is not None
            }
            if len(stable_bindings) != 1:
                raise GateError(f"public-production {domain}: mapped rows must share one stable release identity")
        rollback_receipts = [rows[row_id].receipts.get("rollback") for row_id in row_ids]
        if any(receipt is not None for receipt in rollback_receipts):
            if any(receipt is None for receipt in rollback_receipts):
                raise GateError(f"public-production {domain}: mapped rows must roll back atomically")
            rollback_bindings = {
                canonical_json_sha256(
                    {
                        "issueUri": receipt.payload["issueUri"],
                        "activatedAt": receipt.payload["activatedAt"],
                    }
                )
                for receipt in rollback_receipts
                if receipt is not None
            }
            if len(rollback_bindings) != 1:
                raise GateError(f"public-production {domain}: mapped rows must share one rollback event")
        annulment_receipts = [rows[row_id].receipts.get("activationAnnulment") for row_id in row_ids]
        if any(receipt is not None for receipt in annulment_receipts):
            if any(receipt is None for receipt in annulment_receipts):
                raise GateError(f"public-production {domain}: mapped rows must be annulled atomically")
            annulment_bindings = {
                canonical_json_sha256(
                    {
                        "candidate": receipt.payload["candidate"],
                        "activation": receipt.payload["activation"],
                        "advancedMainCommit": receipt.payload["advancedMainCommit"],
                    }
                )
                for receipt in annulment_receipts
                if receipt is not None
            }
            if len(annulment_bindings) != 1:
                raise GateError(f"public-production {domain}: mapped rows must share one annulment event")
        if mode == "rust":
            unapproved = sorted(
                row_id
                for row_id, state in states.items()
                if state in {"activation_annulled", "rollout", "rollback_active"}
            )
            if unapproved:
                raise GateError(
                    f"public-production {domain}=rust requires promotion approval for every row: "
                    + ", ".join(unapproved)
                )
            bindings = {promotion_bindings[row_id] for row_id in row_ids}
            if None in bindings or len(bindings) != 1:
                raise GateError(
                    f"public-production {domain}=rust requires one shared candidate commit, deterministic bundle, and core version"
                )
            continue
        candidates = sorted(
            row_id
            for row_id, state in states.items()
            if state not in {"activation_annulled", "rollout", "rollback_active"}
        )
        if candidates:
            raise GateError(
                f"public-production {domain}=legacy is allowed only before promotion or during explicit rollback: "
                + ", ".join(candidates)
            )


def run_gate(
    repo_root: Path,
    manifest_path: Path,
    *,
    base_ref: str | None = None,
    evidence_verifier: SignedEvidenceVerifier | Any | None = None,
    deletion_pull_request: int | None = None,
    deletion_head: str | None = None,
    trusted_root: Path | None = None,
) -> None:
    if not repo_root.is_dir():
        raise GateError(f"repository root is missing: {repo_root}")
    repo_root = repo_root.resolve(strict=True)
    manifest_path = manifest_path if manifest_path.is_absolute() else repo_root / manifest_path
    try:
        manifest_relative = manifest_path.relative_to(repo_root).as_posix()
    except ValueError as error:
        raise GateError("manifest path must be inside repository root") from error
    manifest_path = secure_path(repo_root, manifest_relative, "manifest", must_exist=False)
    deletion_sensitive = False
    if base_ref is not None:
        _ensure_base_ref_available(repo_root, base_ref, trusted_root)
        fork_point = git_output(
            repo_root,
            ["merge-base", base_ref, "HEAD"],
            "legacy deletion ledger fork point",
        ).strip()
        if not COMMIT_RE.fullmatch(fork_point):
            raise GateError("legacy deletion ledger baseline: cannot determine fork point")
        if not manifest_path.exists() and git_file_exists(
            repo_root, fork_point, manifest_relative, "fork-point legacy deletion ledger"
        ):
            raise GateError("candidate cannot remove the legacy deletion ledger")
        sensitivity_inventory = _deletion_sensitivity_inventory(repo_root, base_ref)
        changed_paths = _candidate_changed_paths(repo_root, base_ref)
        deletion_sensitive = classify_deletion_sensitivity(
            repo_root,
            base_ref,
            inventory=sensitivity_inventory,
            changed_paths=changed_paths,
        )
        verify_post_deletion_root_changes(
            repo_root,
            base_ref,
            inventory=sensitivity_inventory,
            changed_paths=changed_paths,
        )
        if not deletion_sensitive:
            return
    verify_append_only_artifacts(repo_root, base_ref)
    if not manifest_path.exists():
        if deletion_sensitive:
            raise GateError("deletion-sensitive candidate has no legacy deletion ledger to anchor validation")
        return
    if not manifest_path.is_file():
        raise GateError("manifest: expected regular file")
    manifest = require_object(load_json(manifest_path, "manifest"), "manifest")
    validate_ledger_transition(repo_root, base_ref, manifest)
    manifest_fields = {"schemaVersion", "sourceRoots", "rows", "sharedTargets"}
    exact_keys(manifest, manifest_fields, manifest_fields, "manifest")
    if manifest["schemaVersion"] != 2 or isinstance(manifest["schemaVersion"], bool):
        raise GateError("manifest.schemaVersion must be 2")

    raw_roots = require_object(manifest["sourceRoots"], "manifest.sourceRoots")
    if not raw_roots:
        raise GateError("manifest.sourceRoots must not be empty")
    roots: dict[str, str] = {}
    seen_root_paths: set[str] = set()
    for root_id, raw_path in raw_roots.items():
        if not ID_RE.fullmatch(root_id):
            raise GateError(f"manifest.sourceRoots: invalid root id: {root_id!r}")
        path = repository_path(raw_path, f"manifest.sourceRoots.{root_id}")
        if path in seen_root_paths:
            raise GateError(f"manifest.sourceRoots: duplicate root path: {path}")
        seen_root_paths.add(path)
        root = secure_path(repo_root, path, f"source root {root_id}", must_exist=True)
        if not root.is_dir():
            raise GateError(f"source root {root_id}: expected directory: {path}")
        roots[root_id] = path

    raw_rows = require_array(manifest["rows"], "manifest.rows")
    rows: dict[str, Row] = {}
    seen_targets: set[tuple[str, str, str]] = set()
    seen_receipts: set[str] = set()
    for index, raw_row in enumerate(raw_rows):
        label = f"manifest.rows[{index}]"
        row = require_object(raw_row, label)
        row_fields = {"id", "state", "authorityGeneration", "receipts", "targets"}
        exact_keys(row, row_fields, row_fields, label)
        row_id = row["id"]
        if not isinstance(row_id, str) or not ROW_ID_RE.fullmatch(row_id):
            raise GateError(f"{label}.id: invalid row id")
        if row_id in rows:
            raise GateError(f"duplicate row id: {row_id}")
        state = row["state"]
        if not isinstance(state, str) or state not in STATES:
            raise GateError(f"{label}.state: unknown state: {state!r}")
        generation = row["authorityGeneration"]
        if not isinstance(generation, int) or isinstance(generation, bool) or generation < 0:
            raise GateError(f"{label}.authorityGeneration: expected non-negative integer")
        receipts = require_object(row["receipts"], f"{label}.receipts")
        expected_receipts = required_receipts(state)
        exact_keys(receipts, allowed_receipts(state), expected_receipts, f"{label}.receipts")
        parsed_receipts: dict[str, Receipt] = {}
        for receipt_key, receipt_path_raw in receipts.items():
            receipt_path = repository_path(receipt_path_raw, f"{label}.receipts.{receipt_key}")
            parsed_receipts[receipt_key] = validate_receipt(
                repo_root,
                receipt_path,
                row_id,
                generation,
                RECEIPT_TRANSITIONS[receipt_key],
                seen_receipts,
            )
        raw_targets = require_array(row["targets"], f"{label}.targets")
        if not raw_targets:
            raise GateError(f"{label}.targets must not be empty")
        targets: list[Target] = []
        for target_index, raw_target in enumerate(raw_targets):
            target = parse_target(raw_target, f"{label}.targets[{target_index}]", roots)
            if target.identity in seen_targets:
                raise GateError(f"duplicate target: {target.identity}")
            seen_targets.add(target.identity)
            targets.append(target)
        if not any(target.role == "legacy_implementation" for target in targets):
            raise GateError(f"{label}.targets must include at least one actual legacy implementation")
        rows[row_id] = Row(
            state=state,
            generation=generation,
            receipts=parsed_receipts,
            targets=targets,
        )

    missing_rows = sorted(set(ROW_IDS) - set(rows))
    unknown_rows = sorted(set(rows) - set(ROW_IDS))
    if missing_rows or unknown_rows or len(raw_rows) != len(ROW_IDS):
        details = []
        if missing_rows:
            details.append("missing " + ", ".join(missing_rows))
        if unknown_rows:
            details.append("unknown " + ", ".join(unknown_rows))
        raise GateError("manifest.rows must contain the exact stable row set: " + "; ".join(details))

    validate_atomic_deletion_groups(rows)
    verify_post_deletion_primitives(repo_root, rows)

    modes, _ = public_production_profile(repo_root)
    validate_deterministic_promotion_policy(repo_root)
    current_deletion_reviewers = load_deletion_reviewers(repo_root)
    trusted_deletion_reviewers = (
        load_deletion_reviewers(repo_root, base_ref, allow_missing=True)
        if base_ref is not None
        else current_deletion_reviewers
    )
    validate_receipt_root_layout(repo_root)
    for row_id, row in rows.items():
        validate_rollback_history(repo_root, row, row_id, evidence_verifier, trusted_deletion_reviewers)
    promotion_bindings = {
        row_id: validate_receipt_chain(
            repo_root,
            row_id,
            row.state,
            row.generation,
            row.receipts,
            evidence_verifier,
            row.targets,
            trusted_deletion_reviewers,
            base_ref,
        )
        for row_id, row in rows.items()
    }
    validate_public_profile_transitions(rows, modes, promotion_bindings)

    deleted_rows = [row_id for row_id, row in rows.items() if row.state == "legacy_deleted"]
    if deleted_rows:
        if evidence_verifier is None or deletion_pull_request is None or deletion_head is None:
            raise GateError("legacy deletion requires live approval on the exact current deletion pull request head")
        if not COMMIT_RE.fullmatch(deletion_head):
            raise GateError("deletion head must be a full lowercase Git SHA")
        for row_id in deleted_rows:
            deletion_receipt = rows[row_id].receipts["deletionReview"]
            evidence_verifier.verify_deletion_head(
                pull_number=deletion_pull_request,
                deletion_head=deletion_head,
                reviewer=deletion_receipt.payload["reviewer"],
            )

    for row_id in ROW_IDS:
        row = rows[row_id]
        expected_present = row.state != "legacy_deleted"
        for index, target in enumerate(row.targets):
            label = f"row {row_id} target[{index}]"
            present = target_present(repo_root, target, label)
            if expected_present and not present:
                raise GateError(f"{label}: legacy target is absent before legacy_deleted: {target.identity}")
            if not expected_present and present:
                raise GateError(f"{label}: legacy target remains after legacy_deleted: {target.identity}")

    raw_shared = require_array(manifest["sharedTargets"], "manifest.sharedTargets")
    shared_memberships: set[tuple[str, ...]] = set()
    for index, raw_shared_target in enumerate(raw_shared):
        label = f"manifest.sharedTargets[{index}]"
        shared = require_object(raw_shared_target, label)
        exact_keys(shared, {"rowIds", "target"}, {"rowIds", "target"}, label)
        row_ids = require_array(shared["rowIds"], f"{label}.rowIds")
        if len(row_ids) < 2 or any(not isinstance(row_id, str) for row_id in row_ids):
            raise GateError(f"{label}.rowIds: expected at least two row ids")
        if len(row_ids) != len(set(row_ids)):
            raise GateError(f"{label}.rowIds: duplicate row ids")
        unknown = sorted(set(row_ids) - set(rows))
        if unknown:
            raise GateError(f"{label}.rowIds: unknown rows: {', '.join(unknown)}")
        membership = tuple(sorted(row_ids))
        target = parse_target(shared["target"], f"{label}.target", roots)
        if target.role != "rollback_control":
            raise GateError(f"{label}.target must be a rollback_control")
        if target.identity in seen_targets:
            raise GateError(f"duplicate target: {target.identity}")
        seen_targets.add(target.identity)
        membership_target = membership + (repr(target.identity),)
        if membership_target in shared_memberships:
            raise GateError(f"{label}: duplicate shared target")
        shared_memberships.add(membership_target)
        expected_present = any(rows[row_id].state != "legacy_deleted" for row_id in row_ids)
        present = target_present(repo_root, target, f"{label}.target")
        if expected_present and not present:
            raise GateError(f"{label}: shared legacy target is absent while a member row is active")
        if not expected_present and present:
            raise GateError(f"{label}: shared legacy target remains after every member row is legacy_deleted")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--manifest", type=Path, default=Path("config/domain-core-legacy-deletion.json"))
    parser.add_argument("--base-ref", default=os.environ.get("DOMAIN_CORE_BASE_REF") or None)
    parser.add_argument("--verify-signed-evidence", action="store_true")
    parser.add_argument("--deletion-pull-request", type=int)
    parser.add_argument("--deletion-head")
    parser.add_argument("--trusted-root", type=Path, default=None)
    args = parser.parse_args(argv)
    try:
        verifier = SignedEvidenceVerifier() if args.verify_signed_evidence else None
        run_gate(
            args.repo_root,
            args.manifest,
            base_ref=args.base_ref,
            evidence_verifier=verifier,
            deletion_pull_request=args.deletion_pull_request,
            deletion_head=args.deletion_head,
            trusted_root=args.trusted_root,
        )
    except GateError as error:
        print(f"ERROR: domain-core legacy deletion gate failed: {error}", file=sys.stderr)
        return 1
    print("PASS: domain-core legacy deletion guard accepted the candidate")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
