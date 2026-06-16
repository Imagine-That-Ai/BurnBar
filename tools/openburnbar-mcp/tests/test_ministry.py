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

import ministry  # noqa: E402


def test_catalog_reader_flattens_object_shape_from_correct_repo_path() -> None:
    rows = ministry.load_catalog()

    assert ministry.CATALOG_PATH == (
        ministry.REPO_ROOT / "OpenBurnBarCore" / "Sources" / "OpenBurnBarCore" / "Resources" / "catalog.json"
    )
    assert rows
    assert all("_providerID" in row for row in rows)
    assert any(row.get("id") == "gpt-5.4-mini" for row in rows)


def test_models_json_list_indexes_by_model_id_and_alias(tmp_path: Path) -> None:
    models = tmp_path / "models.json"
    models.write_text(
        json.dumps(
            [
                {
                    "modelID": "gpt-5-4-mini",
                    "providerID": "openai",
                    "tier": "mini",
                    "costSignal": 0.74,
                    "aliases": ["openai/gpt-5.4-mini"],
                }
            ]
        ),
        encoding="utf-8",
    )

    index = ministry.load_models_index((models,))

    assert index["gpt-5-4-mini"]["costSignal"] == 0.74
    assert index["openai-gpt-5-4-mini"]["modelID"] == "gpt-5-4-mini"


def test_pareto_guard_keeps_unknown_zero_price_below_real_priced_capability() -> None:
    real_priced = {
        "arg": "real-priced",
        "quota": {"state": "unknown"},
        "backend": "direct",
        "capabilityClassRank": 60,
        "price": 0.25,
        "costUnknown": False,
    }
    unknown_zero = {
        "arg": "unknown-zero",
        "quota": {"state": "unknown"},
        "backend": "direct",
        "capabilityClassRank": 110,
        "price": 0.0,
        "costUnknown": True,
    }

    ranked = sorted([unknown_zero, real_priced], key=lambda candidate: ministry._candidate_sort_key(candidate, "pareto"))

    assert ranked[0]["arg"] == "real-priced"


def test_glm_52_direct_candidate_gets_verified_rank_fallback() -> None:
    candidate = {
        "arg": "custom:OpenBurnBar-glm-5.2-40",
        "model": "glm-5.2",
        "displayName": "Z.ai GLM 5.2",
        "provider": "zai",
        "backend": "direct",
    }

    enriched = ministry.enrich_candidate(candidate, [], {}, None)

    assert enriched["capabilityClassRank"] == 20
    assert enriched["catalog"] is None
    assert enriched["costUnknown"] is True


def test_glm_52_fallback_does_not_inherit_glm_5_catalog_pricing() -> None:
    candidate = {
        "arg": "custom:OpenBurnBar-glm-5.2-40",
        "model": "glm-5.2",
        "displayName": "Z.ai GLM 5.2",
        "provider": "zai",
        "backend": "direct",
    }
    catalog_rows = [
        {
            "id": "glm-5",
            "_providerID": "zai",
            "capabilityClassRank": 85,
            "pricing": {"inputPerMToken": 1.0, "outputPerMToken": 2.0},
            "matchers": [{"all": ["glm", "5"], "none": ["5.1", "turbo", "code"]}],
        }
    ]

    enriched = ministry.enrich_candidate(candidate, catalog_rows, {}, None)

    assert enriched["catalog"] is None
    assert enriched["capabilityClassRank"] == 20
    assert enriched["costSource"] == "unknown"
    assert enriched["costUnknown"] is True


def test_probe_mode_prefers_known_headless_before_unknown_custom_rank() -> None:
    known_headless = {
        "arg": "gpt-5.4-mini",
        "model": "gpt-5.4-mini",
        "provider": "openai",
        "backend": "builtin",
        "capabilityClassRank": 10,
        "price": 0.74,
        "costUnknown": False,
        "quota": {"state": "unknown"},
    }
    custom = {
        "arg": "custom-high-rank",
        "backend": "direct",
        "capabilityClassRank": 90,
        "price": 0.5,
        "costUnknown": False,
        "quota": {"state": "unknown"},
    }

    ranked = sorted([custom, known_headless], key=lambda candidate: ministry._probe_sort_key(candidate, "best"))

    assert ranked[0]["arg"] == "gpt-5.4-mini"


