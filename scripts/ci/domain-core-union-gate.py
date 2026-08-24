#!/usr/bin/env python3
"""Fail-closed ABI and source-provenance gate for the shared Rust domain core."""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import stat
import sys
import tomllib
import zipfile

SCRIPT_DIRECTORY = str(pathlib.Path(__file__).resolve().parent)
if SCRIPT_DIRECTORY not in sys.path:
    sys.path.insert(0, SCRIPT_DIRECTORY)

from domain_core_source_fingerprint import source_fingerprint  # noqa: E402


REQUIRED_DOMAINS = {
    "quota",
    "cloudVaultC1a",
    "cloudVaultC1b",
    "cloudVaultC1c",
    "documentRewrap",
    "hermes",
    "pricing",
    "encryptedSearch",
    "pensieveVectors",
}
FINGERPRINT_NAME = "openburnbar-domain-core-source.sha256"
ANDROID_TOOLCHAIN_PROVENANCE_NAME = "openburnbar-domain-core-android-toolchain.env"


class GateError(RuntimeError):
    pass


def load_manifest(root: pathlib.Path) -> tuple[pathlib.Path, dict[str, object]]:
    path = root / "crates/openburnbar-domain-core/union-abi-manifest.json"
    try:
        if path.is_symlink() or not stat.S_ISREG(path.lstat().st_mode):
            raise GateError("union ABI manifest must be a regular file inside the candidate checkout")
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except GateError:
        raise
    except (OSError, json.JSONDecodeError) as error:
        raise GateError(f"cannot load {path}: {error}") from error
    if manifest.get("schemaVersion") != 1:
        raise GateError("union ABI manifest schemaVersion must be exactly 1")
    return path, manifest


def verify_build_identity(root: pathlib.Path, manifest: dict[str, object]) -> None:
    core_version = manifest.get("coreVersion")
    abi_version = manifest.get("abiVersion")
    if (
        not isinstance(core_version, str)
        or re.fullmatch(
            r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)(?:-(?:(?:0|[1-9]\d*)|(?:\d*[A-Za-z-][0-9A-Za-z-]*))(?:\.(?:(?:0|[1-9]\d*)|(?:\d*[A-Za-z-][0-9A-Za-z-]*)))*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?",
            core_version,
        )
        is None
    ):
        raise GateError("coreVersion must be a canonical SemVer string")
    if not isinstance(abi_version, int) or isinstance(abi_version, bool) or not 1 <= abi_version <= 0xFFFFFFFF:
        raise GateError("abiVersion must be an unsigned 32-bit integer greater than zero")

    cargo_path = root / "crates/openburnbar-domain-core/Cargo.toml"
    try:
        with cargo_path.open("rb") as handle:
            cargo = tomllib.load(handle)
        cargo_version = cargo["workspace"]["package"]["version"]
    except (OSError, KeyError, TypeError, tomllib.TOMLDecodeError) as error:
        raise GateError(f"cannot read canonical domain-core Cargo version: {error}") from error
    if cargo_version != core_version:
        raise GateError(f"coreVersion drifted: manifest={core_version} cargo={cargo_version}")

    rust_path = root / "crates/openburnbar-domain-core/domain-core/src/lib.rs"
    try:
        rust_source = rust_path.read_text(encoding="utf-8")
    except OSError as error:
        raise GateError(f"cannot read canonical domain-core ABI version: {error}") from error
    match = re.search(r"^pub const DOMAIN_CORE_ABI_VERSION: u32 = (\d+);$", rust_source, re.MULTILINE)
    if match is None:
        raise GateError("cannot locate canonical DOMAIN_CORE_ABI_VERSION constant")
    rust_abi_version = int(match.group(1))
    if rust_abi_version != abi_version:
        raise GateError(f"abiVersion drifted: manifest={abi_version} rust={rust_abi_version}")


