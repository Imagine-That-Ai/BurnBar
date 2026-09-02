# PR backlog triage: finding pull requests that already shipped

BurnBar carries ~90 open pull requests. Some of them are dead: the work inside
them is already on `main`, arriving by some other route. Nothing in GitHub's
interface says so. A superseded PR looks exactly like a live one — open,
sometimes approved, sometimes green.

`scripts/ci/find-superseded-prs.mjs` finds them.

## The case that motivated this

PR #2456 (`feat(app): Memory MCP walkthrough modal + quick guide`) sat open and
approved. Its feature had already shipped: #2457 **reimplemented** the
walkthrough independently, and #2461 then fixed an import in it. `main`'s copy
had moved well ahead of the branch:

| | #2456 | `main` |
|---|---|---|
| `MemoryMCPWalkthroughView.swift` | 555 lines | 616 lines |
| spotlight references | 6 | 12 |
| `CloudStoreSettingsView` | plain `ScrollView` | wrapped in `SettingsDeepLinkScrollContainer` |

Rebasing #2456 would have replayed the older revision over the newer one and
regressed `main`. It was caught by hand, by reading both files. That does not
scale to 90 PRs.

## Why the obvious approaches do not work

A reimplementation shares **no commits** with the branch it obsoletes. That
kills every ancestry-based method:

| Approach | Why it misses this |
|---|---|
| `git merge-base` / ancestry | #2457 is topologically unrelated to #2456 |
| `git merge-tree`, empty-diff | Only catches exact duplicates. Misses the common case where `main`'s copy has moved ahead |
| `gh pr view --json state` | Reports `OPEN`, because it is open |
| CI status | Green. The branch is internally consistent; it is just redundant |

The only signal that survives a reimplementation is **whether the lines the PR
adds can already be found on the base branch**. That is what this tool measures.

## How it works

1. List open PRs (`gh pr list`), and fetch every `refs/pull/<n>/head`.
2. For each PR, diff from its **merge base** — the lines it introduces, not the
   lines `main` has moved on without it.
3. Keep only the **added** lines. Removals cannot answer "is this already on
   main".
4. Discard structural noise (see below).
5. Look up each surviving line in `main`'s copy of that same file, comparing
   trimmed text so re-indentation does not defeat the match.
6. Pool the counts across all files, and score.

### The significance filter is the whole game

Lines shorter than 8 characters, or carrying no identifier characters, are
discarded: `}`, `});`, `end`, blank lines, lone brackets. They occur in every
file in the repository, so counting them as "already present on `main`" would
mark essentially every PR superseded.

This is the single most important knob in the tool, and
`MIN_SIGNIFICANT_LENGTH` is deliberately exported so the test suite can
mutate it. Dropping the floor to `0` fails the suite — that is intentional.

### Verdicts

| Verdict | Coverage | Meaning |
|---|---|---|
| `superseded` | ≥ 95% | Nearly everything this PR adds is already on `main`. Strong evidence for closing |
| `partially-landed` | 50–95% | Some of it shipped elsewhere. Read before rebasing |
| `active` | < 50% | Real, unlanded work |
| `indeterminate` | — | No significant added lines at all: a pure deletion, a lockfile bump, a binary asset. The tool refuses to guess |

The 95% threshold is tight on purpose. A false `superseded` invites closing live
work, which is far more expensive than leaving a zombie open one more week.

Counts are **pooled across files**, not averaged per file, so a one-line README
tweak cannot outvote a 600-line implementation file.

## Usage

```bash
node scripts/ci/find-superseded-prs.mjs --repo Imagine-That-Ai/BurnBar
```

```bash
node scripts/ci/find-superseded-prs.mjs --repo Imagine-That-Ai/BurnBar --json > triage.json
```

| Flag | Default | Meaning |
|---|---|---|
| `--repo` | current repo | `owner/name` passed through to `gh` |
| `--base` | `origin/main` | Branch to test "already landed" against |
| `--limit` | `200` | Max PRs to list |
| `--json` | off | Machine-readable output, including per-file scores |
| `--cwd` | `process.cwd()` | Repository checkout to run git in |

The first run fetches every pull ref and takes several minutes on this
repository. Later runs are fast.

## What it will not do

**It never writes to GitHub.** No mode closes, comments on, or labels a PR. The
verdict is evidence for a human decision, not the decision.

It is also deliberately **not wired into CI**. A bot that comments on 90 PRs is
noise, and an automated closer acting on a heuristic is a way to lose work.
Run it when triaging the backlog.

## Testing

```bash
node --test scripts/ci/find-superseded-prs.test.mjs
```

22 tests. The pure core — significance filtering, diff parsing, scoring,
classification — is tested directly. Three integration tests build real
throwaway git repositories, including one that reproduces the #2456 shape: a
branch adds a file, `main` independently reimplements it with extra lines, and
the tool must return `superseded` at 100% coverage.

The suite is mutation-checked. Each of these breaks it:

| Mutation | Tests failed |
|---|---|
| `MIN_SIGNIFICANT_LENGTH` 8 → 0 | 1 |
| `DEFAULT_SUPERSEDED_THRESHOLD` 0.95 → 0.50 | 2 |
| Stop excluding `+++`/`---` diff headers | 2 |
