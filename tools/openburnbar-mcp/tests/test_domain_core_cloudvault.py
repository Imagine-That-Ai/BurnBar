from __future__ import annotations

import base64
import importlib
import json
import shutil
import sys
from pathlib import Path
from types import SimpleNamespace

import pytest

MCP_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = MCP_DIR.parents[1]
if str(MCP_DIR) not in sys.path:
    sys.path.insert(0, str(MCP_DIR))

legacy = importlib.import_module("cloudvault_primitives_legacy")
domain_core_cloudvault = importlib.import_module("domain_core_cloudvault")
CloudVaultDomainAdapter = domain_core_cloudvault.CloudVaultDomainAdapter
DomainCoreIdentityError = domain_core_cloudvault.DomainCoreIdentityError

PACKAGE_DIR = MCP_DIR / "vendor" / "openburnbar-domain-core-python"
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "domain-core" / "cloudvault" / "v1"


def _rust() -> CloudVaultDomainAdapter:
    return CloudVaultDomainAdapter("rust", "rust")


def _mixed_mode_core() -> SimpleNamespace:
    manifest = json.loads((REPO_ROOT / "crates" / "openburnbar-domain-core" / "union-abi-manifest.json").read_text())
    return SimpleNamespace(
        domain_core_version=lambda: manifest["coreVersion"],
        domain_core_abi_version=lambda: manifest["abiVersion"],
        domain_core_source_fingerprint=lambda: manifest["sourceSha256"],
        cloud_vault_aad_v2=lambda *_args: "rust-aad",
        CloudVaultSearchOperation=SimpleNamespace(TOKEN="token"),
        CloudVaultSearchRequest=lambda **values: SimpleNamespace(**values),
        cloud_vault_search=lambda _request: SimpleNamespace(hashes=["rust-search"]),
    )


def test_production_package_identity_and_opaque_project_id_fixture() -> None:
    fixture = json.loads((FIXTURE_DIR / "opaque-identifiers-kat.json").read_text())
    key = bytes.fromhex(fixture["vaultKeyHex"])
    adapter = _rust()

    assert (
        adapter.project_memory_doc_id(fixture["projectMemory"]["slug"], key) == fixture["projectMemory"]["documentID"]
    )
    assert (
        adapter.project_memory_doc_id(fixture["unicode"]["projectSlug"], key) == fixture["unicode"]["projectDocumentID"]
    )


