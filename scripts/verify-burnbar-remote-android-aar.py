#!/usr/bin/env python3
"""Portable provenance and native-structure gate for Vendor/burnbar-remote.aar."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import re
import struct
import subprocess
import sys
import tempfile
import zipfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
CRATE_ROOT = ROOT / "crates" / "burnbar-remote"
GENERATED_ROOT = ROOT / "android" / "burnbar-remote" / "src" / "main" / "java" / "uniffi" / "burnbar_remote"
AAR_PATH = ROOT / "Vendor" / "burnbar-remote.aar"
BUILD_SCRIPT = ROOT / "scripts" / "build-burnbar-remote-android-aar.sh"
VERIFY_SCRIPT = pathlib.Path(__file__).resolve()
METADATA_ENTRY = "META-INF/burnbar-remote-artifact.json"
EXPORTS_ENTRY = "META-INF/burnbar-remote-uniffi-exports.txt"
ABIS = {
    "arm64-v8a": 183,
    "armeabi-v7a": 40,
    "x86": 3,
    "x86_64": 62,
}
LIBRARIES = ("libburnbar_remote.so", "libuniffi_burnbar_remote.so")


class VerificationError(RuntimeError):
    pass


def _hash_paths(root: pathlib.Path, paths: list[pathlib.Path]) -> str:
    digest = hashlib.sha256()
    for path in sorted(paths):
        relative = path.relative_to(root).as_posix().encode()
        contents = path.read_bytes()
        digest.update(len(relative).to_bytes(4, "big"))
        digest.update(relative)
        digest.update(len(contents).to_bytes(8, "big"))
        digest.update(contents)
    return digest.hexdigest()


def source_paths(crate_root: pathlib.Path = CRATE_ROOT) -> list[pathlib.Path]:
    roots = [
        crate_root / ".cargo",
        crate_root / "Cargo.toml",
        crate_root / "Cargo.lock",
        crate_root / "rust-toolchain.toml",
    ]
    roots.extend(sorted(path for path in crate_root.glob("burnbar-remote-*") if path.is_dir()))
    paths: list[pathlib.Path] = []
    for candidate in roots:
        candidates = [candidate] if candidate.is_file() else candidate.rglob("*")
        for path in candidates:
            if not path.is_file() or "target" in path.parts:
                continue
            if path.name in {"README.md", "SECURITY.md", ".gitignore"}:
                continue
            if path.suffix in {".rs", ".toml"} or path.name in {"Cargo.lock", "config"}:
                paths.append(path)
    return sorted(set(paths))


def source_fingerprint(crate_root: pathlib.Path = CRATE_ROOT) -> str:
    return _hash_paths(crate_root, source_paths(crate_root))


def binding_fingerprint(generated_root: pathlib.Path = GENERATED_ROOT) -> str:
    paths = [path for path in generated_root.rglob("*.kt") if path.is_file()]
    if not paths:
        raise VerificationError(f"no generated Kotlin bindings under {generated_root}")
    return _hash_paths(generated_root, paths)


def build_recipe_fingerprint() -> str:
    return _hash_paths(ROOT, [BUILD_SCRIPT, VERIFY_SCRIPT])


def rust_contract(crate_root: pathlib.Path = CRATE_ROOT) -> tuple[str, int]:
    source = (crate_root / "burnbar-remote-ffi" / "src" / "lib.rs").read_text()
    protocol = re.search(r'REMOTE_PROTOCOL_VERSION:\s*&str\s*=\s*"([^"]+)"', source)
    wire = re.search(r"REMOTE_WIRE_VERSION:\s*u8\s*=\s*(\d+)", source)
    if protocol is None or wire is None:
        raise VerificationError("could not read protocol/wire versions from burnbar-remote-ffi")
    return protocol.group(1), int(wire.group(1))


def expected_metadata(exports_sha256: str, profile: str = "release") -> dict[str, object]:
    protocol, wire = rust_contract()
    return {
        "schema_version": 1,
        "artifact": "burnbar-remote.aar",
        "source_sha256": source_fingerprint(),
        "build_recipe_sha256": build_recipe_fingerprint(),
        "kotlin_bindings_sha256": binding_fingerprint(),
        "uniffi_exports_sha256": exports_sha256,
        "profile": profile,
        "abis": list(ABIS),
        "native_libraries": list(LIBRARIES),
        "min_sdk": 26,
        "protocol_version": protocol,
        "wire_version": wire,
        "elf_load_alignment": 16384,
    }


def _elf_properties(contents: bytes) -> tuple[int, list[int]]:
    if contents[:4] != b"\x7fELF":
        raise VerificationError("native library is not ELF")
    elf_class, data = contents[4], contents[5]
    if elf_class not in (1, 2) or data not in (1, 2):
        raise VerificationError("unsupported ELF class or byte order")
    endian = "<" if data == 1 else ">"
    machine = struct.unpack_from(endian + "H", contents, 18)[0]
    if elf_class == 1:
        phoff = struct.unpack_from(endian + "I", contents, 28)[0]
        phentsize, phnum = struct.unpack_from(endian + "HH", contents, 42)
        align_offset = 28
        align_format = "I"
    else:
        phoff = struct.unpack_from(endian + "Q", contents, 32)[0]
        phentsize, phnum = struct.unpack_from(endian + "HH", contents, 54)
        align_offset = 48
        align_format = "Q"
    alignments = []
    for index in range(phnum):
        offset = phoff + index * phentsize
        if offset + phentsize > len(contents):
            raise VerificationError("truncated ELF program header table")
        if struct.unpack_from(endian + "I", contents, offset)[0] == 1:
            alignments.append(struct.unpack_from(endian + align_format, contents, offset + align_offset)[0])
    if not alignments:
        raise VerificationError("ELF has no LOAD segments")
    return machine, alignments


def exported_symbols(library: pathlib.Path, nm: str) -> list[str]:
    completed = subprocess.run(
        [nm, "-D", "--defined-only", str(library)],
        check=True,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    symbols = sorted(
        line.split()[-1]
        for line in completed.stdout.splitlines()
        if line.split() and (line.split()[-1].startswith("uniffi_") or line.split()[-1].startswith("ffi_burnbar_remote_"))
    )
    if not symbols:
        raise VerificationError(f"{library}: no UniFFI exports found")
    return symbols


def verify(aar_path: pathlib.Path = AAR_PATH, nm: str | None = None, expected_profile: str = "release") -> None:
    if not aar_path.is_file():
        raise VerificationError(f"missing committed AAR: {aar_path}")
    expected_entries = {
        "AndroidManifest.xml",
        "R.txt",
        "classes.jar",
        "proguard.txt",
        METADATA_ENTRY,
        EXPORTS_ENTRY,
    }
    expected_entries.update(f"jni/{abi}/{library}" for abi in ABIS for library in LIBRARIES)
    with zipfile.ZipFile(aar_path) as archive:
        names = set(archive.namelist())
        if names != expected_entries:
            raise VerificationError(
                f"AAR entry set drift: missing={sorted(expected_entries - names)} extra={sorted(names - expected_entries)}"
            )
        exports_bytes = archive.read(EXPORTS_ENTRY)
        exports = exports_bytes.decode().splitlines()
        if exports != sorted(set(exports)) or not exports:
            raise VerificationError("embedded UniFFI export set is empty, duplicated, or unsorted")
        exports_sha256 = hashlib.sha256(exports_bytes).hexdigest()
        metadata = json.loads(archive.read(METADATA_ENTRY))
        expected = expected_metadata(exports_sha256, expected_profile)
        if metadata != expected:
            raise VerificationError(
                "artifact metadata drift:\n"
                + json.dumps({"expected": expected, "actual": metadata}, indent=2, sort_keys=True)
            )

        with tempfile.TemporaryDirectory(prefix="burnbar-remote-aar-") as temp:
            temp_root = pathlib.Path(temp)
            observed_exports: list[list[str]] = []
            for abi, expected_machine in ABIS.items():
                primary = archive.read(f"jni/{abi}/{LIBRARIES[0]}")
                alias = archive.read(f"jni/{abi}/{LIBRARIES[1]}")
                if primary != alias:
                    raise VerificationError(f"{abi}: loader aliases are not byte-identical")
                machine, alignments = _elf_properties(primary)
                if machine != expected_machine:
                    raise VerificationError(f"{abi}: ELF machine {machine}, expected {expected_machine}")
                if any(alignment < 16384 for alignment in alignments):
                    raise VerificationError(f"{abi}: LOAD alignment below 16 KB: {alignments}")
                if nm is not None:
                    library_path = temp_root / f"{abi}.so"
                    library_path.write_bytes(primary)
                    observed_exports.append(exported_symbols(library_path, nm))
            if observed_exports and any(symbols != exports for symbols in observed_exports):
                raise VerificationError("embedded UniFFI export set does not match every native ABI")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--aar", type=pathlib.Path, default=AAR_PATH)
    parser.add_argument("--nm", help="llvm-nm path; also validates every ABI's native export set")
    parser.add_argument("--print-source-fingerprint", action="store_true")
    parser.add_argument("--print-binding-fingerprint", action="store_true")
    parser.add_argument("--write-metadata", type=pathlib.Path)
    parser.add_argument("--exports", type=pathlib.Path)
    parser.add_argument("--profile", choices=("debug", "release"), default="release")
    args = parser.parse_args()
    try:
        if args.print_source_fingerprint:
            print(source_fingerprint())
            return 0
        if args.print_binding_fingerprint:
            print(binding_fingerprint())
            return 0
        if args.write_metadata:
            if args.exports is None:
                raise VerificationError("--write-metadata requires --exports")
            exports_sha256 = hashlib.sha256(args.exports.read_bytes()).hexdigest()
            args.write_metadata.write_text(
                json.dumps(expected_metadata(exports_sha256, args.profile), indent=2, sort_keys=True) + "\n"
            )
            return 0
        verify(args.aar, args.nm, args.profile)
        print(f"PASS: {args.aar} provenance, API, four ABIs, and 16 KB ELF alignment")
        return 0
    except (OSError, ValueError, VerificationError, subprocess.CalledProcessError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
