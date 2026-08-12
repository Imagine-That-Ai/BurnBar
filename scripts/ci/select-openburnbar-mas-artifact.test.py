from __future__ import annotations

import importlib.util
import plistlib
import sys
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/ci/select-openburnbar-mas-artifact.py"
SPEC = importlib.util.spec_from_file_location("select_openburnbar_mas_artifact", SCRIPT)
if SPEC is None or SPEC.loader is None:
    raise RuntimeError(f"cannot load {SCRIPT}")
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class SelectOpenBurnBarMASArtifactTests(unittest.TestCase):
    def root(self) -> Path:
        return Path(self.enterContext(tempfile.TemporaryDirectory()))

    def app(self, root: Path, name: str = "OpenBurnBar.app") -> Path:
        app = root / name
        info = app / "Contents" / "Info.plist"
        info.parent.mkdir(parents=True)
        with info.open("wb") as file:
            plistlib.dump(
                {
                    "CFBundleIdentifier": "com.openburnbar.app",
                    "CFBundleShortVersionString": "1.2.3",
                    "CFBundleVersion": "456",
                },
                file,
            )
        return app

    def test_selects_one_exact_app_and_validates_metadata(self) -> None:
        root = self.root()
        app = self.app(root)
        selected = MODULE.select(
            root=root,
            kind="app",
            recursive=False,
            expected=app,
            bundle_id="com.openburnbar.app",
            version="1.2.3",
            build="456",
        )
        self.assertEqual(selected, app.resolve())

    def test_rejects_ambiguous_packages(self) -> None:
        root = self.root()
        (root / "one.pkg").write_bytes(b"one")
        (root / "two.pkg").write_bytes(b"two")
        with self.assertRaisesRegex(ValueError, "expected exactly one pkg"):
            MODULE.select(
                root=root,
                kind="pkg",
                recursive=False,
                expected=None,
                bundle_id=None,
                version=None,
                build=None,
            )

    def test_rejects_symlink_candidate(self) -> None:
        root = self.root()
        target = root / "target.pkg"
        target.write_bytes(b"pkg")
        link_root = root / "export"
        link_root.mkdir()
        (link_root / "OpenBurnBar.pkg").symlink_to(target)
        with self.assertRaisesRegex(ValueError, "must not be a symlink"):
            MODULE.select(
                root=link_root,
                kind="pkg",
                recursive=False,
                expected=None,
                bundle_id=None,
                version=None,
                build=None,
            )

    def test_rejects_wrong_app_metadata(self) -> None:
        root = self.root()
        self.app(root)
        with self.assertRaisesRegex(ValueError, "version must be '9.9.9'"):
            MODULE.select(
                root=root,
                kind="app",
                recursive=False,
                expected=None,
                bundle_id="com.openburnbar.app",
                version="9.9.9",
                build="456",
            )

    def test_recursive_selection_still_rejects_duplicate_exported_apps(self) -> None:
        root = self.root()
        self.app(root / "one")
        self.app(root / "two")
        with self.assertRaisesRegex(ValueError, "found 2"):
            MODULE.select(
                root=root,
                kind="app",
                recursive=True,
                expected=None,
                bundle_id=None,
                version=None,
                build=None,
            )


if __name__ == "__main__":
    unittest.main()
