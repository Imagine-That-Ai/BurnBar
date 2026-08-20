#!/usr/bin/env python3
"""The Ministry model selection and droid command builder.

This module is intentionally stdlib-only so the local MCP server can expose the
orchestration helpers without adding runtime dependencies.
"""

from __future__ import annotations

import json
import os
import re
import shlex
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from collections.abc import Callable

try:
    # Optional BurnBench evidence (bench.json). The Ministry must behave
    # identically when the module or the data is missing, stale, or broken, so
    # the import is guarded and every tie-break lookup is wrapped in try/except.
    import bench as _bench_evidence
except Exception:  # pragma: no cover - defensive optional dependency
    _bench_evidence = None


_THIS_DIR = Path(__file__).resolve().parent
REPO_ROOT = _THIS_DIR.parent.parent
CATALOG_PATH = REPO_ROOT / "OpenBurnBarCore" / "Sources" / "OpenBurnBarKernel" / "Resources" / "catalog.json"
MODELS_JSON_PATHS = (
    REPO_ROOT / "website" / "public" / "data" / "models.json",
    REPO_ROOT / "website" / "scripts" / "rundown-seed" / "models.json",
)
FACTORY_SETTINGS_PATH = Path.home() / ".factory" / "settings.json"
FACTORY_CONFIG_PATH = Path.home() / ".factory" / "config.json"
GATEWAY_BASE_URL = "http://127.0.0.1:8317"
MINISTRY_CACHE_DIR = Path.home() / "Library" / "Application Support" / "OpenBurnBar" / "ministry"

AUTONOMY_LEVELS = {"low", "medium", "high"}
SELECTORS = {"best", "pareto"}
BACKENDS = {"gateway", "direct", "builtin"}

# Hard ceiling on parallel workers per Wand cast — mirrors the
# firestore.rules validMissionGroup() cap. The macOS app/daemon passes the
# user's resolved per-tier cap (Free 1 / Cloud 3 / Cloud Pro 8 / Ultra 16, from
# WandFanOut.maxParallel) via OPENBURNBAR_WAND_PARALLEL_MAX. Missing or
# malformed values are untrusted and fall back to the free tier. Always clamped
# to [1, WAND_PARALLEL_HARD_CEILING].
WAND_PARALLEL_HARD_CEILING = 16
WAND_PARALLEL_DEFAULT = 1


def resolved_wand_parallel_max() -> int:
    """Per-tier parallel fan-out ceiling for a Wand cast, from the env the app sets."""
    raw = os.environ.get("OPENBURNBAR_WAND_PARALLEL_MAX", "").strip()
    try:
        value = int(raw) if raw else WAND_PARALLEL_DEFAULT
    except ValueError:
        value = WAND_PARALLEL_DEFAULT
    return max(1, min(value, WAND_PARALLEL_HARD_CEILING))


RUNTIMES = {"droid", "codex", "claude", "gemini", "opencode", "cursor-agent", "cursoragent", "kimi", "pi"}

SEED_WANDS: list[dict[str, Any]] = [
    {
        "id": "headmaster",
        "name": "Headmaster's Wand",
        "selector": "best",
        "constraints": {"minCapabilityRank": 10},
        "target": "highest-capability proven-headless worker",
        "autonomy": "high",
        "reasoningEffort": None,
        "allowBackends": ["builtin", "direct"],
        "isDefault": True,
    },
    {
        "id": "pareto",
        "name": "Pareto Wand",
        "selector": "pareto",
        "constraints": {"minCapabilityRank": 10},
        "target": "best capability per known cost",
        "autonomy": "medium",
        "reasoningEffort": None,
        "allowBackends": ["builtin", "direct"],
        "isDefault": False,
    },
]

ALLOWLIST_BUILTINS: list[dict[str, Any]] = [
    {
        "arg": "gpt-5.4-mini",
        "model": "gpt-5.4-mini",
        "displayName": "GPT-5.4 Mini",
        "provider": "openai",
        "backend": "builtin",
        "baseURL": None,
        "source": "allowlist",
        "accountID": "factory-builtin",
    }
]

KNOWN_CAPABILITY_RANK_FALLBACKS = {
    # Factory's current catalog has no first-class GLM-5.2 row, but the live
    # droid custom slug is the verified direct Z.ai launch path from the plan.
    "glm-5-2": 20,
    # Direct-CLI Castle routes can expose flagship ids before catalog rows or
    # aliases catch up. These ranks are intentionally conservative except where
    # the catalog already establishes the class ceiling.
    "claude-opus-4-8": 110,
    "opus": 110,
    "gpt-5-5": 90,
    "gemini-3-1-pro-preview": 90,
}
KNOWN_HEADLESS_MODELS = {
    ("openai", "gpt-5-4-mini"),
    ("zai", "glm-5-2"),
}

MEM0_TOOL_NAMES = [
    "add_memory",
    "search_memories",
    "get_memories",
    "delete_all_memories",
    "list_entities",
    "get_memory",
    "update_memory",
    "delete_memory",
    "delete_entities",
    "list_events",
    "get_event_status",
]
SERENA_TOOL_NAMES = [
    "replace_content",
    "replace_symbol_body",
    "insert_after_symbol",
    "insert_before_symbol",
    "search_for_pattern",
    "get_symbols_overview",
    "find_symbol",
    "find_referencing_symbols",
    "find_implementations",
    "find_declaration",
    "get_diagnostics_for_file",
    "rename_symbol",
    "safe_delete_symbol",
    "write_memory",
    "read_memory",
    "list_memories",
    "delete_memory",
    "rename_memory",
    "edit_memory",
    "open_dashboard",
    "onboarding",
    "initial_instructions",
]
DEFAULT_DISABLED_TOOL_IDS = [
    *(f"mem0-mcp___{name}" for name in MEM0_TOOL_NAMES),
    *(f"mem0-lahormigadormida___{name}" for name in MEM0_TOOL_NAMES),
    *(f"serena___{name}" for name in SERENA_TOOL_NAMES),
]

_GATEWAY_CACHE: dict[str, Any] = {"fetchedAt": 0.0, "payload": None}
_SMOKE_CACHE: dict[tuple[str, str], dict[str, Any]] = {}


def utc_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def json_dumps(payload: Any) -> str:
    return json.dumps(payload, indent=2, default=str, sort_keys=True)


def normalize_key(value: Any) -> str:
    raw = str(value or "").strip().lower()
    raw = raw.replace("custom:openburnbar-", "").replace("custom:open-code-", "")
    raw = re.sub(r"[^a-z0-9]+", "-", raw)
    return re.sub(r"-+", "-", raw).strip("-")


