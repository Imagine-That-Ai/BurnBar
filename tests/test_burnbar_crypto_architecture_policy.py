import copy
import json
from pathlib import Path

from scripts.ci.check_burnbar_crypto_architecture_policy import (
    ADR_DOC,
    BACKEND_POLICY_LIB,
    BACKEND_POLICY_NEEDLES,
    CLAIM_MAPPING,
    DEFAULT_MANIFEST,
    LIBSIGNAL_BEARING_MODELS,
    PLATFORM_CRYPTO_CAPABILITIES,
    check_policy,
    load_policy,
    validate_crypto_architecture_policy,
)


def _canonical_manifest() -> dict[str, object]:
    return {
        "schemaVersion": 1,
        "platforms": copy.deepcopy(PLATFORM_CRYPTO_CAPABILITIES),
        "libsignalBearingModels": list(LIBSIGNAL_BEARING_MODELS),
        "claims": dict(CLAIM_MAPPING),
    }


def _materialize_dependencies(tmp_path: Path) -> None:
    """Create the ADR and a backend policy lib carrying the needle symbols so
    that only the mutated invariant produces an error."""
    adr_path = tmp_path / ADR_DOC
    adr_path.parent.mkdir(parents=True, exist_ok=True)
    # The ADR must render every canonical claim string (the checker binds the
    # human-readable record to the enforced vocabulary).
    adr_path.write_text(
        "# ADR-001 Crypto Architecture\n\n"
        + "\n".join(f"- {model}: {claim}" for model, claim in CLAIM_MAPPING.items())
        + "\n",
        encoding="utf-8",
    )

    lib_path = tmp_path / BACKEND_POLICY_LIB
    lib_path.parent.mkdir(parents=True, exist_ok=True)
    lib_path.write_text(
        "// canonical matrix encoded in code\n"
        + "\n".join(f"const {needle} = null;" for needle in BACKEND_POLICY_NEEDLES)
        + "\n",
        encoding="utf-8",
    )


def _has_error(errors: list[str], needle: str) -> bool:
    return any(needle in error for error in errors)


def test_real_manifest_passes() -> None:
    # The shipped manifest plus the real ADR and backend policy library must
    # pass the gate with zero errors.
    errors = check_policy()

    assert errors == [], errors


def test_real_manifest_matches_canonical_matrix() -> None:
    # Sanity: the on-disk manifest equals the hardcoded canonical matrix.
    data = load_policy(DEFAULT_MANIFEST)

    assert data["platforms"] == PLATFORM_CRYPTO_CAPABILITIES


def test_canonical_fixture_passes(tmp_path: Path) -> None:
    _materialize_dependencies(tmp_path)
    data = _canonical_manifest()

    errors = validate_crypto_architecture_policy(data, repo_root=tmp_path)

    assert errors == [], errors


def test_ios_libsignal_double_ratchet_on_d2d_fails(tmp_path: Path) -> None:
    # Invariant 1 + 2: linking libsignal on iOS device_to_device must fail.
    _materialize_dependencies(tmp_path)
    data = _canonical_manifest()
    data["platforms"]["ios"]["device_to_device"] = "libsignal-double-ratchet"  # type: ignore[index]

    errors = validate_crypto_architecture_policy(data, repo_root=tmp_path)

    assert errors != []
    assert _has_error(errors, "ios.device_to_device is libsignal-bearing model")
    assert _has_error(errors, "ios.device_to_device must be 'none-satellite'")


def test_ios_libsignal_at_rest_seal_fails(tmp_path: Path) -> None:
    # Invariant 1: iOS at_rest must use CryptoKit, never libsignal HPKE sealing.
    _materialize_dependencies(tmp_path)
    data = _canonical_manifest()
    data["platforms"]["ios"]["at_rest"] = "libsignal-hpke-seal"  # type: ignore[index]

    errors = validate_crypto_architecture_policy(data, repo_root=tmp_path)

    assert _has_error(errors, "ios.at_rest is libsignal-bearing model 'libsignal-hpke-seal'")
    assert _has_error(errors, "platforms.ios.at_rest must be 'cryptokit-hpke-atrest'")


def test_at_rest_null_fails_closed(tmp_path: Path) -> None:
    # Regression: a present-but-null at_rest cell must NOT pass (was fail-open).
    for platform in ("ios", "backend", "macos"):
        _materialize_dependencies(tmp_path)
        data = _canonical_manifest()
        data["platforms"][platform]["at_rest"] = None  # type: ignore[index]

        errors = validate_crypto_architecture_policy(data, repo_root=tmp_path)

        assert _has_error(errors, f"platforms.{platform}.at_rest must be"), (platform, errors)
        assert _has_error(errors, f"INVARIANT VIOLATION: {platform}.at_rest must be"), (platform, errors)


