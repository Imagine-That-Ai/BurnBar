#!/usr/bin/env python3
"""Verify BurnBar's crypto-architecture policy manifest.

This gate makes BurnBar's per-platform / per-channel cryptography decision
machine-checkable. The product deliberately mixes three distinct backends:

  * official libsignal Double Ratchet on the device<->device lane
    (Mac / Android / daemon),
  * libsignal HPKE at-rest sealing (read on iOS via CryptoKit, not by linking
    libsignal),
  * a homegrown Double Ratchet on the phone<->AI-gateway lane.

The iOS App Store satellite must stay worldwide libsignal-FREE: it never links a
libsignal-bearing model on any channel, reads at-rest payloads through CryptoKit
RFC-9180 HPKE interop, and never markets itself as "Signal Protocol".

The checker hardcodes the canonical capability matrix and fails the build if the
shipped manifest drifts from it or violates any of the four crypto invariants.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parents[2]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

DEFAULT_MANIFEST = ROOT / "docs/security/crypto-architecture-policy.json"
ADR_DOC = "docs/security/ADR-001-crypto-architecture.md"
BACKEND_POLICY_LIB = "packages/e2ee-backend-policy/lib/index.js"
BACKEND_POLICY_NEEDLES = (
    "PLATFORM_CRYPTO_CAPABILITIES",
    "PLATFORMS",
    "CHANNELS",
    "resolvePlatformCryptoModel",
)

# --- Canonical capability matrix (the single source of truth) ----------------
PLATFORMS = ["macos", "android", "daemon", "backend", "ios"]
CHANNELS = ["device_to_device", "at_rest", "ai_gateway"]

PLATFORM_CRYPTO_CAPABILITIES: dict[str, dict[str, str]] = {
    "macos": {
        "device_to_device": "libsignal-double-ratchet",
        "at_rest": "libsignal-hpke-seal",
        "ai_gateway": "homegrown-double-ratchet",
    },
    "android": {
        "device_to_device": "libsignal-double-ratchet",
        "at_rest": "libsignal-hpke-seal",
        "ai_gateway": "homegrown-double-ratchet",
    },
    "daemon": {
        "device_to_device": "libsignal-double-ratchet",
        "at_rest": "libsignal-hpke-seal",
        "ai_gateway": "homegrown-double-ratchet",
    },
    "backend": {
        "at_rest": "libsignal-hpke-seal",
        "ai_gateway": "homegrown-double-ratchet",
    },
    "ios": {
        "device_to_device": "none-satellite",
        "at_rest": "cryptokit-hpke-atrest",
        "ai_gateway": "homegrown-double-ratchet",
    },
}

# libsignal-bearing models: linking these on iOS is the App-Store-clean hard
# violation the whole gate exists to catch.
LIBSIGNAL_BEARING_MODELS = ["libsignal-double-ratchet", "libsignal-hpke-seal"]

# The ONLY models permitted on any iOS channel. Anything else on iOS fails
# closed — so a brand-new model string can never silently appear on the
# App-Store-clean satellite without an explicit decision here.
IOS_ALLOWED_MODELS = {
    "none-satellite",
    "cryptokit-hpke-atrest",
    "homegrown-double-ratchet",
}

# model -> the single marketing claim it is allowed to back.
CLAIM_MAPPING: dict[str, str] = {
    "libsignal-double-ratchet": "Signal Protocol",
    "libsignal-hpke-seal": "Signal at-rest sealing",
    "cryptokit-hpke-atrest": "At-rest HPKE sealing (CryptoKit, RFC 9180, interoperable with the libsignal seal, no libsignal link)",
    "homegrown-double-ratchet": "Hardened encrypted gateway (homegrown Double Ratchet, forward secrecy)",
    "none-satellite": "secure satellite (transport-encrypted)",
}

SIGNAL_PROTOCOL_CLAIM = "Signal Protocol"


def _platforms_match_canonical(platforms: Any) -> list[str]:
    """Assert the manifest's platforms equal the hardcoded canonical matrix."""
    errors: list[str] = []
    if not isinstance(platforms, dict):
        return ["platforms must be a JSON object mapping platform -> channel -> model"]

    expected_names = set(PLATFORM_CRYPTO_CAPABILITIES)
    actual_names = set(platforms)
    missing = sorted(expected_names - actual_names)
    extra = sorted(actual_names - expected_names)
    if missing:
        errors.append("platforms missing required platform(s): " + ", ".join(missing))
    if extra:
        errors.append("platforms contains unknown platform(s): " + ", ".join(extra))

    for platform in PLATFORMS:
        expected_channels = PLATFORM_CRYPTO_CAPABILITIES.get(platform, {})
        actual_channels = platforms.get(platform)
        if actual_channels is None:
            continue
        if not isinstance(actual_channels, dict):
            errors.append(f"platforms.{platform} must be a JSON object mapping channel -> model")
            continue

        expected_channel_names = set(expected_channels)
        actual_channel_names = set(actual_channels)
        missing_channels = sorted(expected_channel_names - actual_channel_names)
        extra_channels = sorted(actual_channel_names - expected_channel_names)
        if missing_channels:
            errors.append(f"platforms.{platform} missing required channel(s): " + ", ".join(missing_channels))
        if extra_channels:
            errors.append(f"platforms.{platform} contains unknown channel(s): " + ", ".join(extra_channels))

        for channel in CHANNELS:
            if channel not in expected_channels:
                continue
            expected_model = expected_channels[channel]
            if channel not in actual_channels:
                # Absence is already reported via missing_channels above.
                continue
            actual_model = actual_channels.get(channel)
            # A present-but-null (or non-string) model must fail closed — NOT be
            # skipped. Skipping null here was a fail-OPEN hole: a load-bearing
            # cell (e.g. ios.at_rest) could be blanked with the gate still green.
            if not isinstance(actual_model, str) or actual_model != expected_model:
                errors.append(f"platforms.{platform}.{channel} must be {expected_model!r}, found {actual_model!r}")
    return errors


