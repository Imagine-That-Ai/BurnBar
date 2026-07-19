from __future__ import annotations

import importlib.util
import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest import mock


ROOT = Path(__file__).resolve().parents[1]
PATH = ROOT / "scripts/ci/verify-domain-core-ios-binary-identity.py"
SPEC = importlib.util.spec_from_file_location("ios_binary_identity", PATH)
assert SPEC and SPEC.loader
IDENTITY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(IDENTITY)

CANDIDATE = {
    "candidateCommit": "1" * 40,
    "coreVersion": "0.3.0",
    "abiVersion": 3,
    "sourceSha256": "2" * 64,
}


def wire(candidate: dict[str, object] = CANDIDATE) -> bytes:
    return (
        "openburnbar-domain-core-identity-v1|"
        f"candidateCommit={candidate['candidateCommit']}|"
        f"coreVersion={candidate['coreVersion']}|"
        f"abiVersion={candidate['abiVersion']}|"
        f"sourceSha256={candidate['sourceSha256']}"
    ).encode()


def otool(value: bytes) -> str:
    lines = ["Contents of (__TEXT,__obb_core_id) section"]
    for index in range(0, len(value), 16):
        chunk = value[index : index + 16]
        groups = " ".join(
            chunk[offset : offset + 4].ljust(4, b"\0")[::-1].hex()
            for offset in range(0, len(chunk), 4)
        )
        lines.append(f"000000010000{index:04x} {groups}")
    return "\n".join(lines) + "\n"


class IosBinaryIdentityTests(unittest.TestCase):
    def fixture(self, root: Path) -> tuple[Path, Path, Path]:
        app = root / "App.app"
        app.mkdir()
        (app / "Info.plist").write_bytes(
            plistlib.dumps(
                {
                    "CFBundleExecutable": "App",
                    "CFBundleIdentifier": "com.openburnbar.mobile",
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "123",
                }
            )
        )
        (app / "App").write_bytes(b"signed Mach-O bytes")
        candidate = root / "candidate.json"
        candidate.write_text(json.dumps(CANDIDATE))
        return app, candidate, root / "receipt.json"

    def runner(self, section: bytes = wire(), *, omit_symbol: str | None = None):
        symbols = {IDENTITY.IDENTITY_SYMBOL} | IDENTITY.FFI_IDENTITY_SYMBOLS
        if omit_symbol:
            symbols.remove(omit_symbol)

        def invoke(*command: str, timeout: int = 60) -> str:
            del timeout
            if command[0] == "file":
                return "Mach-O 64-bit executable arm64\n"
            if command[0] == "lipo":
                return "arm64\n"
            if command[0] == "nm":
                return "\n".join(f"_{symbol}" for symbol in sorted(symbols)) + "\n"
            if command[0] == "otool":
                return otool(section)
            raise AssertionError(command)

        return invoke

    def test_derives_complete_identity_from_linked_macho_section(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app, candidate, output = self.fixture(Path(directory))
            with mock.patch.object(IDENTITY, "run", side_effect=self.runner()):
                result = IDENTITY.verify(app, candidate, output)
            self.assertEqual(CANDIDATE, result["observed"])
            self.assertEqual(CANDIDATE, result["candidate"])
            self.assertEqual("arm64", result["architectures"][0])
            self.assertEqual(64, len(result["executableSha256"]))
            self.assertEqual(64, len(result["identitySectionSha256"]))
            self.assertIn(
                "uniffi_openburnbar_domain_ffi_fn_func_domain_core_candidate_commit",
                result["identitySymbols"],
            )

    def test_rejects_decoy_strings_without_identity_section(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app, candidate, output = self.fixture(Path(directory))
            (app / "App").write_bytes(b"Mach-O\0" + wire())
            with (
                mock.patch.object(IDENTITY, "run", side_effect=self.runner(b"")),
                self.assertRaisesRegex(ValueError, "identity section"),
            ):
                IDENTITY.verify(app, candidate, output)

    def test_rejects_missing_ffi_identity_symbol(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app, candidate, output = self.fixture(Path(directory))
            missing = "uniffi_openburnbar_domain_ffi_fn_func_domain_core_abi_version"
            with (
                mock.patch.object(IDENTITY, "run", side_effect=self.runner(omit_symbol=missing)),
                self.assertRaisesRegex(ValueError, "missing linked Rust identity symbols"),
            ):
                IDENTITY.verify(app, candidate, output)

    def test_rejects_tampered_abi_in_shipped_slice(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app, candidate, output = self.fixture(Path(directory))
            tampered = wire({**CANDIDATE, "abiVersion": 4})
            with (
                mock.patch.object(IDENTITY, "run", side_effect=self.runner(tampered)),
                self.assertRaisesRegex(ValueError, "abiVersion"),
            ):
                IDENTITY.verify(app, candidate, output)

    def test_rejects_tampered_candidate_commit_in_shipped_slice(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            app, candidate, output = self.fixture(Path(directory))
            tampered = wire({**CANDIDATE, "candidateCommit": "9" * 40})
            with (
                mock.patch.object(IDENTITY, "run", side_effect=self.runner(tampered)),
                self.assertRaisesRegex(ValueError, "candidateCommit"),
            ):
                IDENTITY.verify(app, candidate, output)


if __name__ == "__main__":
    unittest.main()