def source_files(crate_root: pathlib.Path, manifest: dict[str, object]) -> list[pathlib.Path]:
    roots = manifest.get("sourceRoots")
    if not isinstance(roots, list) or not roots:
        raise GateError("sourceRoots must be a non-empty list")

    files: set[pathlib.Path] = set()
    for raw_path in roots:
        if not isinstance(raw_path, str) or not raw_path:
            raise GateError("sourceRoots entries must be non-empty strings")
        if "\\" in raw_path:
            raise GateError(f"source root must use normalized POSIX separators: {raw_path}")
        relative = pathlib.PurePosixPath(raw_path)
        if (
            relative.is_absolute()
            or raw_path != relative.as_posix()
            or any(part in ("", ".", "..") for part in relative.parts)
        ):
            raise GateError(f"source root must be a normalized relative path: {raw_path}")
        candidate = crate_root.joinpath(*relative.parts)
        try:
            for parent in [crate_root, *candidate.parents][::-1]:
                if parent == crate_root.parent:
                    continue
                if parent == crate_root or crate_root in parent.parents:
                    if parent.is_symlink():
                        raise GateError(f"source root traverses a symlink: {raw_path}")
            mode = candidate.lstat().st_mode
        except FileNotFoundError:
            raise GateError(f"source root is missing: {raw_path}") from None
        if stat.S_ISLNK(mode):
            raise GateError(f"source root cannot be a symlink: {raw_path}")
        if stat.S_ISREG(mode):
            files.add(candidate)
        elif stat.S_ISDIR(mode):
            for directory, names, filenames in os.walk(candidate, followlinks=False):
                directory_path = pathlib.Path(directory)
                retained_names = []
                for name in names:
                    child = directory_path / name
                    child_mode = child.lstat().st_mode
                    if stat.S_ISLNK(child_mode):
                        raise GateError(
                            f"sourceRoots cannot contain symlink directories: {child.relative_to(crate_root)}"
                        )
                    if not stat.S_ISDIR(child_mode):
                        raise GateError(
                            f"sourceRoots contain a special directory entry: {child.relative_to(crate_root)}"
                        )
                    if name != "target":
                        retained_names.append(name)
                names[:] = retained_names
                for name in filenames:
                    child = directory_path / name
                    child_mode = child.lstat().st_mode
                    if stat.S_ISLNK(child_mode):
                        raise GateError(f"sourceRoots cannot contain symlink files: {child.relative_to(crate_root)}")
                    if not stat.S_ISREG(child_mode):
                        raise GateError(f"sourceRoots contain a special file: {child.relative_to(crate_root)}")
                    files.add(child)
        else:
            raise GateError(f"source root must be a regular file or directory: {raw_path}")
    if not files:
        raise GateError("sourceRoots resolved to no files")
    return sorted(files, key=lambda path: path.relative_to(crate_root).as_posix())


def calculate_source_fingerprint(root: pathlib.Path, manifest: dict[str, object]) -> str:
    crate_root = root / "crates/openburnbar-domain-core"
    files = {
        path.relative_to(crate_root).as_posix(): path.read_bytes()
        for path in source_files(crate_root, manifest)
    }
    return source_fingerprint(files)


def verified_source_fingerprint(root: pathlib.Path, manifest: dict[str, object]) -> str:
    expected = manifest.get("sourceSha256")
    if not isinstance(expected, str) or re.fullmatch(r"[0-9a-f]{64}", expected) is None:
        raise GateError("sourceSha256 must be a 64-character lowercase SHA-256 digest")
    actual = calculate_source_fingerprint(root, manifest)
    if actual != expected:
        raise GateError(
            "domain-core source fingerprint drifted: "
            f"manifest={expected} actual={actual}; review the source change and update the manifest"
        )
    return actual


def update_source_fingerprint(root: pathlib.Path, manifest_path: pathlib.Path, manifest: dict[str, object]) -> str:
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


def extract_uniffi_exports(contents: str) -> list[str]:
    exports: list[str] = []
    awaiting_function = False
    for line in contents.splitlines():
        stripped = line.strip()
        if stripped == "#[uniffi::export]":
            awaiting_function = True
            continue
        if not awaiting_function:
            continue
        match = re.match(r"pub fn ([A-Za-z0-9_]+)\s*\(", stripped)
        if match:
            exports.append(match.group(1))
            awaiting_function = False
            continue
        if stripped.startswith("#[") or stripped.startswith("//") or not stripped:
            continue
        raise GateError("canonical UniFFI source has an export attribute not followed by a public function")
    if awaiting_function:
        raise GateError("canonical UniFFI source ends after an export attribute")
    return exports


def require_exact_uniffi_exports(manifest: dict[str, object], surface_contents: dict[str, str]) -> None:
    expected = manifest.get("uniffiExports")
    if (
        not isinstance(expected, list)
        or not expected
        or any(not isinstance(symbol, str) or not symbol for symbol in expected)
        or len(set(expected)) != len(expected)
    ):
        raise GateError("uniffiExports must be a non-empty ordered list of unique symbols")

    canonical = extract_uniffi_exports(surface_contents["canonical-uniffi"])
    if canonical != expected:
        missing = [symbol for symbol in expected if symbol not in canonical]
        undeclared = [symbol for symbol in canonical if symbol not in expected]
        detail = []
        if missing:
            detail.append("missing=" + ",".join(missing))
        if undeclared:
            detail.append("undeclared=" + ",".join(undeclared))
        if not detail:
            detail.append("order differs")
        raise GateError("canonical UniFFI exports do not exactly match manifest: " + "; ".join(detail))

    header = re.findall(
        r"uniffi_openburnbar_domain_ffi_fn_func_([a-z0-9_]+)\s*\(",
        surface_contents["generated-swift-c-header"],
    )
    if len(header) != len(set(header)) or set(header) != set(expected):
        missing = [symbol for symbol in expected if symbol not in header]
        undeclared = [symbol for symbol in header if symbol not in expected]
        detail = []
        if missing:
            detail.append("missing=" + ",".join(missing))
        if undeclared:
            detail.append("undeclared=" + ",".join(undeclared))
        if len(header) != len(set(header)):
            detail.append("duplicate generated symbols")
        raise GateError("generated C header exports do not exactly match manifest: " + "; ".join(detail))


