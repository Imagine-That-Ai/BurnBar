#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("wrap-callable-logging.py")
spec = importlib.util.spec_from_file_location("wrap_callable_logging", MODULE_PATH)
assert spec and spec.loader
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def test_import_paths() -> None:
    assert module.logging_import_path("insightsHostedAnswer.ts") == "./logging.js"
    assert module.logging_import_path("computerUseOpenTimestamps.ts") == "./logging.js"
    assert module.logging_import_path("callables/providerAccounts.ts") == "../logging.js"
    assert module.logging_import_path("appstore/callable.ts") == "../logging.js"


def test_ensure_import_uses_existing_logging_api() -> None:
    text = 'import { onCall } from "firebase-functions/v2/https";\n'
    migrated = module.ensure_wrap_callable_handler_import(text, "insightsHostedAnswer.ts")
    assert 'import { wrapCallableHandler } from "./logging.js";' in migrated
    assert "loggedOnCall" not in migrated


def test_migrates_one_argument_on_call() -> None:
    text = """export const ping = onCall(async (request) => {
  return { ok: true };
});
"""
    migrated = module.migrate_exports(text)
    assert 'wrapCallableHandler("ping", async (request) =>' in migrated
    assert "loggedOnCall" not in migrated


def test_migrates_options_plus_handler_on_call() -> None:
    text = """export const ping = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: true,
  },
  async (request) => {
    return { ok: true };
  },
);
"""
    migrated = module.migrate_exports(text)
    assert 'wrapCallableHandler("ping", async (request) =>' in migrated
    assert "region: FUNCTIONS_REGION" in migrated
    assert "loggedOnCall" not in migrated


def test_keeps_existing_wrapper_idempotent() -> None:
    text = """export const ping = onCall(
  { region: FUNCTIONS_REGION },
  wrapCallableHandler("ping", async (request) => ({ ok: true })),
);
"""
    assert module.migrate_exports(text) == text


if __name__ == "__main__":
    for name, value in sorted(globals().items()):
        if name.startswith("test_"):
            value()
    print("PASS: wrap-callable-logging migration tests")