def _invariant_ios_libsignal_free(platforms: Any) -> list[str]:
    """Invariant 1: iOS NEVER uses a libsignal-bearing model on ANY channel."""
    errors: list[str] = []
    if not isinstance(platforms, dict):
        return errors
    ios = platforms.get("ios")
    if not isinstance(ios, dict):
        return errors
    for channel, model in sorted(ios.items()):
        if model in LIBSIGNAL_BEARING_MODELS:
            errors.append(
                f"INVARIANT VIOLATION: ios.{channel} is libsignal-bearing model {model!r}; "
                "the iOS App Store satellite must stay libsignal-FREE on every channel"
            )
            continue
        # Substring guard: robust to NEW libsignal variant strings the explicit
        # list above doesn't yet enumerate (e.g. 'libsignal-x25519-session').
        if isinstance(model, str) and "libsignal" in model.lower():
            errors.append(
                f"INVARIANT VIOLATION: ios.{channel} model {model!r} looks libsignal-bearing; "
                "the iOS App Store satellite must stay libsignal-FREE on every channel"
            )
            continue
        # Allowlist: anything not explicitly permitted on iOS fails closed,
        # regardless of the matrix-equality backstop.
        if model not in IOS_ALLOWED_MODELS:
            errors.append(
                f"INVARIANT VIOLATION: ios.{channel} model {model!r} is not in the iOS-permitted "
                f"set {sorted(IOS_ALLOWED_MODELS)}; iOS channels fail closed"
            )
    return errors


def _invariant_device_to_device(platforms: Any) -> list[str]:
    """Invariant 2: device_to_device backend per platform is pinned."""
    errors: list[str] = []
    if not isinstance(platforms, dict):
        return errors

    for platform in ("macos", "android", "daemon"):
        channels = platforms.get(platform)
        if not isinstance(channels, dict):
            continue
        model = channels.get("device_to_device")
        if model != "libsignal-double-ratchet":
            errors.append(
                f"INVARIANT VIOLATION: {platform}.device_to_device must be 'libsignal-double-ratchet', found {model!r}"
            )

    ios = platforms.get("ios")
    if isinstance(ios, dict):
        ios_d2d = ios.get("device_to_device")
        if ios_d2d != "none-satellite":
            errors.append(f"INVARIANT VIOLATION: ios.device_to_device must be 'none-satellite', found {ios_d2d!r}")

    backend = platforms.get("backend")
    if isinstance(backend, dict) and "device_to_device" in backend:
        errors.append("INVARIANT VIOLATION: backend must NOT declare a device_to_device channel")
    return errors


def _invariant_ai_gateway(platforms: Any) -> list[str]:
    """Invariant 3: ai_gateway is homegrown-double-ratchet for EVERY platform."""
    errors: list[str] = []
    if not isinstance(platforms, dict):
        return errors
    for platform in PLATFORMS:
        channels = platforms.get(platform)
        if not isinstance(channels, dict):
            continue
        model = channels.get("ai_gateway")
        if model != "homegrown-double-ratchet":
            errors.append(
                f"INVARIANT VIOLATION: {platform}.ai_gateway must be 'homegrown-double-ratchet', found {model!r}"
            )
    return errors


def _invariant_at_rest(platforms: Any) -> list[str]:
    """Invariant: at_rest model is pinned per platform and fails closed.

    Mirrors the strict `!=` treatment of the device_to_device / ai_gateway
    invariants so a present-but-null at_rest cell cannot slip through.
    """
    errors: list[str] = []
    if not isinstance(platforms, dict):
        return errors
    for platform in PLATFORMS:
        expected_model = PLATFORM_CRYPTO_CAPABILITIES[platform].get("at_rest")
        if expected_model is None:
            continue
        channels = platforms.get(platform)
        if not isinstance(channels, dict):
            continue
        model = channels.get("at_rest")
        if model != expected_model:
            errors.append(f"INVARIANT VIOLATION: {platform}.at_rest must be {expected_model!r}, found {model!r}")
    return errors


