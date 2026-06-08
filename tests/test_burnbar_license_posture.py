import subprocess

from scripts.ci import check_burnbar_license_posture


def test_android_firebase_config_guard_passes_when_file_is_untracked(monkeypatch):
    def fake_run(*args, **kwargs):
        return subprocess.CompletedProcess(args[0], 1, stdout="", stderr="not tracked")

    monkeypatch.setattr(check_burnbar_license_posture.subprocess, "run", fake_run)

    result = check_burnbar_license_posture.check_android_firebase_config_untracked()

    assert result.ok
    assert "is not tracked" in result.details


def test_android_firebase_config_guard_fails_when_file_is_tracked(monkeypatch):
    def fake_run(*args, **kwargs):
        return subprocess.CompletedProcess(args[0], 0, stdout="android/app/google-services.json\n", stderr="")

    monkeypatch.setattr(check_burnbar_license_posture.subprocess, "run", fake_run)

    result = check_burnbar_license_posture.check_android_firebase_config_untracked()

    assert not result.ok
    assert "is tracked" in result.details
