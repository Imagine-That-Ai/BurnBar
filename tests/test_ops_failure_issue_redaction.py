"""Regression tests for the ops-failure GitHub issue action."""

from __future__ import annotations

import json
import subprocess
import textwrap

from conftest import REPO_ROOT


ACTION_PATH = REPO_ROOT / ".github" / "actions" / "ops-failure-issue" / "action.yml"


def run_action_script(*, existing_issue: bool, paging_webhook: str | None = None) -> dict:
    node_script = textwrap.dedent(
        f"""
        (async () => {{
        const fs = require('node:fs');
        const action = fs.readFileSync({str(ACTION_PATH)!r}, 'utf8').split(/\\r?\\n/);
        const start = action.findIndex((line) => line.trim() === 'script: |');
        if (start < 0) throw new Error('missing github-script block');
        const script = action.slice(start + 1)
          .filter((line) => line.startsWith('          ') || line.trim() === '')
          .map((line) => line.startsWith('          ') ? line.slice(10) : line)
          .join('\\n');

        const calls = {{ created: null, comments: [], labels: [], pagePayloads: [] }};
        const github = {{
          paginate: async () => {json.dumps([{"number": 42, "labels": [{"name": "failures:2"}]}] if existing_issue else [])},
          rest: {{
            issues: {{
              listForRepo: async () => [],
              getLabel: async () => ({{}}),
              createLabel: async () => ({{}}),
              create: async (payload) => {{
                calls.created = payload;
                return {{ data: {{ number: 123 }} }};
              }},
              createComment: async (payload) => {{
                calls.comments.push(payload);
                return {{}};
              }},
              removeLabel: async () => ({{}}),
              addLabels: async (payload) => {{
                calls.labels.push(payload);
                return {{}};
              }},
              update: async () => ({{}}),
            }},
          }},
        }};
        const context = {{
          serverUrl: 'https://github.com',
          repo: {{ owner: 'Imagine-That-Ai', repo: 'BurnBar' }},
          runId: 987654321,
          ref: 'refs/heads/main?access_token=sample',
          workflow: 'Nightly failure for ops@example.test',
        }};
        const core = {{
          setFailed(message) {{ throw new Error(message); }},
          notice() {{}},
          info() {{}},
          warning() {{}},
        }};
        // Mock fetch so paging payload can be inspected for secret leakage.
        const originalFetch = globalThis.fetch;
        globalThis.fetch = async (url, options) => {{
          calls.pagePayloads.push(options && options.body ? JSON.parse(options.body) : null);
          return {{ ok: true, status: 200 }};
        }};
        const aws = 'AKIA' + 'IOSFODNN7EXAMPLE';
        const stripe = 'sk_live_' + 'x'.repeat(24);
        const gitlab = 'glpat-' + 'a'.repeat(20);
        const twilio = 'SK' + 'a'.repeat(32);
        const processShim = {{
          env: {{
            GITHUB_WORKSPACE: {str(REPO_ROOT)!r},
            OPS_MODE: 'open',
            OPS_LANE: 'nightly-e2e secret=sample',
            OPS_TITLE_PREFIX: 'Ops failed for ops@example.test with Bearer sample-token',
            OPS_SUMMARY: 'Failed for ops@example.test at /Users/alberto/build.log and /root/.config/openburnbar/state.json',
            OPS_DETAILS: [
              'api_key=sample',
              'client_secret: \"quoted-json-secret\"',
              \"private_key: 'quoted-yaml-secret'\",
              'secret_key: sample',
              'Signed: https://artifact.example.test/pkg?refresh_token=sample&X-Amz-Signature=aws-sig&X-Goog-Signature=goog-sig#token=fragment-secret',
              'Path: /private/tmp/openburnbar/result.json?refresh_token=sample#private_key=sample',
              'Cache: /var/tmp/openburnbar/cache.json',
              `Tokens: ${{aws}} ${{stripe}} ${{gitlab}} ${{twilio}}`,
              '@ops-team',
            ].join('\\n'),
            OPS_LABELS: 'P0 - Critical,area: infra,secret=sample',
            OPS_PAGING_SLACK_WEBHOOK: {json.dumps(paging_webhook if paging_webhook is not None else "")},
          }},
        }};

        const AsyncFunction = Object.getPrototypeOf(async function () {{}}).constructor;
        try {{
          await new AsyncFunction('github', 'context', 'core', 'process', script)(github, context, core, processShim);
        }} finally {{
          globalThis.fetch = originalFetch;
        }}
        console.log(JSON.stringify(calls));
        }})().catch((error) => {{
          console.error(error.stack || String(error));
          process.exit(1);
        }});
        """
    )
    result = subprocess.run(["node", "-e", node_script], check=True, text=True, capture_output=True)
    return json.loads(result.stdout)


