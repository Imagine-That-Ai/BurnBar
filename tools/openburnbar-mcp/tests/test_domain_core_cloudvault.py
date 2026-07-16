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
search_legacy = importlib.import_module("cloudvault_search_legacy")
domain_core_cloudvault = importlib.import_module("domain_core_cloudvault")
CloudVaultDomainAdapter = domain_core_cloudvault.CloudVaultDomainAdapter
DomainCoreIdentityError = domain_core_cloudvault.DomainCoreIdentityError

PACKAGE_DIR = MCP_DIR / "vendor" / "openburnbar-domain-core-python"
FIXTURE_DIR = REPO_ROOT / "tests" / "fixtures" / "domain-core" / "cloudvault" / "v1"


def _rust() -> CloudVaultDomainAdapter:
    return CloudVaultDomainAdapter("rust")


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
    adapter = CloudVaultDomainAdapter("shadow", core=fake, diagnostic=diagnostics.append)
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
        CloudVaultDomainAdapter("rust", core=fake).project_memory_doc_id("slug", bytes(32))


def test_native_digest_substitution_is_rejected(tmp_path: Path) -> None:
    package = tmp_path / "package"
    shutil.copytree(PACKAGE_DIR, package)
    receipt = json.loads((package / "openburnbar-domain-core-package-receipt.json").read_text())
    native = package / receipt["nativeFile"]
    native.write_bytes(native.read_bytes() + b"substitution")
    with pytest.raises(DomainCoreIdentityError, match="native digest mismatch"):
        CloudVaultDomainAdapter("rust", package_dir=package).project_memory_doc_id("slug", bytes(32))


def test_legacy_mode_does_not_require_native_package(tmp_path: Path) -> None:
    adapter = CloudVaultDomainAdapter("legacy", package_dir=tmp_path / "absent")
    key = bytes(range(32))
    assert adapter.project_memory_doc_id("alpha", key) == legacy._cloud_vault_project_memory_doc_id("alpha", key)


def test_shadow_native_load_failure_returns_legacy_with_safe_diagnostic(tmp_path: Path) -> None:
    diagnostics: list[dict[str, object]] = []
    adapter = CloudVaultDomainAdapter("shadow", package_dir=tmp_path / "absent", diagnostic=diagnostics.append)
    key = bytes(range(32))
    expected = legacy._cloud_vault_project_memory_doc_id("private-project", key)
    assert adapter.project_memory_doc_id("private-project", key) == expected
    assert diagnostics[0]["category"] == "rust-error"
    encoded = json.dumps(diagnostics)
    assert "private-project" not in encoded
    assert key.hex() not in encoded
    assert expected not in encoded


# ---------------------------------------------------------------------------
# Negative-control tests: search-specific mode overrides aggregate mode.
#
# Before the fix, search operations read the aggregate mode, so the
# ``search_mode`` keyword argument does not exist and construction raises
# ``TypeError``.  After the fix, search operations read ``search_mode``
# independently.  Each test below proves routing by forbidding the wrong
# path: when ``search_mode="rust"`` the legacy transform must NOT run and
# the Rust path must return a real result, and when ``search_mode="legacy"``
# the adapter returns the legacy golden vectors.  This proves correct
# routing regardless of whether the native package is present, so a test
# FAILS before the fix (TypeError / wrong routing) and PASSES after.
# ---------------------------------------------------------------------------


