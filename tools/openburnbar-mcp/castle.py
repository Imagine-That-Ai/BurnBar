#!/usr/bin/env python3
"""Castle multi-runtime orchestration for OpenBurnBar worker fan-out.

The Ministry ranks models. The Castle widens launchability from a single
`droid exec` universe to runtime-stamped `(runtime, model)` candidates, then
keeps the same hard success gate: done marker present, parsed completion is not
an error, and the worker worktree HEAD differs from the base SHA.
"""

from __future__ import annotations

import json
import os
import shlex
import shutil
import subprocess
import tempfile
import time
import tomllib
from collections.abc import Callable, Iterable
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol

import ministry


CASTLE_CACHE_DIR = ministry.MINISTRY_CACHE_DIR.parent / "castle"
STATUS_SCHEMA_VERSION = 1
PROMPT_PLACEHOLDER = "__CASTLE_PROMPT_FROM_FILE__"
STDERR_SUFFIX = ".stderr"

SCRATCH_EXCLUDES = [
    ".serena/",
    ".codex/",
    ".claude/",
    ".gemini/",
    ".cursor-agent/",
    ".mcp/",
    ".factory/sessions/",
    "*.tmp",
]

RUNTIMES = ("droid", "codex", "claude", "gemini", "opencode", "cursor-agent", "kimi", "pi")

RUNTIME_LABELS = {
    "droid": "House Droid",
    "codex": "House Codex",
    "claude": "House Claude",
    "gemini": "House Gemini",
    "opencode": "House OpenCode",
    "cursor-agent": "House Cursor",
    "kimi": "House Kimi",
    "pi": "House Pi",
}


def normalize_runtime(value: Any) -> str:
    runtime = str(value or "").strip().lower().replace("_", "-")
    if runtime in {"cursoragent", "cursor"}:
        return "cursor-agent"
    return runtime


def runtime_label(runtime: str) -> str:
    return RUNTIME_LABELS.get(normalize_runtime(runtime), f"House {str(runtime).title()}")


def _home_path(*parts: str) -> Path:
    return Path.home().joinpath(*parts)


def _which(executable: str) -> str | None:
    return shutil.which(executable)


