#!/usr/bin/env python3
"""Add common missing Kotlin imports reported by compileDebugKotlin."""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

IMPORTS: dict[str, str] = {
    "dp": "androidx.compose.ui.unit.dp",
    "sp": "androidx.compose.ui.unit.sp",
    "Text": "androidx.compose.material3.Text",
    "MaterialTheme": "androidx.compose.material3.MaterialTheme",
    "Alignment": "androidx.compose.ui.Alignment",
    "RoundedCornerShape": "androidx.compose.foundation.shape.RoundedCornerShape",
    "fillMaxSize": "androidx.compose.foundation.layout.fillMaxSize",
    "fillMaxHeight": "androidx.compose.foundation.layout.fillMaxHeight",
    "fillMaxWidth": "androidx.compose.foundation.layout.fillMaxWidth",
    "padding": "androidx.compose.foundation.layout.padding",
    "weight": "androidx.compose.foundation.layout.RowScope.weight",
    "LaunchedEffect": "androidx.compose.runtime.LaunchedEffect",
    "remember": "androidx.compose.runtime.remember",
    "LinearEasing": "androidx.compose.animation.core.LinearEasing",
    "IOException": "java.io.IOException",
    "UUID": "java.util.UUID",
    "AgentProvider": "com.openburnbar.data.models.AgentProvider",
    "ProviderQuotaSnapshot": "com.openburnbar.data.models.ProviderQuotaSnapshot",
    "QuotaPreferences": "com.openburnbar.data.stores.QuotaPreferences",
    "AuroraGlassCard": "com.openburnbar.ui.components.AuroraGlassCard",
    "GoogleAuthProvider": "com.google.firebase.auth.GoogleAuthProvider",
    "booleanPreferencesKey": "androidx.datastore.preferences.core.booleanPreferencesKey",
    "NativeChart": "com.openburnbar.ui.pulse.NativeChart",
    "HermesRealtimeRelayFrame": "com.openburnbar.irohrelay.HermesRealtimeRelayFrame",
    "UsageDisplayMode": "com.openburnbar.ui.pulse.UsageDisplayMode",
    "defaultWeight": "androidx.glance.layout.defaultWeight",
    "runTest": "kotlinx.coroutines.test.runTest",
    "coEvery": "io.mockk.coEvery",
    "every": "io.mockk.every",
    "ofType": "io.mockk.ofType",
    "justRun": "io.mockk.justRun",
    "verify": "io.mockk.verify",
    "slot": "io.mockk.slot",
    "coVerify": "io.mockk.coVerify",
    "mockk": "io.mockk.mockk",
}


def collect_errors(task: str) -> dict[Path, set[str]]:
    proc = subprocess.run(
        ["./gradlew", task, "--no-daemon"],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    out = proc.stdout + proc.stderr
    by_file: dict[Path, set[str]] = {}
    for line in out.splitlines():
        m = re.search(
            r"e: file:///(.+?\.kt):(\d+):(\d+) Unresolved reference '([^']+)'",
            line,
        )
        if not m:
            continue
        raw = m.group(1)
        path = Path(raw if raw.startswith("/") else f"/{raw}")
        ref = m.group(4)
        if ref in IMPORTS:
            by_file.setdefault(path, set()).add(ref)
    return by_file


def add_imports(path: Path, refs: set[str]) -> bool:
    text = path.read_text()
    existing = set(re.findall(r"^import (.+)$", text, re.MULTILINE))
    to_add = [IMPORTS[r] for r in sorted(refs) if IMPORTS[r] not in existing]
    if not to_add:
        return False
    lines = text.splitlines()
    pkg_idx = next(i for i, l in enumerate(lines) if l.startswith("package "))
    insert_at = pkg_idx + 1
    while insert_at < len(lines) and lines[insert_at].strip() == "":
        insert_at += 1
    while insert_at < len(lines) and (
        lines[insert_at].startswith("@file:") or lines[insert_at].strip() == ""
    ):
        if lines[insert_at].startswith("@file:"):
            insert_at += 1
            while insert_at < len(lines) and lines[insert_at].strip() != "":
                insert_at += 1
        if insert_at < len(lines) and lines[insert_at].strip() == "":
            insert_at += 1
    block = [f"import {imp}" for imp in to_add]
    new_lines = lines[:insert_at] + block + lines[insert_at:]
    path.write_text("\n".join(new_lines) + ("\n" if text.endswith("\n") else ""))
    return True


def main() -> None:
    tasks = [":app:compileDebugKotlin", ":app:compileDebugUnitTestKotlin"]
    for task in tasks:
        print(f"=== {task} ===")
        for _ in range(5):
            by_file = collect_errors(task)
            if not by_file:
                print("No import-fixable unresolved references.")
                break
            changed = 0
            for path, refs in sorted(by_file.items()):
                if add_imports(path, refs):
                    changed += 1
                    print(f"updated {path.relative_to(ROOT)} (+{len(refs)} imports)")
            if changed == 0:
                break
    print("done")


if __name__ == "__main__":
    main()
