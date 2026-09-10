"""Recall filters: validation, SQL compilation, and the in-process matcher."""

from __future__ import annotations

import json
from typing import TYPE_CHECKING, Any

from ._util import _json_dumps
from .constants import FILTER_OPERATORS

if TYPE_CHECKING:
    from .engine import ActiveMemory


def _resolve_field(memory: ActiveMemory, key: str) -> Any:
    direct = {
        "memoryID": memory.id,
        "kind": memory.kind,
        "scope": memory.scope,
        "confidence": memory.confidence,
        "salience": memory.salience,
        "sensitivity": memory.sensitivity,
        "reviewStatus": memory.review_status,
        "review_status": memory.review_status,
        "tags": memory.tags,
        "entities": memory.entities,
        "createdAt": memory.created_at,
        "created_at": memory.created_at,
        "updatedAt": memory.updated_at,
        "updated_at": memory.updated_at,
        "accessCount": memory.access_count,
        "sourceKind": memory.source_kind,
        "source_kind": memory.source_kind,
        "sourceRef": memory.source_ref,
        "extractor": memory.extractor,
        "projectID": memory.project_id,
    }
    if key in direct:
        return direct[key]
    path = key.split(".")
    if path[0] == "metadata":
        path = path[1:]
    value: Any = memory.metadata
    for part in path:
        if isinstance(value, dict) and part in value:
            value = value[part]
        else:
            return None
    return value


_FILTER_SQL_FIELDS: dict[str, tuple[str, str]] = {
    "memoryID": ("m.id", "text"),
    "kind": ("m.kind", "text"),
    "scope": ("m.scope", "text"),
    "confidence": ("m.confidence", "number"),
    "salience": ("m.salience", "number"),
    "sensitivity": ("m.sensitivity", "text"),
    "reviewStatus": (
        "CASE WHEN m.review_status = 'approved' AND memory_aux_is_injection(m.tags_json, m.entities_json, m.metadata_json, m.source_ref) = 1 THEN 'quarantined' ELSE m.review_status END",
        "text",
    ),
    "review_status": (
        "CASE WHEN m.review_status = 'approved' AND memory_aux_is_injection(m.tags_json, m.entities_json, m.metadata_json, m.source_ref) = 1 THEN 'quarantined' ELSE m.review_status END",
        "text",
    ),
    "tags": ("m.tags_json", "array"),
    "entities": ("m.entities_json", "array"),
    "createdAt": ("m.created_at", "text"),
    "created_at": ("m.created_at", "text"),
    "updatedAt": ("m.updated_at", "text"),
    "updated_at": ("m.updated_at", "text"),
    "accessCount": ("m.access_count", "number"),
    "sourceKind": ("m.source_kind", "text"),
    "source_kind": ("m.source_kind", "text"),
    "sourceRef": ("m.source_ref", "text"),
    "extractor": ("m.extractor", "text"),
    "projectID": ("m.project_id", "text"),
}


def _metadata_filter_field(key: str) -> tuple[str, str]:
    parts = key.split(".")
    if parts[0] == "metadata":
        parts = parts[1:]
    if not parts:
        return "m.metadata_json", "json"
    path = "$" + "".join("." + json.dumps(part, ensure_ascii=True) for part in parts)
    quoted_path = "'" + path.replace("'", "''") + "'"
    return f"json_extract(m.metadata_json, {quoted_path})", f"json_type(m.metadata_json, {quoted_path})"


def _compile_filter_comparison(key: str, operator: str, expected: Any) -> tuple[str, list[Any]]:
    field = _FILTER_SQL_FIELDS.get(key)
    if field is None:
        expression, field_type = _metadata_filter_field(key)
    else:
        expression, field_type = field

    if operator in {"contains", "not_contains"}:
        if field_type == "array":
            contains_sql = f"EXISTS (SELECT 1 FROM json_each({expression}) AS item WHERE item.value = ?)"  # noqa: S608 -- reason: expression comes from a fixed field map or escaped JSON path
            params = [expected]
        elif field_type == "text":
            contains_sql = f"instr(lower(COALESCE(CAST({expression} AS TEXT), '')), lower(CAST(? AS TEXT))) > 0"
            params = [expected]
        elif field_type == "number":
            contains_sql, params = "0", []
        elif field_type == "json":
            contains_sql, params = "0", []
        else:
            # SQLite does not short-circuit AND, so json_each must never see a
            # scalar: a text value would raise "malformed JSON". The CASE hands
            # it an empty array unless the field really is one.
            contains_sql = (
                f"COALESCE((({field_type} = 'array' AND EXISTS "  # noqa: S608 -- reason: expressions come from a fixed field map or escaped JSON path
                f"(SELECT 1 FROM json_each(CASE WHEN {field_type} = 'array' THEN {expression} ELSE '[]' END) "
                f"AS item WHERE item.value = ?)) "
                f"OR ({field_type} = 'text' AND "
                f"instr(lower(CAST({expression} AS TEXT)), lower(CAST(? AS TEXT))) > 0)), 0)"
            )
            params = [expected, expected]
        return (f"NOT ({contains_sql})" if operator == "not_contains" else contains_sql), params

    if operator in {"in", "nin"}:
        values = list(expected) if isinstance(expected, (list, tuple, set)) else [expected]
        if not values:
            return ("1" if operator == "nin" else "0"), []
        has_none = any(value is None for value in values)
        concrete = [value for value in values if value is not None]
        membership = ""
        if concrete:
            placeholders = ",".join("?" for _ in concrete)
            membership = f"{expression} {'NOT IN' if operator == 'nin' else 'IN'} ({placeholders})"
        if operator == "in":
            parts = ([membership] if membership else []) + ([f"{expression} IS NULL"] if has_none else [])
            return "(" + " OR ".join(parts) + ")", concrete
        parts = ([membership] if membership else []) + ([f"{expression} IS NOT NULL"] if has_none else [])
        if not has_none:
            parts.append(f"{expression} IS NULL")
        return "(" + " AND ".join(parts) + ")" if has_none else "(" + " OR ".join(parts) + ")", concrete

    if operator in {"eq", "ne"}:
        if expected is None:
            return f"{expression} IS {'NOT ' if operator == 'ne' else ''}NULL", []
        if isinstance(expected, (list, dict)):
            comparison = "!=" if operator == "ne" else "="
            return f"json({expression}) {comparison} json(?)", [_json_dumps(expected)]
        return f"{expression} IS {'NOT ' if operator == 'ne' else ''}?", [expected]

    comparison = {"gt": ">", "gte": ">=", "lt": "<", "lte": "<="}.get(operator)
    if comparison is None:
        return "0", []
    return f"{expression} {comparison} ?", [expected]


