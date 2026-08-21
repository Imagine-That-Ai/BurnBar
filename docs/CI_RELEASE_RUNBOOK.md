# CI & release runbook

Written after the August 2026 outage, in which burnbar.ai served a stale build
for a month and ten consecutive Mac release tags produced zero releases — with
no red check anywhere. Every root cause was a step that had **never worked**,
sitting behind a gate nobody had reason to look at.

Read this before touching a workflow, a release gate, or a deploy path. It is
ordered by how much time each section saves.

---

## 1. The silent failure mode: a green check that never ran

A failing job gets noticed. **A job that never ran does not.**

Every root cause of the August 2026 outage was one failure mode wearing
different clothes: **a green check that never executed its assertion.** Not a
check that ran and reached the wrong answer — a check that reported success
without ever doing its work.

That is why a month passed. Nobody ignored a red signal; there was no signal.

So when something breaks behind a gate that was supposed to catch it, the useful
question is not

> did this check pass?

but

> **did this check actually run — and did it run the thing I think it ran?**

Two confirmed instances, and one mechanism that can manufacture a third. They
look unrelated in the logs. The list is almost certainly not finished.

| # | | Never… | Presents as |
| --- | --- | --- | --- |
| 1.1 | Skip propagation through `needs` | …scheduled | green |
| 1.2 | Path-filter drift | …triggered | green |
| 1.3 | Copied-CLI fixture on macOS | …executed | **either** — see below |

`1.3` earns its place for a reason worth stating up front: the same mechanism
produces a **loud red** or a **silent green** depending only on what the test
happens to assert. We hit the loud half and caught it in minutes. The silent
half is the one this section is about, and nothing would have told us.

### 1.1 Skip propagation through `needs` — never scheduled

GitHub replaces a job's implicit `success()` guard **only** when its `if:` calls
a status-check function (`always()`, `!cancelled()`, `success()`, `failure()`,
`cancelled()`).

Without one, a **skipped** upstream job propagates its skip *transitively*
through `needs` — **including across an intermediate job that ran under
`always()` and succeeded.**

That last clause is the part that fools people. This graph looks fine and is not:

```yaml
gate:                       # skips on every normal run
  if: ${{ inputs.rollback == true }}
build:
  needs: gate
  if: ${{ always() }}       # runs, succeeds
deploy:
  needs: build              # NEVER SCHEDULED — inherits gate's skip
```

`deploy` here is `deploy-hosting`. Adding one skipped gate job upstream of the
build silently stopped every production website deploy for a month.

**Fix:** give the job a status-check function *and* an explicit result check:

```yaml
deploy:
  needs: build
  if: ${{ !cancelled() && needs.build.result == 'success' }}
```

Prefer `!cancelled()` over `always()` for anything credentialed — `always()`
also runs during cancellation.

**Inheriting a skip is often correct.** A validation gate *should* skip when the
preflight gating it skipped. So the gate is a ratchet, not a ban: declare
intentional cases in `governance/workflow-reachability.json` with a real reason.

### 1.2 Path-filter drift — never triggered

A `push.paths` filter that omits a script the workflow runs means **editing that
script triggers nothing**. The fix merges, main advances, and the old artifact
keeps serving.

This is how the Firebase Hosting fix landed on main and deployed nothing: the
changed file, `scripts/lib/firebase-hosting-rest-url.mjs`, was not in
`deploy-hosting.yml`'s filter.

**Rule:** every local script a workflow invokes — and every local module those
scripts import, transitively — belongs in the filter.

### 1.3 A self-test that cannot run on the dev platform — never executed

The newest instance, found 2026-08-20, and the one that shows the class is not
limited to workflow wiring. **A test file can be the thing that never runs.**

`scripts/ci/check-firestore-rules-size.test.mjs` spawns the real CLI from a
fixture under `mkdtempSync(join(tmpdir(), …))` and asserts it exits non-zero.
On macOS `tmpdir()` returns a `/var` symlink, and Node realpaths
`import.meta.url` but **not** `argv` — so the CLI's run-as-main guard

```js
resolve(process.argv[1]) === fileURLToPath(import.meta.url)
```

never matched inside the fixture. **`main()` never ran** and the spawn exited 0.

**Be precise about what happened next, because it decides the taxonomy.** That
test asserts a *non-zero* exit, so the assertion **did run, and it failed
loudly** — the file was red on every Mac and green on Linux, where the CLI
executed correctly. It was never a vacuously-green check, and calling it one
would teach the wrong lesson.

What makes it belong here is the *other* branch of the same mechanism. Flip the
expectation — a test that copies a CLI in and asserts it **succeeds** — and the
identical bug produces the identical exit code 0, the assertion passes, and the
check is green forever without the CLI ever having run. Same cause, opposite
symptom:

