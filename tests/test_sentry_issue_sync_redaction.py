"""Regression tests for Sentry-to-GitHub issue redaction boundaries."""

from __future__ import annotations

import importlib.util

from conftest import REPO_ROOT


def load_sentry_issue_sync():
    module_path = REPO_ROOT / "scripts" / "sentry_issue_sync.py"
    spec = importlib.util.spec_from_file_location("sentry_issue_sync_under_test", module_path)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_sentry_issue_title_is_redacted_before_github_use() -> None:
    sync = load_sentry_issue_sync()

    title = sync.truncate_for_title(
        "Crash for alberto@example.test with Bearer token-value-1234567890 "
        "at /Users/alberto/project/logs/session.log?access_token=query-secret"
    )

    assert "alberto@example.test" not in title
    assert "token-value" not in title
    assert "/Users/alberto" not in title
    assert "query-secret" not in title
    assert "[REDACTED" in title


def test_sentry_issue_text_redacts_structured_tokens_and_url_credentials() -> None:
    sync = load_sentry_issue_sync()

    text = sync.redact_issue_text(
        '{"access_token":"super-secret-json"} '
        "stripe sk_live_12345678901234567890 "
        "callback=https://example.test/callback?github_token=gh-secret-token&ok=1 "
        "db=postgres://sentry_user:db-password-secret@example.test/app "
        "api_key=\"my secret passphrase\""
    )

    assert "super-secret-json" not in text
    assert "sk_live_12345678901234567890" not in text
    assert "gh-secret-token" not in text
    assert "sentry_user" not in text
    assert "db-password-secret" not in text
    assert "my secret passphrase" not in text
    assert "ok=1" in text
    assert "[REDACTED]" in text


def test_sentry_issue_body_redacts_culprit_and_normalizes_marker() -> None:
    sync = load_sentry_issue_sync()
    sync.SENTRY_ORG = "openburnbar"

    body = sync.build_issue_body(
        "openburnbar-functions",
        {
            "id": "12345\n<!-- injected -->",
            "level": "error",
            "count": "2",
            "userCount": "1",
            "firstSeen": "2026-06-21T17:00:00Z",
            "lastSeen": "2026-06-21T17:03:00Z",
                "culprit": (
                    "handler failed for firebase_uid=abc1234567890abcdef "
                    "with api_key=not-a-real-key at "
                    "/private/tmp/openburnbar/event.json?refresh_token=rt-secret"
                ),
            },
    )

    assert "<!-- injected -->" not in body
    assert "<!-- sentry-id: 12345-injected -->" in body
    assert "abc1234567890abcdef" not in body
    assert "not-a-real-key" not in body
    assert "/private/tmp/openburnbar" not in body
    assert "rt-secret" not in body
    assert "firebase_uid=[REDACTED]" in body
    assert "api_key=[REDACTED]" in body
    assert "[REDACTED-PATH]" in body
