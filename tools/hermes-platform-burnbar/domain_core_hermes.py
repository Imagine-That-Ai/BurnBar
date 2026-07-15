"""Authority adapter for the external Hermes plugin's portable transforms."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import platform
import re
import sys
from pathlib import Path
from typing import Any, Callable, TypeVar, cast

try:
    from .legacy import hermes_ratchet_legacy as legacy
except ImportError:
    from legacy import hermes_ratchet_legacy as legacy

_MODE_ENV = "OPENBURNBAR_DOMAIN_CORE_HERMES_MODE"
_PACKAGE_DIR = Path(__file__).resolve().parent / "vendor" / "openburnbar-domain-core-python"
_T = TypeVar("_T")
_MISSING = object()
_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_EXPECTED_CORE_IDENTITY = (
    "0.1.0",
    3,
    "52f84b43c77131e2536a8dde4b366923fbcc66eb9c11baf0cac8c3d5f93f91e1",
)
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


def _mode_from_environment() -> str:
    value = os.environ.get(_MODE_ENV, "legacy").strip().lower()
    return value if value in {"legacy", "shadow", "rust"} else "legacy"


class HermesDomainAdapter:
    def __init__(
        self,
        mode: str,
        *,
        package_dir: Path = _PACKAGE_DIR,
        core: Any | None = None,
        diagnostic: Callable[[dict[str, Any]], None] | None = None,
    ) -> None:
        if mode not in {"legacy", "shadow", "rust"}:
            raise ValueError("invalid Hermes domain-core mode")
        self.mode = mode
        self.package_dir = package_dir
        self._injected_core = core
        self._verified_core: Any | None = None
        self._diagnostic = diagnostic or self._write_diagnostic

    @staticmethod
    def from_environment() -> "HermesDomainAdapter":
        return HermesDomainAdapter(_mode_from_environment())

    @staticmethod
    def _write_diagnostic(payload: dict[str, Any]) -> None:
        sys.stderr.write(json.dumps(payload, sort_keys=True, separators=(",", ":")) + "\n")

    def _core(self) -> Any:
        if self._verified_core is not None:
            return self._verified_core
        try:
            receipt = json.loads(
                (self.package_dir / "openburnbar-domain-core-package-receipt.json").read_text()
            )
            source_sha = (self.package_dir / "openburnbar-domain-core-source.sha256").read_text().strip()
            binding_path = self.package_dir / "openburnbar_domain_ffi.py"
            if set(receipt) != _RECEIPT_KEYS or receipt.get("schemaVersion") != 1:
                raise DomainCoreIdentityError("domain-core Python package receipt is invalid")
            native_file = receipt["nativeFile"]
            if not isinstance(native_file, str) or Path(native_file).name != native_file:
                raise DomainCoreIdentityError("domain-core Python native filename is invalid")
            native_path = self.package_dir / native_file
        except DomainCoreIdentityError:
            raise
        except (OSError, KeyError, json.JSONDecodeError) as exc:
            raise DomainCoreIdentityError("domain-core Python package metadata is unavailable") from exc
        expected = _EXPECTED_CORE_IDENTITY
        packaged = (receipt.get("coreVersion"), receipt.get("abiVersion"), receipt.get("sourceSha256"))
        if (
            packaged != expected
            or source_sha != expected[2]
            or _SHA256.fullmatch(source_sha) is None
            or _SHA256.fullmatch(str(receipt.get("nativeSha256", ""))) is None
            or _SHA256.fullmatch(str(receipt.get("bindingSha256", ""))) is None
        ):
            raise DomainCoreIdentityError("domain-core Python package source identity mismatch")
        if receipt.get("platform") != platform.system().lower() or receipt.get("architecture") != platform.machine().lower():
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
                pass
        self._diagnostic(
            {
                "component": "hermes-plugin-domain-core",
                "operation": operation,
                "category": category,
                "coreVersion": version,
            }
        )

    def _route(self, operation: str, old: Callable[[], _T], rust: Callable[[Any], _T]) -> _T:
        if self.mode == "legacy":
            return old()
        if self.mode == "rust":
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
                raise legacy_error
            return cast(_T, old_value)
        if legacy_error is not None:
            self._report(operation, "legacy-error-rust-success")
            raise legacy_error
        if rust_value != old_value:
            self._report(operation, "value-mismatch")
        return cast(_T, old_value)

    def ratchet_prekey_shared_secret(
        self,
        *,
        dh1: bytes,
        dh2: bytes,
        dh3: bytes,
        uid: str,
        client_id: str,
        initiator_role: str,
        initiator_identity_public_key_base64: str,
        responder_identity_public_key_base64: str,
        initiator_signed_prekey_public_key_base64: str,
        responder_signed_prekey_public_key_base64: str,
        initiator_initial_ratchet_public_key_base64: str,
    ) -> bytes:
        request = {
            "dh1": dh1,
            "dh2": dh2,
            "dh3": dh3,
            "uid": uid,
            "client_id": client_id,
            "initiator_role": initiator_role,
            "initiator_identity_public_key_base64": initiator_identity_public_key_base64,
            "responder_identity_public_key_base64": responder_identity_public_key_base64,
            "initiator_signed_prekey_public_key_base64": initiator_signed_prekey_public_key_base64,
            "responder_signed_prekey_public_key_base64": responder_signed_prekey_public_key_base64,
            "initiator_initial_ratchet_public_key_base64": initiator_initial_ratchet_public_key_base64,
        }

        def rust(core: Any) -> bytes:
            return core.hermes_ratchet_prekey_shared_secret(core.HermesRatchetPrekeyRequest(**request))

        return self._route(
            "ratchet-prekey-shared-secret",
            lambda: legacy.ratchet_prekey_shared_secret(**request),
            rust,
        )
