import json
import os
from pathlib import Path
import shutil
import subprocess


ROOT = Path(__file__).resolve().parents[1]
PREPARE = ROOT / "scripts" / "prepare-openburnbar-app-swiftpm.sh"
VERIFY = ROOT / "scripts" / "ci" / "verify-openburnbar-app-swiftpm-cache.py"

PIN_IDENTITY = "example-package"


def run(
    *args: str,
    cwd: Path,
    env: dict[str, str] | None = None,
) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        list(args),
        cwd=cwd,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def initialize_checkout(path: Path) -> None:
    path.mkdir(parents=True)
    run("git", "init", "-q", cwd=path)
    (path / "README.md").write_text("fixture\n", encoding="utf-8")
    run("git", "add", "README.md", cwd=path)
    result = run(
        "git",
        "-c",
        "user.name=OpenBurnBar CI",
        "-c",
        "user.email=ci@openburnbar.invalid",
        "commit",
        "-qm",
        "fixture",
        cwd=path,
        env={**os.environ, "GIT_COMMITTER_DATE": "2026-01-01T00:00:00Z"},
    )
    assert result.returncode == 0, result.stderr


def fixture_tree(tmp_path: Path) -> tuple[Path, Path, str]:
    repo = tmp_path / "repo"
    project = (
        repo
        / "OpenBurnBar.xcodeproj"
        / "project.xcworkspace"
        / "xcshareddata"
        / "swiftpm"
    )
    project.mkdir(parents=True)
    (repo / ".derived-data").mkdir()
    cache = repo / ".spm-cache"
    checkout = cache / "checkouts" / "ExamplePackage"
    initialize_checkout(checkout)
    revision = run("git", "rev-parse", "HEAD", cwd=checkout).stdout.strip()

    lock = {
        "pins": [
            {
                "identity": PIN_IDENTITY,
                "kind": "remoteSourceControl",
                "location": "https://example.invalid/example-package.git",
                "state": {"revision": revision, "version": "1.0.0"},
            }
        ],
        "version": 3,
    }
    (project / "Package.resolved").write_text(
        json.dumps(lock),
        encoding="utf-8",
    )
    artifact = cache / "artifacts" / "example-package" / "Example.xcframework"
    artifact.mkdir(parents=True)
    local_artifact = repo / "Vendor" / "LocalBinary.xcframework"
    local_artifact.mkdir(parents=True)
    workspace_state = {
        "object": {
            "artifacts": [
                {
                    "packageRef": {"identity": PIN_IDENTITY},
                    "path": str(artifact),
                    "targetName": "Example",
                },
                {
                    "packageRef": {"identity": "unlocked-local-package"},
                    "path": str(local_artifact),
                    "targetName": "LocalBinary",
                },
            ],
            "dependencies": [
                {
                    "packageRef": {"identity": PIN_IDENTITY},
                    "state": {"checkoutState": {"revision": revision}},
                    "subpath": "ExamplePackage",
                },
                {
                    "packageRef": {"identity": "unlocked-local-package"},
                    "state": {"name": "fileSystem"},
                    "subpath": "LocalPackage",
                },
            ],
        },
        "version": 6,
    }
    (cache / "workspace-state.json").write_text(
        json.dumps(workspace_state),
        encoding="utf-8",
    )
    (repo / "OpenBurnBar.xcodeproj" / "project.pbxproj").write_text(
        "// fixture\n",
        encoding="utf-8",
    )
    return repo, cache, revision


def verifier(repo: Path, cache: Path):
    return run(
        "python3",
        str(VERIFY),
        "--lockfile",
        str(
            repo
            / "OpenBurnBar.xcodeproj"
            / "project.xcworkspace"
            / "xcshareddata"
            / "swiftpm"
            / "Package.resolved"
        ),
        "--cache-dir",
        str(cache),
        cwd=repo,
    )


def test_cache_verifier_accepts_exact_locked_checkouts_and_artifacts(tmp_path):
    repo, cache, _ = fixture_tree(tmp_path)

    result = verifier(repo, cache)

    assert result.returncode == 0, result.stderr
    assert "satisfies all 1 Package.resolved pins" in result.stdout


def test_cache_verifier_rejects_missing_artifact(tmp_path):
    repo, cache, _ = fixture_tree(tmp_path)
    shutil.rmtree(cache / "artifacts")

    result = verifier(repo, cache)

    assert result.returncode == 78
    assert "artifact is missing for example-package target Example" in result.stderr


def test_cache_verifier_rejects_missing_recorded_local_package_artifact(tmp_path):
    repo, cache, _ = fixture_tree(tmp_path)
    shutil.rmtree(repo / "Vendor")

    result = verifier(repo, cache)

    assert result.returncode == 78
    assert (
        "artifact is missing for unlocked-local-package target LocalBinary"
        in result.stderr
    )