def _tokens(value: str) -> set[str]:
    return {token for token in re.split(r"[^a-z0-9.]+", value.lower()) if token}


def _read_json_file(path: Path) -> Any:
    with path.open("r", encoding="utf-8") as fh:
        return json.load(fh)


def _coerce_float(value: Any) -> float | None:
    if value is None:
        return None
    try:
        number = float(value)
    except (TypeError, ValueError):
        return None
    if number < 0:
        return None
    return number


def default_wands_path(db_path: Path | None = None) -> Path:
    override = os.environ.get("OPENBURNBAR_MINISTRY_WANDS_PATH", "").strip()
    if override:
        return Path(override).expanduser().resolve()
    base = db_path.parent if db_path else MINISTRY_CACHE_DIR.parent
    return base / "ministry" / "wands.v1.json"


def _seed_wands() -> list[dict[str, Any]]:
    return json.loads(json.dumps(SEED_WANDS))


def sanitize_wands(raw: Any) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    warnings: list[dict[str, Any]] = []
    if isinstance(raw, dict):
        raw_wands = raw.get("wands")
        if not isinstance(raw_wands, list):
            warnings.append({"code": "non_list_wands", "reason": "wand document did not contain a wands[] list"})
            return _seed_wands(), warnings
    elif isinstance(raw, list):
        raw_wands = raw
    else:
        warnings.append({"code": "non_list_document", "reason": "wand store was not a JSON list or object"})
        return _seed_wands(), warnings

    sanitized: list[dict[str, Any]] = []
    seen_ids: set[str] = set()
    default_seen = False
    for index, item in enumerate(raw_wands):
        if not isinstance(item, dict):
            warnings.append({"code": "non_object_wand", "index": index})
            continue
        wand_id = str(item.get("id", "")).strip()
        name = str(item.get("name", "")).strip()
        if not wand_id:
            warnings.append({"code": "missing_id", "index": index})
            continue
        if wand_id in seen_ids:
            warnings.append({"code": "duplicate_id", "id": wand_id, "index": index})
            continue
        if not name:
            warnings.append({"code": "empty_name", "id": wand_id, "index": index})
            continue
        selector = str(item.get("selector", "best")).strip().lower()
        if selector not in SELECTORS:
            warnings.append({"code": "invalid_selector", "id": wand_id, "selector": selector})
            selector = "best"
        autonomy = str(item.get("autonomy", "medium")).strip().lower()
        if autonomy not in AUTONOMY_LEVELS:
            warnings.append({"code": "invalid_autonomy", "id": wand_id, "autonomy": autonomy})
            autonomy = "medium"
        allow_backends = item.get("allowBackends", ["builtin", "direct", "gateway"])
        if not isinstance(allow_backends, list):
            allow_backends = ["builtin", "direct", "gateway"]
            warnings.append({"code": "invalid_allow_backends", "id": wand_id})
        allow_backends = [
            str(value).strip().lower() for value in allow_backends if str(value).strip().lower() in BACKENDS
        ]
        if not allow_backends:
            allow_backends = ["builtin", "direct", "gateway"]
            warnings.append({"code": "empty_allow_backends", "id": wand_id})
        allow_runtimes = item.get("allowRuntimes", ["droid"])
        if not isinstance(allow_runtimes, list):
            allow_runtimes = ["droid"]
            warnings.append({"code": "invalid_allow_runtimes", "id": wand_id})
        normalized_runtimes = []
        for value in allow_runtimes:
            runtime = str(value).strip().lower()
            if runtime in RUNTIMES:
                normalized_runtimes.append("cursor-agent" if runtime == "cursoragent" else runtime)
        allow_runtimes = sorted(set(normalized_runtimes), key=normalized_runtimes.index)
        if not allow_runtimes:
            allow_runtimes = ["droid"]
            warnings.append({"code": "empty_allow_runtimes", "id": wand_id})
        runtime_preference = item.get("runtimePreference", [])
        if not isinstance(runtime_preference, list):
            runtime_preference = []
            warnings.append({"code": "invalid_runtime_preference", "id": wand_id})
        normalized_preference = []
        for value in runtime_preference:
            runtime = str(value).strip().lower()
            if runtime in RUNTIMES:
                normalized_preference.append("cursor-agent" if runtime == "cursoragent" else runtime)
        runtime_preference = sorted(set(normalized_preference), key=normalized_preference.index)
        raw_constraints = item.get("constraints")
        constraints = dict(raw_constraints) if isinstance(raw_constraints, dict) else {}
        min_rank = constraints.get("minCapabilityRank", 0)
        try:
            constraints["minCapabilityRank"] = max(0, int(min_rank))
        except (TypeError, ValueError):
            constraints["minCapabilityRank"] = 0
            warnings.append({"code": "invalid_min_rank", "id": wand_id})
        is_default = bool(item.get("isDefault", False))
        if is_default:
            if default_seen:
                warnings.append({"code": "extra_default_cleared", "id": wand_id})
                is_default = False
            else:
                default_seen = True
        sanitized.append(
            {
                "id": wand_id,
                "name": name,
                "selector": selector,
                "constraints": constraints,
                "target": str(item.get("target", "")).strip(),
                "autonomy": autonomy,
                "reasoningEffort": item.get("reasoningEffort"),
                "allowBackends": allow_backends,
                "allowRuntimes": allow_runtimes,
                "runtimePreference": runtime_preference,
                "isDefault": is_default,
            }
        )
        seen_ids.add(wand_id)

    if not sanitized:
        warnings.append({"code": "empty_after_sanitize", "reason": "no valid wands remained"})
        return _seed_wands(), warnings
    if not any(wand.get("isDefault") for wand in sanitized):
        sanitized[0]["isDefault"] = True
        warnings.append({"code": "default_added", "id": sanitized[0]["id"]})
    return sanitized, warnings


def load_wands(store_path: Path) -> dict[str, Any]:
    if not store_path.is_file():
        return {
            "status": "ok",
            "source": "seed",
            "path": str(store_path),
            "repoRoot": str(REPO_ROOT),
            "wands": _seed_wands(),
            "warnings": [],
        }
    try:
        raw = _read_json_file(store_path)
    except json.JSONDecodeError as exc:
        return {
            "status": "ok",
            "source": "seed",
            "path": str(store_path),
            "repoRoot": str(REPO_ROOT),
            "wands": _seed_wands(),
            "warnings": [{"code": "corrupt_json", "reason": str(exc)}],
        }
    except OSError as exc:
        return {
            "status": "ok",
            "source": "seed",
            "path": str(store_path),
            "repoRoot": str(REPO_ROOT),
            "wands": _seed_wands(),
            "warnings": [{"code": "store_read_failed", "reason": str(exc)}],
        }
    wands, warnings = sanitize_wands(raw)
    return {
        "status": "ok",
        "source": "file",
        "path": str(store_path),
        "repoRoot": str(REPO_ROOT),
        "wands": wands,
        "warnings": warnings,
    }


