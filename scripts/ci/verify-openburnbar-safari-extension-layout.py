#!/usr/bin/env python3
"""Fail-closed structural validation for the embedded Safari Web Extension."""

from __future__ import annotations

import json
import os
import plistlib
import sys
from pathlib import Path


EXPECTED_BUNDLE_ID = "com.openburnbar.app.safari-extension"
EXPECTED_EXTENSION_POINT = "com.apple.Safari.web-extension"
EXPECTED_MINIMUM_SAFARI = "15.4"
EXPECTED_PERSISTENT_HOSTS = frozenset(
    {
        "http://127.0.0.1/*",
        "http://localhost/*",
        "http://[::1]/*",
    }
)
EXPECTED_OPTIONAL_PAGE_HOSTS = frozenset({"http://*/*", "https://*/*"})
REQUIRED_PERMISSIONS = frozenset(
    {"activeTab", "nativeMessaging", "scripting", "storage", "tabs"}
)


def fail(message: str) -> None:
    raise SystemExit(f"ERROR: {message}")


def require_equal(actual: object, expected: object, label: str) -> None:
    if actual != expected:
        fail(f"{label} must be {expected!r}; found {actual!r}.")


def require_member(values: object, expected: str, label: str) -> None:
    if not isinstance(values, list) or expected not in values:
        fail(f"{label} must include {expected!r}; found {values!r}.")


def require_exact_string_set(
    values: object, expected: frozenset[str], label: str
) -> None:
    if (
        not isinstance(values, list)
        or any(not isinstance(value, str) for value in values)
        or len(values) != len(expected)
        or set(values) != expected
    ):
        fail(f"{label} must be exactly {sorted(expected)!r}; found {values!r}.")


def load_plist(path: Path) -> dict[str, object]:
    try:
        with path.open("rb") as file:
            value = plistlib.load(file)
    except (OSError, plistlib.InvalidFileException) as error:
        fail(f"unable to read plist {path}: {error}")
    if not isinstance(value, dict):
        fail(f"plist root must be a dictionary: {path}")
    return value