def test_cache_verifier_rejects_checkout_revision_mismatch(tmp_path):
    repo, cache, revision = fixture_tree(tmp_path)
    state_path = cache / "workspace-state.json"
    state = json.loads(state_path.read_text(encoding="utf-8"))
    state["object"]["dependencies"][0]["state"]["checkoutState"]["revision"] = "2" * 40
    state_path.write_text(json.dumps(state), encoding="utf-8")

    result = verifier(repo, cache)

    assert result.returncode == 78
    assert f"expected {revision}, found {'2' * 40}" in result.stderr


def test_cache_verifier_treats_malformed_lock_as_source_error(tmp_path):
    repo, cache, _ = fixture_tree(tmp_path)
    lockfile = (
        repo
        / "OpenBurnBar.xcodeproj"
        / "project.xcworkspace"
        / "xcshareddata"
        / "swiftpm"
        / "Package.resolved"
    )
    lockfile.write_text('{"pins": [{"identity": "missing-state"}]}', encoding="utf-8")

    result = verifier(repo, cache)

    assert result.returncode == 64
    assert "has no 40-character revision" in result.stderr


def test_cache_verifier_rejects_missing_workspace_state(tmp_path):
    repo, cache, _ = fixture_tree(tmp_path)
    (cache / "workspace-state.json").unlink()

    result = verifier(repo, cache)

    assert result.returncode == 78
    assert "SwiftPM workspace state is missing" in result.stderr


def test_cache_verifier_rejects_malformed_workspace_state(tmp_path):
    repo, cache, _ = fixture_tree(tmp_path)
    (cache / "workspace-state.json").write_text("{", encoding="utf-8")

    result = verifier(repo, cache)

    assert result.returncode == 78
    assert "SwiftPM workspace state is unreadable or malformed" in result.stderr


def fake_environment(tmp_path: Path) -> tuple[dict[str, str], Path]:
    fake_bin = tmp_path / "fake-bin"
    fake_bin.mkdir()
    calls = tmp_path / "xcodebuild-calls"
    fake_xcodebuild = fake_bin / "xcodebuild"
    fake_xcodebuild.write_text(
        """#!/usr/bin/env bash
set -euo pipefail
printf '%s\\n' "$*" >>"$FAKE_XCODEBUILD_CALLS"
if [[ "${FIREBASE_SOURCE_FIRESTORE:-}" != "1" ]]; then
  exit 87
fi
case "${FAKE_XCODEBUILD_MODE:-success}" in
  hard-failure)
    printf 'mutated\\n' >"$FAKE_LOCKFILE"
    exit 42
    ;;
  drift)
    printf 'mutated\\n' >"$FAKE_LOCKFILE"
    ;;
  transient-then-success)
    count="$(wc -l <"$FAKE_XCODEBUILD_CALLS" | tr -d ' ')"
    if [[ "$count" == "1" ]]; then
      printf 'partial\\n' >"$FAKE_LOCKFILE"
      exit 134
    fi
    cmp -s "$FAKE_LOCKFILE" "$FAKE_EXPECTED_LOCKFILE" || exit 86
    ;;
  always-transient)
    printf 'partial\\n' >"$FAKE_LOCKFILE"
    exit 134
    ;;
esac
""",
        encoding="utf-8",
    )
    fake_xcodebuild.chmod(0o755)
    return {**os.environ, "PATH": f"{fake_bin}:{os.environ['PATH']}"}, calls


def prepare(repo: Path, cache: Path, env: dict[str, str], *options: str):
    lockfile = (
        repo
        / "OpenBurnBar.xcodeproj"
        / "project.xcworkspace"
        / "xcshareddata"
        / "swiftpm"
        / "Package.resolved"
    )
    expected = repo / "expected.Package.resolved"
    shutil.copy2(lockfile, expected)
    test_env = {
        **env,
        "FAKE_LOCKFILE": str(lockfile),
        "FAKE_EXPECTED_LOCKFILE": str(expected),
        "OPENBURNBAR_XCODE_PROCESS_TMPDIR": str(repo / "tmp"),
        "OPENBURNBAR_SWIFTPM_RESOLVE_TIMEOUT_SECONDS": "30",
    }
    return (
        run(
            "bash",
            str(PREPARE),
            "--repo-root",
            str(repo),
            "--cache-dir",
            str(cache),
            "--derived-data",
            str(repo / ".derived-data"),
            *options,
            cwd=repo,
            env=test_env,
        ),
        lockfile,
        expected,
    )