def _read_toml(path: Path) -> dict[str, Any]:
    if not path.is_file():
        return {}
    try:
        with path.open("rb") as fh:
            data = tomllib.load(fh)
    except (OSError, tomllib.TOMLDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def _coerce_model_id(value: Any) -> str | None:
    model = str(value or "").strip()
    return model or None


def _candidate(
    *,
    runtime: str,
    arg: str,
    model: str,
    display_name: str,
    provider: str,
    source: str,
    catalog_id: str | None = None,
    account_id: str | None = None,
    backend: str = "direct",
    extra: dict[str, Any] | None = None,
) -> dict[str, Any]:
    runtime = normalize_runtime(runtime)
    payload: dict[str, Any] = {
        "runtime": runtime,
        "runtimeDisplayName": runtime_label(runtime),
        "arg": arg,
        "model": model,
        "displayName": display_name,
        "provider": provider,
        "backend": backend,
        "baseURL": None,
        "source": source,
        "accountID": account_id or f"{runtime}-subscription",
        "catalog_id": catalog_id or model,
        "quota": {"state": "unavailable", "remainingPercent": None, "trust": "not_applicable"},
    }
    if extra:
        payload.update(extra)
    return payload


class RuntimeAdapter(Protocol):
    runtime: str
    executable_name: str

    def enumerate_launchable_models(self, include_quota: bool = True) -> list[dict[str, Any]]: ...

    def resolve_model_arg(self, candidate_or_arg: dict[str, Any] | str) -> str: ...

    def build_command(
        self,
        *,
        task_prompt: str,
        model_arg: str,
        cwd: str | None = None,
        prompt_path: str | None = None,
        result_path: str | None = None,
        done_path: str | None = None,
        status_path: str | None = None,
        autonomy: str = "medium",
        reasoning_effort: str | None = None,
    ) -> dict[str, Any]: ...

    def parse_completion(self, stdout: str, stderr: str = "", exit_code: int = 0) -> dict[str, Any]: ...

    def auth_precondition(self) -> dict[str, Any]: ...


@dataclass(frozen=True)
class CLIModel:
    arg: str
    model: str
    display_name: str
    provider: str
    catalog_id: str | None = None


class BaseCLIAdapter:
    runtime = ""
    executable_name = ""
    provider = ""
    default_models: tuple[CLIModel, ...] = ()

    def executable_path(self) -> str | None:
        return _which(self.executable_name)

    def auth_paths(self) -> list[Path]:
        return []

    def auth_precondition(self) -> dict[str, Any]:
        executable = self.executable_path()
        if not executable:
            return {
                "status": "unavailable",
                "code": "CASTLE_RUNTIME_NOT_INSTALLED",
                "runtime": self.runtime,
                "reason": f"{self.executable_name} executable not found on PATH",
            }
        paths = self.auth_paths()
        if paths and not any(path.exists() for path in paths):
            return {
                "status": "unavailable",
                "code": "CASTLE_RUNTIME_AUTH_MISSING",
                "runtime": self.runtime,
                "executablePath": executable,
                "checkedPaths": [str(path) for path in paths],
                "reason": f"No local auth/config marker found for {self.runtime}",
            }
        return {
            "status": "ok",
            "runtime": self.runtime,
            "executablePath": executable,
            "checkedPaths": [str(path) for path in paths],
        }

    def enumerate_launchable_models(self, include_quota: bool = True) -> list[dict[str, Any]]:
        return [
            _candidate(
                runtime=self.runtime,
                arg=model.arg,
                model=model.model,
                display_name=model.display_name,
                provider=model.provider,
                catalog_id=model.catalog_id,
                source=f"{self.runtime}.static",
            )
            for model in self.default_models
        ]

    def resolve_model_arg(self, candidate_or_arg: dict[str, Any] | str) -> str:
        if isinstance(candidate_or_arg, dict):
            return str(candidate_or_arg.get("arg") or candidate_or_arg.get("model") or "")
        return str(candidate_or_arg)

    def argv(
        self,
        *,
        model_arg: str,
        cwd: str | None,
        autonomy: str,
        reasoning_effort: str | None,
        result_path: str,
    ) -> list[str]:
        raise NotImplementedError

    def build_command(
        self,
        *,
        task_prompt: str,
        model_arg: str,
        cwd: str | None = None,
        prompt_path: str | None = None,
        result_path: str | None = None,
        done_path: str | None = None,
        status_path: str | None = None,
        autonomy: str = "medium",
        reasoning_effort: str | None = None,
    ) -> dict[str, Any]:
        run_id = f"{int(time.time())}-{os.getpid()}"
        base_dir = Path("/tmp") / f"bb-castle-{run_id}"
        prompt_path = prompt_path or str(base_dir / "prompt.txt")
        result_path = result_path or str(base_dir / "result.json")
        done_path = done_path or str(base_dir / "result.done")
        status_path = status_path or str(base_dir / "status.json")
        stderr_path = f"{result_path}{STDERR_SUFFIX}"
        argv = self.argv(
            model_arg=model_arg,
            cwd=cwd,
            autonomy=autonomy,
            reasoning_effort=reasoning_effort,
            result_path=result_path,
        )
        command = command_with_done_marker(
            argv=argv,
            runtime=self.runtime,
            model_arg=model_arg,
            prompt_path=prompt_path,
            result_path=result_path,
            stderr_path=stderr_path,
            done_path=done_path,
            status_path=status_path,
            cwd=cwd,
            stdin_devnull=True,
        )
        return {
            "status": "ok",
            "runtime": self.runtime,
            "modelArg": model_arg,
            "autonomy": autonomy,
            "reasoningEffort": reasoning_effort,
            "cwd": cwd,
            "promptPath": prompt_path,
            "resultPath": result_path,
            "stderrPath": stderr_path,
            "donePath": done_path,
            "statusPath": status_path,
            "prompt": task_prompt,
            "argv": argv,
            "command": command,
        }

    def parse_completion(self, stdout: str, stderr: str = "", exit_code: int = 0) -> dict[str, Any]:
        if exit_code != 0:
            return {"is_error": True, "reason": f"exit code {exit_code}", "stderrTail": stderr[-1200:]}
        return {"is_error": False}


class DroidAdapter:
    runtime = "droid"
    executable_name = "droid"

    def enumerate_launchable_models(self, include_quota: bool = True) -> list[dict[str, Any]]:
        payload = ministry.list_launchable(include_quota=include_quota)
        candidates = payload.get("candidates") or []
        enriched = []
        for candidate in candidates:
            item = dict(candidate)
            item.setdefault("runtime", self.runtime)
            item.setdefault("runtimeDisplayName", runtime_label(self.runtime))
            item.setdefault("catalog_id", item.get("model"))
            enriched.append(item)
        return enriched

    def resolve_model_arg(self, candidate_or_arg: dict[str, Any] | str) -> str:
        if isinstance(candidate_or_arg, dict):
            return str(candidate_or_arg.get("arg") or candidate_or_arg.get("model") or "")
        return str(candidate_or_arg)

    def build_command(
        self,
        *,
        task_prompt: str,
        model_arg: str,
        cwd: str | None = None,
        prompt_path: str | None = None,
        result_path: str | None = None,
        done_path: str | None = None,
        status_path: str | None = None,
        autonomy: str = "medium",
        reasoning_effort: str | None = None,
    ) -> dict[str, Any]:
        payload = ministry.build_droid_command(
            ministry.default_wands_path(),
            task_prompt=task_prompt,
            model_arg=model_arg,
            cwd=cwd,
            prompt_path=prompt_path,
            result_path=result_path,
            done_path=done_path,
            autonomy=autonomy,
            reasoning_effort=reasoning_effort,
        )
        payload["runtime"] = self.runtime
        payload["statusPath"] = status_path
        return payload

    def parse_completion(self, stdout: str, stderr: str = "", exit_code: int = 0) -> dict[str, Any]:
        parsed = _parse_json_object(stdout)
        if parsed is not None:
            return {"is_error": bool(parsed.get("is_error")), "jsonOutput": parsed}
        return {
            "is_error": exit_code != 0,
            "reason": "invalid_json" if stdout.strip() else None,
            "stderrTail": stderr[-1200:],
        }

    def auth_precondition(self) -> dict[str, Any]:
        executable = _which(self.executable_name)
        auth_file = _home_path(".factory", "auth.v2.file")
        if not executable:
            return {"status": "unavailable", "code": "CASTLE_RUNTIME_NOT_INSTALLED", "runtime": self.runtime}
        if not auth_file.exists():
            return {
                "status": "unavailable",
                "code": "CASTLE_RUNTIME_AUTH_MISSING",
                "runtime": self.runtime,
                "checkedPaths": [str(auth_file)],
            }
        return {"status": "ok", "runtime": self.runtime, "executablePath": executable, "checkedPaths": [str(auth_file)]}


class CodexAdapter(BaseCLIAdapter):
    runtime = "codex"
    executable_name = "codex"
    provider = "openai"
    default_models = (
        CLIModel("gpt-5.5", "gpt-5.5", "GPT-5.5", "openai", "gpt-5-5"),
        CLIModel("gpt-5.4-mini", "gpt-5.4-mini", "GPT-5.4 Mini", "openai", "gpt-5.4-mini"),
    )

    def auth_paths(self) -> list[Path]:
        return [_home_path(".codex", "auth.json"), _home_path(".codex", "config.toml")]

    def enumerate_launchable_models(self, include_quota: bool = True) -> list[dict[str, Any]]:
        candidates = super().enumerate_launchable_models(include_quota=include_quota)
        config = _read_toml(_home_path(".codex", "config.toml"))
        seen = {normalize_model_key(candidate.get("model")) for candidate in candidates}
        for model in _codex_models_from_config(config):
            key = normalize_model_key(model)
            if not key or key in seen:
                continue
            seen.add(key)
            candidates.append(
                _candidate(
                    runtime=self.runtime,
                    arg=model,
                    model=model,
                    display_name=model,
                    provider="openai",
                    catalog_id=model,
                    source="codex.config",
                )
            )
        return candidates

    def argv(
        self, *, model_arg: str, cwd: str | None, autonomy: str, reasoning_effort: str | None, result_path: str
    ) -> list[str]:
        args = ["codex", "exec"]
        if cwd:
            args.extend(["-C", cwd])
        args.extend(["-m", model_arg, "-s", "danger-full-access", "--json"])
        if reasoning_effort:
            args.extend(["-c", f"model_reasoning_effort={reasoning_effort}"])
        args.append(PROMPT_PLACEHOLDER)
        return args

    def parse_completion(self, stdout: str, stderr: str = "", exit_code: int = 0) -> dict[str, Any]:
        events = _parse_json_lines(stdout)
        terminal = events[-1] if events else None
        has_error = exit_code != 0 or any(str(event.get("type") or "").endswith(".error") for event in events)
        completed = any(event.get("type") in {"turn.completed", "agent.completed"} for event in events)
        return {
            "is_error": bool(has_error or not completed),
            "terminalEvent": terminal,
            "eventCount": len(events),
            "stderrTail": stderr[-1200:],
        }


class ClaudeAdapter(BaseCLIAdapter):
    runtime = "claude"
    executable_name = "claude"
    provider = "anthropic"
    default_models = (
        CLIModel("claude-opus-4-8", "claude-opus-4-8", "Claude Opus 4.8", "anthropic", "claude-opus-4-8"),
        CLIModel("claude-sonnet-4-6", "claude-sonnet-4-6", "Claude Sonnet 4.6", "anthropic", "claude-sonnet-4-6"),
        CLIModel("claude-haiku-4-5", "claude-haiku-4-5", "Claude Haiku 4.5", "anthropic", "claude-haiku-4-5"),
    )

    def auth_paths(self) -> list[Path]:
        return [_home_path(".claude"), _home_path(".config", "claude")]

    def argv(
        self, *, model_arg: str, cwd: str | None, autonomy: str, reasoning_effort: str | None, result_path: str
    ) -> list[str]:
        return [
            "claude",
            "-p",
            "--output-format",
            "stream-json",
            "--permission-mode",
            "bypassPermissions",
            "--model",
            model_arg,
            PROMPT_PLACEHOLDER,
        ]

    def parse_completion(self, stdout: str, stderr: str = "", exit_code: int = 0) -> dict[str, Any]:
        events = _parse_json_lines(stdout)
        if events:
            has_error = exit_code != 0 or any(
                bool(event.get("is_error")) or event.get("type") == "error" for event in events
            )
            return {
                "is_error": has_error,
                "eventCount": len(events),
                "terminalEvent": events[-1],
                "stderrTail": stderr[-1200:],
            }
        parsed = _parse_json_object(stdout)
        if parsed is not None:
            return {
                "is_error": bool(parsed.get("is_error")) or exit_code != 0,
                "jsonOutput": parsed,
                "stderrTail": stderr[-1200:],
            }
        return {"is_error": True, "reason": "empty_or_invalid_stdout", "stderrTail": stderr[-1200:]}


class GeminiAdapter(BaseCLIAdapter):
    runtime = "gemini"
    executable_name = "gemini"
    provider = "google"
    default_models = (
        CLIModel(
            "gemini-3.1-pro-preview",
            "gemini-3.1-pro-preview",
            "Gemini 3.1 Pro Preview",
            "google",
            "gemini-3.1-pro-preview",
        ),
        CLIModel("gemini-2.5-pro", "gemini-2.5-pro", "Gemini 2.5 Pro", "google", "gemini-2.5-pro"),
    )

    def auth_paths(self) -> list[Path]:
        return [_home_path(".gemini"), _home_path(".config", "gemini")]

    def argv(
        self, *, model_arg: str, cwd: str | None, autonomy: str, reasoning_effort: str | None, result_path: str
    ) -> list[str]:
        return [
            "gemini",
            "-p",
            PROMPT_PLACEHOLDER,
            "-m",
            model_arg,
            "-o",
            "json",
            "--approval-mode",
            "yolo",
            "--skip-trust",
        ]

    def parse_completion(self, stdout: str, stderr: str = "", exit_code: int = 0) -> dict[str, Any]:
        if exit_code != 0:
            return {"is_error": True, "reason": f"exit code {exit_code}", "stderrTail": stderr[-1200:]}
        if not stdout.strip():
            return {"is_error": True, "reason": "empty_stdout", "stderrTail": stderr[-1200:]}
        parsed = _parse_json_object(stdout)
        if parsed is None:
            return {"is_error": True, "reason": "invalid_json", "stderrTail": stderr[-1200:]}
        return {"is_error": parsed.get("error") is not None, "jsonOutput": parsed, "stderrTail": stderr[-1200:]}


class OpenCodeAdapter(BaseCLIAdapter):
    runtime = "opencode"
    executable_name = "opencode"
    provider = "opencode"
    default_models = (
        CLIModel("opencode/grok-code-fast", "grok-code-fast", "OpenCode Grok Code Fast", "opencode", "grok-code-fast"),
        CLIModel("opencode/kimi-k2.6", "kimi-k2.6", "OpenCode Kimi K2.6", "opencode", "kimi-k2.6"),
    )

    def auth_paths(self) -> list[Path]:
        return [_home_path(".config", "opencode"), _home_path(".local", "share", "opencode")]

    def argv(
        self, *, model_arg: str, cwd: str | None, autonomy: str, reasoning_effort: str | None, result_path: str
    ) -> list[str]:
        return [
            "opencode",
            "run",
            "--prompt",
            PROMPT_PLACEHOLDER,
            "-m",
            model_arg,
            "--format",
            "json",
            "--dangerously-skip-permissions",
        ]

    def parse_completion(self, stdout: str, stderr: str = "", exit_code: int = 0) -> dict[str, Any]:
        events = _parse_json_lines(stdout)
        has_error = exit_code != 0 or any(event.get("error") or event.get("type") == "error" for event in events)
        return {
            "is_error": bool(has_error),
            "eventCount": len(events),
            "terminalEvent": events[-1] if events else None,
            "stderrTail": stderr[-1200:],
        }


class CursorAgentAdapter(BaseCLIAdapter):
    runtime = "cursor-agent"
    executable_name = "cursor-agent"
    provider = "cursor"
    default_models = (CLIModel("auto", "auto", "Cursor Agent Auto", "cursor", "cursor-agent"),)

    def auth_paths(self) -> list[Path]:
        return [_home_path(".cursor"), _home_path(".local", "share", "cursor-agent"), _home_path(".cursor-agent")]

    def argv(
        self, *, model_arg: str, cwd: str | None, autonomy: str, reasoning_effort: str | None, result_path: str
    ) -> list[str]:
        return ["cursor-agent", "-p", "--model", model_arg, "--output-format", "json", "--force", PROMPT_PLACEHOLDER]

    def parse_completion(self, stdout: str, stderr: str = "", exit_code: int = 0) -> dict[str, Any]:
        parsed = _parse_json_object(stdout)
        if parsed is not None:
            return {
                "is_error": bool(parsed.get("is_error") or parsed.get("error")) or exit_code != 0,
                "jsonOutput": parsed,
                "stderrTail": stderr[-1200:],
            }
        return {
            "is_error": exit_code != 0 or not stdout.strip(),
            "reason": "invalid_json",
            "stderrTail": stderr[-1200:],
        }


class KimiAdapter(BaseCLIAdapter):
    runtime = "kimi"
    executable_name = "kimi"
    provider = "moonshot"
    default_models = (CLIModel("kimi-k2.6", "kimi-k2.6", "Kimi K2.6", "moonshot", "kimi-k2.6"),)

    def auth_paths(self) -> list[Path]:
        return [_home_path(".kimi"), _home_path(".config", "kimi")]

    def argv(
        self, *, model_arg: str, cwd: str | None, autonomy: str, reasoning_effort: str | None, result_path: str
    ) -> list[str]:
        return ["kimi", "-p", PROMPT_PLACEHOLDER, "-m", model_arg, "--output-format", "stream-json"]

    def parse_completion(self, stdout: str, stderr: str = "", exit_code: int = 0) -> dict[str, Any]:
        events = _parse_json_lines(stdout)
        has_error = exit_code != 0 or any(event.get("error") or event.get("is_error") for event in events)
        return {
            "is_error": bool(has_error),
            "eventCount": len(events),
            "terminalEvent": events[-1] if events else None,
            "stderrTail": stderr[-1200:],
        }


class PiAdapter(BaseCLIAdapter):
    runtime = "pi"
    executable_name = "pi"
    provider = "pi"
    default_models = (CLIModel("openai/gpt-5.5", "gpt-5.5", "Pi OpenAI GPT-5.5", "openai", "gpt-5-5"),)

    def auth_paths(self) -> list[Path]:
        return [_home_path(".pi"), _home_path(".config", "pi")]

    def argv(
        self, *, model_arg: str, cwd: str | None, autonomy: str, reasoning_effort: str | None, result_path: str
    ) -> list[str]:
        provider, model = split_provider_model(model_arg, default_provider="openai")
        return ["pi", "-p", PROMPT_PLACEHOLDER, "--provider", provider, "--model", model, "--mode", "json"]

    def parse_completion(self, stdout: str, stderr: str = "", exit_code: int = 0) -> dict[str, Any]:
        parsed = _parse_json_object(stdout)
        if parsed is None:
            return {
                "is_error": True,
                "reason": "invalid_json" if stdout.strip() else "empty_stdout",
                "stderrTail": stderr[-1200:],
            }
        return {
            "is_error": bool(parsed.get("error")) or exit_code != 0,
            "jsonOutput": parsed,
            "stderrTail": stderr[-1200:],
        }


REGISTRY: dict[str, RuntimeAdapter] = {
    "droid": DroidAdapter(),
    "codex": CodexAdapter(),
    "claude": ClaudeAdapter(),
    "gemini": GeminiAdapter(),
    "opencode": OpenCodeAdapter(),
    "cursor-agent": CursorAgentAdapter(),
    "kimi": KimiAdapter(),
    "pi": PiAdapter(),
}


def adapter_for(runtime: str) -> RuntimeAdapter:
    normalized = normalize_runtime(runtime)
    adapter = REGISTRY.get(normalized)
    if not adapter:
        raise KeyError(f"Unsupported Castle runtime: {runtime}")
    return adapter


def list_runtimes() -> dict[str, Any]:
    return {
        "status": "ok",
        "count": len(REGISTRY),
        "runtimes": [
            {
                "id": runtime,
                "name": runtime_label(runtime),
                "executable": adapter.executable_name,
                "auth": adapter.auth_precondition(),
            }
            for runtime, adapter in REGISTRY.items()
        ],
    }


def list_launchable(runtime: str | None = None, include_quota: bool = True) -> dict[str, Any]:
    runtimes = [normalize_runtime(runtime)] if runtime else list(REGISTRY)
    raw_candidates: list[dict[str, Any]] = []
    failures: list[dict[str, Any]] = []
    for runtime_id in runtimes:
        adapter = REGISTRY.get(runtime_id)
        if not adapter:
            failures.append({"runtime": runtime_id, "code": "CASTLE_RUNTIME_UNSUPPORTED"})
            continue
        try:
            raw_candidates.extend(adapter.enumerate_launchable_models(include_quota=include_quota))
        except Exception as exc:
            failures.append({"runtime": runtime_id, "code": "CASTLE_ENUMERATION_FAILED", "reason": str(exc)})
    candidates = enrich_candidates(dedupe_candidates(raw_candidates), include_quota=include_quota)
    return {
        "status": "ok",
        "repoRoot": str(ministry.REPO_ROOT),
        "runtimeFilter": runtime,
        "count": len(candidates),
        "failures": failures,
        "candidates": candidates,
    }


def enrich_candidates(candidates: list[dict[str, Any]], include_quota: bool = True) -> list[dict[str, Any]]:
    catalog_rows = ministry.load_catalog()
    models_index = ministry.load_models_index()
    enriched: list[dict[str, Any]] = []
    for candidate in candidates:
        item = ministry.enrich_candidate(candidate, catalog_rows, models_index, None)
        item.setdefault("runtime", normalize_runtime(candidate.get("runtime") or "droid"))
        item.setdefault("runtimeDisplayName", runtime_label(item["runtime"]))
        item.setdefault(
            "quota",
            candidate.get("quota") or {"state": "unavailable", "remainingPercent": None, "trust": "not_applicable"},
        )
        enriched.append(item)
    return enriched


def dedupe_candidates(candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen: set[tuple[str, str, str]] = set()
    result: list[dict[str, Any]] = []
    for candidate in candidates:
        runtime = normalize_runtime(candidate.get("runtime") or "droid")
        key = (runtime, str(candidate.get("backend") or ""), str(candidate.get("arg") or ""))
        if key in seen:
            continue
        seen.add(key)
        item = dict(candidate)
        item["runtime"] = runtime
        item.setdefault("runtimeDisplayName", runtime_label(runtime))
        result.append(item)
    return result


def select_models_for_wand(
    store_path: Path,
    wand_id: str | None = None,
    count: int = 3,
    require_provider_diversity: bool = True,
    require_runtime_diversity: bool = True,
    allow_runtimes: list[str] | None = None,
    exclude_keys: list[str] | None = None,
    prove_headless: bool = False,
    max_probes: int = 6,
    probe_ttl: int = 3600,
    probe_runner: Callable[[str, str, str, int], dict[str, Any]] | None = None,
) -> dict[str, Any]:
    count = max(1, min(int(count), 12))
    wands_payload = ministry.load_wands(store_path)
    wand = _wand_by_id(wands_payload, wand_id)
    if not wand:
        return {"status": "ok", "selected": [], "reason": "wand_not_found", "wandID": wand_id}

    runtime_filter = _allowed_runtimes(wand, allow_runtimes)
    launchable = list_launchable(include_quota=True)
    excluded = set(exclude_keys or [])
    min_rank = int((wand.get("constraints") or {}).get("minCapabilityRank") or 0)
    selector = str(wand.get("selector") or "best")
    runtime_preference = [normalize_runtime(item) for item in (wand.get("runtimePreference") or [])]
    candidates = [
        candidate
        for candidate in launchable["candidates"]
        if _candidate_runtime(candidate) in runtime_filter
        and _candidate_key(candidate) not in excluded
        and int(candidate.get("capabilityClassRank") or 0) >= min_rank
    ]
    ranked = sorted(candidates, key=lambda candidate: castle_sort_key(candidate, selector, runtime_preference))
    ordered = (
        sorted(ranked, key=lambda candidate: castle_probe_sort_key(candidate, selector, runtime_preference))
        if prove_headless
        else ranked
    )

    selected: list[dict[str, Any]] = []
    probe_failures: list[dict[str, Any]] = []
    used_providers: set[str] = set()
    used_runtimes: set[str] = set()
    probes_used = 0
    runner = probe_runner or _probe_runner

    def eligible(candidate: dict[str, Any], enforce_provider: bool, enforce_runtime: bool) -> bool:
        if _candidate_key(candidate) in {_candidate_key(item) for item in selected}:
            return False
        provider = str(candidate.get("provider") or candidate.get("backend") or "")
        runtime = _candidate_runtime(candidate)
        if enforce_provider and provider in used_providers:
            return False
        if enforce_runtime and runtime in used_runtimes:
            return False
        return True

    passes = [
        (require_provider_diversity, require_runtime_diversity),
        (False, require_runtime_diversity),
        (False, False),
    ]
    for enforce_provider, enforce_runtime in passes:
        for candidate in ordered:
            if len(selected) >= count:
                break
            if not eligible(candidate, enforce_provider, enforce_runtime):
                continue
            candidate = dict(candidate)
            if prove_headless:
                if probes_used >= max(1, max_probes):
                    break
                probes_used += 1
                probe = runner(
                    _candidate_runtime(candidate),
                    str(candidate["arg"]),
                    str(wand.get("autonomy") or "medium"),
                    probe_ttl,
                )
                if not probe.get("landsCommit"):
                    probe_failures.append(
                        {"runtime": _candidate_runtime(candidate), "arg": candidate.get("arg"), "probe": probe}
                    )
                    continue
                candidate["smokeProbe"] = probe
            selected.append(candidate)
            used_providers.add(str(candidate.get("provider") or candidate.get("backend") or ""))
            used_runtimes.add(_candidate_runtime(candidate))
        if len(selected) >= count:
            break

    reason = None
    if len(selected) < count:
        reason = "insufficient_proven_candidates" if prove_headless else "insufficient_route_eligible_candidates"
    return {
        "status": "ok",
        "selected": selected,
        "requestedCount": count,
        "selectedCount": len(selected),
        "reason": reason,
        "wand": wand,
        "proofStatus": "proven_headless"
        if prove_headless and len(selected) == count
        else ("partial" if prove_headless else "unproven"),
        "allowRuntimes": sorted(runtime_filter),
        "providerDiversityRequired": require_provider_diversity,
        "runtimeDiversityRequired": require_runtime_diversity,
        "providerCount": len({str(item.get("provider") or item.get("backend") or "") for item in selected}),
        "runtimeCount": len({_candidate_runtime(item) for item in selected}),
        "probeFailures": probe_failures,
        "rankedCount": len(ranked),
        "rankedPreview": ranked[:10],
    }


def build_command(
    *,
    runtime: str,
    task_prompt: str,
    model_arg: str,
    cwd: str | None = None,
    prompt_path: str | None = None,
    result_path: str | None = None,
    done_path: str | None = None,
    status_path: str | None = None,
    autonomy: str = "medium",
    reasoning_effort: str | None = None,
) -> dict[str, Any]:
    adapter = adapter_for(runtime)
    return adapter.build_command(
        task_prompt=task_prompt,
        model_arg=model_arg,
        cwd=cwd,
        prompt_path=prompt_path,
        result_path=result_path,
        done_path=done_path,
        status_path=status_path,
        autonomy=autonomy,
        reasoning_effort=reasoning_effort,
    )


def smoke_probe(
    runtime: str, arg: str, autonomy: str = "medium", ttl: int = 3600, timeout_seconds: int = 120
) -> dict[str, Any]:
    return adapter_smoke_probe(adapter_for(runtime), arg, autonomy=autonomy, ttl=ttl, timeout_seconds=timeout_seconds)


def adapter_smoke_probe(
    adapter: RuntimeAdapter, arg: str, autonomy: str = "medium", ttl: int = 3600, timeout_seconds: int = 120
) -> dict[str, Any]:
    cache_key = (normalize_runtime(adapter.runtime), arg, autonomy)
    now = time.time()
    cached = _SMOKE_CACHE.get(cache_key)
    if cached and ttl > 0 and now - float(cached.get("fetchedAtEpoch", 0)) < ttl:
        result = dict(cached)
        result["cacheHit"] = True
        return result

    precondition = adapter.auth_precondition()
    if precondition.get("status") != "ok":
        payload = {**precondition, "arg": arg, "autonomy": autonomy, "landsCommit": False}
        _SMOKE_CACHE[cache_key] = {**payload, "fetchedAtEpoch": now}
        return payload

    with tempfile.TemporaryDirectory(prefix="bb-castle-probe-") as tmp:
        repo = Path(tmp)
        _run(["git", "init", "-q"], repo)
        _run(["git", "config", "user.email", "castle-probe@openburnbar.local"], repo)
        _run(["git", "config", "user.name", "OpenBurnBar Castle Probe"], repo)
        seed_worktree_isolation(repo)
        (repo / "README.md").write_text("Castle smoke probe baseline.\n", encoding="utf-8")
        _run(["git", "add", "README.md"], repo)
        _run(["git", "commit", "-q", "-m", "baseline"], repo)
        base = _run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
        prompt_path = repo / "prompt.txt"
        result_path = repo / "result.json"
        done_path = repo / "result.done"
        status_path = repo / "status.json"
        prompt = scoped_probe_prompt("castle_probe.txt")
        command_payload = adapter.build_command(
            task_prompt=prompt,
            model_arg=arg,
            cwd=str(repo),
            prompt_path=str(prompt_path),
            result_path=str(result_path),
            done_path=str(done_path),
            status_path=str(status_path),
            autonomy=autonomy,
        )
        prompt_path.write_text(prompt, encoding="utf-8")
        started = time.time()
        try:
            proc = subprocess.run(
                command_payload["command"],
                cwd=str(repo),
                shell=True,
                text=True,
                capture_output=True,
                timeout=max(30, min(int(timeout_seconds), 300)),
            )
        except subprocess.TimeoutExpired as exc:
            payload = {
                "status": "timeout",
                "code": "CASTLE_RUNTIME_TIMEOUT",
                "runtime": adapter.runtime,
                "arg": arg,
                "autonomy": autonomy,
                "landsCommit": False,
                "durationSeconds": round(time.time() - started, 3),
                "reason": str(exc),
            }
            _SMOKE_CACHE[cache_key] = {**payload, "fetchedAtEpoch": now}
            return payload
        result = collect_result(
            runtime=adapter.runtime,
            worktree_path=str(repo),
            base_sha=base,
            result_path=str(result_path),
            done_path=str(done_path),
            status_path=str(status_path),
        )
        payload = {
            "status": result.get("status"),
            "runtime": adapter.runtime,
            "arg": arg,
            "autonomy": autonomy,
            "landsCommit": bool(result.get("landedCommit")),
            "isError": result.get("isError"),
            "exitCode": proc.returncode,
            "baseSHA": base,
            "headSHA": result.get("headSHA"),
            "durationSeconds": round(time.time() - started, 3),
            "cacheHit": False,
            "stderrTail": ((result.get("stderr") or "") + proc.stderr)[-2000:],
            "statusRecord": result.get("statusRecord"),
        }
        _SMOKE_CACHE[cache_key] = {**payload, "fetchedAtEpoch": now}
        return payload


_SMOKE_CACHE: dict[tuple[str, str, str], dict[str, Any]] = {}


def collect_result(
    *,
    runtime: str,
    worktree_path: str,
    base_sha: str,
    result_path: str,
    done_path: str,
    status_path: str | None = None,
) -> dict[str, Any]:
    done = Path(done_path)
    result = Path(result_path)
    stderr = Path(f"{result_path}{STDERR_SUFFIX}")
    if not done.exists():
        return {
            "status": "running",
            "runtime": normalize_runtime(runtime),
            "reason": "done marker is absent",
            "resultExists": result.exists(),
            "resultSize": result.stat().st_size if result.exists() else 0,
        }
    exit_code = _done_exit_code(done)
    stdout = result.read_text(encoding="utf-8") if result.exists() else ""
    stderr_text = stderr.read_text(encoding="utf-8") if stderr.exists() else ""
    adapter = adapter_for(runtime)
    parsed = adapter.parse_completion(stdout, stderr_text, exit_code=exit_code)
    head_proc = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=worktree_path,
        text=True,
        capture_output=True,
        timeout=15,
    )
    head = head_proc.stdout.strip() if head_proc.returncode == 0 else None
    is_error = bool(parsed.get("is_error"))
    landed = bool(head and head != base_sha and not is_error)
    phase = "landed" if landed else ("no_op" if head == base_sha and not is_error else "failed")
    status_record = status_record_for_worker(
        runtime=runtime,
        model_arg=_done_value(done, "modelArg"),
        phase=phase,
        lands_commit=landed,
        base_sha=base_sha,
        head_sha=head,
        result_path=result_path,
        done_path=done_path,
        error_reason=parsed.get("reason") if is_error else None,
    )
    if status_path:
        write_status_record(status_path, status_record)
    return {
        "status": "ok" if landed else "failed",
        "runtime": normalize_runtime(runtime),
        "donePath": str(done),
        "resultPath": str(result),
        "stderrPath": str(stderr),
        "isError": is_error,
        "baseSHA": base_sha,
        "headSHA": head,
        "landedCommit": landed,
        "completion": parsed,
        "stderr": stderr_text,
        "statusRecord": status_record,
    }


def status_record_for_worker(
    *,
    runtime: str,
    model_arg: str | None,
    phase: str,
    lands_commit: bool,
    base_sha: str | None,
    head_sha: str | None,
    result_path: str | None,
    done_path: str | None,
    error_reason: str | None = None,
) -> dict[str, Any]:
    runtime = normalize_runtime(runtime)
    honesty: list[str] = []
    if phase == "no_op":
        honesty.append("no_op")
    if phase == "failed":
        honesty.append("failed")
    return {
        "schemaVersion": STATUS_SCHEMA_VERSION,
        "updatedAt": ministry.utc_now(),
        "runtime": runtime,
        "house": runtime_label(runtime),
        "modelArg": model_arg,
        "phase": phase,
        "landsCommit": bool(lands_commit),
        "baseSHA": base_sha,
        "headSHA": head_sha,
        "resultPath": result_path,
        "donePath": done_path,
        "honesty": honesty,
        "errorReason": error_reason,
    }


def write_status_record(status_path: str | Path, record: dict[str, Any]) -> None:
    path = Path(status_path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(record, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(tmp, path)


def status_snapshot(paths: list[str]) -> dict[str, Any]:
    records = []
    failures = []
    for raw in paths:
        path = Path(raw).expanduser()
        try:
            records.append(json.loads(path.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError) as exc:
            failures.append({"path": str(path), "reason": str(exc)})
    return {"status": "ok", "count": len(records), "records": records, "failures": failures}


def seed_worktree_isolation(worktree_path: str | Path, extra_patterns: Iterable[str] = ()) -> dict[str, Any]:
    repo = Path(worktree_path)
    exclude = repo / ".git" / "info" / "exclude"
    exclude.parent.mkdir(parents=True, exist_ok=True)
    existing = exclude.read_text(encoding="utf-8").splitlines() if exclude.is_file() else []
    patterns = [*SCRATCH_EXCLUDES, *extra_patterns]
    added = []
    lines = list(existing)
    for pattern in patterns:
        if pattern not in lines:
            lines.append(pattern)
            added.append(pattern)
    exclude.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")
    return {"status": "ok", "path": str(exclude), "added": added}


def scoped_probe_prompt(filename: str) -> str:
    return (
        "\n".join(
            [
                "This is an OpenBurnBar Castle smoke probe in a disposable git repository.",
                f"Create or update {filename} with one short line.",
                f"Then run exactly: git add {shlex.quote(filename)} && git commit -m 'castle smoke probe'.",
                "Do not run git add -A.",
                "Do not read or write files outside this repository.",
            ]
        )
        + "\n"
    )


def command_with_done_marker(
    *,
    argv: list[str],
    runtime: str,
    model_arg: str,
    prompt_path: str,
    result_path: str,
    stderr_path: str,
    done_path: str,
    status_path: str | None,
    cwd: str | None,
    stdin_devnull: bool,
) -> str:
    rendered = " ".join(_shell_arg(part, prompt_path=prompt_path) for part in argv)
    prefix = f"cd {ministry.shell_quote(cwd)} && " if cwd else ""
    stdin = " < /dev/null" if stdin_devnull else ""
    status_fragment = ""
    if status_path:
        status_fragment = (
            f'printf \'{{"schemaVersion":{STATUS_SCHEMA_VERSION},"updatedAt":"%s",'
            f'"runtime":{json.dumps(normalize_runtime(runtime))},'
            f'"house":{json.dumps(runtime_label(runtime))},'
            f'"modelArg":{json.dumps(model_arg)},"phase":"completed",'
            f'"landsCommit":false,"resultPath":{json.dumps(result_path)},'
            f'"donePath":{json.dumps(done_path)}}}\\n\' '
            f'"$(date -u +%Y-%m-%dT%H:%M:%SZ)" > {ministry.shell_quote(status_path)}; '
        )
    return (
        f"mkdir -p {ministry.shell_quote(Path(prompt_path).parent)} && "
        f"{prefix}{rendered} > {ministry.shell_quote(result_path)} 2> {ministry.shell_quote(stderr_path)}{stdin}; "
        "rc=$?; "
        f'printf \'{{"exitCode":%s,"runtime":{json.dumps(normalize_runtime(runtime))},'
        f'"modelArg":{json.dumps(model_arg)},"completedAt":"%s"}}\\n\' '
        f'"$rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > {ministry.shell_quote(done_path)}; '
        f"{status_fragment}"
        "exit $rc"
    )


def castle_sort_key(
    candidate: dict[str, Any], selector: str, runtime_preference: list[str] | None = None
) -> tuple[Any, ...]:
    runtime_preference = runtime_preference or []
    runtime_tier = _runtime_preference_tier(candidate, runtime_preference)
    qtier = ministry._quota_sort_tier(candidate)
    rank = int(candidate.get("capabilityClassRank") or 0)
    price = float(candidate.get("price") or 0)
    arg = _candidate_key(candidate)
    if selector == "pareto":
        cost_unknown_tier = 1 if candidate.get("costUnknown") else 0
        eff = 0.0 if candidate.get("costUnknown") else rank / (price + 0.01)
        return (qtier, cost_unknown_tier, -eff, price, runtime_tier, arg)
    return (qtier, -rank, 1 if candidate.get("costUnknown") else 0, price, runtime_tier, arg)


def castle_probe_sort_key(
    candidate: dict[str, Any], selector: str, runtime_preference: list[str] | None = None
) -> tuple[Any, ...]:
    proof_tier = 0 if _known_headless(candidate) else 1
    return (proof_tier, *castle_sort_key(candidate, selector, runtime_preference))


def normalize_model_key(value: Any) -> str:
    return ministry.normalize_key(value)


def split_provider_model(value: str, default_provider: str) -> tuple[str, str]:
    if "/" in value:
        provider, model = value.split("/", 1)
        return provider, model
    return default_provider, value


def _candidate_runtime(candidate: dict[str, Any]) -> str:
    return normalize_runtime(candidate.get("runtime") or "droid")


def _candidate_key(candidate: dict[str, Any]) -> str:
    return f"{_candidate_runtime(candidate)}:{candidate.get('arg') or candidate.get('model') or ''}"


def _runtime_preference_tier(candidate: dict[str, Any], runtime_preference: list[str]) -> int:
    runtime = _candidate_runtime(candidate)
    try:
        return runtime_preference.index(runtime)
    except ValueError:
        return len(runtime_preference)


def _allowed_runtimes(wand: dict[str, Any], override: list[str] | None) -> set[str]:
    raw = override if override is not None else (wand.get("allowRuntimes") or ["droid"])
    allowed = {normalize_runtime(item) for item in raw if normalize_runtime(item) in REGISTRY}
    return allowed or {"droid"}


def _wand_by_id(wands_payload: dict[str, Any], wand_id: str | None) -> dict[str, Any] | None:
    return ministry._wand_by_id(wands_payload, wand_id)


def _known_headless(candidate: dict[str, Any]) -> bool:
    runtime = _candidate_runtime(candidate)
    model = normalize_model_key(candidate.get("model"))
    if runtime == "droid":
        return ministry._is_known_headless_candidate(candidate)
    return runtime in {"codex", "claude", "gemini"} and model in {
        "gpt-5-5",
        "claude-opus-4-8",
        "gemini-3-1-pro-preview",
    }


def _probe_runner(runtime: str, arg: str, autonomy: str, ttl: int) -> dict[str, Any]:
    return smoke_probe(runtime, arg, autonomy=autonomy, ttl=ttl)


def _codex_models_from_config(config: dict[str, Any]) -> list[str]:
    models: list[str] = []
    top_model = _coerce_model_id(config.get("model"))
    if top_model:
        models.append(top_model)
    profiles = config.get("profiles")
    if isinstance(profiles, dict):
        for profile in profiles.values():
            if isinstance(profile, dict):
                model = _coerce_model_id(profile.get("model"))
                if model:
                    models.append(model)
    result = []
    seen = set()
    for model in models:
        key = normalize_model_key(model)
        if key and key not in seen:
            seen.add(key)
            result.append(model)
    return result


def _parse_json_object(text: str) -> dict[str, Any] | None:
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        return None
    return value if isinstance(value, dict) else None


def _parse_json_lines(text: str) -> list[dict[str, Any]]:
    events: list[dict[str, Any]] = []
    for line in text.splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            events.append(value)
    return events


def _shell_arg(part: str, *, prompt_path: str) -> str:
    if part == PROMPT_PLACEHOLDER:
        return f'"$(cat {ministry.shell_quote(prompt_path)})"'
    return ministry.shell_quote(part)


def _done_exit_code(path: Path) -> int:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return 1
    try:
        return int(data.get("exitCode", 1))
    except (TypeError, ValueError):
        return 1


def _done_value(path: Path, key: str) -> str | None:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    value = data.get(key)
    return str(value) if value is not None else None


def _run(cmd: list[str], cwd: Path, timeout: int = 120) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=str(cwd), text=True, capture_output=True, timeout=timeout)


def json_dumps(payload: Any) -> str:
    return ministry.json_dumps(payload)
