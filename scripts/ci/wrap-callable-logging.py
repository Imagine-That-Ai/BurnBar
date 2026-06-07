#!/usr/bin/env python3
"""Migrate onCall exports to loggedOnCall for structured logging (idempotent)."""

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
    if rel.startswith("appstore/"):
        return "../logging.js"
    if rel.startswith("computerUse"):
        return "./logging.js"
    return "../logging.js"


def ensure_logged_on_call_import(text: str, rel: str) -> str:
    mod = logging_import_path(rel)
    if "loggedOnCall" in text and f'from "{mod}"' in text:
        return text
    pat = rf'import \{{([^}}]+)\}} from "{re.escape(mod)}";'
    m = re.search(pat, text)
    if m:
        names = [n.strip() for n in m.group(1).split(",") if n.strip()]
        for need in ("loggedOnCall",):
            if need not in names:
                names.append(need)
        repl = f'import {{ {", ".join(names)} }} from "{mod}";'
        return text[: m.start()] + repl + text[m.end() :]
    anchor = re.search(r'import \{[^}]+\} from "firebase-functions/v2/https";', text)
    if anchor:
        ins = f'\nimport {{ loggedOnCall }} from "{mod}";'
        return text[: anchor.end()] + ins + text[anchor.end() :]
    return f'import {{ loggedOnCall }} from "{mod}";\n' + text


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


def migrate_exports(text: str) -> str:
    if "loggedOnCall" in text and re.search(
        r"export const \w+ = loggedOnCall\(", text
    ):
        return text
    return re.sub(
        r"export const (\w+) = onCall\(",
        r'export const \1 = loggedOnCall(\n  "\1",\n',
        text,
    )


def process_file(rel: str) -> None:
    path = SRC / rel
    text = path.read_text()
    text = strip_inner_with_callable_logging(text)
    text = strip_manual_log_callable_start(text)
    text = ensure_logged_on_call_import(text, rel)
    text = migrate_exports(text)
    path.write_text(text)
    count = len(re.findall(r"loggedOnCall\(", text))
    print(f"ok {rel} ({count} loggedOnCall)")


def main() -> int:
    for rel in FILES:
        process_file(rel)
    return 0


if __name__ == "__main__":
    sys.exit(main())
