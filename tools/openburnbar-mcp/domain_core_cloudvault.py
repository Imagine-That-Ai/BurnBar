"""Authority adapter for local-MCP CloudVault pure transforms."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import platform
import re
import sys
from collections.abc import Callable
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, TypeVar, cast

import cloudvault_primitives_legacy as legacy
import cloudvault_search_legacy as search_legacy

OPENBURNBAR_CLOUD_VAULT_BLOB_AAD_CONTEXT = legacy.OPENBURNBAR_CLOUD_VAULT_BLOB_AAD_CONTEXT
_MODE_ENV = "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE"
_SEARCH_MODE_ENV = "OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE"
_PACKAGE_DIR = Path(__file__).resolve().parent / "vendor" / "openburnbar-domain-core-python"
_REPO_ROOT = Path(__file__).resolve().parents[2]
_MANIFEST_PATH = _REPO_ROOT / "crates" / "openburnbar-domain-core" / "union-abi-manifest.json"
_T = TypeVar("_T")
_MISSING = object()
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_RECEIPT_KEYS = {
    "schemaVersion",
    "coreVersion",
    "abiVersion",
    "sourceSha256",
    "platform",
    "architecture",
    "nativeFile",
    "nativeSha256",
    "bindingSha256",
}


class DomainCoreIdentityError(RuntimeError):
    """The packaged native core is absent, substituted, or source-incoherent."""


def _sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def _load_binding(binding_path: Path) -> Any:
    resolved = binding_path.resolve()
    module_name = f"_openburnbar_domain_ffi_{hashlib.sha256(str(resolved).encode()).hexdigest()}"
    existing = sys.modules.get(module_name)
    if existing is not None:
        if Path(existing.__file__).resolve() != resolved:
            raise DomainCoreIdentityError("domain-core Python module path mismatch")
        return existing
    spec = importlib.util.spec_from_file_location(module_name, resolved)
    if spec is None or spec.loader is None:
        raise DomainCoreIdentityError("domain-core Python binding has no loader")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
    except Exception as exc:
        sys.modules.pop(module_name, None)
        raise DomainCoreIdentityError("domain-core Python binding could not be loaded") from exc
    return module


def _mode_from_environment(name: str = _MODE_ENV) -> str:
    value = os.environ.get(name, "legacy").strip().lower()
    return value if value in {"legacy", "shadow", "rust"} else "legacy"


class CloudVaultDomainAdapter:
    def __init__(
        self,
        mode: str,
        search_mode: str,
        *,
        package_dir: Path = _PACKAGE_DIR,
        core: Any | None = None,
        diagnostic: Callable[[dict[str, Any]], None] | None = None,
    ) -> None:
        valid_modes = {"legacy", "shadow", "rust"}
        if mode not in valid_modes:
            raise ValueError("invalid CloudVault domain-core mode")
        if search_mode not in valid_modes:
            raise ValueError("invalid CloudVault search domain-core mode")
        self.mode = mode
        self.search_mode = search_mode
        self.package_dir = package_dir
        self._injected_core = core
        self._verified_core: Any | None = None
        self._diagnostic = diagnostic or self._write_diagnostic

    @staticmethod
    def _write_diagnostic(payload: dict[str, Any]) -> None:
        sys.stderr.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")

    def _core(self) -> Any:
        if self._verified_core is not None:
            return self._verified_core
        manifest = json.loads(_MANIFEST_PATH.read_text())
        receipt_path = self.package_dir / "openburnbar-domain-core-package-receipt.json"
        source_path = self.package_dir / "openburnbar-domain-core-source.sha256"
        binding_path = self.package_dir / "openburnbar_domain_ffi.py"
        try:
            receipt = json.loads(receipt_path.read_text())
            source_sha = source_path.read_text().strip()
            if set(receipt) != _RECEIPT_KEYS or receipt.get("schemaVersion") != 1:
                raise DomainCoreIdentityError("domain-core Python package receipt is invalid")
            native_file = receipt["nativeFile"]
            if not isinstance(native_file, str) or Path(native_file).name != native_file:
                raise DomainCoreIdentityError("domain-core Python native filename is invalid")
            native_path = self.package_dir / native_file
        except (OSError, KeyError, json.JSONDecodeError) as exc:
            raise DomainCoreIdentityError("domain-core Python package metadata is unavailable") from exc
        expected = (manifest["coreVersion"], manifest["abiVersion"], manifest["sourceSha256"])
        packaged = (receipt.get("coreVersion"), receipt.get("abiVersion"), receipt.get("sourceSha256"))
        if (
            packaged != expected
            or source_sha != expected[2]
            or _SHA256.fullmatch(source_sha) is None
            or _SHA256.fullmatch(str(receipt.get("nativeSha256", ""))) is None
            or _SHA256.fullmatch(str(receipt.get("bindingSha256", ""))) is None
        ):
            raise DomainCoreIdentityError("domain-core Python package source identity mismatch")
        if (
            receipt.get("platform") != platform.system().lower()
            or receipt.get("architecture") != platform.machine().lower()
        ):
            raise DomainCoreIdentityError("domain-core Python package host identity mismatch")
        if not native_path.is_file() or _sha256(native_path) != receipt.get("nativeSha256"):
            raise DomainCoreIdentityError("domain-core Python native digest mismatch")
        if not binding_path.is_file() or _sha256(binding_path) != receipt.get("bindingSha256"):
            raise DomainCoreIdentityError("domain-core Python binding digest mismatch")
        if self._injected_core is None:
            core = _load_binding(binding_path)
        else:
            core = self._injected_core
        loaded = (
            core.domain_core_version(),
            core.domain_core_abi_version(),
            core.domain_core_source_fingerprint(),
        )
        if loaded != expected:
            raise DomainCoreIdentityError("loaded domain-core identity mismatch")
        self._verified_core = core
        return core

    def _report(self, operation: str, category: str) -> None:
        version = "unavailable"
        if self._verified_core is not None:
            try:
                version = self._verified_core.domain_core_version()
            except Exception:
                version = "unavailable"
        self._diagnostic(
            {
                "component": "local-mcp-domain-core",
                "operation": operation,
                "category": category,
                "coreVersion": version,
            }
        )

    def _route(self, operation: str, old: Callable[[], _T], rust: Callable[[Any], _T]) -> _T:
        return self._route_with_mode(self.mode, operation, old, rust)

    def _route_search(self, operation: str, old: Callable[[], _T], rust: Callable[[Any], _T]) -> _T:
        return self._route_with_mode(self.search_mode, operation, old, rust)

    def _route_with_mode(self, mode: str, operation: str, old: Callable[[], _T], rust: Callable[[Any], _T]) -> _T:
        if mode == "legacy":
            return old()
        if mode == "rust":
            return rust(self._core())
        legacy_error: Exception | None = None
        old_value: object = _MISSING
        try:
            old_value = old()
        except Exception as exc:
            legacy_error = exc
        try:
            rust_value = rust(self._core())
        except Exception as exc:
            category = "both-error" if legacy_error and type(exc) is type(legacy_error) else "rust-error"
            self._report(operation, category)
            if legacy_error is not None:
                raise legacy_error from exc
            return cast(_T, old_value)
        if legacy_error is not None:
            self._report(operation, "legacy-error-rust-success")
            raise legacy_error
        if rust_value != old_value:
            self._report(operation, "value-mismatch")
        return cast(_T, old_value)

    @staticmethod
    def _aad_parts(value: str) -> tuple[str, str, str, str, int, str]:
        parts = value.split("|")
        if len(parts) != 7 or parts[0] != legacy.OPENBURNBAR_CLOUD_VAULT_AAD_PREFIX:
            raise ValueError("invalid CloudVault AAD context")
        try:
            schema_version = int(parts[5])
        except ValueError as exc:
            raise ValueError("invalid CloudVault AAD schema version") from exc
        return parts[1], parts[2], parts[3], parts[4], schema_version, parts[6]

    def aad_context(
        self, uid: str, collection: str, doc_id: str, field: str, schema_version: int = 2, purpose: str | None = None
    ) -> str:
        return self._route(
            "aad-v2",
            lambda: legacy._cloud_vault_aad_context(uid, collection, doc_id, field, schema_version, purpose),
            lambda core: core.cloud_vault_aad_v2(uid, collection, doc_id, field, schema_version, purpose),
        )

    def validate_aad(self, value: str) -> str:
        def rust(core: Any) -> str:
            uid, collection, doc_id, field, schema_version, purpose = self._aad_parts(value)
            canonical = core.cloud_vault_aad_v2(uid, collection, doc_id, field, schema_version, purpose)
            if canonical != value:
                raise ValueError("invalid CloudVault AAD context")
            return value

        return self._route("aad-validate", lambda: legacy._validate_cloud_vault_aad(value), rust)

    def keyed_hash(self, data: bytes, vault_key: bytes, purpose: str) -> str:
        names = {
            "blob-integrity": "BLOB_INTEGRITY",
            "session-body": "SESSION_BODY",
            "project-memory-content": "PROJECT_MEMORY_CONTENT",
        }

        def rust(core: Any) -> str:
            try:
                enum_value = getattr(core.CloudVaultHashPurpose, names[purpose])
            except KeyError as exc:
                raise ValueError("unsupported CloudVault keyed-hash purpose") from exc
            return core.cloud_vault_keyed_hash_hex(data, vault_key, enum_value)

        return self._route("keyed-hash", lambda: legacy._cloud_vault_hmac_hex(data, vault_key, purpose), rust)

    def project_memory_doc_id(self, slug: str, vault_key: bytes) -> str:
        return self._route(
            "project-memory-doc-id",
            lambda: legacy._cloud_vault_project_memory_doc_id(slug, vault_key),
            lambda core: core.cloud_vault_project_memory_doc_id(slug, vault_key),
        )

    def normalized_tokens(self, text: str) -> list[str]:
        return self._route_search(
            "search-analyze",
            lambda: search_legacy._cloud_normalized_tokens(text),
            lambda core: list(core.cloud_vault_search_analyze(text).normalized_tokens),
        )

    def token_hashes(self, text: str, vault_key: bytes, limit: int = 10) -> list[str]:
        return self._search(
            "token-search",
            "TOKEN",
            text,
            vault_key,
            limit,
            lambda: search_legacy._cloud_token_hashes(text, vault_key, limit),
        )

    def semantic_hashes(self, text: str, vault_key: bytes, limit: int = 12) -> list[str]:
        return self._search(
            "semantic-search",
            "SEMANTIC",
            text,
            vault_key,
            limit,
            lambda: search_legacy._cloud_semantic_hashes(text, vault_key, limit),
        )

    def _search(
        self, operation: str, enum_name: str, text: str, vault_key: bytes, limit: int, old: Callable[[], list[str]]
    ) -> list[str]:
        def rust(core: Any) -> list[str]:
            request = core.CloudVaultSearchRequest(
                operation=getattr(core.CloudVaultSearchOperation, enum_name),
                text=text,
                vault_key=vault_key,
                limit=limit,
            )
            return list(core.cloud_vault_search(request).hashes)

        return self._route_search(operation, old, rust)

    def open_sealed_text(self, envelope: dict[str, Any], vault_key: bytes, expected_aad: str | None = None) -> str:
        def rust(core: Any) -> str:
            if envelope.get("algorithm") != "AES-256-GCM":
                raise ValueError("unsupported sealed text algorithm")
            schema_version = int(envelope.get("schemaVersion") or 1)
            if schema_version >= 2 and (not expected_aad or envelope.get("aad") != expected_aad):
                raise ValueError("sealed text AAD context mismatch")
            return core.cloud_vault_aes_gcm_open_text_detached(
                core.cloud_vault_base64_decode_strict(str(envelope["nonce"])),
                core.cloud_vault_base64_decode_strict(str(envelope["ciphertext"])),
                core.cloud_vault_base64_decode_strict(str(envelope["tag"])),
                vault_key,
                expected_aad.encode("utf-8") if schema_version >= 2 and expected_aad else b"",
            )

        return self._route(
            "sealed-text-open", lambda: legacy._open_cloud_sealed_text(envelope, vault_key, expected_aad), rust
        )

    def open_blob(self, envelope: dict[str, Any], vault_key: bytes, expected_aad: str | None = None) -> bytes:
        def rust(core: Any) -> bytes:
            if envelope.get("algorithm") != "AES-256-GCM":
                raise ValueError("unsupported blob algorithm")
            combined = core.cloud_vault_base64_decode_strict(str(envelope["sealedBoxBase64"]))
            if len(combined) <= 28:
                raise ValueError("encrypted blob envelope is too short")
            schema_version = int(envelope.get("schemaVersion") or 1)
            aad = b""
            if schema_version >= 2:
                envelope_aad = str(envelope.get("aad", ""))
                if envelope_aad != OPENBURNBAR_CLOUD_VAULT_BLOB_AAD_CONTEXT:
                    if not expected_aad or envelope_aad != expected_aad:
                        raise ValueError("encrypted blob AAD context mismatch")
                    self.validate_aad(expected_aad)
                    aad = expected_aad.encode("utf-8")
            plaintext = core.cloud_vault_aes_gcm_open_combined(combined, vault_key, aad)
            if schema_version >= 2:
                if int(envelope.get("integrityHashVersion") or 0) != 1:
                    raise ValueError("encrypted blob integrity version mismatch")
                actual = core.cloud_vault_keyed_hash_hex(
                    plaintext, vault_key, core.CloudVaultHashPurpose.BLOB_INTEGRITY
                )
                if actual != str(envelope.get("plaintextHMAC", "")):
                    raise ValueError("encrypted blob HMAC mismatch")
            elif core.cloud_vault_sha256_hex(plaintext) != str(envelope.get("plaintextSHA256", "")):
                raise ValueError("encrypted blob SHA-256 mismatch")
            return plaintext

        return self._route(
            "blob-open", lambda: legacy._open_cloud_blob_envelope(envelope, vault_key, expected_aad), rust
        )

    def seal_blob(
        self, plaintext: bytes, vault_key: bytes, key_version: int = 1, aad_context: str | None = None
    ) -> dict[str, Any]:
        nonce = os.urandom(12)
        created_at = datetime.now(UTC).isoformat().replace("+00:00", "Z")

        def old() -> dict[str, Any]:
            return legacy._seal_cloud_blob_envelope(
                plaintext, vault_key, key_version, aad_context, nonce=nonce, created_at=created_at
            )

        def rust(core: Any) -> dict[str, Any]:
            if aad_context:
                self.validate_aad(aad_context)
            aad = aad_context.encode("utf-8") if aad_context else b""
            combined = core.cloud_vault_aes_gcm_seal_combined(plaintext, vault_key, nonce, aad)
            return {
                "schemaVersion": 2,
                "algorithm": "AES-256-GCM",
                "keyVersion": int(key_version),
                "plaintextHMAC": core.cloud_vault_keyed_hash_hex(
                    plaintext, vault_key, core.CloudVaultHashPurpose.BLOB_INTEGRITY
                ),
                "integrityHashVersion": 1,
                "sealedBoxBase64": core.cloud_vault_base64_encode(combined),
                "createdAt": created_at,
                "aad": aad_context or OPENBURNBAR_CLOUD_VAULT_BLOB_AAD_CONTEXT,
            }

        return self._route("blob-seal", old, rust)


_PRODUCTION = CloudVaultDomainAdapter(
    _mode_from_environment(),
    _mode_from_environment(_SEARCH_MODE_ENV),
)


def _cloud_vault_aad_context(
    uid: str, collection: str, doc_id: str, field: str, schema_version: int = 2, purpose: str | None = None
) -> str:
    return _PRODUCTION.aad_context(uid, collection, doc_id, field, schema_version, purpose)


def _validate_cloud_vault_aad(value: str) -> str:
    return _PRODUCTION.validate_aad(value)


def _cloud_vault_hmac_hex(data: bytes, vault_key: bytes, purpose: str) -> str:
    return _PRODUCTION.keyed_hash(data, vault_key, purpose)


def _cloud_vault_project_memory_doc_id(project_slug: str, vault_key: bytes) -> str:
    return _PRODUCTION.project_memory_doc_id(project_slug, vault_key)


def _cloud_normalized_tokens(text: str) -> list[str]:
    return _PRODUCTION.normalized_tokens(text)


def _cloud_token_hashes(text: str, vault_key: bytes, limit: int = 10) -> list[str]:
    return _PRODUCTION.token_hashes(text, vault_key, limit)


def _cloud_semantic_hashes(text: str, vault_key: bytes, limit: int = 12) -> list[str]:
    return _PRODUCTION.semantic_hashes(text, vault_key, limit)


def _open_cloud_sealed_text(envelope: dict[str, Any], vault_key: bytes, expected_aad: str | None = None) -> str:
    return _PRODUCTION.open_sealed_text(envelope, vault_key, expected_aad)


def _open_cloud_blob_envelope(envelope: dict[str, Any], vault_key: bytes, expected_aad: str | None = None) -> bytes:
    return _PRODUCTION.open_blob(envelope, vault_key, expected_aad)


def _seal_cloud_blob_envelope(
    plaintext: bytes, vault_key: bytes, key_version: int = 1, aad_context: str | None = None
) -> dict[str, Any]:
    return _PRODUCTION.seal_blob(plaintext, vault_key, key_version, aad_context)