def test_ios_new_libsignal_variant_caught_by_substring(tmp_path: Path) -> None:
    # A brand-new libsignal model string the explicit list doesn't enumerate must
    # still be caught by the libsignal-free guard, not only by matrix-equality.
    _materialize_dependencies(tmp_path)
    data = _canonical_manifest()
    data["platforms"]["ios"]["at_rest"] = "libsignal-x25519-session"  # type: ignore[index]

    errors = validate_crypto_architecture_policy(data, repo_root=tmp_path)

    assert _has_error(errors, "looks libsignal-bearing"), errors


def test_ios_unknown_model_fails_closed_via_allowlist(tmp_path: Path) -> None:
    # A non-libsignal but non-permitted iOS model must fail closed via the allowlist.
    _materialize_dependencies(tmp_path)
    data = _canonical_manifest()
    data["platforms"]["ios"]["at_rest"] = "mystery-experimental-seal"  # type: ignore[index]

    errors = validate_crypto_architecture_policy(data, repo_root=tmp_path)

    assert _has_error(errors, "is not in the iOS-permitted set"), errors


def test_libsignal_bearing_models_is_tamper_evident(tmp_path: Path) -> None:
    # Emptying/altering the manifest's libsignalBearingModels must fail (the
    # field is load-bearing, not decorative).
    _materialize_dependencies(tmp_path)
    data = _canonical_manifest()
    data["libsignalBearingModels"] = []  # type: ignore[index]

    errors = validate_crypto_architecture_policy(data, repo_root=tmp_path)

    assert _has_error(errors, "libsignalBearingModels must equal"), errors


def test_adr_missing_canonical_claim_fails(tmp_path: Path) -> None:
    # If the ADR drops/renames a canonical claim string, the gate must catch it.
    _materialize_dependencies(tmp_path)
    adr_path = tmp_path / ADR_DOC
    adr_path.write_text("# ADR-001 Crypto Architecture\n(no claim strings here)\n", encoding="utf-8")
    data = _canonical_manifest()

    errors = validate_crypto_architecture_policy(data, repo_root=tmp_path)

    assert _has_error(errors, "must render the canonical claim"), errors


def test_macos_device_to_device_must_be_libsignal(tmp_path: Path) -> None:
    # Invariant 2: real device<->device on Mac/Android/daemon is official Signal.
    _materialize_dependencies(tmp_path)
    data = _canonical_manifest()
    data["platforms"]["macos"]["device_to_device"] = "homegrown-double-ratchet"  # type: ignore[index]

    errors = validate_crypto_architecture_policy(data, repo_root=tmp_path)

    assert _has_error(
        errors, "macos.device_to_device must be 'libsignal-double-ratchet'"
    )


def test_backend_must_not_declare_device_to_device(tmp_path: Path) -> None:
    # Invariant 2: backend has NO device_to_device channel.
    _materialize_dependencies(tmp_path)
    data = _canonical_manifest()
    data["platforms"]["backend"]["device_to_device"] = "libsignal-double-ratchet"  # type: ignore[index]

    errors = validate_crypto_architecture_policy(data, repo_root=tmp_path)

    assert _has_error(errors, "backend must NOT declare a device_to_device channel")


def test_ai_gateway_libsignal_fails(tmp_path: Path) -> None:
    # Invariant 3: ai_gateway must be homegrown on every platform; libsignal there
    # is pointless because the gateway decrypts plaintext to run the model.
    _materialize_dependencies(tmp_path)
    data = _canonical_manifest()
    data["platforms"]["macos"]["ai_gateway"] = "libsignal-double-ratchet"  # type: ignore[index]

    errors = validate_crypto_architecture_policy(data, repo_root=tmp_path)

    assert _has_error(
        errors, "macos.ai_gateway must be 'homegrown-double-ratchet'"
    )


def test_ios_ai_gateway_libsignal_fails(tmp_path: Path) -> None:
    # Invariant 1 + 3: iOS ai_gateway must never be libsignal either.
    _materialize_dependencies(tmp_path)
    data = _canonical_manifest()
    data["platforms"]["ios"]["ai_gateway"] = "libsignal-hpke-seal"  # type: ignore[index]

    errors = validate_crypto_architecture_policy(data, repo_root=tmp_path)

    assert _has_error(errors, "ios.ai_gateway is libsignal-bearing model")
    assert _has_error(errors, "ios.ai_gateway must be 'homegrown-double-ratchet'")


