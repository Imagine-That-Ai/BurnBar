#!/usr/bin/env python3
"""Extract MagicNumber literals in OpenBurnBar Android data/ layer to named constants."""

from __future__ import annotations

import re
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

ANDROID_ROOT = Path(__file__).resolve().parents[1]
APP_ROOT = ANDROID_ROOT / "app"
DETEKT_REPORT = Path("/tmp/detekt-magic-data.txt")

# detekt ignoreNumbers from detekt.yml
IGNORE_NUMBERS = {-1, 0, 1, 2, 100, 1000}

LITERAL_RE = re.compile(
    r"""
    (?<![.\w])
    (
        0[xX][0-9a-fA-F_]+(?:[uU][lL]?|[lL][uU]?|[fFdD])?
        |
        0[bB][01_]+(?:[uU][lL]?|[lL][uU]?|[fFdD])?
        |
        \d[\d_]*(?:\.\d[\d_]*)?(?:[eE][+-]?\d+)?(?:[uU][lL]?|[lL][uU]?|[fFdD])?
    )
    (?![.\w])
    """,
    re.VERBOSE,
)

VIOLATION_RE = re.compile(
    r"at (.+?):(\d+):(\d+)",
)


@dataclass(frozen=True)
class Violation:
    path: Path
    line: int
    column: int


@dataclass(frozen=True)
class LiteralMatch:
    text: str
    start: int
    end: int
    line: int


def run_detekt() -> None:
    env = {"JAVA_HOME": subprocess.check_output(["/usr/bin/printenv", "JAVA_HOME"], text=True).strip()
             if subprocess.run(["/usr/bin/printenv", "JAVA_HOME"], capture_output=True).returncode == 0
             else str(Path.home() / ".homebrew/opt/openjdk@21")}
    cmd = ["./gradlew", "detekt", "--no-daemon"]
    proc = subprocess.run(
        cmd,
        cwd=ANDROID_ROOT,
        env={**dict(subprocess.os.environ), **env},
        capture_output=True,
        text=True,
    )
    lines = [ln for ln in (proc.stdout + proc.stderr).splitlines() if "MagicNumber" in ln and "data/" in ln]
    DETEKT_REPORT.write_text("\n".join(lines) + "\n", encoding="utf-8")


def parse_violations(report: Path) -> list[Violation]:
    violations: list[Violation] = []
    for raw in report.read_text(encoding="utf-8").splitlines():
        m = VIOLATION_RE.search(raw)
        if not m:
            continue
        path = Path(m.group(1))
        if "/android/" in str(path):
            rel = str(path).split("/android/", 1)[1]
            path = ANDROID_ROOT / rel
        violations.append(Violation(path=path, line=int(m.group(2)), column=int(m.group(3))))
    return violations


def parse_numeric_value(text: str) -> float | None:
    t = text.replace("_", "")
    try:
        if t.lower().endswith("f"):
            return float(t[:-1])
        if t.lower().endswith("d"):
            return float(t[:-1])
        if t.lower().endswith("l"):
            return float(int(t[:-1], 0))
        if t.lower().endswith("u"):
            return float(int(t[:-1], 0))
        if t.lower().endswith("ul") or t.lower().endswith("lu"):
            return float(int(t[:-2], 0))
        if t.startswith(("0x", "0X")):
            return float(int(t, 16))
        if t.startswith(("0b", "0B")):
            return float(int(t, 2))
        if "." in t or "e" in t.lower():
            return float(t)
        return float(int(t, 10))
    except ValueError:
        return None


def should_ignore(text: str) -> bool:
    val = parse_numeric_value(text)
    if val is None:
        return True
    if val.is_integer() and int(val) in IGNORE_NUMBERS:
        return True
    return False


def find_literal_at_column(line: str, column: int) -> LiteralMatch | None:
    # detekt columns are 1-based; find literal whose start is closest at/ before column
    best: LiteralMatch | None = None
    for m in LITERAL_RE.finditer(line):
        start = m.start(1) + 1
        if start <= column <= m.end(1):
            return LiteralMatch(text=m.group(1), start=m.start(1), end=m.end(1), line=0)
        if start <= column:
            best = LiteralMatch(text=m.group(1), start=m.start(1), end=m.end(1), line=0)
    return best


