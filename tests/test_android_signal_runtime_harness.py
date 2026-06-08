import json
from pathlib import Path

import pytest

from scripts.ci.run_android_signal_runtime_tests import (
    UNIT_TEST_API_KEY,
    UNIT_TEST_MARKER,
    UNIT_TEST_PROJECT_ID,
    android_test_environment,
    ensure_unit_test_google_services,
    is_unit_test_google_services_config,
)


def google_services_path(repo_root: Path) -> Path:
    return repo_root / "android" / "app" / "google-services.json"


def marker_path(repo_root: Path) -> Path:
    return repo_root / "android" / "app" / ".firebase-unit-test-injected"


def test_unit_test_google_services_config_is_created_and_cleaned_up(tmp_path):
    with ensure_unit_test_google_services(tmp_path) as path:
        assert path == google_services_path(tmp_path)
        assert path.exists()
        assert marker_path(tmp_path).read_text(encoding="utf-8") == UNIT_TEST_MARKER
        assert is_unit_test_google_services_config(path)
        payload = json.loads(path.read_text(encoding="utf-8"))
        assert payload["project_info"]["project_id"] == UNIT_TEST_PROJECT_ID
        assert payload["client"][0]["api_key"][0]["current_key"] == UNIT_TEST_API_KEY
        assert UNIT_TEST_API_KEY.startswith("AIza")
        assert "REPLACE_" not in path.read_text(encoding="utf-8")

    assert not google_services_path(tmp_path).exists()
    assert not marker_path(tmp_path).exists()


def test_existing_real_google_services_config_is_preserved(tmp_path):
    path = google_services_path(tmp_path)
    path.parent.mkdir(parents=True)
    path.write_text(
        json.dumps(
            {
                "project_info": {"project_id": "burnbar-real"},
                "client": [
                    {
                        "client_info": {
                            "mobilesdk_app_id": "1:real:android:real",
                            "android_client_info": {"package_name": "com.openburnbar"},
                        }
                    }
                ],
            }
        ),
        encoding="utf-8",
    )

    with ensure_unit_test_google_services(tmp_path) as resolved:
        assert resolved == path

    assert path.exists()
    assert json.loads(path.read_text(encoding="utf-8"))["project_info"]["project_id"] == "burnbar-real"
    assert not marker_path(tmp_path).exists()


def test_unit_test_config_recognizer_requires_dummy_api_key(tmp_path):
    path = google_services_path(tmp_path)
    path.parent.mkdir(parents=True)
    with ensure_unit_test_google_services(tmp_path) as generated:
        payload = json.loads(generated.read_text(encoding="utf-8"))
    payload["client"][0]["api_key"][0]["current_key"] = "AIza111111111111111111111111111111111"
    path.write_text(json.dumps(payload), encoding="utf-8")

    assert not is_unit_test_google_services_config(path)


def test_marker_mismatch_refuses_to_touch_possible_real_config(tmp_path):
    path = google_services_path(tmp_path)
    path.parent.mkdir(parents=True)
    path.write_text(
        json.dumps(
            {
                "project_info": {"project_id": "burnbar-real"},
                "client": [
                    {
                        "client_info": {
                            "mobilesdk_app_id": "1:real:android:real",
                            "android_client_info": {"package_name": "com.openburnbar"},
                        }
                    }
                ],
            }
        ),
        encoding="utf-8",
    )
    marker_path(tmp_path).write_text(UNIT_TEST_MARKER, encoding="utf-8")

    with pytest.raises(RuntimeError, match="not the deterministic unit-test config"):
        with ensure_unit_test_google_services(tmp_path):
            pass

    assert path.exists()
    assert marker_path(tmp_path).exists()


def test_android_test_environment_prefers_existing_env_values(monkeypatch):
    monkeypatch.setenv("JAVA_HOME", "/custom/java")
    monkeypatch.setenv("ANDROID_HOME", "/custom/android")
    monkeypatch.delenv("ANDROID_SDK_ROOT", raising=False)

    env = android_test_environment()

    assert env["JAVA_HOME"] == "/custom/java"
    assert env["ANDROID_HOME"] == "/custom/android"
    assert env["ANDROID_SDK_ROOT"] == "/custom/android"