def assert_public_issue_payload_is_redacted(payload: dict) -> None:
    rendered = json.dumps(payload, sort_keys=True)

    assert "ops@example.test" not in rendered
    assert "sample-token" not in rendered
    assert "/Users/alberto" not in rendered
    assert "/root/.config" not in rendered
    assert "/private/tmp/openburnbar" not in rendered
    assert "/var/tmp/openburnbar" not in rendered
    assert "api_key=sample" not in rendered
    assert "client_secret" in rendered
    assert "quoted-json-secret" not in rendered
    assert "private_key" in rendered
    assert "quoted-yaml-secret" not in rendered
    assert "secret=sample" not in rendered
    assert "secret_key: sample" not in rendered
    assert "aws-sig" not in rendered
    assert "goog-sig" not in rendered
    assert "fragment-secret" not in rendered
    assert "SKaaaaaaaa" not in rendered
    assert "access_token=sample" not in rendered
    assert "refresh_token=sample" not in rendered
    assert "private_key=sample" not in rendered
    assert "IOSFODNN7EXAMPLE" not in rendered
    assert "sk_live_" not in rendered
    assert "glpat-" not in rendered
    assert "[REDACTED" in rendered


def test_ops_failure_issue_creation_redacts_inputs() -> None:
    calls = run_action_script(existing_issue=False)

    assert calls["created"]["title"].startswith("Ops failed for [REDACTED-EMAIL] with Bearer [REDACTED]")
    assert_public_issue_payload_is_redacted(calls)


def test_ops_failure_issue_recurrence_comment_redacts_inputs() -> None:
    calls = run_action_script(existing_issue=True)

    assert calls["comments"], "standing issue recurrence must leave a comment"
    assert calls["labels"], "standing issue recurrence must bump the count label"
    assert_public_issue_payload_is_redacted(calls)



def test_ops_failure_issue_paging_payload_redacts_inputs() -> None:
    """P0 creation with a configured webhook must page to Slack with redacted content."""
    # Use a webhook URL that itself contains a secret pattern to prove the
    # webhook URL is never leaked into the page payload body.
    calls = run_action_script(
        existing_issue=False,
        paging_webhook="https://hooks.slack.com/services/T000/B000/secret-webhook-token-12345",
    )
    assert calls["pagePayloads"], "P0 creation with webhook configured must page"
    # The page payload body (the Slack text) must not contain the webhook URL
    # or any input secrets — the URL is the destination, not the content.
    page_text = calls["pagePayloads"][0]["text"]
    assert "secret-webhook-token" not in page_text, "webhook URL must not leak into page body"
    assert "ops@example.test" not in page_text
    assert "sample-token" not in page_text
    assert "/Users/alberto" not in page_text
    assert "access_token=sample" not in page_text
    assert "refresh_token=sample" not in page_text
    # The page payload text must contain the lane and issue reference.
    assert "nightly" in page_text.lower() or "e2e" in page_text.lower()
    assert "issues/123" in page_text
    # The full issue payload (title, body, labels) must still be redacted.
    assert_public_issue_payload_is_redacted(calls)
    # The paged:ops label must be added after a successful page.
    label_names = [label for batch in calls["labels"] for label in batch.get("labels", [])]
    assert "paged:ops" in label_names, "successful page must add paged:ops label"