def test_claims_must_be_present(tmp_path: Path) -> None:
    # Invariant 4: claim mapping must be present.
    _materialize_dependencies(tmp_path)
    data = _canonical_manifest()
    del data["claims"]

    errors = validate_crypto_architecture_policy(data, repo_root=tmp_path)

    assert _has_error(errors, "claims must be a JSON object")


def test_ios_must_never_map_to_signal_protocol_claim(tmp_path: Path) -> None:
    # Invariant 4: even if a checker bug let an iOS channel adopt the
    # "Signal Protocol" claim, the claim guard must catch it.
    _materialize_dependencies(tmp_path)
    data = _canonical_manifest()
    # Point an iOS channel at a model whose claim is "Signal Protocol".
    data["platforms"]["ios"]["at_rest"] = "libsignal-double-ratchet"  # type: ignore[index]

    errors = validate_crypto_architecture_policy(data, repo_root=tmp_path)

    assert _has_error(
        errors, "iOS must NEVER claim Signal Protocol"
    )


def test_claim_value_drift_fails(tmp_path: Path) -> None:
    # Invariant 4: claim text must match the canonical mapping exactly.
    _materialize_dependencies(tmp_path)
    data = _canonical_manifest()
    data["claims"]["cryptokit-hpke-atrest"] = "Signal Protocol"  # type: ignore[index]

    errors = validate_crypto_architecture_policy(data, repo_root=tmp_path)

    assert _has_error(errors, "claims.cryptokit-hpke-atrest must be")


def test_platforms_must_equal_canonical_matrix(tmp_path: Path) -> None:
    # Drift from the canonical matrix (extra platform) must fail.
    _materialize_dependencies(tmp_path)
    data = _canonical_manifest()
    data["platforms"]["windows"] = {  # type: ignore[index]
        "device_to_device": "libsignal-double-ratchet",
        "at_rest": "libsignal-hpke-seal",
        "ai_gateway": "homegrown-double-ratchet",
    }

    errors = validate_crypto_architecture_policy(data, repo_root=tmp_path)

    assert _has_error(errors, "platforms contains unknown platform(s): windows")


def test_missing_adr_fails(tmp_path: Path) -> None:
    # The ADR must exist alongside the manifest.
    data = _canonical_manifest()
    # Materialize only the backend lib, not the ADR.
    lib_path = tmp_path / BACKEND_POLICY_LIB
    lib_path.parent.mkdir(parents=True, exist_ok=True)
    lib_path.write_text(
        "\n".join(f"const {needle} = null;" for needle in BACKEND_POLICY_NEEDLES),
        encoding="utf-8",
    )

    errors = validate_crypto_architecture_policy(data, repo_root=tmp_path)

    assert _has_error(errors, f"architecture decision record is missing: {ADR_DOC}")


def test_missing_backend_policy_needles_fail(tmp_path: Path) -> None:
    # The backend policy library must encode the matrix symbols in code.
    adr_path = tmp_path / ADR_DOC
    adr_path.parent.mkdir(parents=True, exist_ok=True)
    adr_path.write_text("# ADR-001\n", encoding="utf-8")
    lib_path = tmp_path / BACKEND_POLICY_LIB
    lib_path.parent.mkdir(parents=True, exist_ok=True)
    lib_path.write_text("// empty\n", encoding="utf-8")
    data = _canonical_manifest()

    errors = validate_crypto_architecture_policy(data, repo_root=tmp_path)

    assert _has_error(errors, f"{BACKEND_POLICY_LIB} missing required symbol(s)")
    for needle in BACKEND_POLICY_NEEDLES:
        assert _has_error(errors, needle)


def test_missing_manifest_file_reports_clearly(tmp_path: Path) -> None:
    missing = tmp_path / "docs/security/crypto-architecture-policy.json"

    errors = check_policy(missing, repo_root=tmp_path)

    assert errors == [
        "crypto-architecture policy manifest is missing: docs/security/crypto-architecture-policy.json"
    ]


def test_invalid_json_reports_clearly(tmp_path: Path) -> None:
    bad = tmp_path / "policy.json"
    bad.write_text("{not json", encoding="utf-8")

    errors = check_policy(bad, repo_root=tmp_path)

    assert len(errors) == 1
    assert errors[0].startswith("crypto-architecture policy manifest is not valid JSON:")