def validate_wands(store_path: Path) -> dict[str, Any]:
    current = load_wands(store_path)
    sanitized = current["wands"]
    file_payload = None
    if store_path.is_file():
        try:
            file_payload = _read_json_file(store_path)
        except (OSError, json.JSONDecodeError):
            file_payload = None
    comparable_payload = file_payload
    if isinstance(file_payload, dict):
        comparable_payload = dict(file_payload)
        comparable_payload.pop("updatedAt", None)
    return {
        "status": "ok",
        "path": str(store_path),
        "source": current["source"],
        "valid": not current["warnings"],
        "warnings": current["warnings"],
        "sanitized": sanitized,
        "wouldChange": comparable_payload is not None
        and comparable_payload != {"schemaVersion": 1, "wands": sanitized},
    }


def save_wands(store_path: Path, raw_wands: Any) -> dict[str, Any]:
    wands, warnings = sanitize_wands(raw_wands)
    payload = {"schemaVersion": 1, "updatedAt": utc_now(), "wands": wands}
    tmp: Path | None = None
    try:
        store_path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            dir=store_path.parent,
            prefix=f".{store_path.name}.",
            suffix=".tmp",
            delete=False,
        ) as fh:
            tmp = Path(fh.name)
            fh.write(json.dumps(payload, indent=2, sort_keys=True) + "\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, store_path)
        tmp = None

        # Persist the directory entry where the platform supports directory
        # fsync. The file itself is already safely replaced if this is absent.
        try:
            directory_fd = os.open(store_path.parent, os.O_RDONLY)
            try:
                os.fsync(directory_fd)
            finally:
                os.close(directory_fd)
        except OSError:
            pass
    except OSError as exc:
        if tmp is not None:
            try:
                tmp.unlink(missing_ok=True)
            except OSError:
                pass
        return {
            "status": "error",
            "code": "WAND_STORE_WRITE_FAILED",
            "reason": str(exc),
            "path": str(store_path),
            "wands": wands,
            "warnings": warnings,
        }
    return {"status": "ok", "path": str(store_path), "wands": wands, "warnings": warnings}


def read_factory_settings(
    settings_path: Path = FACTORY_SETTINGS_PATH, config_path: Path = FACTORY_CONFIG_PATH
) -> dict[str, Any]:
    for path in (settings_path, config_path):
        if not path.is_file():
            continue
        try:
            data = _read_json_file(path)
        except (OSError, json.JSONDecodeError):
            continue
        if isinstance(data, dict):
            data["_sourcePath"] = str(path)
            return data
    return {"_sourcePath": None}


def _custom_models(settings: dict[str, Any]) -> list[dict[str, Any]]:
    raw = settings.get("customModels")
    if not isinstance(raw, list):
        raw = settings.get("custom_models")
    return raw if isinstance(raw, list) else []


def _classify_backend(base_url: str) -> tuple[str, str | None]:
    host = urllib.parse.urlparse(base_url).netloc.lower()
    if not host:
        host = base_url.lower()
    if host.startswith("127.0.0.1:8317") or host.startswith("localhost:8317"):
        return "gateway", None
    if "opencode.ai" in host:
        return "direct", "opencode"
    if "api.z.ai" in host or host == "z.ai":
        return "direct", "zai"
    return "direct", None


def launch_candidates_from_factory(settings: dict[str, Any]) -> list[dict[str, Any]]:
    candidates: list[dict[str, Any]] = []
    for index, item in enumerate(_custom_models(settings)):
        if not isinstance(item, dict):
            continue
        model = str(item.get("model") or item.get("modelId") or item.get("modelID") or "").strip()
        arg = str(item.get("id") or item.get("arg") or model).strip()
        if not model or not arg:
            continue
        base_url = str(item.get("baseUrl") or item.get("baseURL") or "").strip()
        backend, provider_hint = _classify_backend(base_url)
        provider = provider_hint or str(item.get("provider") or "").strip() or None
        candidates.append(
            {
                "arg": arg,
                "model": model,
                "displayName": str(item.get("displayName") or item.get("name") or model).strip(),
                "provider": provider,
                "backend": backend,
                "baseURL": base_url or None,
                "source": "factory.customModels",
                "settingsIndex": index,
                "accountID": "auto" if backend == "gateway" else provider or "direct",
            }
        )
    candidates.extend(json.loads(json.dumps(ALLOWLIST_BUILTINS)))
    return _dedupe_candidates(candidates)


def _dedupe_candidates(candidates: list[dict[str, Any]]) -> list[dict[str, Any]]:
    seen: set[tuple[str, str, str]] = set()
    result: list[dict[str, Any]] = []
    for candidate in candidates:
        runtime = str(candidate.get("runtime") or "droid")
        key = (runtime, str(candidate.get("backend")), str(candidate.get("arg")))
        if key in seen:
            continue
        seen.add(key)
        result.append(candidate)
    return result


def load_catalog(catalog_path: Path = CATALOG_PATH) -> list[dict[str, Any]]:
    data = _read_json_file(catalog_path)
    if not isinstance(data, dict) or not isinstance(data.get("providers"), list):
        raise ValueError("catalog.json must be an object with providers[]")
    rows: list[dict[str, Any]] = []
    for provider in data["providers"]:
        if not isinstance(provider, dict):
            continue
        provider_id = str(provider.get("id") or "").strip()
        for model in provider.get("models") or []:
            if not isinstance(model, dict):
                continue
            row = dict(model)
            row["_providerID"] = provider_id
            row["_providerDisplayName"] = provider.get("displayName")
            row["_providerBaseURL"] = provider.get("baseURL")
            rows.append(row)
    return rows


def load_models_index(paths: tuple[Path, ...] = MODELS_JSON_PATHS) -> dict[str, dict[str, Any]]:
    data: Any = None
    source_path: Path | None = None
    for path in paths:
        if path.is_file():
            data = _read_json_file(path)
            source_path = path
            break
    if not isinstance(data, list):
        return {}
    index: dict[str, dict[str, Any]] = {}
    for row in data:
        if not isinstance(row, dict):
            continue
        keys = [row.get("modelID"), *(row.get("aliases") or [])]
        for key in keys:
            norm = normalize_key(key)
            if norm:
                enriched = dict(row)
                enriched["_sourcePath"] = str(source_path) if source_path else None
                index.setdefault(norm, enriched)
    return index


def _provider_matches(candidate: dict[str, Any], row: dict[str, Any]) -> bool:
    candidate_provider = normalize_key(candidate.get("provider"))
    catalog_provider = normalize_key(row.get("_providerID"))
    if not candidate_provider:
        return True
    if candidate_provider in {"generic-chat-completion-api", "openai-compatible"}:
        return True
    return candidate_provider == catalog_provider


def match_catalog_model(candidate: dict[str, Any], catalog_rows: list[dict[str, Any]]) -> dict[str, Any] | None:
    identifiers = [
        candidate.get("catalog_id"),
        candidate.get("catalogID"),
        candidate.get("model"),
        candidate.get("arg"),
        candidate.get("displayName"),
    ]
    exact_keys = {normalize_key(value) for value in identifiers if value}
    exact_keys.discard("")

    provider_rows = [row for row in catalog_rows if _provider_matches(candidate, row)]
    search_rows = provider_rows or catalog_rows
    for row in search_rows:
        row_keys = {normalize_key(row.get("id")), normalize_key(row.get("canonicalModelID"))}
        row_keys.update(normalize_key(alias) for alias in row.get("aliases") or [])
        if exact_keys.intersection(row_keys):
            return row

    # Some live Factory routes are verified launch slugs that intentionally do
    # not yet have catalog identity rows. Do not let broad token matchers make
    # them inherit a neighboring model's price or identity.
    if normalize_key(candidate.get("model")) in KNOWN_CAPABILITY_RANK_FALLBACKS:
        return None

    haystack = " ".join(str(value or "") for value in identifiers)
    haystack_norm = normalize_key(haystack).replace("-", " ")
    haystack_tokens = _tokens(haystack_norm)
    for row in search_rows:
        for matcher in row.get("matchers") or []:
            if not isinstance(matcher, dict):
                continue
            all_terms = [str(term).lower() for term in matcher.get("all") or []]
            any_terms = [str(term).lower() for term in matcher.get("any") or []]
            none_terms = [str(term).lower() for term in matcher.get("none") or []]
            if any(term in haystack_norm or normalize_key(term) in haystack_tokens for term in none_terms):
                continue
            if all(term in haystack_norm or normalize_key(term) in haystack_tokens for term in all_terms) and (
                not any_terms
                or any(term in haystack_norm or normalize_key(term) in haystack_tokens for term in any_terms)
            ):
                return row
    return None


def match_models_metadata(
    candidate: dict[str, Any], catalog_row: dict[str, Any] | None, models_index: dict[str, dict[str, Any]]
) -> dict[str, Any] | None:
    keys = [candidate.get("catalog_id"), candidate.get("catalogID"), candidate.get("model"), candidate.get("arg")]
    if catalog_row:
        keys.extend([catalog_row.get("id"), catalog_row.get("canonicalModelID"), *(catalog_row.get("aliases") or [])])
    for key in keys:
        row = models_index.get(normalize_key(key))
        if row:
            return row
    return None


def _catalog_price(row: dict[str, Any] | None) -> tuple[float, bool]:
    if not row:
        return 0.0, True
    pricing = row.get("pricing")
    if not isinstance(pricing, dict):
        return 0.0, True
    input_price = _coerce_float(pricing.get("inputPerMToken"))
    output_price = _coerce_float(pricing.get("outputPerMToken"))
    cache_price = _coerce_float(pricing.get("cacheReadPerMToken"))
    parts = [value for value in (input_price, output_price, cache_price) if value is not None]
    if not parts:
        return 0.0, True
    total = sum(parts)
    return total, total <= 0


def enrich_candidate(
    candidate: dict[str, Any],
    catalog_rows: list[dict[str, Any]],
    models_index: dict[str, dict[str, Any]],
    quota_by_model: dict[str, dict[str, Any]] | None = None,
) -> dict[str, Any]:
    row = match_catalog_model(candidate, catalog_rows)
    model_meta = match_models_metadata(candidate, row, models_index)
    rank = 0
    if row and row.get("capabilityClassRank") is not None:
        try:
            rank = int(row.get("capabilityClassRank") or 0)
        except (TypeError, ValueError):
            rank = 0
    if rank <= 0:
        rank = KNOWN_CAPABILITY_RANK_FALLBACKS.get(normalize_key(candidate.get("model")), rank)
    cost_signal = _coerce_float(model_meta.get("costSignal")) if model_meta else None
    catalog_price, catalog_unknown = _catalog_price(row)
    if cost_signal is not None and cost_signal > 0:
        price = cost_signal
        cost_unknown = False
        cost_source = "models.costSignal"
    else:
        price = catalog_price
        cost_unknown = catalog_unknown
        cost_source = "catalog.pricing" if not catalog_unknown else "unknown"

    quota = {"state": "unavailable", "remainingPercent": None, "trust": "not_applicable"}
    if candidate.get("backend") == "gateway" and quota_by_model is not None:
        quota = _quota_for_candidate(candidate, quota_by_model)

    enriched = dict(candidate)
    enriched.update(
        {
            "catalog": _catalog_summary(row),
            "modelsMetadata": _models_summary(model_meta),
            "capabilityClassRank": rank,
            "price": round(price, 6),
            "costUnknown": bool(cost_unknown),
            "costSource": cost_source,
            "quota": quota,
        }
    )
    return enriched


def _catalog_summary(row: dict[str, Any] | None) -> dict[str, Any] | None:
    if not row:
        return None
    return {
        "providerID": row.get("_providerID"),
        "id": row.get("id"),
        "displayName": row.get("displayName"),
        "canonicalModelID": row.get("canonicalModelID"),
        "capabilityClassID": row.get("capabilityClassID"),
        "capabilityClassRank": row.get("capabilityClassRank"),
        "pricing": row.get("pricing"),
    }


def _models_summary(row: dict[str, Any] | None) -> dict[str, Any] | None:
    if not row:
        return None
    return {
        "modelID": row.get("modelID"),
        "providerID": row.get("providerID"),
        "tier": row.get("tier"),
        "costSignal": row.get("costSignal"),
        "sourcePath": row.get("_sourcePath"),
    }


def read_gateway_token(settings: dict[str, Any] | None = None) -> dict[str, Any]:
    settings = settings or read_factory_settings()
    for item in _custom_models(settings):
        if not isinstance(item, dict):
            continue
        base_url = str(item.get("baseUrl") or item.get("baseURL") or "")
        backend, _ = _classify_backend(base_url)
        token = str(item.get("apiKey") or item.get("api_key") or "").strip()
        if backend == "gateway" and token:
            return {
                "status": "ok",
                "token": token,
                "baseURL": base_url.rstrip("/") or GATEWAY_BASE_URL,
                "sourcePath": settings.get("_sourcePath"),
            }
    return {
        "status": "unavailable",
        "code": "GATEWAY_TOKEN_MISSING",
        "reason": "No 127.0.0.1:8317 custom model apiKey found",
    }


def gateway_get(path: str = "/v1/models", ttl: int = 30) -> dict[str, Any]:
    now = time.time()
    if ttl > 0 and _GATEWAY_CACHE["payload"] is not None and now - float(_GATEWAY_CACHE["fetchedAt"]) < ttl:
        cached = dict(_GATEWAY_CACHE["payload"])
        cached["cacheHit"] = True
        return cached
    token_payload = read_gateway_token()
    if token_payload.get("status") != "ok":
        return token_payload
    base_url = str(token_payload.get("baseURL") or GATEWAY_BASE_URL).rstrip("/")
    url = f"{base_url}{path}"
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {token_payload['token']}"})
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            body = resp.read().decode("utf-8")
            payload = json.loads(body)
    except (OSError, urllib.error.URLError, json.JSONDecodeError) as exc:
        return {
            "status": "unavailable",
            "code": "GATEWAY_REQUEST_FAILED",
            "reason": str(exc),
            "url": url,
            "tokenSourcePath": token_payload.get("sourcePath"),
        }
    result = {
        "status": "ok",
        "url": url,
        "tokenSourcePath": token_payload.get("sourcePath"),
        "payload": payload,
        "cacheHit": False,
        "fetchedAt": utc_now(),
    }
    _GATEWAY_CACHE.update({"fetchedAt": now, "payload": result})
    return result


def _extract_quota_state(row: dict[str, Any]) -> str:
    for key in ("quota_state", "quotaState", "state", "availability"):
        value = row.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip().lower()
    return "unknown"


def gateway_quota(ttl: int = 30) -> dict[str, Any]:
    response = gateway_get("/v1/models", ttl=ttl)
    if response.get("status") != "ok":
        return response
    payload = response.get("payload")
    rows = payload.get("data") if isinstance(payload, dict) else None
    if not isinstance(rows, list):
        return {
            "status": "unavailable",
            "code": "GATEWAY_MODELS_SHAPE_UNSUPPORTED",
            "reason": "Expected /v1/models to return object with data[]",
            "url": response.get("url"),
        }
    models = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        model_id = str(row.get("id") or "").strip()
        if not model_id:
            continue
        models.append(
            {
                "id": model_id,
                "ownedBy": row.get("owned_by") or row.get("ownedBy"),
                "quotaState": _extract_quota_state(row),
                "remainingPercent": None,
                "quotaTrust": "enum_only",
            }
        )
    return {
        "status": "ok",
        "url": response.get("url"),
        "tokenSourcePath": response.get("tokenSourcePath"),
        "cacheHit": response.get("cacheHit", False),
        "modelCount": len(models),
        "data": models,
    }


def _quota_index(quota_payload: dict[str, Any]) -> dict[str, dict[str, Any]]:
    if quota_payload.get("status") != "ok":
        return {}
    index: dict[str, dict[str, Any]] = {}
    for row in quota_payload.get("data") or []:
        if not isinstance(row, dict):
            continue
        index[normalize_key(row.get("id"))] = row
    return index


def _quota_for_candidate(candidate: dict[str, Any], quota_by_model: dict[str, dict[str, Any]]) -> dict[str, Any]:
    for key in (candidate.get("model"), candidate.get("arg"), candidate.get("displayName")):
        row = quota_by_model.get(normalize_key(key))
        if row:
            return {
                "state": row.get("quotaState", "unknown"),
                "remainingPercent": None,
                "trust": row.get("quotaTrust", "enum_only"),
            }
    return {"state": "unknown", "remainingPercent": None, "trust": "enum_only"}


def list_launchable(include_quota: bool = True) -> dict[str, Any]:
    settings = read_factory_settings()
    catalog_rows = load_catalog()
    models_index = load_models_index()
    quota_payload = gateway_quota() if include_quota else {"status": "skipped"}
    quota_by_model = _quota_index(quota_payload)
    candidates = [
        enrich_candidate(candidate, catalog_rows, models_index, quota_by_model if include_quota else None)
        for candidate in launch_candidates_from_factory(settings)
    ]
    return {
        "status": "ok",
        "repoRoot": str(REPO_ROOT),
        "settingsSourcePath": settings.get("_sourcePath"),
        "catalogPath": str(CATALOG_PATH),
        "modelsJsonPaths": [str(path) for path in MODELS_JSON_PATHS if path.is_file()],
        "quotaStatus": {k: v for k, v in quota_payload.items() if k != "data"},
        "count": len(candidates),
        "candidates": candidates,
    }


def disabled_tool_ids() -> list[str]:
    override = os.environ.get("OPENBURNBAR_MINISTRY_DISABLED_TOOL_IDS", "").strip()
    if override:
        return [part.strip() for part in re.split(r"[,\s]+", override) if part.strip()]
    return list(DEFAULT_DISABLED_TOOL_IDS)


def disabled_tools_arg() -> str:
    return ",".join(disabled_tool_ids())


def _quota_sort_tier(candidate: dict[str, Any]) -> int:
    if candidate.get("backend") != "gateway":
        return 0
    state = str((candidate.get("quota") or {}).get("state") or "unknown").lower()
    if state in {"ok", "available", "healthy", "normal", "unknown"}:
        return 0
    if state in {"limited", "degraded", "near_limit", "warning"}:
        return 1
    return 2


def _candidate_sort_key(candidate: dict[str, Any], selector: str) -> tuple[Any, ...]:
    qtier = _quota_sort_tier(candidate)
    rank = int(candidate.get("capabilityClassRank") or 0)
    price = float(candidate.get("price") or 0)
    arg = str(candidate.get("arg") or "")
    if selector == "pareto":
        cost_unknown_tier = 1 if candidate.get("costUnknown") else 0
        eff = 0.0 if candidate.get("costUnknown") else rank / (price + 0.01)
        return (qtier, cost_unknown_tier, -eff, price, arg)
    return (qtier, -rank, 1 if candidate.get("costUnknown") else 0, price, arg)


def _probe_sort_key(candidate: dict[str, Any], selector: str) -> tuple[Any, ...]:
    # Proof mode starts with candidates already known to be headless-capable in
    # this launch universe, then falls back to the policy-ranked custom routes.
    proof_tier = 0 if _is_known_headless_candidate(candidate) else 1
    return (proof_tier, *_candidate_sort_key(candidate, selector))


def _is_known_headless_candidate(candidate: dict[str, Any]) -> bool:
    provider = normalize_key(candidate.get("provider"))
    model = normalize_key(candidate.get("model"))
    return (provider, model) in KNOWN_HEADLESS_MODELS


def _tie_group_key(candidate: dict[str, Any]) -> tuple[int, int]:
    return (_quota_sort_tier(candidate), int(candidate.get("capabilityClassRank") or 0))


def _apply_bench_tiebreak(
    ranked: list[dict[str, Any]], mission_family: str | None
) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    """Optionally reorder adjacent equal-(quota tier, capability rank) groups.

    Within each tied group, candidates are stably reordered by the fresh,
    adequately-powered bench.json solution_rate for their default ("droid")
    harness pairing in the mission's family (falling back to overall scope).
    Candidates without usable evidence sink to the bottom of their tied group
    in their original relative order. Returns the input list untouched whenever
    bench evidence is unavailable, stale, or errors — the existing quota /
    capability / price ordering is always the fallback. Never raises.
    """
    info: dict[str, Any] = {"applied": False, "family": mission_family or None, "harness": "droid"}
    if _bench_evidence is None or len(ranked) < 2:
        return ranked, info
    try:
        groups: list[tuple[int, int]] = []
        start = 0
        for index in range(1, len(ranked) + 1):
            if index == len(ranked) or _tie_group_key(ranked[index]) != _tie_group_key(ranked[start]):
                if index - start > 1:
                    groups.append((start, index))
                start = index
        if not groups:
            return ranked, info
        ordered = list(ranked)
        moved = False
        for start, end in groups:
            group = ordered[start:end]
            scored = [
                (
                    position,
                    _bench_evidence.solution_rate_for_model(
                        "droid", candidate.get("model") or candidate.get("arg"), mission_family
                    ),
                )
                for position, candidate in enumerate(group)
            ]
            if all(rate is None for _position, rate in scored):
                continue
            # Stable sort: unknown evidence (-inf proxy 1.0) keeps its relative
            # order below every known rate in [0, 1].
            scored.sort(key=lambda item: (0.0 - item[1]) if item[1] is not None else 1.0)
            reordered = [group[position] for position, _rate in scored]
            if [id(row) for row in reordered] != [id(row) for row in group]:
                moved = True
                ordered[start:end] = reordered
        if not moved:
            return ranked, info
        info["applied"] = True
        return ordered, info
    except Exception:  # pragma: no cover - defensive: evidence must never break selection
        return ranked, {"applied": False, "family": mission_family or None, "harness": "droid"}


def _wand_by_id(wands_payload: dict[str, Any], wand_id: str | None) -> dict[str, Any] | None:
    wands = wands_payload.get("wands") or []
    if wand_id:
        for wand in wands:
            if wand.get("id") == wand_id:
                return wand
        return None
    for wand in wands:
        if wand.get("isDefault"):
            return wand
    return wands[0] if wands else None


def select_model_for_wand(
    store_path: Path,
    wand_id: str | None = None,
    exclude_args: list[str] | None = None,
    prove_headless: bool = False,
    max_probes: int = 2,
    probe_ttl: int = 3600,
    probe_runner: Callable[[str, str, int], dict[str, Any]] | None = None,
    mission_family: str | None = None,
) -> dict[str, Any]:
    wands_payload = load_wands(store_path)
    wand = _wand_by_id(wands_payload, wand_id)
    if not wand:
        return {"status": "ok", "selected": None, "reason": "wand_not_found", "wandID": wand_id}

    launchable = list_launchable(include_quota=True)
    excluded = set(exclude_args or [])
    allowed_backends = set(wand.get("allowBackends") or ["builtin", "direct", "gateway"])
    min_rank = int((wand.get("constraints") or {}).get("minCapabilityRank") or 0)
    candidates = [
        candidate
        for candidate in launchable["candidates"]
        if candidate.get("arg") not in excluded
        and candidate.get("backend") in allowed_backends
        and int(candidate.get("capabilityClassRank") or 0) >= min_rank
    ]
    selector = str(wand.get("selector") or "best")
    ranked = sorted(candidates, key=lambda candidate: _candidate_sort_key(candidate, selector))
    if not ranked:
        return {
            "status": "ok",
            "selected": None,
            "reason": "no_route_eligible_candidates",
            "wand": wand,
            "candidateCount": len(launchable["candidates"]),
        }
    ranked, bench_tiebreak = _apply_bench_tiebreak(ranked, mission_family)

    def _annotate(payload: dict[str, Any]) -> dict[str, Any]:
        if bench_tiebreak.get("applied"):
            payload["benchTieBreak"] = bench_tiebreak
        return payload

    if not prove_headless:
        return _annotate(
            {
                "status": "ok",
                "selected": ranked[0],
                "wand": wand,
                "proofStatus": "unproven",
                "rankedCount": len(ranked),
                "rankedPreview": ranked[:10],
            }
        )

    runner = probe_runner or smoke_probe
    probe_failures: list[dict[str, Any]] = []
    probe_ranked = sorted(ranked, key=lambda candidate: _probe_sort_key(candidate, selector))
    for candidate in probe_ranked[: max(1, max_probes)]:
        probe = runner(str(candidate["arg"]), str(wand.get("autonomy") or "medium"), probe_ttl)
        if probe.get("landsCommit"):
            selected = dict(candidate)
            selected["smokeProbe"] = probe
            return _annotate(
                {
                    "status": "ok",
                    "selected": selected,
                    "wand": wand,
                    "proofStatus": "proven_headless",
                    "probeOrdering": "known_headless_first",
                    "rankedCount": len(ranked),
                    "rankedPreview": ranked[:10],
                }
            )
        probe_failures.append({"arg": candidate.get("arg"), "probe": probe})
    return _annotate(
        {
            "status": "ok",
            "selected": None,
            "reason": "probe_failed_for_ranked_candidates",
            "wand": wand,
            "probeFailures": probe_failures,
            "rankedCount": len(ranked),
        }
    )


def select_models_for_wand(
    store_path: Path,
    wand_id: str | None = None,
    count: int = 2,
    require_provider_diversity: bool = True,
    exclude_args: list[str] | None = None,
    prove_headless: bool = False,
    max_probes: int = 4,
    probe_ttl: int = 3600,
    probe_runner: Callable[[str, str, int], dict[str, Any]] | None = None,
    mission_family: str | None = None,
) -> dict[str, Any]:
    count = max(1, min(int(count), resolved_wand_parallel_max()))
    wands_payload = load_wands(store_path)
    wand = _wand_by_id(wands_payload, wand_id)
    if not wand:
        return {"status": "ok", "selected": [], "reason": "wand_not_found", "wandID": wand_id}

    launchable = list_launchable(include_quota=True)
    excluded = set(exclude_args or [])
    allowed_backends = set(wand.get("allowBackends") or ["builtin", "direct", "gateway"])
    min_rank = int((wand.get("constraints") or {}).get("minCapabilityRank") or 0)
    candidates = [
        candidate
        for candidate in launchable["candidates"]
        if candidate.get("arg") not in excluded
        and candidate.get("backend") in allowed_backends
        and int(candidate.get("capabilityClassRank") or 0) >= min_rank
    ]
    selector = str(wand.get("selector") or "best")
    ranked = sorted(candidates, key=lambda candidate: _candidate_sort_key(candidate, selector))
    ranked, bench_tiebreak = _apply_bench_tiebreak(ranked, mission_family)
    ordered = sorted(ranked, key=lambda candidate: _probe_sort_key(candidate, selector)) if prove_headless else ranked

    selected: list[dict[str, Any]] = []
    probe_failures: list[dict[str, Any]] = []
    used_providers: set[str] = set()
    attempted_args: set[str] = set()
    probes_used = 0
    probe_limit = max(1, max_probes)
    runner = probe_runner or smoke_probe

    def eligible(candidate: dict[str, Any], enforce_diversity: bool) -> bool:
        candidate_arg = str(candidate.get("arg"))
        if candidate_arg in attempted_args or candidate_arg in {str(item.get("arg")) for item in selected}:
            return False
        provider = str(candidate.get("provider") or candidate.get("backend") or "")
        return not enforce_diversity or provider not in used_providers

    passes = [True, False] if require_provider_diversity else [False]
    for enforce_diversity in passes:
        pass_candidates = ordered
        if not enforce_diversity and used_providers:
            # Once diversity must relax, use the remaining bounded probes on
            # siblings of a provider that already proved it can land a commit.
            pass_candidates = sorted(
                ordered,
                key=lambda candidate: (
                    0 if str(candidate.get("provider") or candidate.get("backend") or "") in used_providers else 1
                ),
            )
        for candidate in pass_candidates:
            if len(selected) >= count:
                break
            remaining_probes = probe_limit - probes_used
            remaining_slots = count - len(selected)
            if prove_headless and enforce_diversity and used_providers and remaining_probes <= remaining_slots:
                break
            if not eligible(candidate, enforce_diversity):
                continue
            if prove_headless:
                if probes_used >= probe_limit:
                    break
                probes_used += 1
                attempted_args.add(str(candidate["arg"]))
                probe = runner(str(candidate["arg"]), str(wand.get("autonomy") or "medium"), probe_ttl)
                if not probe.get("landsCommit"):
                    probe_failures.append({"arg": candidate.get("arg"), "probe": probe})
                    continue
                candidate = dict(candidate)
                candidate["smokeProbe"] = probe
            selected.append(candidate)
            used_providers.add(str(candidate.get("provider") or candidate.get("backend") or ""))
        if len(selected) >= count:
            break

    reason = None
    if len(selected) < count:
        reason = "insufficient_proven_candidates" if prove_headless else "insufficient_route_eligible_candidates"
    payload = {
        "status": "ok",
        "selected": selected,
        "requestedCount": count,
        "selectedCount": len(selected),
        "reason": reason,
        "wand": wand,
        "proofStatus": "proven_headless"
        if prove_headless and len(selected) == count
        else ("partial" if prove_headless else "unproven"),
        "providerDiversityRequired": require_provider_diversity,
        "providerCount": len({str(item.get("provider") or item.get("backend") or "") for item in selected}),
        "probeOrdering": "known_headless_first" if prove_headless else "policy",
        "probeFailures": probe_failures,
        "rankedCount": len(ranked),
        "rankedPreview": ranked[:10],
    }
    if bench_tiebreak.get("applied"):
        payload["benchTieBreak"] = bench_tiebreak
    return payload


def _run(cmd: list[str], cwd: Path, timeout: int = 120) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, cwd=str(cwd), text=True, capture_output=True, timeout=timeout)