| the test asserts | CLI silently doesn't run | you find out |
| --- | --- | --- |
| non-zero exit | assertion fails | immediately, loudly |
| **success** | **assertion passes** | **never** |

So the honest statement is: we found the loud half, and the loud half is a gift.
It told us the mechanism exists before the silent half bit us.

**Fix:** realpath the fixture root — `mkdtempSync` under `realpathSync(tmpdir())`.

**This is a class, not a bug** — but the signature is narrower than it first
looks, and being imprecise here just produces noise nobody reads. All three
conditions must hold:

1. a fixture root from `mkdtempSync(join(tmpdir(), …))` — not realpathed, and
2. an executable **copied into** that fixture (`copyFileSync`/`cpSync`), and
3. that copy spawned as `node <path-inside-fixture>`, relying on its
   run-as-main guard to fire.

Spawning a script from the real `scripts/ci/` is safe: `argv[1]` is then a real
path and matches. It is the copy-into-tmpdir step that creates the mismatch.

```bash
grep -rl 'mkdtempSync(join(tmpdir()' scripts/ci/ \
  | xargs grep -lE 'copyFileSync|cpSync' \
  | xargs grep -lE 'spawnSync|execFileSync'
```

Surveyed 2026-08-20: **11 files match, 9 of them self-tests, and all 9 pass on
macOS** — so no second live instance was found. Note the list includes
`check-firestore-rules-size.test.mjs` itself, which is how you know the recipe
finds the real thing.

A match is a **candidate, not a bug**. Confirm it by positive control (below),
because the two halves fail very differently:

- a test asserting a **non-zero** exit fails loudly when it hits this — that is
  how this instance was found at all
- a test asserting **success passes vacuously**, and looks green forever

The second half is the dangerous one, and greping cannot tell you which you have.

### Detecting the next one

The instances differ; the detection does not. **Reproduce the exact CI
invocation, not a subset of it** — same entrypoint, same working directory,
same platform. Most of these hide precisely in the gap between "the command I
ran locally" and "the command CI ran".

Two habits catch them cheaply:

- **Positive-control your gates.** Before trusting a green verdict, prove the
  gate still fails on a known-bad input. Several lanes here already do this
  (`Self-test the diff-coverage gate`, `Positive control first: prove the gate
  still fails…`). A gate that cannot be made to fail is not passing — it is
  not running.
- **Read the log for evidence of work, not for the word "passed".** A check
  that emits no counts, no filenames and no findings usually did nothing. "0
  problems found" and "found nothing because it scanned nothing" render
  identically in a green tick.

When a gate is green and the thing it guards broke anyway, assume it never ran
until you have seen it do work.

### What is enforced, and what is not

`1.1` and `1.2` are enforced:

```bash
node scripts/ci/verify-workflow-reachability.mjs
```

Runs in `Workflow Lint` on every PR, reports the offending job or path, and
tells you which of the two you hit.

**`1.3` is not enforced by anything yet, and the two obvious controls do not
work.** Say plainly what each one can and cannot do:

- **Running the self-tests on a Mac** catches only the loud half. A test whose
  copied CLI silently exits 0 while asserting success stays green on macOS and
  Linux alike.
- **The grep** yields *candidates*. It cannot establish that any candidate's
  assertions actually executed — which is the only question that matters.

The control that does work is a **positive control per candidate**: feed the
gate a known-bad input and prove it goes red. A gate that cannot be made to
fail is not passing; it is not running. Until that is automated, "I ran the
grep" and "it is green on my Mac" are **not** evidence that 1.3 was checked, and
the green `Workflow Lint` tick is not coverage for it either.

---

## 2. Editing a workflow: the checklist

1. **Regenerate the control-plane manifest in the same commit.** It pins trusted
   bytes per control-plane file; skipping this fails `promotion-contracts` with
   an error that names symlinks and drift rather than your edit.
   ```bash
   node scripts/ci/verify-domain-core-control-plane.mjs --write
   ```
2. **Run the reachability gate** (§1).
3. **Run the contract tests that pin workflow text.** Several assert on exact
   invocation strings, so a legitimate fix can fail a test that pinned the bug:
   ```bash
   node --test \
     scripts/ci/verify-domain-core-workflows.test.mjs \
     scripts/ci/verify-domain-core-native-release-workflows.test.mjs \
     scripts/ci/verify-domain-core-control-plane.test.mjs \
     scripts/ci/verify-workflow-reachability.test.mjs
   ```
   **If a test pinned the broken behaviour, update the test and say so
   explicitly in the PR body.** One of these pinned a relative signing-policy
   path that could never pass.
