#!/usr/bin/env python3
"""
Sentry → GitHub Issue Sync
===========================
Polls the Sentry REST API for newly-reported errors across all OpenBurnBar
Sentry projects and creates (or skips) corresponding GitHub issues.

Covers: openburnbar-macos, openburnbar-functions, openburnbar-extension,
        openburnbar-android, burnbar-website

Required environment variables:
  SENTRY_AUTH_TOKEN   Sentry API token with org:read + event:read scopes
  SENTRY_ORG          Sentry organization slug
  GH_TOKEN            GitHub token with issues:write scope
  GH_REPO             GitHub repository in "owner/repo" format

Optional:
  LOOKBACK_HOURS      How far back to look (default: 4)
  MIN_OCCURRENCES     Minimum event count to create an issue (default: 1)
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

SENTRY_AUTH_TOKEN = os.environ.get("SENTRY_AUTH_TOKEN", "")
SENTRY_ORG = os.environ.get("SENTRY_ORG", "")
GH_TOKEN = os.environ.get("GH_TOKEN", "")
GH_REPO = os.environ.get("GH_REPO", "")
LOOKBACK_HOURS = int(os.environ.get("LOOKBACK_HOURS", "4"))
MIN_OCCURRENCES = int(os.environ.get("MIN_OCCURRENCES", "1"))

if not SENTRY_AUTH_TOKEN or not SENTRY_ORG:
    print("::notice::SENTRY_AUTH_TOKEN or SENTRY_ORG not set — skipping Sentry sync.")
    sys.exit(0)

# Maps Sentry project slug → GitHub area label.
PROJECTS = {
    "openburnbar-macos":     "area:macOS",
    "openburnbar-functions": "area:functions",
    "openburnbar-extension": "area:extension",
    "openburnbar-android":   "area:Android",
    "burnbar-website":       "area:website",
}

# Sentry level → GitHub priority label.
LEVEL_TO_PRIORITY = {
    "fatal":   "P0",
    "error":   "P1",
    "warning": "P2",
}


def sentry_get(path: str) -> list:
    url = f"https://sentry.io/api/0{path}"
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {SENTRY_AUTH_TOKEN}",
        "Content-Type": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read())
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return []
        raise


def find_existing_issue(sentry_id: str) -> int | None:
    """Return the GitHub issue number if a matching issue already exists."""
    marker = f"sentry-id: {sentry_id}"
    result = subprocess.run(
        [
            "gh", "issue", "list",
            "--repo", GH_REPO,
            "--state", "open",
            "--search", f"in:body {marker}",
            "--json", "number,body",
            "--limit", "5",
        ],
        capture_output=True,
    )
    if result.returncode != 0:
        return None
    issues = json.loads(result.stdout or "[]")
    for issue in issues:
        if marker in (issue.get("body") or ""):
            return issue["number"]
    return None


def fmt_ts(ts: str) -> str:
    if not ts:
        return "unknown"
    try:
        dt = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return dt.strftime("%Y-%m-%d %H:%M UTC")
    except Exception:
        return ts


def build_issue_body(project_slug: str, issue: dict) -> str:
    sentry_id = issue.get("id", "")
    sentry_url = f"https://sentry.io/organizations/{SENTRY_ORG}/issues/{sentry_id}/"
    level = issue.get("level", "error")
    culprit = issue.get("culprit", "")
    first_seen = issue.get("firstSeen", "")
    last_seen = issue.get("lastSeen", "")
    count = issue.get("count", "0")
    user_count = issue.get("userCount", 0)

    lines = [
        f"<!-- sentry-id: {sentry_id} -->",
        "",
        f"> Automatically created by the Sentry Error to GitHub Issue workflow: {sentry_url}",
        "",
        "## Error Details",
        "",
        "| Field | Value |",
        "|---|---|",
        f"| **Sentry Project** | `{project_slug}` |",
        f"| **Level** | `{level}` |",
        f"| **Occurrences** | {count} |",
        f"| **Users Affected** | {user_count} |",
        f"| **First Seen** | {fmt_ts(first_seen)} |",
        f"| **Last Seen** | {fmt_ts(last_seen)} |",
        f"| **Culprit** | `{culprit}` |",
        "",
        "## How to Investigate",
        "",
        f"1. Open the [Sentry issue]({sentry_url}) for full stack traces, breadcrumbs, and release info.",
        "2. Filter by environment (`production` / `staging`) and release version.",
        f"3. Check recent commits touching `{culprit}` for root cause.",
        "",
        "## Links",
        "",
        f"- [Sentry Issue {sentry_id}]({sentry_url})",
        f"- [All open {project_slug} issues](https://sentry.io/organizations/{SENTRY_ORG}/issues/?project={project_slug})",
        "",
        "---",
        "*Auto-synced from Sentry. Resolve in Sentry to close this issue.*",
    ]
    return "\n".join(lines)


def main() -> None:
    now = datetime.now(tz=timezone.utc)
    cutoff = now - timedelta(hours=LOOKBACK_HOURS)
    cutoff_str = cutoff.strftime("%Y-%m-%dT%H:%M:%SZ")

    total_created = 0
    total_skipped = 0

    for project_slug, area_label in PROJECTS.items():
        print(f"\n--- Checking project: {project_slug} ---")

        query = f"is:unresolved firstSeen:>{cutoff_str}"
        path = (
            f"/projects/{SENTRY_ORG}/{project_slug}/issues/"
            f"?{urllib.parse.urlencode({'query': query, 'limit': 25, 'sort': 'date'})}"
        )

        try:
            issues = sentry_get(path)
        except Exception as exc:
            print(f"::warning::Sentry API error for {project_slug}: {exc}")
            continue

        if not isinstance(issues, list):
            print("  No issues or project not found.")
            continue

        print(f"  Found {len(issues)} new issue(s) since {LOOKBACK_HOURS}h ago.")

        for issue in issues:
            sentry_id = issue.get("id", "")
            level = issue.get("level", "error")
            count = int(issue.get("count", 0))
            title = issue.get("title", "Unknown error")

            if level == "warning" and MIN_OCCURRENCES > 1:
                total_skipped += 1
                continue

            if count < MIN_OCCURRENCES:
                total_skipped += 1
                continue

            existing = find_existing_issue(sentry_id)
            if existing:
                print(f"  Skipping Sentry #{sentry_id} '{title[:60]}' — already tracked as GH #{existing}")
                total_skipped += 1
                continue

            priority = LEVEL_TO_PRIORITY.get(level, "P2")
            gh_title = f"[Sentry/{project_slug}] {title[:100]}"
            gh_body = build_issue_body(project_slug, issue)
            labels = ["type:bug", area_label, priority]

            print(f"  Creating GH issue: {gh_title[:80]}")

            cmd = [
                "gh", "issue", "create",
                "--repo", GH_REPO,
                "--title", gh_title,
                "--body", gh_body,
            ]
            for label in labels:
                cmd += ["--label", label]

            result = subprocess.run(cmd, capture_output=True)
            if result.returncode == 0:
                issue_url = result.stdout.decode().strip()
                print(f"  Created: {issue_url}")
                total_created += 1
            else:
                stderr = result.stderr.decode()
                # Label-not-found is non-fatal; retry without optional labels.
                if "could not add label" in stderr.lower() or "label" in stderr.lower():
                    cmd_minimal = [
                        "gh", "issue", "create",
                        "--repo", GH_REPO,
                        "--title", gh_title,
                        "--body", gh_body,
                        "--label", "type:bug",
                    ]
                    result2 = subprocess.run(cmd_minimal, capture_output=True)
                    if result2.returncode == 0:
                        print(f"  Created (minimal labels): {result2.stdout.decode().strip()}")
                        total_created += 1
                    else:
                        print(f"::warning::Failed to create issue: {result2.stderr.decode()[:200]}")
                else:
                    print(f"::warning::Failed to create issue: {stderr[:200]}")

    print(f"\n=== Summary: {total_created} issue(s) created, {total_skipped} skipped ===")


if __name__ == "__main__":
    main()
