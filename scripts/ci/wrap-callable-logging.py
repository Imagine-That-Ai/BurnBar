#!/usr/bin/env python3
"""Migrate onCall exports to wrapCallableHandler for structured logging."""

from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SRC = ROOT / "functions" / "src"

FILES = [
    "callables/providerAccounts.ts",
    "callables/voipPush.ts",
    "callables/encryptedSearch.ts",
    "computerUseOpenTimestamps.ts",
    "callables/misc.ts",
    "callables/agentNotifications.ts",
    "callables/hermes.ts",
    "callables/mediaSku.ts",
    "callables/piAgent.ts",
    "callables/stripe.ts",
    "insightsHostedAnswer.ts",
    "callables/remoteMcp.ts",
    "callables/deviceLinks.ts",
    "appstore/callable.ts",
]


def logging_import_path(rel: str) -> str:
    if "/" not in rel or rel.startswith("computerUse"):
        return "./logging.js"
    return "../logging.js"


def ensure_wrap_callable_handler_import(text: str, rel: str) -> str:
    mod = logging_import_path(rel)
    if "wrapCallableHandler" in text and f'from "{mod}"' in text:
        return text
    pat = rf'import \{{([^}}]+)\}} from "{re.escape(mod)}";'
    m = re.search(pat, text)
    if m:
        names = [n.strip() for n in m.group(1).split(",") if n.strip()]
        for need in ("wrapCallableHandler",):
            if need not in names:
                names.append(need)
        repl = f'import {{ {", ".join(names)} }} from "{mod}";'
        return text[: m.start()] + repl + text[m.end() :]
    anchor = re.search(r'import \{[^}]+\} from "firebase-functions/v2/https";', text)
    if anchor:
        ins = f'\nimport {{ wrapCallableHandler }} from "{mod}";'
        return text[: anchor.end()] + ins + text[anchor.end() :]
    return f'import {{ wrapCallableHandler }} from "{mod}";\n' + text


def strip_inner_with_callable_logging(text: str) -> str:
    text = re.sub(
        r"return withCallableLogging\(\"[^\"]+\", request, uid, async \(\) => \{\n",
        "",
        text,
    )
    text = re.sub(r"\n    \}\);\n(?=  \}\n\))", "\n", text)
    return text


def strip_manual_log_callable_start(text: str) -> str:
    """Remove inline logCallableStart when loggedOnCall wraps the handler."""
    text = re.sub(
        r"\n\s*const traceId = traceIdFromCallableRequest\(request\);\n"
        r"\s*logCallableStart\([^;]+;\n",
        "\n",
        text,
    )
    return text


def find_matching_paren(text: str, open_index: int) -> int:
    depth = 0
    quote: str | None = None
    escape = False
    for index in range(open_index, len(text)):
        char = text[index]
        if quote is not None:
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == quote:
                quote = None
            continue
        if char in ('"', "'", "`"):
            quote = char
        elif char == "(":
            depth += 1
        elif char == ")":
            depth -= 1
            if depth == 0:
                return index
    raise ValueError("unbalanced onCall expression")


def split_top_level_args(args: str) -> list[str]:
    parts: list[str] = []
    start = 0
    depth = 0
    quote: str | None = None
    escape = False
    for index, char in enumerate(args):
        if quote is not None:
            if escape:
                escape = False
            elif char == "\\":
                escape = True
            elif char == quote:
                quote = None
            continue
        if char in ('"', "'", "`"):
            quote = char
        elif char in "([{":
            depth += 1
        elif char in ")]}":
            depth -= 1
        elif char == "," and depth == 0:
            parts.append(args[start:index].strip())
            start = index + 1
    tail = args[start:].strip()
    if tail:
        parts.append(tail)
    return parts


def wrapped_on_call_args(export_name: str, args_text: str) -> str:
    if "wrapCallableHandler(" in args_text:
        return args_text
    args = split_top_level_args(args_text)
    if len(args) == 1:
        return f'\n  wrapCallableHandler("{export_name}", {args[0]}),\n'
    if len(args) == 2:
        return f'\n  {args[0]},\n  wrapCallableHandler("{export_name}", {args[1]}),\n'
    raise ValueError(f"unsupported onCall argument count for {export_name}: {len(args)}")


def migrate_exports(text: str) -> str:
    result: list[str] = []
    cursor = 0
    pattern = re.compile(r"export const (\w+) = onCall\(")
    for match in pattern.finditer(text):
        open_index = match.end() - 1
        close_index = find_matching_paren(text, open_index)
        export_name = match.group(1)
        result.append(text[cursor : open_index + 1])
        result.append(wrapped_on_call_args(export_name, text[open_index + 1 : close_index]))
        cursor = close_index
    result.append(text[cursor:])
    return "".join(result)


def process_file(rel: str) -> None:
    path = SRC / rel
    text = path.read_text()
    text = strip_inner_with_callable_logging(text)
    text = strip_manual_log_callable_start(text)
    text = ensure_wrap_callable_handler_import(text, rel)
    text = migrate_exports(text)
    path.write_text(text)
    count = len(re.findall(r"wrapCallableHandler\(", text))
    print(f"ok {rel} ({count} wrapCallableHandler)")


def main() -> int:
    for rel in FILES:
        process_file(rel)
    return 0


if __name__ == "__main__":
    sys.exit(main())
