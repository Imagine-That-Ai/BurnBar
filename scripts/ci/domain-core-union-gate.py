#!/usr/bin/env python3
"""Fail-closed ABI and source-provenance gate for the shared Rust domain core."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import sys
import zipfile


REQUIRED_DOMAINS = {
    "quota",
    "cloudVaultC1a",
    "cloudVaultC1b",
    "cloudVaultC1c",
    "documentRewrap",
    "hermes",
    "pricing",
    "encryptedSearch",
}
FINGERPRINT_NAME = "openburnbar-domain-core-source.sha256"


class GateError(RuntimeError):
    pass


def load_manifest(root: pathlib.Path) -> tuple[pathlib.Path, dict[str, object]]:
    path = root / "crates/openburnbar-domain-core/union-abi-manifest.json"
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise GateError(f"cannot load {path}: {error}") from error
    if manifest.get("schemaVersion") != 1:
        raise GateError("union ABI manifest schemaVersion must be exactly 1")
    return path, manifest


def source_files(crate_root: pathlib.Path, manifest: dict[str, object]) -> list[pathlib.Path]:
    roots = manifest.get("sourceRoots")
    if not isinstance(roots, list) or not roots:
        raise GateError("sourceRoots must be a non-empty list")

    files: set[pathlib.Path] = set()
    for raw_path in roots:
        if not isinstance(raw_path, str) or not raw_path:
            raise GateError("sourceRoots entries must be non-empty strings")
        candidate = crate_root / raw_path
        if not candidate.exists():
            raise GateError(f"source root is missing: {raw_path}")
        if candidate.is_file():
            files.add(candidate)
        else:
            files.update(
                path
                for path in candidate.rglob("*")
                if path.is_file() and "target" not in path.parts
            )
    if not files:
        raise GateError("sourceRoots resolved to no files")
    return sorted(files, key=lambda path: path.relative_to(crate_root).as_posix())


def calculate_source_fingerprint(root: pathlib.Path, manifest: dict[str, object]) -> str:
    crate_root = root / "crates/openburnbar-domain-core"
    digest = hashlib.sha256()
    for path in source_files(crate_root, manifest):
        relative = path.relative_to(crate_root).as_posix().encode()
        contents = path.read_bytes()
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(len(contents).to_bytes(8, "big"))
        digest.update(contents)
    return digest.hexdigest()


def verified_source_fingerprint(root: pathlib.Path, manifest: dict[str, object]) -> str:
    expected = manifest.get("sourceSha256")
    if not isinstance(expected, str) or len(expected) != 64:
        raise GateError("sourceSha256 must be a 64-character SHA-256 digest")
    actual = calculate_source_fingerprint(root, manifest)
    if actual != expected:
        raise GateError(
            "domain-core source fingerprint drifted: "
            f"manifest={expected} actual={actual}; review the source change and update the manifest"
        )
    return actual


def update_source_fingerprint(
    root: pathlib.Path, manifest_path: pathlib.Path, manifest: dict[str, object]
) -> str:
    actual = calculate_source_fingerprint(root, manifest)
    updated = dict(manifest)
    updated["sourceSha256"] = actual
    temporary = manifest_path.with_name(f".{manifest_path.name}.{os.getpid()}.tmp")
    try:
        temporary.write_text(
            json.dumps(updated, indent=2, ensure_ascii=True) + "\n",
            encoding="utf-8",
        )
        os.replace(temporary, manifest_path)
    finally:
        temporary.unlink(missing_ok=True)
    return actual


def check_abi(root: pathlib.Path, manifest: dict[str, object]) -> None:
    domains = manifest.get("domains")
    surfaces = manifest.get("abiSurfaces")
    if not isinstance(domains, dict) or set(domains) != REQUIRED_DOMAINS:
        raise GateError(
            "domains must contain exactly the required convergence domains: "
            + ", ".join(sorted(REQUIRED_DOMAINS))
        )
    if not isinstance(surfaces, list) or not surfaces:
        raise GateError("abiSurfaces must be a non-empty list")

    full_union_surfaces: set[str] = set()
    for surface in surfaces:
        if not isinstance(surface, dict):
            raise GateError("abiSurfaces entries must be objects")
        name = surface.get("name")
        kind = surface.get("kind")
        raw_path = surface.get("path")
        required = surface.get("requiredDomains")
        required_symbols = surface.get("requiredSymbols", [])
        if not all(isinstance(value, str) and value for value in (name, kind, raw_path)):
            raise GateError("each ABI surface requires non-empty name, kind, and path")
        if not isinstance(required, list) or not required:
            raise GateError(f"{name}: requiredDomains must be non-empty")
        if not isinstance(required_symbols, list) or any(
            not isinstance(symbol, str) or not symbol for symbol in required_symbols
        ):
            raise GateError(f"{name}: requiredSymbols must contain only non-empty strings")
        unknown = set(required) - REQUIRED_DOMAINS
        if unknown:
            raise GateError(f"{name}: unknown domains: {', '.join(sorted(unknown))}")
        path = root / raw_path
        try:
            contents = path.read_text(encoding="utf-8")
        except OSError as error:
            raise GateError(f"{name}: cannot read {raw_path}: {error}") from error

        for domain_name in required:
            domain = domains.get(domain_name)
            if not isinstance(domain, dict):
                raise GateError(f"{name}: invalid domain manifest for {domain_name}")
            symbols = domain.get(kind)
            if not isinstance(symbols, list) or not symbols:
                raise GateError(f"{name}: {domain_name} has no {kind} symbol contract")
            missing = [symbol for symbol in symbols if not isinstance(symbol, str) or symbol not in contents]
            if missing:
                raise GateError(
                    f"{name}: {domain_name} is absent or incomplete in {raw_path}; "
                    f"missing named symbol(s): {', '.join(str(symbol) for symbol in missing)}"
                )
        missing_surface_symbols = [
            symbol for symbol in required_symbols if symbol not in contents
        ]
        if missing_surface_symbols:
            raise GateError(
                f"{name}: {raw_path} is missing surface-specific symbol(s): "
                + ", ".join(missing_surface_symbols)
            )
        if set(required) == REQUIRED_DOMAINS:
            full_union_surfaces.add(str(name))

    required_full_surfaces = {
        "canonical-uniffi",
        "generated-swift",
        "generated-swift-c-header",
        "generated-kotlin",
        "generated-csharp",
    }
    if full_union_surfaces != required_full_surfaces:
        raise GateError(
            "full union coverage must be asserted exactly for canonical UniFFI and generated "
            "Swift/Kotlin/C# bindings"
        )


def read_sidecar(path: pathlib.Path) -> str:
    try:
        value = path.read_text(encoding="ascii").strip()
    except OSError as error:
        raise GateError(f"missing provenance sidecar {path}: {error}") from error
    if len(value) != 64:
        raise GateError(f"invalid provenance sidecar {path}")
    return value


def check_provenance(root: pathlib.Path, fingerprint: str, surfaces: list[str]) -> None:
    sidecars = {
        "swift": root / "crates/openburnbar-domain-core/artifact-provenance/swift.sha256",
        "kotlin": root / "crates/openburnbar-domain-core/artifact-provenance/kotlin.sha256",
        "csharp": root / "crates/openburnbar-domain-core/artifact-provenance/csharp.sha256",
        "browser-wasm": root / "apps/console/vendor/openburnbar-domain-core-wasm" / FINGERPRINT_NAME,
        "node-wasm": root / "functions/vendor/openburnbar/domain-core-wasm" / FINGERPRINT_NAME,
        "xcframework": root / "Vendor/OpenBurnBarDomainCore.xcframework" / FINGERPRINT_NAME,
    }
    allowed = set(sidecars) | {"aar"}
    unknown = set(surfaces) - allowed
    if unknown:
        raise GateError(f"unknown provenance surfaces: {', '.join(sorted(unknown))}")

    for surface in surfaces:
        if surface == "aar":
            aar = root / "Vendor/openburnbar-domain-core.aar"
            try:
                with zipfile.ZipFile(aar) as archive:
                    value = archive.read(f"META-INF/{FINGERPRINT_NAME}").decode("ascii").strip()
            except (OSError, KeyError, UnicodeDecodeError, zipfile.BadZipFile) as error:
                raise GateError(f"cannot read AAR source provenance: {error}") from error
        else:
            value = read_sidecar(sidecars[surface])
        if value != fingerprint:
            raise GateError(
                f"{surface} provenance is stale: artifact={value} source={fingerprint}"
            )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--root",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parents[2],
    )
    parser.add_argument("--source-fingerprint", action="store_true")
    parser.add_argument("--update-source-fingerprint", action="store_true")
    parser.add_argument("--check-abi", action="store_true")
    parser.add_argument("--check-provenance", nargs="+", default=[])
    args = parser.parse_args()

    try:
        root = args.root.resolve()
        manifest_path, manifest = load_manifest(root)
        if args.update_source_fingerprint:
            if args.source_fingerprint or args.check_abi or args.check_provenance:
                raise GateError("--update-source-fingerprint cannot be combined with checks")
            fingerprint = update_source_fingerprint(root, manifest_path, manifest)
            print(fingerprint)
            return 0
        fingerprint = verified_source_fingerprint(root, manifest)
        if args.check_abi:
            check_abi(root, manifest)
        if args.check_provenance:
            check_provenance(root, fingerprint, args.check_provenance)
        if args.source_fingerprint:
            print(fingerprint)
        if not (args.source_fingerprint or args.check_abi or args.check_provenance):
            raise GateError(
                "select --source-fingerprint, --update-source-fingerprint, --check-abi, "
                "or --check-provenance"
            )
    except GateError as error:
        print(f"domain-core-union-gate: ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
