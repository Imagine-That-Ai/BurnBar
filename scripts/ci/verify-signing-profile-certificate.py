#!/usr/bin/env python3
"""Verify that a provisioning profile explicitly allows the signer certificate."""

from __future__ import annotations

import hashlib
import hmac
import plistlib
import sys
from pathlib import Path


def fingerprint(certificate: bytes) -> str:
    return hashlib.sha256(certificate).hexdigest().upper()


def main() -> int:
    if len(sys.argv) != 3:
        print(
            "usage: verify-signing-profile-certificate.py PROFILE_PLIST SIGNER_DER",
            file=sys.stderr,
        )
        return 2

    profile_path = Path(sys.argv[1])
    signer_path = Path(sys.argv[2])
    with profile_path.open("rb") as file:
        profile = plistlib.load(file)
    signer = signer_path.read_bytes()

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

    allowed = ", ".join(fingerprint(certificate) for certificate in certificates)
    print(
        "ERROR: Embedded provisioning profile does not authorize the certificate "
        f"that signed the bundle. signerSHA256={signer_fingerprint} "
        f"allowedSHA256={allowed}",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
