import copy
import importlib.util
import json
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/domain-core-union-gate.py"
SPEC = importlib.util.spec_from_file_location("domain_core_union_gate", SCRIPT)
assert SPEC and SPEC.loader
GATE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GATE)


def materialize_abi_surfaces(root: pathlib.Path, manifest: dict[str, object]) -> None:
    domains = manifest["domains"]
    for surface in manifest["abiSurfaces"]:
        symbols = []
        for domain_name in surface["requiredDomains"]:
            symbols.extend(domains[domain_name][surface["kind"]])
        symbols.extend(surface.get("requiredSymbols", []))
        path = root / surface["path"]
        path.parent.mkdir(parents=True, exist_ok=True)
        contents = "\n".join(symbols) + "\n"
        if surface["name"] == "canonical-uniffi":
            contents += "\n".join(
                f"#[uniffi::export]\npub fn {symbol}() {{}}"
                for symbol in manifest["uniffiExports"]
            )
            contents += "\n"
        elif surface["name"] == "generated-swift-c-header":
            contents += "\n".join(
                f"void uniffi_openburnbar_domain_ffi_fn_func_{symbol}(void);"
                for symbol in manifest["uniffiExports"]
            )
            contents += "\n"
        path.write_text(contents, encoding="utf-8")


def materialize_android_toolchain_pins(root: pathlib.Path) -> None:
    crate = root / "crates/openburnbar-domain-core"
    crate.mkdir(parents=True, exist_ok=True)
    (crate / "rust-toolchain.toml").write_text(
        '[toolchain]\nchannel = "1.96.0"\n',
        encoding="ascii",
    )
    config = root / "config"
    config.mkdir(parents=True, exist_ok=True)
    (config / "domain-core-android-ndk-version.txt").write_text(
        "26.3.11579264\n",
        encoding="ascii",
    )


def materialize_build_identity_helper(
    root: pathlib.Path,
    source_crate: str,
) -> tuple[pathlib.Path, dict[str, object]]:
    crate_root = root / "crates/openburnbar-domain-core"
    crate = crate_root / source_crate
    source = crate / "src"
    source.mkdir(parents=True)
    shutil.copy2(
        ROOT / "crates/openburnbar-domain-core" / source_crate / "build.rs",
        crate / "build.rs",
    )
    build_support = crate_root / "build-support"
    build_support.mkdir()
    shutil.copy2(
        ROOT / "crates/openburnbar-domain-core/build-support/source_fingerprint.rs",
        build_support / "source_fingerprint.rs",
    )
    (crate / "Cargo.toml").write_text(
        f"""[package]
name = "{source_crate}-build-helper-contract"
version = "0.0.0"
edition = "2021"

[build-dependencies]
serde_json = "=1.0.150"
sha2 = "=0.10.9"
""",
        encoding="ascii",
    )
    (source / "lib.rs").write_text(
        """pub const COMPILED_SOURCE_FINGERPRINT: &str =
    env!("OPENBURNBAR_DOMAIN_CORE_SOURCE_FINGERPRINT");
include!(concat!(env!("CARGO_MANIFEST_DIR"), "/expected.rs"));

#[test]
fn compiled_identity_matches_verified_manifest() {
    assert_eq!(COMPILED_SOURCE_FINGERPRINT, EXPECTED_SOURCE_FINGERPRINT);
}
""",
        encoding="ascii",
    )
    return crate, {
        "schemaVersion": 1,
        "sourceRoots": [
            f"{source_crate}/build.rs",
            f"{source_crate}/src",
            "build-support",
        ]
    }


def run_build_identity_helper(
    root: pathlib.Path,
    crate: pathlib.Path,
    manifest: dict[str, object] | str,
    target_directory: pathlib.Path,
) -> subprocess.CompletedProcess[str]:
    manifest_payload = (
        manifest if isinstance(manifest, str) else json.dumps(manifest) + "\n"
    )
    (root / "crates/openburnbar-domain-core/union-abi-manifest.json").write_text(
        manifest_payload,
        encoding="ascii",
    )
    return subprocess.run(
        ["cargo", "test", "--quiet", "--offline"],
        cwd=crate,
        env={**os.environ, "CARGO_TARGET_DIR": str(target_directory)},
        capture_output=True,
        text=True,
        check=False,
    )


