#!/usr/bin/env bash
# Self-test for the preserve/* tag pre-push guard. Feeds the hook the exact
# stdin shape git uses (<local ref> <local sha> <remote ref> <remote sha>) and
# asserts it blocks preserve/* tag creation while allowing everything else.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
hook="${here}/pre-push"
sha="1111111111111111111111111111111111111111"
zero="0000000000000000000000000000000000000000"

run() { printf '%s\n' "$1" | "${hook}"; }

fail=0

# 1) Pushing a preserve/* tag must be BLOCKED (non-zero exit).
if run "refs/tags/preserve/20260615-001558/stash-00 ${sha} refs/tags/preserve/20260615-001558/stash-00 ${zero}" 2>/dev/null; then
  echo "FAIL: preserve/* tag push was allowed" >&2
  fail=1
else
  echo "ok: preserve/* tag push blocked"
fi

# 2) A normal release tag must be ALLOWED.
if run "refs/tags/v1.2.3 ${sha} refs/tags/v1.2.3 ${zero}" >/dev/null 2>&1; then
  echo "ok: normal release tag allowed"
else
  echo "FAIL: normal release tag was blocked" >&2
  fail=1
fi

# 3) A branch push must be ALLOWED.
if run "refs/heads/main ${sha} refs/heads/main ${zero}" >/dev/null 2>&1; then
  echo "ok: branch push allowed"
else
  echo "FAIL: branch push was blocked" >&2
  fail=1
fi

# 4) DELETING a preserve/* tag must be ALLOWED (local sha all-zero).
if run "(delete) ${zero} refs/tags/preserve/x/stash-00 ${sha}" >/dev/null 2>&1; then
  echo "ok: preserve/* tag deletion allowed"
else
  echo "FAIL: preserve/* tag deletion was blocked" >&2
  fail=1
fi

# 5) A mixed push including a preserve/* tag must be BLOCKED.
if printf '%s\n%s\n' \
  "refs/heads/main ${sha} refs/heads/main ${zero}" \
  "refs/tags/preserve/x/stash-00 ${sha} refs/tags/preserve/x/stash-00 ${zero}" | "${hook}" 2>/dev/null; then
  echo "FAIL: mixed push with preserve/* tag was allowed" >&2
  fail=1
else
  echo "ok: mixed push with preserve/* tag blocked"
fi

# 6) A preserve/* tag pushed under a RENAMED remote ref must be BLOCKED.
#    This is the source-ref guard: local_ref=refs/tags/preserve/x but
#    remote_ref=refs/tags/leaked. Checking only remote_ref would miss it.
if run "refs/tags/preserve/x/stash-00 ${sha} refs/tags/leaked ${zero}" 2>/dev/null; then
  echo "FAIL: preserve/* tag pushed under renamed remote ref was allowed" >&2
  fail=1
else
  echo "ok: preserve/* tag under renamed remote ref blocked"
fi

if ((fail)); then
  echo "PRE-PUSH GUARD SELF-TEST FAILED" >&2
  exit 1
fi
echo "PASS: pre-push preserve/* tag guard self-test"