def test_disabled_tools_are_namespaced_not_bare_servers(monkeypatch) -> None:
    monkeypatch.delenv("OPENBURNBAR_MINISTRY_DISABLED_TOOL_IDS", raising=False)
    disabled = ministry.disabled_tool_ids()
    command = ministry.build_droid_command(
        tmp_wands_path(),
        task_prompt="Do the task.",
        model_arg="gpt-5.4-mini",
        prompt_path="/tmp/ministry-prompt.txt",
        result_path="/tmp/ministry-result.json",
        done_path="/tmp/ministry-result.done",
    )

    assert "mem0" not in disabled
    assert "serena" not in disabled
    assert "mem0-mcp___add_memory" in disabled
    assert "serena___search_for_pattern" in disabled
    assert "--disabled-tools" in command["argv"]
    disabled_arg = command["argv"][command["argv"].index("--disabled-tools") + 1]
    assert "mem0,serena" not in disabled_arg
    assert "mem0-mcp___add_memory" in disabled_arg


def test_result_done_marker_gates_running_and_success(tmp_path: Path) -> None:
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
    result.write_text("", encoding="utf-8")

    running = ministry.collect_result(str(repo), base, str(result), str(done))

    assert running["status"] == "running"
    assert running["resultSize"] == 0

    (repo / "worker.txt").write_text("done\n", encoding="utf-8")
    subprocess.run(["git", "add", "worker.txt"], cwd=repo, check=True)
    subprocess.run(["git", "commit", "-q", "-m", "worker"], cwd=repo, check=True)
    result.write_text(json.dumps({"is_error": False}), encoding="utf-8")
    done.write_text('{"exitCode":0}\n', encoding="utf-8")

    collected = ministry.collect_result(str(repo), base, str(result), str(done))

    assert collected["status"] == "ok"
    assert collected["landedCommit"] is True


def test_wand_sanitizer_falls_back_and_has_one_default_with_headless_floor() -> None:
    wands, warnings = ministry.sanitize_wands({"wands": [{"id": "bad", "name": ""}]})

    assert warnings
    assert sum(1 for wand in wands if wand["isDefault"]) == 1
    headmaster = next(wand for wand in wands if wand["id"] == "headmaster")
    assert headmaster["constraints"]["minCapabilityRank"] <= 10


def test_resolved_wand_parallel_max_env_and_clamp(monkeypatch) -> None:
    monkeypatch.delenv("OPENBURNBAR_WAND_PARALLEL_MAX", raising=False)
    assert ministry.resolved_wand_parallel_max() == 16  # ceiling fallback
    monkeypatch.setenv("OPENBURNBAR_WAND_PARALLEL_MAX", "3")
    assert ministry.resolved_wand_parallel_max() == 3  # Cloud cap
    monkeypatch.setenv("OPENBURNBAR_WAND_PARALLEL_MAX", "8")
    assert ministry.resolved_wand_parallel_max() == 8  # Cloud Pro cap
    monkeypatch.setenv("OPENBURNBAR_WAND_PARALLEL_MAX", "999")
    assert ministry.resolved_wand_parallel_max() == 16  # clamped to ceiling
    monkeypatch.setenv("OPENBURNBAR_WAND_PARALLEL_MAX", "0")
    assert ministry.resolved_wand_parallel_max() == 1  # floor
    monkeypatch.setenv("OPENBURNBAR_WAND_PARALLEL_MAX", "garbage")
    assert ministry.resolved_wand_parallel_max() == 16  # invalid → ceiling