def test_search_mode_rust_overrides_aggregate_legacy_for_token_search(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """SEARCH_MODE=rust routes token search to Rust even when aggregate mode is legacy.

    Before fix: ``search_mode`` kwarg does not exist → ``TypeError`` at construction.
    After fix:  search uses ``search_mode="rust"`` → legacy must not run; Rust returns hashes.
    """

    def forbidden(*_args: object, **_kwargs: object) -> list[str]:
        raise AssertionError("legacy token search must not run when search_mode=rust")

    monkeypatch.setattr(search_legacy, "_cloud_token_hashes", forbidden)
    adapter = CloudVaultDomainAdapter("legacy", search_mode="rust")
    result = adapter.token_hashes("private-query", bytes(range(32)), 10)
    assert result, "Rust token search must return hashes"


def test_search_mode_rust_overrides_aggregate_legacy_for_semantic_search(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """SEARCH_MODE=rust routes semantic search to Rust even when aggregate mode is legacy.

    Before fix: ``search_mode`` kwarg does not exist → ``TypeError`` at construction.
    After fix:  search uses ``search_mode="rust"`` → legacy must not run; Rust returns hashes.
    """

    def forbidden(*_args: object, **_kwargs: object) -> list[str]:
        raise AssertionError("legacy semantic search must not run when search_mode=rust")

    monkeypatch.setattr(search_legacy, "_cloud_semantic_hashes", forbidden)
    adapter = CloudVaultDomainAdapter("legacy", search_mode="rust")
    result = adapter.semantic_hashes("private-query", bytes(range(32)), 12)
    assert result, "Rust semantic search must return hashes"


def test_search_mode_rust_overrides_aggregate_legacy_for_normalized_tokens(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """SEARCH_MODE=rust routes search-analyze to Rust even when aggregate mode is legacy.

    Before fix: ``search_mode`` kwarg does not exist → ``TypeError`` at construction.
    After fix:  search uses ``search_mode="rust"`` → legacy must not run; Rust returns tokens.
    """

    def forbidden(*_args: object, **_kwargs: object) -> list[str]:
        raise AssertionError("legacy normalized tokens must not run when search_mode=rust")

    monkeypatch.setattr(search_legacy, "_cloud_normalized_tokens", forbidden)
    adapter = CloudVaultDomainAdapter("legacy", search_mode="rust")
    result = adapter.normalized_tokens("private-query")
    assert result, "Rust normalized tokens must return a list"


def test_search_mode_legacy_overrides_aggregate_rust_for_search() -> None:
    """SEARCH_MODE=legacy routes search to legacy even when aggregate mode is rust.

    Before fix: ``search_mode`` kwarg does not exist → ``TypeError`` at construction.
    After fix:  search uses ``search_mode="legacy"`` → returns legacy hashes (no native needed).
    """
    adapter = CloudVaultDomainAdapter("rust", search_mode="legacy")
    key = bytes(range(32))
    expected = search_legacy._cloud_token_hashes("The QUICK, quick fox and X.", key, 250)
    assert adapter.token_hashes("The QUICK, quick fox and X.", key, 250) == expected


# ---------------------------------------------------------------------------
# Independence proofs: non-search operations ignore search_mode.
#
# These construct adapters with ``search_mode`` set to a value that differs
# from the aggregate ``mode`` and verify that non-search operations route on
# the aggregate mode, not search_mode.  Before the fix, ``search_mode`` kwarg
# does not exist → ``TypeError``.  After the fix, the assertions prove that
# AAD, keyed hash, project-memory doc id, and blob operations remain on the
# aggregate mode.
# ---------------------------------------------------------------------------


def test_aggregate_aad_ignores_search_mode() -> None:
    """AAD routes on aggregate mode, not search_mode.

    Before fix: ``search_mode`` kwarg does not exist → ``TypeError``.
    After fix:  AAD uses ``mode="legacy"`` → returns legacy AAD (no native needed).
    """
    adapter = CloudVaultDomainAdapter("legacy", search_mode="rust")
    expected = legacy._cloud_vault_aad_context("private-user", "sessions", "doc", "body", 2, "body")
    assert adapter.aad_context("private-user", "sessions", "doc", "body", 2, "body") == expected


def test_aggregate_keyed_hash_ignores_search_mode() -> None:
    """Keyed hash routes on aggregate mode, not search_mode.

    Before fix: ``search_mode`` kwarg does not exist → ``TypeError``.
    After fix:  keyed hash uses ``mode="legacy"`` → returns legacy HMAC (no native needed).
    """
    adapter = CloudVaultDomainAdapter("legacy", search_mode="rust")
    key = bytes(range(32))
    expected = legacy._cloud_vault_hmac_hex(b"private-data", key, "blob-integrity")
    assert adapter.keyed_hash(b"private-data", key, "blob-integrity") == expected


def test_aggregate_project_memory_doc_id_ignores_search_mode() -> None:
    """Project-memory doc id routes on aggregate mode, not search_mode.

    Before fix: ``search_mode`` kwarg does not exist → ``TypeError``.
    After fix:  project-memory doc id uses ``mode="legacy"`` → returns legacy doc id (no native needed).
    """
    adapter = CloudVaultDomainAdapter("legacy", search_mode="rust")
    key = bytes(range(32))
    expected = legacy._cloud_vault_project_memory_doc_id("private-project", key)
    assert adapter.project_memory_doc_id("private-project", key) == expected


def test_aggregate_operations_use_rust_mode_when_search_mode_is_legacy(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Non-search operations use aggregate rust mode even when search_mode is legacy.

    Before fix: ``search_mode`` kwarg does not exist → ``TypeError``.
    After fix:  project-memory doc id uses ``mode="rust"`` → legacy must not run; Rust returns a doc id.
    """

    def forbidden(*_args: object, **_kwargs: object) -> str:
        raise AssertionError("legacy project-memory doc id must not run when aggregate mode=rust")

    monkeypatch.setattr(legacy, "_cloud_vault_project_memory_doc_id", forbidden)
    adapter = CloudVaultDomainAdapter("rust", search_mode="legacy")
    result = adapter.project_memory_doc_id("slug", bytes(32))
    assert result, "Rust project-memory doc id must return a value"


def test_combined_search_legacy_and_aggregate_rust_route_independently(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """Search uses search_mode=legacy while aggregate ops use mode=rust, independently.

    Before fix: ``search_mode`` kwarg does not exist → ``TypeError``.
    After fix:  search returns legacy hashes; project-memory doc id routes to Rust (legacy must not run).
    """
    adapter = CloudVaultDomainAdapter("rust", search_mode="legacy")
    key = bytes(range(32))
    # Search uses search_mode=legacy → succeeds with legacy hashes
    expected = search_legacy._cloud_token_hashes("The QUICK, quick fox and X.", key, 250)
    assert adapter.token_hashes("The QUICK, quick fox and X.", key, 250) == expected
    # Non-search uses mode=rust → legacy must not run; Rust returns a doc id

    def forbidden(*_args: object, **_kwargs: object) -> str:
        raise AssertionError("legacy project-memory doc id must not run when aggregate mode=rust")

    monkeypatch.setattr(legacy, "_cloud_vault_project_memory_doc_id", forbidden)
    result = adapter.project_memory_doc_id("slug", key)
    assert result, "Rust project-memory doc id must return a value"


def test_env_var_search_mode_rust_overrides_aggregate_legacy(monkeypatch: pytest.MonkeyPatch) -> None:
    """Env-var SEARCH_MODE=rust routes search to Rust even when MODE=legacy.

    Before fix: ``_search_mode_from_environment`` does not exist → ``AttributeError``.
    After fix:  search uses env SEARCH_MODE=rust → legacy must not run; Rust returns hashes.
    """
    monkeypatch.setenv("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "legacy")
    monkeypatch.setenv("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE", "rust")
    adapter = CloudVaultDomainAdapter(
        domain_core_cloudvault._mode_from_environment(),
        search_mode=domain_core_cloudvault._search_mode_from_environment(),
    )

    def forbidden(*_args: object, **_kwargs: object) -> list[str]:
        raise AssertionError("legacy token search must not run when env SEARCH_MODE=rust")

    monkeypatch.setattr(search_legacy, "_cloud_token_hashes", forbidden)
    result = adapter.token_hashes("private-query", bytes(range(32)), 10)
    assert result, "Rust token search must return hashes"


def test_env_var_search_mode_legacy_overrides_aggregate_rust(monkeypatch: pytest.MonkeyPatch) -> None:
    """Env-var SEARCH_MODE=legacy routes search to legacy even when MODE=rust.

    Before fix: ``_search_mode_from_environment`` does not exist → ``AttributeError``.
    After fix:  search uses env SEARCH_MODE=legacy → returns legacy hashes (no native needed).
    """
    monkeypatch.setenv("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_MODE", "rust")
    monkeypatch.setenv("OPENBURNBAR_DOMAIN_CORE_CLOUDVAULT_SEARCH_MODE", "legacy")
    adapter = CloudVaultDomainAdapter(
        domain_core_cloudvault._mode_from_environment(),
        search_mode=domain_core_cloudvault._search_mode_from_environment(),
    )
    key = bytes(range(32))
    expected = search_legacy._cloud_token_hashes("The QUICK, quick fox and X.", key, 250)
    assert adapter.token_hashes("The QUICK, quick fox and X.", key, 250) == expected
