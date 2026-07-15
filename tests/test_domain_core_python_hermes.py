from __future__ import annotations

import base64
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

REPO_ROOT = Path(__file__).resolve().parents[1]
PLUGIN_DIR = REPO_ROOT / "tools" / "hermes-platform-burnbar"
if str(PLUGIN_DIR) not in sys.path:
    sys.path.insert(0, str(PLUGIN_DIR))

from domain_core_hermes import DomainCoreIdentityError, HermesDomainAdapter
from legacy import hermes_ratchet_legacy as legacy

PACKAGE_DIR = PLUGIN_DIR / "vendor" / "openburnbar-domain-core-python"
FIXTURE_PATH = REPO_ROOT / "tests" / "fixtures" / "domain-core" / "hermes" / "v1" / "hermes-crypto-kat.json"


def _vector() -> tuple[dict[str, object], dict[str, object]]:
    fixture = json.loads(FIXTURE_PATH.read_text())
    vector = fixture["ratchet"]["prekey"]
    request = {
        "dh1": bytes(range(32)),
        "dh2": bytes(range(32, 64)),
        "dh3": bytes(range(64, 96)),
        "uid": vector["uid"],
        "client_id": vector["clientID"],
        "initiator_role": vector["initiatorRole"],
        "initiator_identity_public_key_base64": vector["initiatorIdentityPublicKeyBase64"],
        "responder_identity_public_key_base64": vector["responderIdentityPublicKeyBase64"],
        "initiator_signed_prekey_public_key_base64": vector["initiatorSignedPreKeyPublicKeyBase64"],
        "responder_signed_prekey_public_key_base64": vector["responderSignedPreKeyPublicKeyBase64"],
        "initiator_initial_ratchet_public_key_base64": vector["initiatorInitialRatchetPublicKeyBase64"],
    }
    return vector, request


def test_production_native_matches_frozen_prekey_vector_and_legacy() -> None:
    vector, request = _vector()
    expected = bytes.fromhex(str(vector["sharedSecretHex"]))
    assert legacy.ratchet_prekey_shared_secret(**request) == expected
    assert HermesDomainAdapter("rust").ratchet_prekey_shared_secret(**request) == expected


def test_rust_mode_calls_one_composite_ffi_operation() -> None:
    _, request = _vector()
    manifest = json.loads(
        (REPO_ROOT / "crates" / "openburnbar-domain-core" / "union-abi-manifest.json").read_text()
    )
    calls: list[object] = []
    fake = SimpleNamespace(
        domain_core_version=lambda: manifest["coreVersion"],
        domain_core_abi_version=lambda: manifest["abiVersion"],
        domain_core_source_fingerprint=lambda: manifest["sourceSha256"],
        HermesRatchetPrekeyRequest=lambda **values: values,
        hermes_ratchet_prekey_shared_secret=lambda value: calls.append(value) or b"rust-secret",
    )
    assert HermesDomainAdapter("rust", core=fake).ratchet_prekey_shared_secret(**request) == b"rust-secret"
    assert calls == [request]


def test_rust_mode_fails_closed_without_invoking_legacy(monkeypatch: pytest.MonkeyPatch) -> None:
    _, request = _vector()
    called = False

    def forbidden(**_request: object) -> bytes:
        nonlocal called
        called = True
        raise AssertionError("legacy must not run")

    monkeypatch.setattr(legacy, "ratchet_prekey_shared_secret", forbidden)
    request["dh1"] = b"short"
    with pytest.raises(Exception):
        HermesDomainAdapter("rust").ratchet_prekey_shared_secret(**request)
    assert called is False