def constant_name_for(text: str, context: str, used_names: set[str]) -> str:
    val = parse_numeric_value(text)
    ctx = context.lower()

    hints: list[str] = []
    if "gcm" in ctx or "tag" in ctx:
        if val == 128:
            hints.append("GCM_AUTH_TAG_BITS")
        if val == 12:
            hints.append("GCM_NONCE_BYTES")
        if val == 16:
            hints.append("GCM_TAG_BYTES")
    if "sha" in ctx or "hash" in ctx or "digest" in ctx:
        if val == 32:
            hints.append("SHA256_DIGEST_BYTES")
        if val == 16:
            hints.append("HASH_PREFIX_BYTES")
    if "0xff" in text.lower() or val == 255:
        hints.append("BYTE_MASK")
    if "0x04" in text.lower():
        hints.append("UNCOMPRESSED_POINT_PREFIX")
    if "bit" in ctx and val == 8:
        hints.append("BITS_PER_BYTE")
    if ("second" in ctx or "nano" in ctx or "delay" in ctx or "millis" in ctx) and val:
        if val == 1_000_000_000:
            hints.append("NANOS_PER_SECOND")
        if val == 1_000_000:
            hints.append("NANOS_PER_MILLIS")
        if val == 50_000_000:
            hints.append("MAX_PACE_WAIT_NANOS")
    if "byte" in ctx and val == 8:
        hints.append("BITS_PER_BYTE")
    if "limit" in ctx or "token" in ctx:
        if val == 250:
            hints.append("DEFAULT_TOKEN_HASH_LIMIT")
        if val == 24:
            hints.append("DEFAULT_SEMANTIC_HASH_LIMIT")
    if "dimension" in ctx or "accumulator" in ctx:
        if val == 64:
            hints.append("SEMANTIC_VECTOR_DIMENSIONS")
        if val == 8:
            hints.append("SIMHASH_BAND_SIZE")
    if "weight" in ctx or "feature" in ctx:
        if val == 2.4:
            hints.append("TOKEN_FEATURE_WEIGHT")
        if val == 1.8:
            hints.append("STEM_FEATURE_WEIGHT")
        if val == 0.8:
            hints.append("PREFIX_FEATURE_WEIGHT")
        if val == 1.3:
            hints.append("BIGRAM_FEATURE_WEIGHT")
    if "percent" in ctx or "%" in context:
        hints.append("PERCENT_SCALE")
    if "millis" in ctx or "ms" in ctx:
        hints.append("MILLIS")
    if "second" in ctx and val and val >= 60:
        hints.append("SECONDS")

    if not hints:
        clean = text.replace("_", "").upper()
        suffix = ""
        if clean.endswith("L"):
            suffix = "_L"
            clean = clean[:-1]
        elif clean.endswith("F"):
            suffix = "_F"
            clean = clean[:-1]
        elif clean.endswith("D"):
            suffix = "_D"
            clean = clean[:-1]
        hints.append(f"VAL_{clean}{suffix}")

    for base in hints:
        name = base
        i = 2
        while name in used_names:
            name = f"{base}_{i}"
            i += 1
        used_names.add(name)
        return name
    raise RuntimeError("unreachable")


def find_insertion_point(lines: list[str]) -> int:
    """Return line index after imports / package where constants can be inserted."""
    i = 0
    while i < len(lines) and lines[i].startswith("package "):
        i += 1
    while i < len(lines) and lines[i].strip() == "":
        i += 1
    while i < len(lines) and (lines[i].startswith("import ") or lines[i].startswith("@file:")):
        i += 1
    while i < len(lines) and lines[i].strip() == "":
        i += 1
    return i


def find_class_or_object_insertion(lines: list[str], start: int) -> int | None:
    for idx in range(start, min(start + 40, len(lines))):
        line = lines[idx]
        if re.match(r"^(class|object|interface|enum class)\s+", line):
            # look for opening brace
            for j in range(idx, min(idx + 8, len(lines))):
                if "{" in lines[j]:
                    return j + 1
    return None


def format_const(text: str, name: str) -> str:
    val = parse_numeric_value(text)
    if val is not None and val == int(val) and "." not in text and "e" not in text.lower():
        if text.endswith(("L", "l")) or (abs(val) > 2_147_483_647):
            lit = text if text.endswith(("L", "l")) else f"{text}L"
            return f"private const val {name} = {lit}"
        if text.endswith(("u", "U")):
            return f"private const val {name} = {text}"
        return f"private const val {name} = {text}"
    return f"private const val {name} = {text}"


