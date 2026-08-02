#!/usr/bin/env python3
"""Verify that a provisioning profile explicitly allows the signer certificate."""

from __future__ import annotations

import argparse
import hashlib
import hmac
import plistlib
import sys
from pathlib import Path


LEGACY_V1029_DMG_SHA256 = "FC0926B4E7AE0C9E155D9BE6711A06119F7A2FFF2F7DF8448FD34CA052DB9D96"
LEGACY_V1029_SIGNER_SHA256 = "2B5CCCC3256C4FE179A7C34614152AE3B940D21EB9193F36D312BAAD82C762BB"
LEGACY_V1029_PROFILE_CERTIFICATE_SHA256 = (
    "F6D16CF680A35D2C27805517469FC6427CDFFFD3D2207C13FFF13CC0F10F6A6A"
)


def fingerprint(certificate: bytes) -> str:
    return hashlib.sha256(certificate).hexdigest().upper()


def allows_legacy_v1029_profile_membership_exception(
    *,
    release_version: str | None,
    artifact_sha256: str | None,
    signer_sha256: str,
    allowed_sha256: tuple[str, ...],
) -> bool:
    """Allow only the immutable v1.0.29 public DMG's known profile mismatch."""

    if release_version != "1.0.29" or artifact_sha256 is None:
        return False
    if len(allowed_sha256) != 1:
        return False

    normalized_artifact_sha256 = artifact_sha256.strip().upper()
    return (
        hmac.compare_digest(normalized_artifact_sha256, LEGACY_V1029_DMG_SHA256)
        and hmac.compare_digest(signer_sha256, LEGACY_V1029_SIGNER_SHA256)
        and hmac.compare_digest(allowed_sha256[0], LEGACY_V1029_PROFILE_CERTIFICATE_SHA256)
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Verify that a provisioning profile explicitly allows the signer certificate."
    )
    parser.add_argument("profile_plist", type=Path)
    parser.add_argument("signer_der", type=Path)
    parser.add_argument("--artifact-sha256")
    parser.add_argument("--release-version")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if (args.artifact_sha256 is None) != (args.release_version is None):
        print(
            "ERROR: --artifact-sha256 and --release-version must be provided together.",
            file=sys.stderr,
        )
        return 2

    with args.profile_plist.open("rb") as file:
        profile = plistlib.load(file)
    signer = args.signer_der.read_bytes()

    certificates = profile.get("DeveloperCertificates")
    if not isinstance(certificates, list) or not certificates:
        print(
            "ERROR: Provisioning profile has no DeveloperCertificates allowlist.",
            file=sys.stderr,
        )
        return 1
    if not all(isinstance(certificate, bytes) for certificate in certificates):
        print(
            "ERROR: Provisioning profile DeveloperCertificates is malformed.",
            file=sys.stderr,
        )
        return 1

    signer_fingerprint = fingerprint(signer)
    if any(hmac.compare_digest(signer, certificate) for certificate in certificates):
        print(f"PASS: Embedded provisioning profile authorizes signer certificate SHA256={signer_fingerprint}.")
        return 0

    allowed_fingerprints = tuple(fingerprint(certificate) for certificate in certificates)
    if allows_legacy_v1029_profile_membership_exception(
        release_version=args.release_version,
        artifact_sha256=args.artifact_sha256,
        signer_sha256=signer_fingerprint,
        allowed_sha256=allowed_fingerprints,
    ):
        print(
            "WARN: Accepting the temporary v1.0.29 public-DMG provisioning-profile "
            "certificate-membership exception for "
            f"artifactSHA256={LEGACY_V1029_DMG_SHA256} "
            f"signerSHA256={LEGACY_V1029_SIGNER_SHA256} "
            f"allowedSHA256={LEGACY_V1029_PROFILE_CERTIFICATE_SHA256}. "
            "All other public-download trust gates remain mandatory.",
            file=sys.stderr,
        )
        return 0

    allowed = ", ".join(allowed_fingerprints)
    print(
        "ERROR: Embedded provisioning profile does not authorize the certificate "
        f"that signed the bundle. signerSHA256={signer_fingerprint} "
        f"allowedSHA256={allowed}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