def test_shadow_returns_legacy_and_emits_only_safe_metadata() -> None:
    vector, request = _vector()
    manifest = json.loads(
        (REPO_ROOT / "crates" / "openburnbar-domain-core" / "union-abi-manifest.json").read_text()
    )
    diagnostics: list[dict[str, object]] = []
    fake = SimpleNamespace(
        domain_core_version=lambda: manifest["coreVersion"],
        domain_core_abi_version=lambda: manifest["abiVersion"],
        domain_core_source_fingerprint=lambda: manifest["sourceSha256"],
        HermesRatchetPrekeyRequest=lambda **values: values,
        hermes_ratchet_prekey_shared_secret=lambda _value: b"mismatch",
    )
    expected = bytes.fromhex(str(vector["sharedSecretHex"]))
    actual = HermesDomainAdapter("shadow", core=fake, diagnostic=diagnostics.append).ratchet_prekey_shared_secret(
        **request
    )
    assert actual == expected
    assert diagnostics == [
        {
            "component": "hermes-plugin-domain-core",
            "operation": "ratchet-prekey-shared-secret",
            "category": "value-mismatch",
            "coreVersion": manifest["coreVersion"],
        }
    ]
    encoded = json.dumps(diagnostics)
    assert str(request["uid"]) not in encoded
    assert expected.hex() not in encoded
    assert bytes(request["dh1"]).hex() not in encoded


def test_invalid_public_point_and_noncanonical_base64_fail_closed() -> None:
    _, request = _vector()
    request["initiator_identity_public_key_base64"] = base64.b64encode(bytes(65)).decode()
    with pytest.raises(Exception):
        HermesDomainAdapter("rust").ratchet_prekey_shared_secret(**request)
    request["initiator_identity_public_key_base64"] = "not-base64"
    with pytest.raises(Exception):
        HermesDomainAdapter("rust").ratchet_prekey_shared_secret(**request)


def test_same_abi_wrong_source_is_rejected() -> None:
    _, request = _vector()
    manifest = json.loads(
        (REPO_ROOT / "crates" / "openburnbar-domain-core" / "union-abi-manifest.json").read_text()
    )
    fake = SimpleNamespace(
        domain_core_version=lambda: manifest["coreVersion"],
        domain_core_abi_version=lambda: manifest["abiVersion"],
        domain_core_source_fingerprint=lambda: "0" * 64,
    )
    with pytest.raises(DomainCoreIdentityError, match="loaded domain-core identity mismatch"):
        HermesDomainAdapter("rust", core=fake).ratchet_prekey_shared_secret(**request)


def test_native_digest_substitution_is_rejected(tmp_path: Path) -> None:
    _, request = _vector()
    package = tmp_path / "package"
    shutil.copytree(PACKAGE_DIR, package)
    receipt = json.loads((package / "openburnbar-domain-core-package-receipt.json").read_text())
    native = package / receipt["nativeFile"]
    native.write_bytes(native.read_bytes() + b"substitution")
    with pytest.raises(DomainCoreIdentityError, match="native digest mismatch"):
        HermesDomainAdapter("rust", package_dir=package).ratchet_prekey_shared_secret(**request)


def test_legacy_mode_does_not_require_native_package(tmp_path: Path) -> None:
    vector, request = _vector()
    assert HermesDomainAdapter("legacy", package_dir=tmp_path / "missing").ratchet_prekey_shared_secret(
        **request
    ) == bytes.fromhex(str(vector["sharedSecretHex"]))


def test_external_plugin_copy_loads_without_burnbar_source_tree(tmp_path: Path) -> None:
    vector, request = _vector()
    plugin = tmp_path / "burnbar"
    plugin.mkdir()
    shutil.copy2(PLUGIN_DIR / "domain_core_hermes.py", plugin / "domain_core_hermes.py")
    shutil.copytree(PLUGIN_DIR / "legacy", plugin / "legacy")
    shutil.copytree(PACKAGE_DIR, plugin / "vendor" / "openburnbar-domain-core-python")
    wire = {
        **request,
        "dh1": request["dh1"].hex(),
        "dh2": request["dh2"].hex(),
        "dh3": request["dh3"].hex(),
    }
    script = """
import json
import os
from domain_core_hermes import HermesDomainAdapter

request = json.loads(os.environ["REQUEST"])
for name in ("dh1", "dh2", "dh3"):
    request[name] = bytes.fromhex(request[name])
print(HermesDomainAdapter("rust").ratchet_prekey_shared_secret(**request).hex())
"""
    env = dict(os.environ)
    env["PYTHONPATH"] = str(plugin)
    env["REQUEST"] = json.dumps(wire)
    completed = subprocess.run(
        [sys.executable, "-c", script],
        cwd=tmp_path,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )
    assert completed.stdout.strip() == vector["sharedSecretHex"]