def test_prepare_skips_xcode_when_cache_is_complete(tmp_path):
    repo, cache, _ = fixture_tree(tmp_path)
    env, calls = fake_environment(tmp_path)
    env["FAKE_XCODEBUILD_CALLS"] = str(calls)

    result, lockfile, expected = prepare(repo, cache, env)

    assert result.returncode == 0, result.stderr
    assert "package resolution was not run" in result.stdout
    assert not calls.exists()
    assert lockfile.read_bytes() == expected.read_bytes()


def test_prepare_removes_stale_containment_evidence_when_no_resolve_runs(tmp_path):
    repo, cache, _ = fixture_tree(tmp_path)
    evidence = (
        repo
        / ".derived-data"
        / ".openburnbar-swiftpm-resolution"
        / "attempt-1-containment.json"
    )
    evidence.parent.mkdir(parents=True)
    evidence.write_text('{"stale": true}', encoding="utf-8")
    env, calls = fake_environment(tmp_path)
    env["FAKE_XCODEBUILD_CALLS"] = str(calls)

    result, _, _ = prepare(repo, cache, env)

    assert result.returncode == 0, result.stderr
    assert not evidence.exists()


def test_prepare_check_only_fails_closed_for_incomplete_cache(tmp_path):
    repo, cache, _ = fixture_tree(tmp_path)
    shutil.rmtree(cache / "checkouts")
    env, calls = fake_environment(tmp_path)
    env["FAKE_XCODEBUILD_CALLS"] = str(calls)

    result, lockfile, expected = prepare(repo, cache, env, "--check-only")

    assert result.returncode == 78
    assert "--check-only forbids network or cache mutation" in result.stderr
    assert not calls.exists()
    assert lockfile.read_bytes() == expected.read_bytes()


def test_prepare_restores_lock_after_hard_resolver_failure(tmp_path):
    repo, cache, _ = fixture_tree(tmp_path)
    shutil.rmtree(cache / "checkouts")
    env, calls = fake_environment(tmp_path)
    env.update(
        {
            "FAKE_XCODEBUILD_CALLS": str(calls),
            "FAKE_XCODEBUILD_MODE": "hard-failure",
        }
    )

    result, lockfile, expected = prepare(repo, cache, env)

    assert result.returncode == 42
    assert calls.read_text(encoding="utf-8").count("\n") == 1
    assert lockfile.read_bytes() == expected.read_bytes()


def test_prepare_retries_only_exit_134_from_exact_lockfile(tmp_path):
    repo, cache, _ = fixture_tree(tmp_path)
    env, calls = fake_environment(tmp_path)
    env.update(
        {
            "FAKE_XCODEBUILD_CALLS": str(calls),
            "FAKE_XCODEBUILD_MODE": "transient-then-success",
        }
    )

    result, lockfile, expected = prepare(repo, cache, env, "--force-resolve")

    assert result.returncode == 0, result.stderr
    assert calls.read_text(encoding="utf-8").count("\n") == 2
    assert "known IDE model-graph exit 134" in result.stderr
    assert lockfile.read_bytes() == expected.read_bytes()


def test_prepare_stops_after_bounded_exit_134_attempts(tmp_path):
    repo, cache, _ = fixture_tree(tmp_path)
    env, calls = fake_environment(tmp_path)
    env.update(
        {
            "FAKE_XCODEBUILD_CALLS": str(calls),
            "FAKE_XCODEBUILD_MODE": "always-transient",
            "OPENBURNBAR_SWIFTPM_RESOLVE_MAX_ATTEMPTS": "2",
        }
    )

    result, lockfile, expected = prepare(repo, cache, env, "--force-resolve")

    assert result.returncode == 134
    assert calls.read_text(encoding="utf-8").count("\n") == 2
    assert "known IDE model-graph exit 134 on attempt 1/2" in result.stderr
    assert "known IDE model-graph exit 134 on attempt 2/2" not in result.stderr
    assert "returned exit 134 on all 2 attempts" in result.stderr
    assert lockfile.read_bytes() == expected.read_bytes()


def test_prepare_rejects_successful_lockfile_drift(tmp_path):
    repo, cache, _ = fixture_tree(tmp_path)
    env, calls = fake_environment(tmp_path)
    env.update(
        {
            "FAKE_XCODEBUILD_CALLS": str(calls),
            "FAKE_XCODEBUILD_MODE": "drift",
        }
    )

    result, lockfile, expected = prepare(repo, cache, env, "--force-resolve")

    assert result.returncode == 65
    assert "mutated Package.resolved" in result.stderr
    assert lockfile.read_bytes() == expected.read_bytes()