class DomainCoreUnionGateTests(unittest.TestCase):
    def test_workflow_routes_canonical_android_toolchain_changes(self) -> None:
        workflow = (ROOT / ".github/workflows/domain-core.yml").read_text(encoding="utf-8")
        self.assertEqual(
            workflow.count('"config/domain-core-android-ndk-version.txt"'),
            2,
            "push and pull-request path filters must both cover the canonical NDK pin",
        )

    def test_repository_manifest_matches_source_with_canonical_sha256(self) -> None:
        _, manifest = GATE.load_manifest(ROOT)
        fingerprint = GATE.verified_source_fingerprint(ROOT, manifest)
        self.assertRegex(fingerprint, re.compile(r"\A[0-9a-f]{64}\Z"))

    def test_native_binding_provenance_sidecars_match_canonical_source(self) -> None:
        _, manifest = GATE.load_manifest(ROOT)
        fingerprint = GATE.verified_source_fingerprint(ROOT, manifest)
        provenance_root = ROOT / "crates/openburnbar-domain-core/artifact-provenance"
        expected_sidecars = {
            "csharp.sha256",
            "kotlin.sha256",
            "swift.sha256",
        }
        actual_sidecars = {path.name for path in provenance_root.glob("*.sha256")}

        self.assertEqual(expected_sidecars, actual_sidecars)
        for sidecar_name in sorted(expected_sidecars):
            with self.subTest(sidecar=sidecar_name):
                value = GATE.read_sidecar(provenance_root / sidecar_name)
                self.assertRegex(value, re.compile(r"\A[0-9a-f]{64}\Z"))
                self.assertEqual(fingerprint, value)

    def test_loaded_source_fingerprint_is_a_required_uniffi_export(self) -> None:
        _, manifest = GATE.load_manifest(ROOT)
        export = "domain_core_source_fingerprint"
        self.assertIn(export, manifest["uniffiExports"])

        canonical_surface = next(
            ROOT / surface["path"]
            for surface in manifest["abiSurfaces"]
            if surface["name"] == "canonical-uniffi"
        )
        self.assertIn(
            export,
            GATE.extract_uniffi_exports(canonical_surface.read_text(encoding="utf-8")),
        )

    def test_missing_manifest_source_fingerprint_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            crate = root / "crates/openburnbar-domain-core"
            crate.mkdir(parents=True)
            (crate / "source.rs").write_text("source\n", encoding="utf-8")

            with self.assertRaisesRegex(GATE.GateError, "sourceSha256"):
                GATE.verified_source_fingerprint(root, {"sourceRoots": ["source.rs"]})

    def test_noncanonical_manifest_source_fingerprint_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            crate = root / "crates/openburnbar-domain-core"
            crate.mkdir(parents=True)
            (crate / "source.rs").write_text("source\n", encoding="utf-8")
            manifest = {"sourceRoots": ["source.rs"]}
            canonical = GATE.calculate_source_fingerprint(root, manifest)

            for malformed in ("g" * 64, canonical.upper(), canonical[:-1]):
                with self.subTest(fingerprint=malformed):
                    mutated = {**manifest, "sourceSha256": malformed}
                    with self.assertRaisesRegex(GATE.GateError, "sourceSha256"):
                        GATE.verified_source_fingerprint(root, mutated)

    def test_compile_time_identity_helper_rejects_missing_or_malformed_fingerprint(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            target_directory = root / "target"
            cases = {
                "missing": None,
                "non_string": 7,
                "uppercase": "A" * 64,
                "non_hex": "g" * 64,
                "short": "a" * 63,
            }

            for source_crate in ("domain-ffi", "domain-wasm"):
                for name, fingerprint in cases.items():
                    with self.subTest(helper=source_crate, case=name):
                        fixture_root = root / f"{source_crate}-{name}"
                        crate, manifest = materialize_build_identity_helper(
                            fixture_root,
                            source_crate,
                        )
                        if fingerprint is not None:
                            manifest["sourceSha256"] = fingerprint
                        result = run_build_identity_helper(
                            fixture_root,
                            crate,
                            manifest,
                            target_directory,
                        )
                        self.assertNotEqual(0, result.returncode)
                        self.assertIn("sourceSha256", result.stderr)

    def test_compile_time_identity_helpers_emit_verified_fingerprint(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            target_directory = root / "target"
            for source_crate in ("domain-ffi", "domain-wasm"):
                with self.subTest(helper=source_crate):
                    fixture_root = root / source_crate
                    crate, manifest = materialize_build_identity_helper(
                        fixture_root,
                        source_crate,
                    )
                    fingerprint = GATE.calculate_source_fingerprint(fixture_root, manifest)
                    manifest["sourceSha256"] = fingerprint
                    (crate / "expected.rs").write_text(
                        f'pub const EXPECTED_SOURCE_FINGERPRINT: &str = "{fingerprint}";\n',
                        encoding="ascii",
                    )

                    result = run_build_identity_helper(
                        fixture_root,
                        crate,
                        manifest,
                        target_directory,
                    )
                    self.assertEqual(0, result.returncode, result.stderr)

    def test_compile_time_identity_helpers_reject_valid_but_stale_source(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            target_directory = root / "target"
            for source_crate in ("domain-ffi", "domain-wasm"):
                with self.subTest(helper=source_crate):
                    fixture_root = root / source_crate
                    crate, manifest = materialize_build_identity_helper(
                        fixture_root,
                        source_crate,
                    )
                    fingerprint = GATE.calculate_source_fingerprint(fixture_root, manifest)
                    manifest["sourceSha256"] = fingerprint
                    (crate / "src/lib.rs").write_text(
                        (crate / "src/lib.rs").read_text(encoding="ascii")
                        + "pub fn source_mutation() {}\n",
                        encoding="ascii",
                    )

                    result = run_build_identity_helper(
                        fixture_root,
                        crate,
                        manifest,
                        target_directory,
                    )
                    self.assertNotEqual(0, result.returncode)
                    self.assertIn("source fingerprint drifted", result.stderr)

    def test_compile_time_identity_helpers_reject_invalid_json(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            target_directory = root / "target"
            for source_crate in ("domain-ffi", "domain-wasm"):
                with self.subTest(helper=source_crate):
                    fixture_root = root / source_crate
                    crate, _ = materialize_build_identity_helper(fixture_root, source_crate)
                    result = run_build_identity_helper(
                        fixture_root,
                        crate,
                        "{not-json\n",
                        target_directory,
                    )
                    self.assertNotEqual(0, result.returncode)
                    self.assertIn("cannot parse", result.stderr)

    def test_synthetic_union_abi_is_complete(self) -> None:
        _, manifest = GATE.load_manifest(ROOT)
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            materialize_abi_surfaces(root, manifest)
            GATE.check_abi(root, manifest)

    def test_missing_named_reseal_nonce_fails_closed(self) -> None:
        _, manifest = GATE.load_manifest(ROOT)
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            materialize_abi_surfaces(root, manifest)
            swift = root / next(
                surface["path"]
                for surface in manifest["abiSurfaces"]
                if surface["name"] == "generated-swift"
            )
            swift.write_text(
                swift.read_text(encoding="utf-8").replace("CloudVaultResealNonce", ""),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(GATE.GateError, "CloudVaultResealNonce"):
                GATE.check_abi(root, manifest)

    def test_missing_canonical_wasm_nonce_plan_error_fails_closed(self) -> None:
        _, manifest = GATE.load_manifest(ROOT)
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            materialize_abi_surfaces(root, manifest)
            wasm = root / next(
                surface["path"]
                for surface in manifest["abiSurfaces"]
                if surface["name"] == "canonical-wasm"
            )
            wasm.write_text(
                wasm.read_text(encoding="utf-8").replace("invalid_rewrap_nonce_plan", ""),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(GATE.GateError, "invalid_rewrap_nonce_plan"):
                GATE.check_abi(root, manifest)

    def test_omitted_domain_fails_closed(self) -> None:
        _, manifest = GATE.load_manifest(ROOT)
        mutated = copy.deepcopy(manifest)
        del mutated["domains"]["hermes"]
        with self.assertRaisesRegex(GATE.GateError, "exactly the required"):
            GATE.check_abi(ROOT, mutated)

    def test_omitted_full_union_surface_fails_closed(self) -> None:
        _, manifest = GATE.load_manifest(ROOT)
        mutated = copy.deepcopy(manifest)
        mutated["abiSurfaces"] = [
            surface
            for surface in mutated["abiSurfaces"]
            if surface["name"] != "generated-csharp"
        ]
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            materialize_abi_surfaces(root, mutated)
            with self.assertRaisesRegex(GATE.GateError, "full union coverage"):
                GATE.check_abi(root, mutated)

    def test_undeclared_uniffi_export_fails_closed(self) -> None:
        _, manifest = GATE.load_manifest(ROOT)
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            materialize_abi_surfaces(root, manifest)
            rust = root / next(
                surface["path"]
                for surface in manifest["abiSurfaces"]
                if surface["name"] == "canonical-uniffi"
            )
            rust.write_text(
                rust.read_text(encoding="utf-8")
                + "#[uniffi::export]\npub fn undeclared_export() {}\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(GATE.GateError, "undeclared=undeclared_export"):
                GATE.check_abi(root, manifest)

    def test_generated_header_export_drift_fails_closed(self) -> None:
        _, manifest = GATE.load_manifest(ROOT)
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            materialize_abi_surfaces(root, manifest)
            header = root / next(
                surface["path"]
                for surface in manifest["abiSurfaces"]
                if surface["name"] == "generated-swift-c-header"
            )
            header.write_text(
                header.read_text(encoding="utf-8")
                + "void uniffi_openburnbar_domain_ffi_fn_func_undeclared_export(void);\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(GATE.GateError, "undeclared=undeclared_export"):
                GATE.check_abi(root, manifest)

    def test_missing_and_stale_sidecars_fail_closed(self) -> None:
        fingerprint = "a" * 64
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            with self.assertRaisesRegex(GATE.GateError, "missing provenance sidecar"):
                GATE.check_provenance(root, fingerprint, ["swift"])
            sidecar = root / "crates/openburnbar-domain-core/artifact-provenance/swift.sha256"
            sidecar.parent.mkdir(parents=True)
            sidecar.write_text("b" * 64 + "\n", encoding="ascii")
            with self.assertRaisesRegex(GATE.GateError, "swift provenance is stale"):
                GATE.check_provenance(root, fingerprint, ["swift"])

    def test_stale_aar_embedded_provenance_fails_closed(self) -> None:
        fingerprint = "a" * 64
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            materialize_android_toolchain_pins(root)
            aar = root / "Vendor/openburnbar-domain-core.aar"
            aar.parent.mkdir(parents=True)
            with zipfile.ZipFile(aar, "w") as archive:
                archive.writestr(
                    f"META-INF/{GATE.FINGERPRINT_NAME}",
                    "b" * 64 + "\n",
                )
                archive.writestr(
                    f"META-INF/{GATE.ANDROID_TOOLCHAIN_PROVENANCE_NAME}",
                    "rust=1.96.0\nndk=26.3.11579264\n",
                )
            with self.assertRaisesRegex(GATE.GateError, "aar provenance is stale"):
                GATE.check_provenance(root, fingerprint, ["aar"])

    def test_stale_aar_toolchain_provenance_fails_closed(self) -> None:
        fingerprint = "a" * 64
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            materialize_android_toolchain_pins(root)
            aar = root / "Vendor/openburnbar-domain-core.aar"
            aar.parent.mkdir(parents=True)
            with zipfile.ZipFile(aar, "w") as archive:
                archive.writestr(
                    f"META-INF/{GATE.FINGERPRINT_NAME}",
                    fingerprint + "\n",
                )
                archive.writestr(
                    f"META-INF/{GATE.ANDROID_TOOLCHAIN_PROVENANCE_NAME}",
                    "rust=1.96.0\nndk=29.0.14206865\n",
                )
            with self.assertRaisesRegex(GATE.GateError, "toolchain provenance is stale"):
                GATE.check_provenance(root, fingerprint, ["aar"])

    def test_canonical_aar_toolchain_provenance_passes(self) -> None:
        fingerprint = "a" * 64
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            materialize_android_toolchain_pins(root)
            aar = root / "Vendor/openburnbar-domain-core.aar"
            aar.parent.mkdir(parents=True)
            with zipfile.ZipFile(aar, "w") as archive:
                archive.writestr(
                    f"META-INF/{GATE.FINGERPRINT_NAME}",
                    fingerprint + "\n",
                )
                archive.writestr(
                    f"META-INF/{GATE.ANDROID_TOOLCHAIN_PROVENANCE_NAME}",
                    "rust=1.96.0\nndk=26.3.11579264\n",
                )

            GATE.check_provenance(root, fingerprint, ["aar"])

    def test_unknown_provenance_surface_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            with self.assertRaisesRegex(GATE.GateError, "unknown provenance surfaces"):
                GATE.check_provenance(pathlib.Path(temporary), "a" * 64, ["mystery"])

    def test_source_mutation_invalidates_fingerprint(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            crate = root / "crates/openburnbar-domain-core"
            crate.mkdir(parents=True)
            (crate / "source.rs").write_text("before\n", encoding="utf-8")
            manifest = {"sourceRoots": ["source.rs"], "sourceSha256": "0" * 64}
            manifest["sourceSha256"] = GATE.calculate_source_fingerprint(root, manifest)
            GATE.verified_source_fingerprint(root, manifest)
            (crate / "source.rs").write_text("after\n", encoding="utf-8")
            with self.assertRaisesRegex(GATE.GateError, "fingerprint drifted"):
                GATE.verified_source_fingerprint(root, manifest)

    def test_update_source_fingerprint_atomically_rewrites_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            crate = root / "crates/openburnbar-domain-core"
            crate.mkdir(parents=True)
            (crate / "source.rs").write_text("source\n", encoding="utf-8")
            manifest_path = crate / "union-abi-manifest.json"
            manifest = {
                "schemaVersion": 1,
                "sourceSha256": "0" * 64,
                "sourceRoots": ["source.rs"],
            }
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            result = subprocess.run(
                [
                    sys.executable,
                    str(SCRIPT),
                    "--root",
                    str(root),
                    "--update-source-fingerprint",
                ],
                check=True,
                capture_output=True,
                text=True,
            )
            actual = result.stdout.strip()
            updated = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(actual, updated["sourceSha256"])
            self.assertEqual([], list(crate.glob(".*.tmp")))


if __name__ == "__main__":
    unittest.main()
