# Runbook — make the Windows Engine lane a REQUIRED status check

> **STATUS: AUTHORED, NOT ENABLED.** This is a documented procedure, not an
> applied change. Do **not** run the enrolment commands until the preconditions
> below are all met — enrolling a check that has never gone green, or that does
> not report on every PR, will BLOCK all merges to `main`.

The Windows Engine lane (`.github/workflows/openburnbar-engine-windows.yml`)
builds the production `OpenBurnBarCore` target and runs the walking skeleton on
Windows. It is the automated evidence for the G1 gate. This runbook records
exactly how to promote it to a branch-protection required check when it is ready.

---

## 1. The status-check contexts

A required "status check context" on GitHub == a **job `name`**. The Engine lane
exposes two, one per architecture:

| Leg | Job id | Status-check context (job `name`) |
|---|---|---|
| x86_64 | `build` | `swift build --target OpenBurnBarCore (x86_64-unknown-windows-msvc)` |
| ARM64 | `build-arm64` | `swift build --target OpenBurnBarCore (aarch64-unknown-windows-msvc)` |

Enrol **both** so neither arch can silently regress. (Do not enrol the workflow
*name* — GitHub keys required checks on the job/context string above.)

---

## 2. Preconditions (all required before enrolment)

1. **The workflow is on `main`.** Required-check enrolment can only reference a
   context GitHub has actually observed. The Windows workflows land on `main`
   first (HANDOFF.md §3 item 2); until then required-check enrolment is a no-op
   that just wedges PRs.
2. **Each leg has gone green at least once on its runner.**
   - x86_64: already GREEN — CI run `28672100306` (walking skeleton 23/23).
   - ARM64 (`windows-11-arm`): must get **one** green run first. The leg is
     authored + lint-clean but has never executed on a real ARM64 runner (it
     cannot be exercised on the macOS/x64 dev host). Trigger it via
     `workflow_dispatch` on `main` and confirm both the `swift build` and the
     `swift run` (walking-skeleton) steps pass before enrolling the ARM64
     context.
3. **The path-filter gotcha is resolved** (see §3) — otherwise the required
   context will not report on PRs that don't touch `OpenBurnBarCore/**`, and
   those PRs will hang on "Expected — Waiting for status".

---

## 3. Path-filter gotcha (read before enrolling)

The lane's `pull_request:` trigger is **path-filtered** to
`OpenBurnBarCore/Sources/OpenBurnBarCore/**`, `Package.swift`,
`Package.resolved`, and the workflow file. GitHub does **not** post a
neutral/success status for a required check whose workflow was skipped by a path
filter — the PR shows a permanently pending "Expected" check and cannot merge.

Pick ONE remediation before enrolment:

- **(A) Drop the path filter** so the lane runs on every PR. Simplest, but spends
  Windows/ARM64 runner minutes on every PR (free for this PUBLIC repo, but slower
  PR feedback).
- **(B) Add an always-running gate-shim job** that owns the required context and
  short-circuits when the paths are untouched — the standard pattern. Enrol the
  **shim's** context instead of the two build contexts. Sketch:

  ```yaml
  jobs:
    engine-windows-required:
      name: Engine (Windows) required
      runs-on: ubuntu-latest
      steps:
        - uses: actions/checkout@<pinned-sha>
        - id: changed
          # set steps.changed.outputs.any=true iff an OpenBurnBarCore path moved
          run: echo "any=..." >> "$GITHUB_OUTPUT"
        - if: steps.changed.outputs.any == 'true'
          run: echo "Engine paths changed — the real Windows legs must be green."
        # When paths changed, gate on the real jobs via `needs:` + a result check;
        # when they did not, this job passes and satisfies the required context.
  ```

- **(C) Merge-queue / required-workflows** at the org level, which report a
  skipped path-filtered workflow as success. Only if the org already uses a
  merge queue.

`Fast Feedback Gate` (already required — see §4) uses the `needs: [...]` +
`toJSON(needs)` aggregation pattern; mirror it for option B.

---

## 4. Enrolment commands (gh api — run only when §2 + §3 are satisfied)

Branch protection stores required contexts as a flat `contexts[]` array. Enrol by
**read-modify-write** so existing required checks are preserved (the current set
already includes `Fast Feedback Gate`, `PR Native Gate`,
`App build + test (AgentLens)`, etc. — do not clobber them).

```bash
REPO=Imagine-That-Ai/BurnBar
BRANCH=main

# 1. Snapshot the current required checks (KEEP THIS for rollback).
gh api "repos/$REPO/branches/$BRANCH/protection/required_status_checks" \
  > /tmp/required-checks.before.json

# 2. Add the two Windows Engine contexts to the existing set (option A/C).
#    For option B, replace the two strings below with the single shim context.
gh api "repos/$REPO/branches/$BRANCH/protection/required_status_checks/contexts" \
  -X POST \
  -f 'contexts[]=swift build --target OpenBurnBarCore (x86_64-unknown-windows-msvc)' \
  -f 'contexts[]=swift build --target OpenBurnBarCore (aarch64-unknown-windows-msvc)'

# 3. Confirm they are now required.
gh api "repos/$REPO/branches/$BRANCH/protection/required_status_checks" \
  | python3 -c 'import json,sys; print("\n".join(json.load(sys.stdin)["contexts"]))'
```

The `/contexts` sub-resource `POST` **appends** without touching the other
required checks or the `strict` flag, so it is the safe surgical form. (A full
`PUT .../required_status_checks` would require re-sending the entire object.)

### Rollback

```bash
REPO=Imagine-That-Ai/BurnBar
BRANCH=main
gh api "repos/$REPO/branches/$BRANCH/protection/required_status_checks/contexts" \
  -X DELETE \
  -f 'contexts[]=swift build --target OpenBurnBarCore (x86_64-unknown-windows-msvc)' \
  -f 'contexts[]=swift build --target OpenBurnBarCore (aarch64-unknown-windows-msvc)'
```

`DELETE` on `/contexts` removes just those entries and leaves the rest of branch
protection intact. If anything looks off, restore the full snapshot with
`PUT .../required_status_checks` from `/tmp/required-checks.before.json`.

---

## 5. Note on the storage architecture gate

The architecture-honesty gate `windows-storage-architecture` (in
`fast-feedback.yml`, see WPD-0005 —
`docs/windows-port/decisions/0005-windows-storage-architecture.md`; it replaced
the storage-prune waiver gate on 2026-07-06) is already enforced transitively:
it is a `needs:` dependency of `Fast Feedback Gate`, which **is** a required
context today. So while the Engine lane compiles the storage-pruned,
compute-only Engine subset, `main` already refuses a PR that sets the boundary
flag from a workflow not named in WPD-0005's machine-read block, or that drops
the C# storage seam's tests — no separate enrolment needed for that gate.