def process_file(path: Path, violations: list[Violation]) -> bool:
    if not path.exists():
        return False
    source = path.read_text(encoding="utf-8")
    lines = source.splitlines(keepends=True)

    # collect literals per line from violations
    literal_spans: dict[tuple[int, int, int], str] = {}
    for v in violations:
        if v.line < 1 or v.line > len(lines):
            continue
        line_text = lines[v.line - 1]
        match = find_literal_at_column(line_text.rstrip("\n"), v.column)
        if match is None:
            continue
        if should_ignore(match.text):
            continue
        key = (v.line, match.start, match.end)
        literal_spans[key] = match.text

    if not literal_spans:
        return False

    used_names: set[str] = set(re.findall(r"\b(?:private\s+)?const val (\w+)", source))
    used_names.update(re.findall(r"\b(?:private\s+)?val (\w+)\s*=", source))

    const_for_text: dict[str, str] = {}
    for (_line, start, end), text in sorted(literal_spans.items(), key=lambda x: (x[0][0], x[0][1])):
        if text in const_for_text:
            continue
        line_no = _line
        context = lines[line_no - 1]
        if line_no > 1:
            context = lines[line_no - 2] + context
        const_for_text[text] = constant_name_for(text, context, used_names)

    # replace from end of each line to preserve offsets
    by_line: dict[int, list[tuple[int, int, str]]] = defaultdict(list)
    for (line_no, start, end), text in literal_spans.items():
        by_line[line_no].append((start, end, const_for_text[text]))

    for line_no in sorted(by_line.keys()):
        raw = lines[line_no - 1]
        newline = ""
        if raw.endswith("\r\n"):
            newline = "\r\n"
            body = raw[:-2]
        elif raw.endswith("\n"):
            newline = "\n"
            body = raw[:-1]
        else:
            body = raw
        for start, end, name in sorted(by_line[line_no], key=lambda t: t[0], reverse=True):
            body = body[:start] + name + body[end:]
        lines[line_no - 1] = body + newline

    # insert constants block if not already present for these names
    const_lines = [format_const(text, name) for text, name in sorted(const_for_text.items(), key=lambda x: x[1])]
    const_block = "private object MagicNumbers {\n" + "\n".join(f"    {c}" for c in const_lines) + "\n}\n\n"

    # Prefer inserting inside first top-level object/class if file is mostly an object
    insert_at = find_insertion_point(lines)
    inner = find_class_or_object_insertion(lines, insert_at)
    if inner is not None and "object " in lines[inner - 1]:
        # insert as private const vals directly in object instead of nested object
        indent = "    "
        const_block_inner = "\n".join(f"{indent}{c}" for c in const_lines) + "\n"
        # check if companion exists later - for object, insert after opening brace line
        lines.insert(inner, const_block_inner)
    else:
        lines.insert(insert_at, const_block)

    # qualify references with MagicNumbers. when inserted as top-level private object
    if inner is None or "object " not in lines[inner - 1]:
        for line_no in by_line:
            raw = lines[line_no - 1]
            for _text, name in const_for_text.items():
                raw = re.sub(rf"(?<![.\w]){re.escape(name)}(?![.\w])", f"MagicNumbers.{name}", raw)
            lines[line_no - 1] = raw

    new_source = "".join(lines)
    if new_source != source:
        path.write_text(new_source, encoding="utf-8")
        return True
    return False


def main() -> int:
    if len(sys.argv) > 1 and sys.argv[1] == "--refresh":
        run_detekt()
    if not DETEKT_REPORT.exists():
        run_detekt()

    violations = parse_violations(DETEKT_REPORT)
    by_file: dict[Path, list[Violation]] = defaultdict(list)
    for v in violations:
        by_file[v.path].append(v)

    changed = 0
    for path, file_violations in sorted(by_file.items(), key=lambda x: len(x[1]), reverse=True):
        if process_file(path, file_violations):
            changed += 1
            print(f"fixed {path.relative_to(ANDROID_ROOT)} ({len(file_violations)} violations targeted)")

    print(f"Updated {changed} files")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
