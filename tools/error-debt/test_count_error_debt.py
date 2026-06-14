#!/usr/bin/env python3
"""Unit tests for the tag-aware `try?` debt counter.

Run directly: ``python3 tools/error-debt/test_count_error_debt.py``.
Exits non-zero on the first failed assertion so CI/agents fail closed.
"""

from __future__ import annotations

import importlib.util
import pathlib


def _load_counter():
    module_path = pathlib.Path(__file__).resolve().parent / "count-error-debt.py"
    spec = importlib.util.spec_from_file_location("count_error_debt", module_path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


COUNTER = _load_counter()
count = COUNTER.count_untagged_try_optional_in_text


def expect(label: str, actual, want) -> None:
    if actual != want:
        raise AssertionError(f"{label}: expected {want}, got {actual}")
    print(f"ok  {label}")


def main() -> int:
    # Bare site is untagged debt.
    expect("bare", count("let x = try? foo()"), (1, 0))

    # Trailing tag on the same line exempts the site.
    expect(
        "trailing-tag",
        count("let x = try? foo() // try?-ok(best-effort cache read)"),
        (0, 1),
    )

    # Tag on the immediately-preceding line exempts the site.
    expect(
        "tag-above",
        count("// try?-ok(cancellation only)\ntry? await Task.sleep(nanoseconds: 1)"),
        (0, 1),
    )

    # A standalone tag comment contributes nothing (the `try?` inside the
    # `try?-ok` token must never be counted).
    expect("tag-comment-only", count("// try?-ok(reason)"), (0, 0))

    # A blank line between the tag and the site does NOT exempt it — the tag
    # must be adjacent, otherwise stale tags could silently hide new debt.
    expect(
        "non-adjacent-tag",
        count("// try?-ok(reason)\n\ntry? foo()"),
        (1, 0),
    )

    # Two sites on one tagged line are both exempted; two bare sites count 2.
    expect(
        "two-on-line-tagged",
        count("guard let a = try? f(), let b = try? g() else { return } // try?-ok(x)"),
        (0, 2),
    )
    expect(
        "two-on-line-bare",
        count("guard let a = try? f(), let b = try? g() else { return }"),
        (2, 0),
    )

    # `try` without the optional marker is not a `try?` site.
    expect("plain-try", count("let x = try foo()"), (0, 0))

    # Mixed file: one bare, one tagged.
    expect(
        "mixed",
        count("try? a()\ntry? b() // try?-ok(telemetry)"),
        (1, 1),
    )

    print("\nAll try? counter tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