def smoke_probe(arg: str, autonomy: str = "medium", ttl: int = 3600, timeout_seconds: int = 90) -> dict[str, Any]:
    autonomy = autonomy if autonomy in AUTONOMY_LEVELS else "medium"
    cache_key = (arg, autonomy)
    now = time.time()
    cached = _SMOKE_CACHE.get(cache_key)
    if cached and ttl > 0 and now - float(cached.get("fetchedAtEpoch", 0)) < ttl:
        result = dict(cached)
        result["cacheHit"] = True
        return result

    droid = shutil.which("droid")
    if not droid:
        return {
            "status": "unavailable",
            "code": "DROID_NOT_FOUND",
            "arg": arg,
            "autonomy": autonomy,
            "landsCommit": False,
            "reason": "droid executable not found on PATH",
        }

    with tempfile.TemporaryDirectory(prefix="bb-ministry-probe-") as tmp:
        repo = Path(tmp)
        prompt_path = repo / "prompt.txt"
        result_path = repo / "result.json"
        _run(["git", "init", "-q"], repo)
        _run(["git", "config", "user.email", "ministry-probe@openburnbar.local"], repo)
        _run(["git", "config", "user.name", "OpenBurnBar Ministry Probe"], repo)
        (repo / "README.md").write_text("Ministry smoke probe baseline.\n", encoding="utf-8")
        _run(["git", "add", "README.md"], repo)
        _run(["git", "commit", "-q", "-m", "baseline"], repo)
        base = _run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
        prompt_path.write_text(
            "\n".join(
                [
                    "This is an OpenBurnBar Ministry smoke probe in a disposable git repository.",
                    "Create or update ministry_probe.txt with one short line.",
                    "Then run exactly: git add ministry_probe.txt && git commit -m 'ministry smoke probe'.",
                    "Do not read or write files outside this repository.",
                ]
            )
            + "\n",
            encoding="utf-8",
        )
        cmd = [
            droid,
            "exec",
            "--auto",
            autonomy,
            "-m",
            arg,
            "--disabled-tools",
            disabled_tools_arg(),
            "-f",
            str(prompt_path),
            "-o",
            "json",
        ]
        started = time.time()
        try:
            proc = _run(cmd, repo, timeout=max(30, min(int(timeout_seconds), 300)))
        except subprocess.TimeoutExpired as exc:
            payload = {
                "status": "timeout",
                "code": "DROID_TIMEOUT",
                "arg": arg,
                "autonomy": autonomy,
                "landsCommit": False,
                "durationSeconds": round(time.time() - started, 3),
                "reason": str(exc),
            }
            _SMOKE_CACHE[cache_key] = {**payload, "fetchedAtEpoch": now}
            return payload
        result_path.write_text(proc.stdout or "", encoding="utf-8")
        head = _run(["git", "rev-parse", "HEAD"], repo).stdout.strip()
        parsed: dict[str, Any] | None = None
        if proc.stdout.strip():
            try:
                parsed = json.loads(proc.stdout)
            except json.JSONDecodeError:
                parsed = None
        is_error = bool(parsed.get("is_error")) if isinstance(parsed, dict) else proc.returncode != 0
        payload = {
            "status": "ok",
            "arg": arg,
            "autonomy": autonomy,
            "landsCommit": bool(head and head != base and not is_error),
            "isError": is_error,
            "exitCode": proc.returncode,
            "baseSHA": base,
            "headSHA": head,
            "durationSeconds": round(time.time() - started, 3),
            "cacheHit": False,
            "stderrTail": proc.stderr[-2000:],
            "jsonOutput": parsed,
        }
        _SMOKE_CACHE[cache_key] = {**payload, "fetchedAtEpoch": now}
        return payload


