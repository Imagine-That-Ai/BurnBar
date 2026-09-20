"""The engine is a package of focused modules, and its facade hides the split from consumers."""

from __future__ import annotations

import ast
import importlib
import re
from pathlib import Path

MCP_DIR = Path(__file__).resolve().parents[1]
PACKAGE_DIR = MCP_DIR / "memory_engine"
MAX_MODULE_LINES = 1500
CONSUMERS = [MCP_DIR / "server.py", MCP_DIR / "eval_memory.py", *sorted((MCP_DIR / "tests").glob("*.py"))]
REFERENCE = re.compile(r"\bme\.([A-Za-z_][A-Za-z0-9_]*)")

# Module-level state that is rebound at runtime. Importing any of these by name
# copies the current value and stops tracking the module, so a patch applied to
# the module is silently lost. Value = the files allowed to import it anyway:
# the facade may alias the provider *class* because consumers construct it
# (`me.OllamaEmbeddingProvider(...)`), but never the flag-like values, which
# exist to be patched.
PATCHED_THROUGH_THEIR_MODULE: dict[str, tuple[str, ...]] = {
    "GATE_CORPUS_AVAILABLE": (),
    "SCHEMA_MIGRATIONS": (),
    "OllamaEmbeddingProvider": ("__init__.py",),
}


def test_memory_engine_is_a_package_of_bounded_modules():
    assert (PACKAGE_DIR / "__init__.py").is_file()
    assert not (MCP_DIR / "memory_engine.py").exists()
    oversized = {
        path.name: sum(1 for _ in path.open(encoding="utf-8"))
        for path in PACKAGE_DIR.glob("*.py")
        if sum(1 for _ in path.open(encoding="utf-8")) > MAX_MODULE_LINES
    }
    assert oversized == {}, f"modules over {MAX_MODULE_LINES} lines: {oversized}"


def test_facade_exposes_every_name_consumers_reference():
    me = importlib.import_module("memory_engine")
    missing: dict[str, list[str]] = {}
    for consumer in CONSUMERS:
        names = sorted(set(REFERENCE.findall(consumer.read_text(encoding="utf-8"))))
        absent = [name for name in names if not hasattr(me, name)]
        if absent:
            missing[consumer.name] = absent
    assert missing == {}, f"facade is missing names used by consumers: {missing}"


def test_mutable_flags_are_read_through_their_module():
    """`from .gate import GATE_CORPUS_AVAILABLE` would freeze the flag and break monkeypatching.

    The check walks the AST rather than matching text so it also catches the
    parenthesized multi-line form, and it covers `__init__.py`: a facade
    re-export freezes the value exactly like an intra-package import does.
    """
    offenders = []
    for path in sorted(PACKAGE_DIR.glob("*.py")):
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
            if not (isinstance(node, ast.ImportFrom) and node.level):
                continue
            for alias in node.names:
                allowed = PATCHED_THROUGH_THEIR_MODULE.get(alias.name)
                if allowed is not None and path.name not in allowed:
                    offenders.append(f"{path.name}:{alias.name}")
    assert offenders == [], offenders
