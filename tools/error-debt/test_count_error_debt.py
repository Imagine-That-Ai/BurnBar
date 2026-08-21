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

    # A `try?` mentioned only in a comment is prose, not debt.
    expect("comment-only", count("// Replaces try? expr patterns"), (0, 0))
    expect("doc-comment-only", count("/// uses try? under the hood"), (0, 0))

    # A code `try?` with a trailing non-tag comment still counts once.
    expect("code-plus-comment", count("let x = try? foo() // best effort"), (1, 0))

    # `//` inside a string literal is not a comment, so it is not stripped — and
    # a `try?` living only in the trailing comment is still ignored.
    expect("slashes-in-string", count('let u = "https://x" // try? here'), (0, 0))

    # The `try?` substring inside an identifier doing optional chaining is NOT a
    # Swift `try?` and must not be counted (the original regex over-counted these).
    expect("entry-optional-chain", count("auditEntryIndex: entry?.entryIndex,"), (0, 0))
    expect("cacheentry-type", count("let conversation: CodexConversationCacheEntry?"), (0, 0))
    expect("registry-optional-chain", count("foo.mediaControlStreamRegistry?.bar()"), (0, 0))
    expect("retry-in-string", count('label.text = "Refresh failed — retry?"'), (0, 0))
    # …but a real `try?` after an identifier-adjacent boundary still counts.
    expect("real-try-after-paren", count("let x = (try? foo()) ?? d"), (1, 0))

    print("\nAll try? counter tests passed.\n")
    return grdb_row_cast_tests()


def grdb_row_cast_tests() -> int:
    def count(text: str) -> tuple[int, int]:
        untagged, tagged, _ = COUNTER.count_grdb_row_casts_in_text(text)
        return untagged, tagged

    # The three casts that can never succeed against SQLite storage.
    expect("as-int", count('let n = (row["messageCount"] as? Int) ?? 0'), (1, 0))
    expect("as-bool", count('let flag = (row["isLocal"] as? Bool) ?? false'), (1, 0))
    expect("as-date", count('let at = row["createdAt"] as? Date'), (1, 0))

    # `as? Double` succeeds on REAL but silently nils on INTEGER — SUM(), COUNT()
    # and CASE WHEN projections all hand back Int64. That is the rollup-reads-zero
    # bug, so it counts.
    expect("as-double", count('let total = (row["totalTokens"] as? Double) ?? 0'), (1, 0))
    # `as? Int64` happens to work on INTEGER, but breaks the moment the column or
    # aggregate is REAL. One rule, no exceptions to memorize.
    expect("as-int64", count('let n = row["ftsRowid"] as? Int64'), (1, 0))

    # TEXT storage *is* String, so that cast is sound and stays legal.
    expect("as-string", count('let id = row["id"] as? String'), (0, 0))

    # Row-shaped identifiers are covered; dictionaries are not.
    expect("suffixed-row", count('let n = ftsRow["rank"] as? Double'), (1, 0))
    expect("json-dictionary", count('let n = payload["count"] as? Int'), (0, 0))
    expect("firestore-document", count('let n = document["citationCount"] as? Int'), (0, 0))

    # Optional chains and collection elements reach the same untyped subscript,
    # so the gate has to recognize them as readily as the bare identifier.
    expect("optional-chain", count('let n = row?["count"] as? Int'), (1, 0))
    expect("indexed-literal", count('let n = rows[0]["count"] as? Int'), (1, 0))
    expect("indexed-variable", count('let n = rows[index]["count"] as? Int'), (1, 0))
    expect("indexed-optional-result", count('let n = rows.first?["count"] as? Int'), (1, 0))
    # A dictionary collection keeps its exemption in the same spellings.
    expect("indexed-dictionary", count('let n = payloads[0]["count"] as? Int'), (0, 0))

    # A row bound to an ordinary name is still a row. Name-only matching handed
    # every one of these a free pass through an assert-zero gate.
    expect(
        "bound-row-same-line",
        count('let mapping = try Row.fetchOne(db, sql: sql)\nlet n = mapping?["ftsRowid"] as? Int64'),
        (1, 0),
    )
    expect(
        "bound-row-inside-read-block",
        count(
            'let mapping = try queue.read { db in\n'
            '    try Row.fetchOne(db, sql: "SELECT ftsRowid FROM search_chunks")\n'
            '}\n'
            'let n = mapping?["ftsRowid"] as? Int64'
        ),
        (1, 0),
    )
    expect(
        "bound-rows-collection",
        count('let columns = try Row.fetchAll(db, sql: sql)\nlet n = columns[0]["count"] as? Int'),
        (1, 0),
    )
    # A same-named binding that is NOT a row keeps its exemption, so the
    # derivation has to read the binding rather than the identifier.
    expect(
        "bound-non-row",
        count('let mapping = try JSONDecoder().decode(Payload.self, from: data)\nlet n = mapping["count"] as? Int'),
        (0, 0),
    )
    # A fetch below an unrelated binding must not be attributed to it.
    expect(
        "fetch-attributed-to-its-own-binding",
        count('let payload = decoded\nlet row = try Row.fetchOne(db, sql: sql)\nlet n = payload["count"] as? Int'),
        (0, 0),
    )

    # The typed subscript is the fix and must never be flagged.
    expect("typed-subscript", count('let n: Int = row["messageCount"] ?? 0'), (0, 0))

    # Tag on the same line, and on the line above, exempt the site.
    expect(
        "trailing-tag",
        count('let n = row["c"] as? Int // grdb-row-ok(plain dictionary)'),
        (0, 1),
    )
    expect(
        "preceding-tag",
        count('// grdb-row-ok(plain dictionary)\nlet n = row["c"] as? Int'),
        (0, 1),
    )

    # A cast quoted in prose documents the hazard; it is not the hazard.
    expect("comment-only", count('/// `row["x"] as? Int` always yields nil.'), (0, 0))

    # Two casts on one line count twice.
    expect(
        "two-per-line",
        count('let c = (row["cost"] as? Double) ?? Double(row["cost"] as? Int64 ?? 0)'),
        (2, 0),
    )

    print("\nAll GRDB row-cast counter tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