def shell_quote(value: str | Path) -> str:
    return shlex.quote(str(value))


def build_droid_command(
    store_path: Path,
    task_prompt: str,
    wand_id: str | None = None,
    model_arg: str | None = None,
    cwd: str | None = None,
    prompt_path: str | None = None,
    result_path: str | None = None,
    done_path: str | None = None,
    autonomy: str | None = None,
    reasoning_effort: str | None = None,
    prove_headless: bool = False,
) -> dict[str, Any]:
    selection = None
    if not model_arg:
        selection = select_model_for_wand(store_path, wand_id=wand_id, prove_headless=prove_headless)
        selected = selection.get("selected")
        if not selected:
            return {"status": "unavailable", "code": "NO_MODEL_SELECTED", "selection": selection}
        model_arg = str(selected["arg"])
        autonomy = autonomy or str((selection.get("wand") or {}).get("autonomy") or "medium")
        reasoning_effort = reasoning_effort or (selection.get("wand") or {}).get("reasoningEffort")
    autonomy = autonomy if autonomy in AUTONOMY_LEVELS else "medium"

    run_id = f"{int(time.time())}-{os.getpid()}"
    base_dir = Path("/tmp") / f"bb-ministry-{run_id}"
    prompt_path = prompt_path or str(base_dir / "prompt.txt")
    result_path = result_path or str(base_dir / "result.json")
    done_path = done_path or str(base_dir / "result.done")

    args = ["droid", "exec", "--auto", autonomy, "-m", model_arg, "--disabled-tools", disabled_tools_arg()]
    if reasoning_effort:
        args.extend(["--reasoning-effort", str(reasoning_effort)])
    if cwd:
        args.extend(["--cwd", cwd])
    args.extend(["-f", prompt_path, "-o", "json"])
    command = (
        f"mkdir -p {shell_quote(Path(prompt_path).parent)} && "
        f"{' '.join(shell_quote(part) for part in args)} > {shell_quote(result_path)}; "
        "rc=$?; "
        f'printf \'{{"exitCode":%s,"completedAt":"%s"}}\\n\' "$rc" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > {shell_quote(done_path)}; '
        "exit $rc"
    )
    return {
        "status": "ok",
        "modelArg": model_arg,
        "autonomy": autonomy,
        "reasoningEffort": reasoning_effort,
        "cwd": cwd,
        "promptPath": prompt_path,
        "resultPath": result_path,
        "donePath": done_path,
        "prompt": task_prompt,
        "argv": args,
        "command": command,
        "selection": selection,
    }