4. **If you changed a `paths:` filter or a script it covers**, confirm the
   workflow actually triggers — a merge that does not fire the workflow looks
   identical to success.

---

## 3. Paths that pass a file to a verifier

`regularFile()` in `scripts/lib/domain-core-release-evidence.mjs` **fail-closes
on relative paths** (`mustBeAbsolute: true` by default).

A workflow that passes a repo-relative path to any script consuming it can never
succeed. `release.yml` did exactly this for the Apple signing policy, which is
why `build-and-release` never once reached packaging across ten release tags:

```yaml
# WRONG — cannot ever pass
--policy config/apple-release-signing-policy.json

# RIGHT
--policy "$GITHUB_WORKSPACE/config/apple-release-signing-policy.json"
```

---

## 4. Merging here

`main` is governed by the **`Main native merge queue`** ruleset
(`gh api repos/Imagine-That-Ai/BurnBar/rulesets`), not just classic branch
protection. Turning off "require merge queue" in branch settings does nothing
while the ruleset is active.

- `grouping_strategy: ALLGREEN` — GitHub batches up to 5 PRs and **ejects the
  entire batch if any member fails**. Two PRs touching the same file (e.g. both
  regenerating `domain-core-control-plane-manifest.json`) will fight and both
  get ejected, repeatedly, with no failing check to explain it.
- **Queue conflicting PRs one at a time.**
- `Ajnunezg` holds an `always` bypass on that ruleset, so `gh pr merge --admin`
  works when the queue is misbehaving.
- A PR sitting `BLOCKED` while fully green usually has an **unresolved review
  thread**, or a check that was **cancelled** (cancelled ≠ failed, but also ≠
  passed). Check both before assuming CI is broken.

---

## 5. Release: what actually gates what

From `release.yml`:

- `build-and-release` (build, sign, notarize, package) needs **only**
  `release-preflight`, `authorize-domain-core-rollback` (may be skipped), and
  `domain-core-native-release-gate`. **The slow validation gates do not gate
  the build.** A red Swift/mobile/SQLCipher gate does not stop the DMG.
- `prepare-release-publication` needs **every** gate. It is fail-closed, and it
  is what actually publishes.
- Owner-approved bypasses exist for an emergency cut:
  `run_release_validation_gates: false` and `run_mobile_unit_tests: false`, each
  requiring a reason that **must contain a GitHub run/PR URL or a 40-character
  commit SHA** or preflight rejects it.
- `promote` is a **separate second run**, not a flag on the build. Publication
  never repoints the public update channel; `release-promotion` does, and it
  requires `expected_live_macos_version` / `expected_live_macos_commit` matching
  what `downloads.burnbar.ai/latest-macos.json` currently advertises.

So a full release is **two dispatches**: build+publish, then promote.

### Local escape hatch

`make release-website` builds, signs, notarizes, and produces the DMG/ZIP plus a
signed appcast **entirely locally** — and never touches the iOS target, which is
useful when an iOS-only break is blocking a macOS release.

It needs a Developer ID cert in the login keychain, `APPLE_NOTARY_KEY_ID` /
`APPLE_NOTARY_ISSUER_ID` / `APPLE_NOTARY_API_KEY_P8`, a Sparkle key (read from
the keychain by `sign_update`), and `Vendor/*.xcframework`, which are gitignored
— symlink them from a populated checkout when building from a fresh worktree.

**Build from the release tag, not a dirty tree.** A local build happily bakes in
uncommitted work-in-progress.

CI additionally produces attestations and provenance that a local build does
not. Apple notarization — the thing that stops Gatekeeper warnings — is
identical either way.

---

## 6. When a deploy or release "did nothing"

In order, because each is cheap and rules out the next:

1. **Did the workflow run at all?** `gh run list --workflow "<name>" --limit 3`.
   No run ⇒ path filter (§1.2).
2. **Did the job run, or was it skipped?** A `skipped` job with `steps: 0` and
   `runner_name: null` was never scheduled ⇒ skip propagation (§1.1).
3. **Is it waiting on an environment approval?**
   `gh api repos/OWNER/REPO/actions/runs/<id>/pending_deployments`. A run in
   `waiting` needs a human, and the reviewer list tells you who.
4. **Did the artifact expire?** Domain-core protected verification artifacts
   expire after **7 days**; the hosting gate demands exactly one unexpired
   match and fail-closes at zero.
5. **Is the standing ops issue already screaming?** Recurring deploy failures
   comment on a standing issue rather than opening new ones — 55 comments
   accumulated during the outage. Search open issues before diagnosing.