def test_selector_can_probe_past_first_failure(monkeypatch, tmp_path: Path) -> None:
    store = tmp_path / "wands.v1.json"
    store.write_text(
        json.dumps(
            {
                "wands": [
                    {
                        "id": "headmaster",
                        "name": "Headmaster's Wand",
                        "selector": "best",
                        "constraints": {"minCapabilityRank": 10},
                        "autonomy": "medium",
                        "allowBackends": ["direct"],
                        "isDefault": True,
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(
        ministry,
        "list_launchable",
        lambda include_quota=True: {
            "candidates": [
                {
                    "arg": "first",
                    "backend": "direct",
                    "capabilityClassRank": 100,
                    "price": 1.0,
                    "costUnknown": False,
                    "quota": {"state": "unknown"},
                },
                {
                    "arg": "second",
                    "backend": "direct",
                    "capabilityClassRank": 90,
                    "price": 1.0,
                    "costUnknown": False,
                    "quota": {"state": "unknown"},
                },
            ]
        },
    )

    def probe(arg: str, autonomy: str, ttl: int) -> dict:
        return {"landsCommit": arg == "second", "arg": arg, "autonomy": autonomy, "ttl": ttl}

    selected = ministry.select_model_for_wand(store, prove_headless=True, max_probes=2, probe_runner=probe)

    assert selected["proofStatus"] == "proven_headless"
    assert selected["selected"]["arg"] == "second"


def test_multi_selector_preserves_provider_diversity_with_proof(monkeypatch, tmp_path: Path) -> None:
    store = tmp_path / "wands.v1.json"
    store.write_text(
        json.dumps(
            {
                "wands": [
                    {
                        "id": "headmaster",
                        "name": "Headmaster's Wand",
                        "selector": "best",
                        "constraints": {"minCapabilityRank": 10},
                        "autonomy": "medium",
                        "allowBackends": ["direct"],
                        "isDefault": True,
                    }
                ]
            }
        ),
        encoding="utf-8",
    )
    monkeypatch.setattr(
        ministry,
        "list_launchable",
        lambda include_quota=True: {
            "candidates": [
                {
                    "arg": "openai-a",
                    "provider": "openai",
                    "backend": "direct",
                    "capabilityClassRank": 100,
                    "price": 1.0,
                    "costUnknown": False,
                    "quota": {"state": "unknown"},
                },
                {
                    "arg": "openai-b",
                    "provider": "openai",
                    "backend": "direct",
                    "capabilityClassRank": 90,
                    "price": 1.0,
                    "costUnknown": False,
                    "quota": {"state": "unknown"},
                },
                {
                    "arg": "zai-a",
                    "provider": "zai",
                    "backend": "direct",
                    "capabilityClassRank": 80,
                    "price": 1.0,
                    "costUnknown": False,
                    "quota": {"state": "unknown"},
                },
            ]
        },
    )
    probed: list[str] = []

    def probe(arg: str, autonomy: str, ttl: int) -> dict:
        probed.append(arg)
        return {"landsCommit": True, "arg": arg, "autonomy": autonomy, "ttl": ttl}

    selected = ministry.select_models_for_wand(
        store,
        count=2,
        require_provider_diversity=True,
        prove_headless=True,
        max_probes=4,
        probe_runner=probe,
    )

    assert selected["proofStatus"] == "proven_headless"
    assert selected["selectedCount"] == 2
    assert selected["providerCount"] == 2
    assert [item["arg"] for item in selected["selected"]] == ["openai-a", "zai-a"]
    assert probed == ["openai-a", "zai-a"]


def test_cleanup_uses_exact_transcript_candidates_without_find_delete(tmp_path: Path) -> None:
    session_id = "session-abc12345"
    sessions_dir = tmp_path / "sessions"
    nested = sessions_dir / "nested"
    nested.mkdir(parents=True)
    transcript = nested / f"{session_id}.jsonl"
    transcript.write_text("{}\n", encoding="utf-8")
    (nested / "other-session.jsonl").write_text("{}\n", encoding="utf-8")

    candidates = ministry.session_transcript_candidates(session_id, sessions_dir=sessions_dir)
    plan = ministry.cleanup_plan(session_id="../../bad*")

    assert candidates == [str(transcript)]
    assert plan["transcriptCandidates"] == []
    assert all(command[0] != "find" for command in plan["commands"])


def tmp_wands_path() -> Path:
    return Path("/tmp/openburnbar-ministry-test-wands.json")