def collect_result(worktree_path: str, base_sha: str, result_path: str, done_path: str) -> dict[str, Any]:
    done = Path(done_path)
    result = Path(result_path)
    if not done.exists():
        return {
            "status": "running",
            "reason": "done marker is absent",
            "resultExists": result.exists(),
            "resultSize": result.stat().st_size if result.exists() else 0,
        }
    parsed: dict[str, Any] | None = None
    if result.exists() and result.stat().st_size > 0:
        try:
            parsed = json.loads(result.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            parsed = {"parseError": str(exc)}
    head_proc = subprocess.run(
        ["git", "rev-parse", "HEAD"],
        cwd=worktree_path,
        text=True,
        capture_output=True,
        timeout=15,
    )
    head = head_proc.stdout.strip() if head_proc.returncode == 0 else None
    is_error = bool(parsed.get("is_error")) if isinstance(parsed, dict) else True
    landed = bool(head and head != base_sha and not is_error)
    return {
        "status": "ok" if landed else "failed",
        "donePath": str(done),
        "resultPath": str(result),
        "isError": is_error,
        "baseSHA": base_sha,
        "headSHA": head,
        "landedCommit": landed,
        "result": parsed,
    }


def cleanup_plan(
    worktree_path: str | None = None,
    branch: str | None = None,
    prompt_path: str | None = None,
    result_path: str | None = None,
    done_path: str | None = None,
    session_id: str | None = None,
) -> dict[str, Any]:
    commands: list[list[str]] = []
    transcript_candidates: list[str] = []
    if worktree_path:
        commands.append(["git", "worktree", "remove", "--force", worktree_path])
    if branch:
        commands.append(["git", "branch", "-D", branch])
    for path in (prompt_path, result_path, done_path):
        if path:
            commands.append(["rm", "-f", path])
    if session_id:
        transcript_candidates = session_transcript_candidates(session_id)
        for path in transcript_candidates:
            commands.append(["rm", "-f", path])
    return {"status": "ok", "dryRun": True, "commands": commands, "transcriptCandidates": transcript_candidates}


def session_transcript_candidates(session_id: str, sessions_dir: Path | None = None) -> list[str]:
    safe = str(session_id or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9._:-]{8,128}", safe):
        return []
    root = sessions_dir or (Path.home() / ".factory" / "sessions")
    if not root.is_dir():
        return []
    matches: list[str] = []
    for path in root.rglob("*"):
        if path.is_file() and safe in path.name:
            matches.append(str(path))
    return sorted(matches)
