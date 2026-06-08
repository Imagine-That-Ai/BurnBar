#!/usr/bin/env python3
"""Run Android Signal runtime JVM tests with a non-secret Firebase fallback.

The Android Google Services Gradle plugin requires android/app/google-services.json
before it will build even local JVM unit tests. Runtime evidence for the Kotlin
Signal gate must not depend on a developer's real Firebase config, so this
script materializes a deterministic unit-test-only config when the real file is
absent, runs the targeted offline Signal tests, and removes only the file it
created.
"""

from __future__ import annotations

import argparse
from contextlib import contextmanager
import json
import os
from pathlib import Path
import subprocess
import sys
from typing import Iterator


ROOT = Path(__file__).resolve().parents[2]
UNIT_TEST_PROJECT_ID = "openburnbar-unit-tests"
UNIT_TEST_MARKER = "unit-test-google-services-json\n"
UNIT_TEST_API_KEY = "AIza000000000000000000000000000000000"

SIGNAL_RUNTIME_GRADLE_ARGS = [
    "./gradlew",
    ":app:testDebugUnitTest",
    "--tests",
    "*AndroidSignalSession*",
    "--tests",
    "*AndroidSignalInteropKatTest",
    "--tests",
    "*AndroidCloudVaultSignalPayloadsTest",
    "--tests",
    "*AndroidSignalIdentityKeyStoreTest",
    "--no-daemon",
    "--rerun-tasks",
]


def unit_test_google_services_payload() -> dict:
    return {
        "project_info": {
            "project_number": "000000000000",
            "project_id": UNIT_TEST_PROJECT_ID,
            "storage_bucket": f"{UNIT_TEST_PROJECT_ID}.firebasestorage.app",
        },
        "client": [
            {
                "client_info": {
                    "mobilesdk_app_id": "1:000000000000:android:0000000000000000000000",
                    "android_client_info": {
                        "package_name": "com.openburnbar",
                    },
                },
                "oauth_client": [],
                "api_key": [
                    {
                        "current_key": UNIT_TEST_API_KEY,
                    },
                ],
                "services": {
                    "appinvite_service": {
                        "other_platform_oauth_client": [],
                    },
                },
            }
        ],
        "configuration_version": "1",
    }


def _load_json(path: Path) -> dict | None:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None


def is_unit_test_google_services_config(path: Path) -> bool:
    payload = _load_json(path)
    if not isinstance(payload, dict):
        return False
    project_info = payload.get("project_info")
    client = payload.get("client")
    if not isinstance(project_info, dict) or not isinstance(client, list) or not client:
        return False
    first_client = client[0]
    if not isinstance(first_client, dict):
        return False
    client_info = first_client.get("client_info")
    if not isinstance(client_info, dict):
        return False
    android_client_info = client_info.get("android_client_info")
    if not isinstance(android_client_info, dict):
        return False
    api_key = first_client.get("api_key")
    if not isinstance(api_key, list) or not api_key or not isinstance(api_key[0], dict):
        return False
    return (
        project_info.get("project_id") == UNIT_TEST_PROJECT_ID
        and android_client_info.get("package_name") == "com.openburnbar"
        and client_info.get("mobilesdk_app_id") == "1:000000000000:android:0000000000000000000000"
        and api_key[0].get("current_key") == UNIT_TEST_API_KEY
    )


@contextmanager
def ensure_unit_test_google_services(repo_root: Path) -> Iterator[Path]:
    app_dir = repo_root / "android" / "app"
    json_path = app_dir / "google-services.json"
    marker_path = app_dir / ".firebase-unit-test-injected"

    if json_path.exists():
        if marker_path.exists() and not is_unit_test_google_services_config(json_path):
            raise RuntimeError(
                "refusing to use android/app/.firebase-unit-test-injected because "
                "android/app/google-services.json is not the deterministic unit-test config"
            )
        yield json_path
        return

    app_dir.mkdir(parents=True, exist_ok=True)
    payload = json.dumps(unit_test_google_services_payload(), indent=2, sort_keys=True) + "\n"
    temp_path = json_path.with_name("google-services.json.unit-test.tmp")
    created = False
    try:
        temp_path.write_text(payload, encoding="utf-8")
        temp_path.replace(json_path)
        marker_path.write_text(UNIT_TEST_MARKER, encoding="utf-8")
        created = True
        yield json_path
    finally:
        if created and marker_path.exists() and is_unit_test_google_services_config(json_path):
            json_path.unlink(missing_ok=True)
            marker_path.unlink(missing_ok=True)
        temp_path.unlink(missing_ok=True)


def android_test_environment(base_env: dict[str, str] | None = None) -> dict[str, str]:
    env = dict(base_env or os.environ)
    if not env.get("JAVA_HOME"):
        for candidate in (
            Path.home() / ".homebrew" / "opt" / "openjdk@21",
            Path("/opt/homebrew/opt/openjdk@21"),
            Path("/usr/local/opt/openjdk@21"),
        ):
            if candidate.is_dir():
                env["JAVA_HOME"] = str(candidate)
                break
    if not env.get("ANDROID_HOME"):
        for candidate in (
            Path.home() / "Library" / "Android" / "sdk",
            Path.home() / "Library" / "Android",
        ):
            if candidate.is_dir():
                env["ANDROID_HOME"] = str(candidate)
                break
    if env.get("ANDROID_HOME") and not env.get("ANDROID_SDK_ROOT"):
        env["ANDROID_SDK_ROOT"] = env["ANDROID_HOME"]
    return env


def run_android_signal_runtime_tests(repo_root: Path) -> int:
    android_dir = repo_root / "android"
    with ensure_unit_test_google_services(repo_root) as json_path:
        if is_unit_test_google_services_config(json_path):
            print("Using deterministic unit-test Firebase config for Android JVM tests.")
        else:
            print("Using existing Android Firebase config for Android JVM tests.")
        result = subprocess.run(
            SIGNAL_RUNTIME_GRADLE_ARGS,
            cwd=android_dir,
            env=android_test_environment(),
            check=False,
        )
    return result.returncode


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=Path, default=ROOT)
    args = parser.parse_args(argv)
    try:
        return run_android_signal_runtime_tests(args.repo_root.resolve())
    except RuntimeError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