---

## 7. For agents working in this repo

- **Check for an existing PR before starting.** Duplicate fixes for the hosting
  deploy were built twice in one night because nobody looked.
- **`git stash` is repo-global across worktrees.** A `stash`/`pop` in one
  worktree can pop a *different* session's stash. Prefer committing to a scratch
  branch.
- **`git worktree remove` follows a `Vendor` symlink** and deletes through it
  into the shared checkout. Remove the symlink first, or leave the worktree.
- **Do not cut a new version tag to work around a failing gate.** Ten tags were
  burned that way. Fix the gate; the tag is not the problem.
- **Verify against the tag CI is building**, not your working tree. Local
  branches drift, and a fix that "works locally" may be testing different code.

---

## 8. xcframeworks and the `include/module.modulemap` collision

`xcodebuild -create-xcframework -library X.a -headers H/` makes Xcode copy `H/`
into a **shared** `BuildProductsPath/include` at build time. A headers directory
containing `module.modulemap` therefore claims a path no other binary target can
also claim. Link two such xcframeworks into one target and the build dies:

```
error: Multiple commands produce '.../Release-iphoneos/include/module.modulemap'
  Command: ProcessXCFramework Vendor/OpenBurnBarDomainCore.xcframework
  Command: ProcessXCFramework Vendor/OpenBurnBarIroh.xcframework
```

This blocked every iOS archive — and therefore every release, since
`build-and-release` packages iOS in the same job that produces the macOS DMG —
in August 2026. **PR CI never saw it**: `OpenBurnBarDomainCore.xcframework` is
built during the release job and is not vendored, so the two only met on the
release path.

**One bare-layout xcframework is fine.** The collision needs two, so
`scripts/ci/verify-xcframework-modulemap-collision.mjs` fails on the second
rather than banning the layout.

**The fix for a new one** is to package a real `.framework`, whose module map
lives inside the bundle at `Modules/module.modulemap` and cannot collide. See
`make_framework()` in `scripts/build-domain-core-xcframework.sh`, modelled on
`scripts/build-burnbar-remote-xcframework.sh`, which has always shipped this way.

A static library placed inside a `.framework` bundle is a normal "static
framework" and is what both of those scripts produce.

---

## 9. iOS must not block a macOS release

`build-and-release` packages the macOS DMG **and** the App Store iOS archive in
one job, deliberately: both come from a single source-coherent Signal FFI build
(see *Prepare Signal FFI XCFramework for release app*). Moving iOS to its own
job would mean either duplicating ~1300 lines of signing/FFI setup or rebuilding
the FFI separately — which breaks exactly the coherence that design protects.

The defect was never the shared job. It was that **an iOS failure failed the
whole release**, including a macOS app that had already built and signed
cleanly. In August 2026 an iOS-only `module.modulemap` collision blocked every
macOS release for weeks.

So the iOS archive is `continue-on-error: true`, and its outcome is recorded:

- `steps.ios-status` writes `success` / `failure` into the job output
  `ios_status`.
- Failure emits an `::error::` annotation **and** a job-summary block naming
  exactly what is excluded.
- The iOS artifact upload and `domain-core-ios-release-evidence` both gate on
  `ios_status == 'success'`.

The release therefore **degrades visibly** — macOS ships, iOS is excluded, and
the run says so in three places — instead of failing wholesale or, worse,
silently publishing an incomplete set.

**If you are debugging a release that shipped without iOS assets**, look for the
`iOS archive failed` annotation on `build-and-release`. That is the intended
signal, not a bug.

### Corrections to §2, from a peer session

The manifest rule in §2 was stated too broadly. Precisely:

- The control-plane manifest pins ~14 release/deploy workflows and ~300
  **scripts**. `fast-feedback.yml` and `security-pr.yml` are **not** pinned.
- The pinned set spans `scripts/` broadly — including `scripts/ci/*.py` and
  release-verification shell scripts such as `verify-public-macos-download-trust.sh`.
  **If a release packet touches anything under `scripts/`, assume it is pinned
  and run `--write`.**
- Release packets are the highest-risk carrier for this: they routinely edit
  pinned scripts while everyone's attention is on the release. Three separate
  emergency packets (#2343, #2344, #2347) each left `main` red this way, and the
  resulting failure names a file the author never touched — which reads as an
  inexplicable ejection rather than a missing regeneration.

**The check that catches all of it**, and the one to make reflexive:

```bash
node scripts/ci/verify-domain-core-control-plane.mjs --write
git diff config/domain-core-control-plane-manifest.json
```

The diff should name **only files you edited**. Any other filename means `main`
was already stale before you started — do not assume it is your change.
