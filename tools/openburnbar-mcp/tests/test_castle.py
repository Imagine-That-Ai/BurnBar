#!/usr/bin/env python3
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path


_HERE = Path(__file__).resolve().parent
_PARENT = _HERE.parent
if str(_PARENT) not in sys.path:
    sys.path.insert(0, str(_PARENT))

import castle  # noqa: E402
import ministry  # noqa: E402


def test_registry_exposes_eight_runtime_houses() -> None:
    payload = castle.list_runtimes()

    assert payload["count"] == 8
    assert {item["id"] for item in payload["runtimes"]} == {
        "droid",
        "codex",
        "claude",
        "gemini",
        "opencode",
        "cursor-agent",
        "kimi",
        "pi",
    }


def test_droid_adapter_stamps_runtime_without_changing_ministry_candidate(monkeypatch) -> None:
    monkeypatch.setattr(
        ministry,
        "list_launchable",
        lambda include_quota=True: {
            "candidates": [
                {
                    "arg": "gpt-5.4-mini",
                    "model": "gpt-5.4-mini",
                    "provider": "openai",
                    "backend": "builtin",
                }
            ]
        },
    )

    candidates = castle.DroidAdapter().enumerate_launchable_models()

    assert candidates[0]["runtime"] == "droid"
    assert candidates[0]["runtimeDisplayName"] == "House Droid"
    assert candidates[0]["arg"] == "gpt-5.4-mini"


def test_runtime_aware_dedup_keeps_same_arg_in_different_houses() -> None:
    candidates = castle.dedupe_candidates(
        [
            {"runtime": "codex", "backend": "direct", "arg": "gpt-5.5", "model": "gpt-5.5"},
            {"runtime": "pi", "backend": "direct", "arg": "gpt-5.5", "model": "gpt-5.5"},
            {"runtime": "codex", "backend": "direct", "arg": "gpt-5.5", "model": "gpt-5.5"},
        ]
    )

    assert [(item["runtime"], item["arg"]) for item in candidates] == [("codex", "gpt-5.5"), ("pi", "gpt-5.5")]


def test_allow_runtimes_treats_legacy_missing_runtime_as_droid(monkeypatch, tmp_path: Path) -> None:
    store = tmp_path / "wands.v1.json"
    store.write_text(
        json.dumps(
            {
                "wands": [
                    {
                        "id": "legacy",
                        "name": "Legacy Wand",
                        "selector": "best",
                        "constraints": {"minCapabilityRank": 1},
                        "autonomy": "medium",
                        "allowBackends": ["direct"],
                        "allowRuntimes": ["droid"],
                        "isDefault": True,
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(
        castle,
        "list_launchable",
        lambda include_quota=True: {
            "candidates": [
                {
                    "arg": "legacy-droid",
                    "model": "legacy-droid",
                    "provider": "factory",
                    "backend": "direct",
                    "capabilityClassRank": 10,
                    "price": 1.0,
                    "costUnknown": False,
                    "quota": {"state": "unknown"},
                }
            ]
        },
    )

    selected = castle.select_models_for_wand(store, wand_id="legacy", count=1)

    assert selected["selectedCount"] == 1
    assert selected["selected"][0]["arg"] == "legacy-droid"


def test_catalog_id_and_rank_fallback_surface_flagships() -> None:
    claude = castle.enrich_candidates(
        [
            {
                "runtime": "claude",
                "arg": "opus",
                "model": "opus",
                "catalog_id": "claude-opus-4-8",
                "displayName": "Claude Opus",
                "provider": "anthropic",
                "backend": "direct",
            }
        ],
        include_quota=False,
    )[0]
    gemini = castle.enrich_candidates(
        [
            {
                "runtime": "gemini",
                "arg": "gemini-3.1-pro-preview",
                "model": "gemini-3.1-pro-preview",
                "catalog_id": "gemini-3.1-pro-preview",
                "displayName": "Gemini 3.1 Pro Preview",
                "provider": "google",
                "backend": "direct",
            }
        ],
        include_quota=False,
    )[0]

    assert claude["capabilityClassRank"] == 110
    assert gemini["capabilityClassRank"] == 90


def test_worktree_isolation_and_scoped_add_keep_hook_scratch_out_of_commit(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=repo, check=True)
    castle.seed_worktree_isolation(repo)
    (repo / "README.md").write_text("base\n", encoding="utf-8")
    subprocess.run(["git", "add", "README.md"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "base"], cwd=repo, check=True)
    (repo / ".serena").mkdir()
    (repo / ".serena" / "project.yml").write_text("name: leaked\n", encoding="utf-8")
    (repo / "castle_probe.txt").write_text("landed\n", encoding="utf-8")
    subprocess.run(["git", "add", "castle_probe.txt"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "scoped"], cwd=repo, check=True)

    tree = subprocess.check_output(
        ["git", "show", "--name-only", "--format=", "HEAD"], cwd=repo, text=True
    ).splitlines()

    assert tree == ["castle_probe.txt"]


def test_gemini_completion_parse_is_strict_about_empty_stdout_and_exit_code() -> None:
    adapter = castle.GeminiAdapter()

    assert adapter.parse_completion("", "", exit_code=0)["is_error"] is True
    assert adapter.parse_completion('{"error":null,"text":"ok"}', "", exit_code=1)["is_error"] is True
    assert adapter.parse_completion('{"error":null,"text":"ok"}', "", exit_code=0)["is_error"] is False


def test_collect_result_writes_noop_status_when_head_does_not_move(tmp_path: Path) -> None:
    repo = tmp_path / "repo"
    repo.mkdir()
    subprocess.run(["git", "init", "-q"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=repo, check=True)
    subprocess.run(["git", "config", "user.name", "Test"], cwd=repo, check=True)
    (repo / "README.md").write_text("base\n", encoding="utf-8")
    subprocess.run(["git", "add", "README.md"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "base"], cwd=repo, check=True)
    base = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip()
    result = tmp_path / "result.json"
    done = tmp_path / "result.done"
    status = tmp_path / "status.json"
    result.write_text('{"error":null,"text":"no changes"}\n', encoding="utf-8")
    done.write_text('{"exitCode":0,"runtime":"gemini","modelArg":"gemini-3.1-pro-preview"}\n', encoding="utf-8")

    collected = castle.collect_result(
        runtime="gemini",
        worktree_path=str(repo),
        base_sha=base,
        result_path=str(result),
        done_path=str(done),
        status_path=str(status),
    )
    record = json.loads(status.read_text(encoding="utf-8"))

    assert collected["landedCommit"] is False
    assert collected["statusRecord"]["phase"] == "no_op"
    assert record["phase"] == "no_op"
    assert record["landsCommit"] is False