def _invariant_claim_mapping(data: Any, platforms: Any) -> list[str]:
    """Invariant 4: claim mapping present and iOS never maps to 'Signal Protocol'."""
    errors: list[str] = []
    claims = data.get("claims") if isinstance(data, dict) else None
    if not isinstance(claims, dict):
        errors.append("claims must be a JSON object mapping model -> marketing claim")
        return errors

    for model, expected_claim in CLAIM_MAPPING.items():
        if model not in claims:
            errors.append(f"claims missing required model claim: {model}")
            continue
        actual_claim = claims.get(model)
        if actual_claim != expected_claim:
            errors.append(f"claims.{model} must be {expected_claim!r}, found {actual_claim!r}")

    # iOS may never back the "Signal Protocol" claim on any channel.
    if isinstance(platforms, dict):
        ios = platforms.get("ios")
        if isinstance(ios, dict):
            for channel, model in sorted(ios.items()):
                if claims.get(model) == SIGNAL_PROTOCOL_CLAIM:
                    errors.append(
                        f"INVARIANT VIOLATION: ios.{channel} model {model!r} maps to the "
                        f"'{SIGNAL_PROTOCOL_CLAIM}' claim; iOS must NEVER claim Signal Protocol"
                    )
    return errors


def validate_crypto_architecture_policy(data: Any, *, repo_root: Path = ROOT) -> list[str]:
    """Validate the loaded policy manifest. Returns a list of error strings."""
    errors: list[str] = []
    if not isinstance(data, dict):
        return ["manifest root must be a JSON object"]

    if data.get("schemaVersion") != 1:
        errors.append(f"schemaVersion must be 1, found {data.get('schemaVersion')!r}")

    platforms = data.get("platforms")

    # The manifest's platforms must equal the hardcoded canonical matrix.
    errors.extend(_platforms_match_canonical(platforms))

    # The manifest's own libsignal-bearing list must equal the canonical one,
    # so the field is tamper-evident rather than decorative.
    manifest_bearing = data.get("libsignalBearingModels")
    if manifest_bearing != LIBSIGNAL_BEARING_MODELS:
        errors.append(f"libsignalBearingModels must equal {LIBSIGNAL_BEARING_MODELS!r}, found {manifest_bearing!r}")

    # Enforce the crypto invariants.
    errors.extend(_invariant_ios_libsignal_free(platforms))
    errors.extend(_invariant_device_to_device(platforms))
    errors.extend(_invariant_at_rest(platforms))
    errors.extend(_invariant_ai_gateway(platforms))
    errors.extend(_invariant_claim_mapping(data, platforms))

    # The ADR must exist alongside the machine-readable manifest AND render the
    # same canonical claim strings, so the human-readable record cannot silently
    # drift from the enforced vocabulary (e.g. back to a forbidden token).
    adr_path = repo_root / ADR_DOC
    if not adr_path.is_file():
        errors.append(f"architecture decision record is missing: {ADR_DOC}")
    else:
        try:
            adr_text = adr_path.read_text(encoding="utf-8")
        except OSError as exc:
            errors.append(f"architecture decision record could not be read: {exc}")
        else:
            for model, claim in CLAIM_MAPPING.items():
                if claim not in adr_text:
                    errors.append(f"{ADR_DOC} must render the canonical claim for {model!r}: {claim!r}")

    # The backend policy library must encode the same matrix in code.
    lib_path = repo_root / BACKEND_POLICY_LIB
    if not lib_path.is_file():
        errors.append(f"backend policy library is missing: {BACKEND_POLICY_LIB}")
    else:
        try:
            contents = lib_path.read_text(encoding="utf-8")
        except OSError as exc:
            errors.append(f"backend policy library could not be read: {exc}")
        else:
            missing_needles = [needle for needle in BACKEND_POLICY_NEEDLES if needle not in contents]
            if missing_needles:
                errors.append(f"{BACKEND_POLICY_LIB} missing required symbol(s): " + ", ".join(missing_needles))

    return errors


def load_policy(path: Path = DEFAULT_MANIFEST) -> Any:
    return json.loads(path.read_text(encoding="utf-8"))


def check_policy(path: Path = DEFAULT_MANIFEST, *, repo_root: Path = ROOT) -> list[str]:
    if not path.is_file():
        try:
            rel = path.relative_to(repo_root)
        except ValueError:
            rel = path
        return [f"crypto-architecture policy manifest is missing: {rel}"]
    try:
        data = load_policy(path)
    except json.JSONDecodeError as exc:
        return [f"crypto-architecture policy manifest is not valid JSON: {exc}"]
    return validate_crypto_architecture_policy(data, repo_root=repo_root)


def main() -> int:
    errors = check_policy()
    if errors:
        print("FAIL: BurnBar crypto-architecture policy is invalid", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("PASS: BurnBar crypto-architecture policy verified")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