def _invalid_filter_reason(filters: Any) -> str | None:
    if not isinstance(filters, dict) or not filters:
        return "filters must be a non-empty object"
    for key, expected in filters.items():
        if key in {"AND", "OR"}:
            if not isinstance(expected, list) or not expected:
                return f"{key} must contain non-empty filter objects"
            for child in expected:
                reason = _invalid_filter_reason(child)
                if reason:
                    return reason
            continue
        field = _FILTER_SQL_FIELDS.get(key)
        field_type = field[1] if field else "json"
        if isinstance(expected, list):
            comparisons = {"in": expected}
        elif isinstance(expected, dict) and expected and all(op in FILTER_OPERATORS for op in expected):
            comparisons = expected
        else:
            comparisons = {"eq": expected}
        if isinstance(expected, dict) and (not expected or not all(op in FILTER_OPERATORS for op in expected)):
            continue
        for operator, value in comparisons.items():
            if operator in {"eq", "ne"} and field_type in {"text", "number"} and isinstance(value, (list, dict)):
                return f"{key}.{operator} requires a scalar operand"
            if operator in {"contains", "not_contains", "gt", "gte", "lt", "lte"} and isinstance(value, (list, dict)):
                return f"{key}.{operator} requires a scalar operand"
            if operator in {"in", "nin"}:
                if not isinstance(value, list):
                    return f"{key}.{operator} requires a list operand"
                if any(isinstance(item, (list, dict)) for item in value):
                    return f"{key}.{operator} list items must be scalars"
    return None


def _compile_filter_sql(filters: dict[str, Any]) -> tuple[str, list[Any]]:
    """Compile the validated mem0 filter grammar to bound list I/O in SQL."""
    if not isinstance(filters, dict) or not filters:
        return "0", []
    clauses: list[str] = []
    params: list[Any] = []
    for key, expected in filters.items():
        if key in {"AND", "OR"}:
            if not isinstance(expected, list) or not expected:
                clauses.append("0")
                continue
            nested = [_compile_filter_sql(item) for item in expected if isinstance(item, dict) and item]
            if len(nested) != len(expected):
                clauses.append("0")
                continue
            clauses.append("(" + (" AND " if key == "AND" else " OR ").join(item[0] for item in nested) + ")")
            for _sql, nested_params in nested:
                params.extend(nested_params)
            continue
        comparisons = (
            expected
            if isinstance(expected, dict) and expected and all(operator in FILTER_OPERATORS for operator in expected)
            else {"in": expected}
            if isinstance(expected, list)
            else {"eq": expected}
        )
        for operator, value in comparisons.items():
            sql, comparison_params = _compile_filter_comparison(key, operator, value)
            clauses.append(sql)
            params.extend(comparison_params)
    return "(" + " AND ".join(clauses) + ")", params


def _compare(actual: Any, operator: str, expected: Any) -> bool:
    if operator == "eq":
        return actual == expected
    if operator == "ne":
        return actual != expected
    if operator == "in":
        return actual in (expected if isinstance(expected, (list, tuple, set)) else [expected])
    if operator == "nin":
        return actual not in (expected if isinstance(expected, (list, tuple, set)) else [expected])
    if operator == "contains":
        if isinstance(actual, (list, tuple, set)):
            return expected in actual
        return isinstance(actual, str) and str(expected).lower() in actual.lower()
    if operator == "not_contains":
        return not _compare(actual, "contains", expected)
    try:
        if operator == "gt":
            return actual > expected
        if operator == "gte":
            return actual >= expected
        if operator == "lt":
            return actual < expected
        if operator == "lte":
            return actual <= expected
    except TypeError:
        return False
    return False


def match_filters(memory: ActiveMemory, filters: dict[str, Any]) -> bool:
    """mem0-style filters: {"AND": [...]}, {"OR": [...]}, {"field": value}, {"field": {"op": value}}."""
    if not isinstance(filters, dict):
        return False
    for key, expected in filters.items():
        if key == "AND":
            if (
                not isinstance(expected, list)
                or not expected
                or not all(
                    isinstance(clause, dict) and bool(clause) and match_filters(memory, clause) for clause in expected
                )
            ):
                return False
            continue
        if key == "OR":
            if (
                not isinstance(expected, list)
                or not expected
                or not all(isinstance(clause, dict) and bool(clause) for clause in expected)
            ):
                return False
            if not any(match_filters(memory, clause) for clause in expected):
                return False
            continue
        actual = _resolve_field(memory, key)
        if isinstance(expected, dict) and expected and all(op in FILTER_OPERATORS for op in expected):
            for operator, value in expected.items():
                if not _compare(actual, operator, value):
                    return False
        elif isinstance(expected, list):
            if not _compare(actual, "in", expected):
                return False
        elif not _compare(actual, "eq", expected):
            return False
    return True
