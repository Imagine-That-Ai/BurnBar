import copy
import importlib.util
import json
import pathlib
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


class DomainCoreUnionGateTests(unittest.TestCase):
    def test_repository_manifest_matches_source(self) -> None:
        _, manifest = GATE.load_manifest(ROOT)
        fingerprint = GATE.verified_source_fingerprint(ROOT, manifest)
        self.assertEqual(64, len(fingerprint))

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
            aar = root / "Vendor/openburnbar-domain-core.aar"
            aar.parent.mkdir(parents=True)
            with zipfile.ZipFile(aar, "w") as archive:
                archive.writestr(
                    f"META-INF/{GATE.FINGERPRINT_NAME}",
                    "b" * 64 + "\n",
                )
            with self.assertRaisesRegex(GATE.GateError, "aar provenance is stale"):
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