def test_production_binding_ignores_another_consumers_global_module(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    fixture = json.loads((FIXTURE_DIR / "opaque-identifiers-kat.json").read_text())
    key = bytes.fromhex(fixture["vaultKeyHex"])
    monkeypatch.setitem(
        sys.modules,
        "openburnbar_domain_ffi",
        SimpleNamespace(__file__="/untrusted/other-consumer/openburnbar_domain_ffi.py"),
    )
    assert (
        _rust().project_memory_doc_id(fixture["projectMemory"]["slug"], key) == fixture["projectMemory"]["documentID"]
    )


def test_aad_and_fixed_keyed_hash_canonical_fixtures() -> None:
    fixture = json.loads((FIXTURE_DIR / "cloudvault-deterministic-kat.json").read_text())
    adapter = _rust()
    for vector in fixture["aad"]:
        assert (
            adapter.aad_context(
                vector["uid"],
                vector["collection"],
                vector["docID"],
                vector["field"],
                vector["schemaVersion"],
                vector["purpose"],
            )
            == vector["v2"]
        )
        assert adapter.validate_aad(vector["v2"]) == vector["v2"]
    for vector in fixture["keyedHashes"]:
        if vector["purpose"] == "session-chunk":
            continue
        assert (
            adapter.keyed_hash(
                bytes.fromhex(vector["dataHex"]),
                bytes.fromhex(vector["keyHex"]),
                vector["purpose"],
            )
            == vector["hex"]
        )


def test_token_and_semantic_search_use_canonical_ordered_hashes() -> None:
    fixture = json.loads((FIXTURE_DIR / "cloudvault-search-contract.json").read_text())
    keys = {
        "primary": bytes.fromhex(fixture["primaryKeyHex"]),
        "alternate": bytes.fromhex(fixture["alternateKeyHex"]),
    }
    adapter = _rust()
    for vector in fixture["hashCases"]:
        if vector["operation"] not in {"token", "semantic"} or "text" not in vector:
            continue
        actual = (
            adapter.token_hashes(vector["text"], keys[vector["key"]], vector["limit"])
            if vector["operation"] == "token"
            else adapter.semantic_hashes(vector["text"], keys[vector["key"]], vector["limit"])
        )
        assert actual == vector["expected"], vector["id"]


def test_foundation_legacy_search_rust_routes_modes_independently(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "legacy")
    monkeypatch.setenv("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE", "rust")
    monkeypatch.setattr(legacy, "_cloud_vault_aad_context", lambda *_args: "legacy-aad")
    adapter = CloudVaultDomainAdapter(
        domain_core_cloudvault._mode_from_environment(),
        domain_core_cloudvault._mode_from_environment(domain_core_cloudvault._SEARCH_MODE_ENV),
        core=_mixed_mode_core(),
    )

    assert adapter.aad_context("uid", "collection", "doc", "field") == "legacy-aad"
    assert adapter.token_hashes("query", bytes(32)) == ["rust-search"]


def test_foundation_rust_search_legacy_routes_modes_independently(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "rust")
    monkeypatch.setenv("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE", "legacy")
    monkeypatch.setattr(
        domain_core_cloudvault.search_legacy,
        "_cloud_token_hashes",
        lambda *_args: ["legacy-search"],
    )
    adapter = CloudVaultDomainAdapter(
        domain_core_cloudvault._mode_from_environment(),
        domain_core_cloudvault._mode_from_environment(domain_core_cloudvault._SEARCH_MODE_ENV),
        core=_mixed_mode_core(),
    )

    assert adapter.aad_context("uid", "collection", "doc", "field") == "rust-aad"
    assert adapter.token_hashes("query", bytes(32)) == ["legacy-search"]


def test_sealed_text_and_blob_cross_open_canonical_aes_fixture() -> None:
    fixture = json.loads((FIXTURE_DIR / "cloudvault-deterministic-kat.json").read_text())
    vector = fixture["aesGcm"][1]
    key = bytes.fromhex(vector["keyHex"])
    nonce = bytes.fromhex(vector["nonceHex"])
    ciphertext = bytes.fromhex(vector["ciphertextHex"])
    tag = bytes.fromhex(vector["tagHex"])
    aad = bytes.fromhex(vector["aadHex"]).decode()
    plaintext = bytes.fromhex(vector["plaintextHex"])
    adapter = _rust()
    text_envelope = {
        "schemaVersion": 2,
        "algorithm": "AES-256-GCM",
        "nonce": base64.b64encode(nonce).decode(),
        "ciphertext": base64.b64encode(ciphertext).decode(),
        "tag": base64.b64encode(tag).decode(),
        "aad": aad,
    }
    assert adapter.open_sealed_text(text_envelope, key, aad) == plaintext.decode()

    blob_envelope = {
        "schemaVersion": 2,
        "algorithm": "AES-256-GCM",
        "sealedBoxBase64": vector["combinedBase64"],
        "plaintextHMAC": adapter.keyed_hash(plaintext, key, "blob-integrity"),
        "integrityHashVersion": 1,
        "aad": aad,
    }
    assert adapter.open_blob(blob_envelope, key, aad) == plaintext
    sealed = adapter.seal_blob(plaintext, key, key_version=7, aad_context=aad)
    assert sealed["keyVersion"] == 7
    assert adapter.open_blob(sealed, key, aad) == plaintext
    cloudvault_error = adapter._core().CloudVaultFfiError

    wrong_key = bytes([key[0] ^ 1]) + key[1:]
    with pytest.raises(cloudvault_error):
        adapter.open_blob(sealed, wrong_key, aad)
    with pytest.raises(ValueError, match="AAD context mismatch"):
        adapter.open_blob(sealed, key, aad.replace("|body|", "|title|"))
    tampered = dict(sealed)
    combined = bytearray(base64.b64decode(tampered["sealedBoxBase64"]))
    combined[-1] ^= 1
    tampered["sealedBoxBase64"] = base64.b64encode(combined).decode()
    with pytest.raises(cloudvault_error):
        adapter.open_blob(tampered, key, aad)


def test_rust_mode_fails_closed_without_invoking_legacy(monkeypatch: pytest.MonkeyPatch) -> None:
    called = False

    def forbidden(*_args, **_kwargs):
        nonlocal called
        called = True
        raise AssertionError("legacy must not run")

    monkeypatch.setattr(legacy, "_cloud_vault_project_memory_doc_id", forbidden)
    adapter = _rust()
    with pytest.raises(adapter._core().CloudVaultFfiError):
        adapter.project_memory_doc_id("slug", b"short")
    assert called is False


def test_shadow_returns_legacy_and_reports_only_safe_metadata() -> None:
    diagnostics: list[dict[str, object]] = []
    manifest = json.loads((REPO_ROOT / "crates" / "openburnbar-domain-core" / "union-abi-manifest.json").read_text())
    fake = SimpleNamespace(
        domain_core_version=lambda: manifest["coreVersion"],
        domain_core_abi_version=lambda: manifest["abiVersion"],
        domain_core_source_fingerprint=lambda: manifest["sourceSha256"],
        cloud_vault_project_memory_doc_id=lambda _slug, _key: "pm_mismatch",
    )
    adapter = CloudVaultDomainAdapter("shadow", "shadow", core=fake, diagnostic=diagnostics.append)
    key = bytes(range(32))
    expected = legacy._cloud_vault_project_memory_doc_id("secret-project", key)
    assert adapter.project_memory_doc_id("secret-project", key) == expected
    assert diagnostics == [
        {
            "component": "local-mcp-domain-core",
            "operation": "project-memory-doc-id",
            "category": "value-mismatch",
            "coreVersion": manifest["coreVersion"],
        }
    ]
    encoded = json.dumps(diagnostics)
    assert "secret-project" not in encoded
    assert key.hex() not in encoded
    assert expected not in encoded


def test_same_abi_wrong_source_is_rejected() -> None:
    manifest = json.loads((REPO_ROOT / "crates" / "openburnbar-domain-core" / "union-abi-manifest.json").read_text())
    fake = SimpleNamespace(
        domain_core_version=lambda: manifest["coreVersion"],
        domain_core_abi_version=lambda: manifest["abiVersion"],
        domain_core_source_fingerprint=lambda: "0" * 64,
    )
    with pytest.raises(DomainCoreIdentityError, match="loaded domain-core identity mismatch"):
        CloudVaultDomainAdapter("rust", "rust", core=fake).project_memory_doc_id("slug", bytes(32))


def test_native_digest_substitution_is_rejected(tmp_path: Path) -> None:
    package = tmp_path / "package"
    shutil.copytree(PACKAGE_DIR, package)
    receipt = json.loads((package / "openburnbar-domain-core-package-receipt.json").read_text())
    native = package / receipt["nativeFile"]
    native.write_bytes(native.read_bytes() + b"substitution")
    with pytest.raises(DomainCoreIdentityError, match="native digest mismatch"):
        CloudVaultDomainAdapter("rust", "rust", package_dir=package).project_memory_doc_id("slug", bytes(32))


def test_legacy_mode_does_not_require_native_package(tmp_path: Path) -> None:
    adapter = CloudVaultDomainAdapter("legacy", "legacy", package_dir=tmp_path / "absent")
    key = bytes(range(32))
    assert adapter.project_memory_doc_id("alpha", key) == legacy._cloud_vault_project_memory_doc_id("alpha", key)


def test_shadow_native_load_failure_returns_legacy_with_safe_diagnostic(tmp_path: Path) -> None:
    diagnostics: list[dict[str, object]] = []
    adapter = CloudVaultDomainAdapter(
        "shadow", "shadow", package_dir=tmp_path / "absent", diagnostic=diagnostics.append
    )
    key = bytes(range(32))
    expected = legacy._cloud_vault_project_memory_doc_id("private-project", key)
    assert adapter.project_memory_doc_id("private-project", key) == expected
    assert diagnostics[0]["category"] == "rust-error"
    encoded = json.dumps(diagnostics)
    assert "private-project" not in encoded
    assert key.hex() not in encoded
    assert expected not in encoded