def load_manifest(path: Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        fail(f"unable to read Safari manifest {path}: {error}")
    if not isinstance(value, dict):
        fail(f"Safari manifest root must be an object: {path}")
    return value


def validate(appex_path: Path) -> None:
    if not appex_path.is_dir() or appex_path.is_symlink():
        fail(f"Safari extension must be a real bundle directory: {appex_path}")

    contents = appex_path / "Contents"
    info_path = contents / "Info.plist"
    resources = contents / "Resources"
    manifest_path = resources / "manifest.json"
    if not info_path.is_file() or info_path.is_symlink():
        fail(f"Safari extension Info.plist is missing or symlinked at {info_path}.")
    if not manifest_path.is_file() or manifest_path.is_symlink():
        fail(
            "Safari WebExtension manifest must exist at the appex resource root: "
            f"{manifest_path}."
        )

    info = load_plist(info_path)
    require_equal(
        info.get("CFBundleIdentifier"),
        EXPECTED_BUNDLE_ID,
        "Safari extension CFBundleIdentifier",
    )
    require_equal(
        info.get("CFBundlePackageType"),
        "XPC!",
        "Safari extension CFBundlePackageType",
    )
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable:
        fail("Safari extension CFBundleExecutable must be non-empty.")
    executable_path = contents / "MacOS" / executable
    if not executable_path.is_file() or not os.access(executable_path, os.X_OK):
        fail(
            "Safari extension executable is missing or not executable at "
            f"{executable_path}."
        )

    extension = info.get("NSExtension")
    if not isinstance(extension, dict):
        fail("Safari extension Info.plist must contain an NSExtension dictionary.")
    require_equal(
        extension.get("NSExtensionPointIdentifier"),
        EXPECTED_EXTENSION_POINT,
        "Safari NSExtensionPointIdentifier",
    )
    principal_class = extension.get("NSExtensionPrincipalClass")
    if not isinstance(principal_class, str) or not principal_class.endswith(
        ".SafariWebExtensionHandler"
    ):
        fail(
            "Safari NSExtensionPrincipalClass must resolve to "
            "<module>.SafariWebExtensionHandler."
        )

    manifest = load_manifest(manifest_path)
    require_equal(manifest.get("manifest_version"), 3, "Safari manifest_version")
    require_equal(
        manifest.get("version"),
        info.get("CFBundleShortVersionString"),
        "Safari manifest/app version",
    )
    background = manifest.get("background")
    if not isinstance(background, dict):
        fail("Safari manifest background must be an object.")
    require_equal(
        background.get("service_worker"),
        "background.js",
        "Safari background service worker",
    )
    browser_settings = manifest.get("browser_specific_settings")
    safari_settings = (
        browser_settings.get("safari")
        if isinstance(browser_settings, dict)
        else None
    )
    require_equal(
        safari_settings.get("strict_min_version")
        if isinstance(safari_settings, dict)
        else None,
        EXPECTED_MINIMUM_SAFARI,
        "Safari strict_min_version",
    )
    permissions = manifest.get("permissions")
    for permission in sorted(REQUIRED_PERMISSIONS):
        require_member(permissions, permission, "Safari manifest permissions")
    require_exact_string_set(
        manifest.get("host_permissions"),
        EXPECTED_PERSISTENT_HOSTS,
        "Safari persistent host permissions",
    )
    require_exact_string_set(
        manifest.get("optional_host_permissions"),
        EXPECTED_OPTIONAL_PAGE_HOSTS,
        "Safari optional page host permissions",
    )
    if "safari" in manifest:
        fail("Safari manifest settings must live under browser_specific_settings.safari.")

    referenced_files: list[object] = [
        background.get("service_worker"),
    ]
    action = manifest.get("action")
    if not isinstance(action, dict):
        fail("Safari manifest action must be an object.")
    require_equal(
        action.get("default_popup"),
        "popup.html",
        "Safari action default_popup",
    )
    referenced_files.append(action.get("default_popup"))
    default_icon = action.get("default_icon")
    if isinstance(default_icon, dict):
        referenced_files.extend(default_icon.values())
    icons = manifest.get("icons")
    if isinstance(icons, dict):
        referenced_files.extend(icons.values())
    web_resources = manifest.get("web_accessible_resources")
    if isinstance(web_resources, list):
        for entry in web_resources:
            if isinstance(entry, dict) and isinstance(entry.get("resources"), list):
                referenced_files.extend(entry["resources"])

    content_security_policy = manifest.get("content_security_policy")
    extension_pages_csp = (
        content_security_policy.get("extension_pages")
        if isinstance(content_security_policy, dict)
        else None
    )
    if not isinstance(extension_pages_csp, str):
        fail("Safari manifest must define content_security_policy.extension_pages.")
    if "script-src 'self'" not in extension_pages_csp:
        fail("Safari extension CSP must restrict scripts to 'self'.")
    if "object-src 'none'" not in extension_pages_csp:
        fail("Safari extension CSP must disable object sources.")
    if any(
        forbidden in extension_pages_csp
        for forbidden in ("'unsafe-eval'", "'unsafe-inline'", "http:", "https:")
    ):
        fail("Safari extension CSP must not authorize inline, evaluated, or remote code.")

    resources_root = resources.resolve()
    for relative in sorted(
        {value for value in referenced_files if isinstance(value, str)}
    ):
        relative_path = Path(relative)
        if not relative or relative_path.is_absolute() or ".." in relative_path.parts:
            fail(f"Safari manifest contains an unsafe resource path: {relative!r}.")
        candidate = (resources_root / relative_path).resolve()
        try:
            candidate.relative_to(resources_root)
        except ValueError:
            fail(
                "Safari manifest resource escapes the appex resource root: "
                f"{relative!r}."
            )
        if not candidate.is_file():
            fail(f"Safari manifest references missing resource {relative!r}.")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit(f"usage: {sys.argv[0]} /path/to/OpenBurnBarSafariExtension.appex")
    validate(Path(sys.argv[1]))
    print(
        "PASS: OpenBurnBar Safari appex layout, identity, native handler, MV3 "
        "manifest, and referenced WebExtension resources are complete."
    )


if __name__ == "__main__":
    main()
