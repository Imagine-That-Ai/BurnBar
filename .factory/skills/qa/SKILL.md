---
name: qa
description: Run OpenBurnBar functional QA and write qa-results/report.md plus supporting artifacts.
---

# qa

Use this skill when asked to run functional QA for OpenBurnBar, including CI
prompts that say to write the final report to `qa-results/report.md`.

## Non-Interactive Rule

This skill must run without asking the user anything. In CI there is no human
available, so do not use AskUser, do not pause for confirmation, and do not
invent pass/fail rows.

## Required Action

From the repository root, run exactly:

```sh
bash tools/qa/run-functional-qa.sh
```

The script is the source of truth for:

- creating `qa-results/report.md`
- writing command logs under `qa-results/logs/`
- writing `qa-results/environment-probe.txt`
- failing closed when required QA credentials or smoke checks fail

If the script exits non-zero, report that QA failed and point to
`qa-results/report.md` plus the relevant log under `qa-results/logs/`.
If it exits zero, report that functional QA passed and point to
`qa-results/report.md`.

## Evidence Discipline

- Never print secret values. Presence/absence is enough.
- Do not mark a row passed unless the script produced that result.
- Do not replace a failing required check with a skipped row.