def check_abi(root: pathlib.Path, manifest: dict[str, object]) -> None:
    domains = manifest.get("domains")
    surfaces = manifest.get("abiSurfaces")
    if not isinstance(domains, dict) or set(domains) != REQUIRED_DOMAINS:
        raise GateError(
            "domains must contain exactly the required convergence domains: " + ", ".join(sorted(REQUIRED_DOMAINS))
        )
    if not isinstance(surfaces, list) or not surfaces:
        raise GateError("abiSurfaces must be a non-empty list")

    full_union_surfaces: set[str] = set()
    surface_contents: dict[str, str] = {}
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
        surface_contents[str(name)] = contents

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
        missing_surface_symbols = [symbol for symbol in required_symbols if symbol not in contents]
        if missing_surface_symbols:
            raise GateError(
                f"{name}: {raw_path} is missing surface-specific symbol(s): " + ", ".join(missing_surface_symbols)
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
            "full union coverage must be asserted exactly for canonical UniFFI and generated Swift/Kotlin/C# bindings"
        )
    require_exact_uniffi_exports(manifest, surface_contents)


def read_sidecar(path: pathlib.Path) -> str:
    try:
        value = path.read_text(encoding="ascii").strip()
    except OSError as error:
        raise GateError(f"missing provenance sidecar {path}: {error}") from error
    if len(value) != 64:
        raise GateError(f"invalid provenance sidecar {path}")
    return value


def expected_android_toolchain_provenance(root: pathlib.Path) -> bytes:
    rust_path = root / "crates/openburnbar-domain-core/rust-toolchain.toml"
    try:
        with rust_path.open("rb") as handle:
            rust_config = tomllib.load(handle)
        rust_channel = rust_config["toolchain"]["channel"]
    except (OSError, KeyError, tomllib.TOMLDecodeError, TypeError) as error:
        raise GateError(f"cannot read canonical Rust toolchain: {error}") from error
    if not isinstance(rust_channel, str) or not re.fullmatch(r"\d+\.\d+\.\d+", rust_channel):
        raise GateError(f"invalid canonical Rust toolchain channel: {rust_channel!r}")

    ndk_path = root / "config/domain-core-android-ndk-version.txt"
    try:
        ndk_config = ndk_path.read_text(encoding="ascii")
    except (OSError, UnicodeDecodeError) as error:
        raise GateError(f"cannot read canonical Android toolchain: {error}") from error
    match = re.fullmatch(
        r"(\d+(?:\.\d+)+)\n?",
        ndk_config,
    )
    if match is None:
        raise GateError(f"invalid canonical Android toolchain config: {ndk_path}")

    return f"rust={rust_channel}\nndk={match.group(1)}\n".encode("ascii")


def check_provenance(root: pathlib.Path, fingerprint: str, surfaces: list[str]) -> None:
    sidecars = {
        "swift": root / "crates/openburnbar-domain-core/artifact-provenance/swift.sha256",
        "kotlin": root / "crates/openburnbar-domain-core/artifact-provenance/kotlin.sha256",
        "csharp": root / "crates/openburnbar-domain-core/artifact-provenance/csharp.sha256",
        "python": root / "crates/openburnbar-domain-core/artifact-provenance/python.sha256",
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
                    actual_toolchain = archive.read(f"META-INF/{ANDROID_TOOLCHAIN_PROVENANCE_NAME}")
            except (OSError, KeyError, UnicodeDecodeError, zipfile.BadZipFile) as error:
                raise GateError(f"cannot read AAR provenance: {error}") from error
            expected_toolchain = expected_android_toolchain_provenance(root)
            if actual_toolchain != expected_toolchain:
                raise GateError(
                    "aar toolchain provenance is stale: "
                    f"artifact={actual_toolchain.decode('ascii', errors='replace')!r} "
                    f"source={expected_toolchain.decode('ascii')!r}"
                )
        else:
            value = read_sidecar(sidecars[surface])
        if value != fingerprint:
            raise GateError(f"{surface} provenance is stale: artifact={value} source={fingerprint}")


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
    parser.add_argument("--check-build-identity", action="store_true")
    parser.add_argument("--check-provenance", nargs="+", default=[])
    args = parser.parse_args()

    try:
        root = args.root.resolve()
        manifest_path, manifest = load_manifest(root)
        if args.update_source_fingerprint:
            if args.source_fingerprint or args.check_abi or args.check_build_identity or args.check_provenance:
                raise GateError("--update-source-fingerprint cannot be combined with checks")
            fingerprint = update_source_fingerprint(root, manifest_path, manifest)
            print(fingerprint)
            return 0
        fingerprint = verified_source_fingerprint(root, manifest)
        if args.check_abi or args.check_build_identity:
            verify_build_identity(root, manifest)
        if args.check_abi:
            check_abi(root, manifest)
        if args.check_provenance:
            check_provenance(root, fingerprint, args.check_provenance)
        if args.source_fingerprint:
            print(fingerprint)
        if not (args.source_fingerprint or args.check_abi or args.check_build_identity or args.check_provenance):
            raise GateError(
                "select --source-fingerprint, --update-source-fingerprint, --check-abi, --check-build-identity, or --check-provenance"
            )
    except GateError as error:
        print(f"domain-core-union-gate: ERROR: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
