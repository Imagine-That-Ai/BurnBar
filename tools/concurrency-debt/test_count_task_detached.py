#!/usr/bin/env python3
"""Unit tests for the executable `Task.detached` counter.

Run directly: ``python3 tools/concurrency-debt/test_count_task_detached.py``.
"""

from __future__ import annotations

import importlib.util
import pathlib


def _load_counter():
    module_path = pathlib.Path(__file__).resolve().parent / "count-task-detached.py"
    spec = importlib.util.spec_from_file_location("count_task_detached", module_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


COUNTER = _load_counter()
count = COUNTER.count_task_detached_in_text


def expect(label: str, actual: int, want: int) -> None:
    if actual != want:
        raise AssertionError(f"{label}: expected {want}, got {actual}")
    print(f"ok  {label}")


def main() -> int:
    expect("real-call", count("Task.detached(priority: .utility) { work() }"), 1)
    expect("spaced-call", count("Task . detached { work() }"), 1)
    expect("line-comment", count("// Do not use Task.detached here"), 0)
    expect("doc-comment", count("/// Retired Task.detached usage"), 0)
    expect("block-comment", count("/* Task.detached { old() } */\nlet x = 1"), 0)
    expect("nested-block-comment", count("/* outer /* Task.detached {} */ still comment */"), 0)
    expect("string-literal", count('let s = "Task.detached is mentioned"'), 0)
    expect("raw-string-literal", count('let s = #"Task.detached in raw string"#'), 0)
    expect("multiline-string", count('let s = """\nTask.detached in text\n"""'), 0)
    expect("raw-multiline-string", count('let s = #"""\nTask.detached in text\n"""#'), 0)
    expect(
        "mixed",
        count(
            """
            // Task.detached removed here
            let label = "Task.detached"
            Task.detached { await run() }
            """
        ),
        1,
    )
    print("\nAll Task.detached counter tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
