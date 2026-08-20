# Rust supply-chain gates

How OpenBurnBar defends its Rust dependencies, why the usual tools are not
enough on their own, and what to do when a gate goes red.

## The incident that shaped this

On **2026-08-20** CI went red across every branch. `cargo audit` reported one
denied warning:

```
Crate:    arrayref
Version:  0.3.9
Warning:  yanked
```

`arrayref` is a ~100-line utility crate that turns a slice into a fixed-size
array reference. Pulling the thread:

| version | status | declared dependencies |
| --- | --- | --- |
| 0.3.4 | clean | `quickcheck` (dev) |
| 0.3.5 – 0.3.9 | **all yanked** | `quickcheck` (dev) |
| 0.3.10 | published, then **deleted by crates.io** | `proc-macro1`, `quickcheck` |

`proc-macro1` **did not exist on crates.io**. It is one character from
`proc-macro2`, which nearly every Rust project depends on transitively.

A tiny, stable utility crate does not suddenly grow a proc-macro dependency.
Five consecutive versions do not get yanked by accident. And crates.io does not
*delete* a version — as opposed to yanking it — for a packaging mistake. This
was a compromised publish, and the registry's own response confirms it.

**The part that matters for the future:** `0.3.10` was not dangerous the moment
it landed, because `proc-macro1` was unregistered and would fail to resolve. It
was dangerous because **anyone could register that name at any time**, and every
project that had upgraded would then execute an attacker's build script. An
unregistered dependency name is a loaded gun, not a broken link.

### What the existing tools saw

Nothing.

`cargo-audit`, `cargo-deny` and `osv-scanner` all answer one question: *does a
published advisory match a package I have already resolved?* There was no
advisory — the attack was hours old. And we had not resolved `0.3.10`; the
danger was on the **upgrade path**, one `cargo update` away.

The only reason we noticed at all is that the collateral yank of `0.3.9` tripped
`--deny warnings`. We were warned by a side effect.

## The two gates

### 1. `check-cargo-dependency-confusion.mjs` — registry facts, not advisories

Everything already in a `Cargo.lock` is by definition resolvable; cargo proved
that when it wrote the file. So dependency confusion cannot enter through the
pinned set — **it enters through the upgrade path**.

For every locked crate the gate reads the crates.io sparse index, looks at the
versions *newer* than the one we pin, and reports:

- **phantom** — a declared dependency naming a crate that does not exist.
  Reported with its nearest published neighbour when there is one, because
  `proc-macro1` sitting next to `proc-macro2` stops being a coincidence.
- **missing-pin** — a locked version the registry does not carry at all.

Because it reasons about registry facts rather than advisories, it fires
**before** anyone writes a CVE. That is the entire point.

Two design decisions worth knowing:

- **Renamed dependencies resolve through `package`, not `name`.** Cargo lets a
  crate write `rand_0_9 = { package = "rand", version = "0.9" }`, and the index
  records the *local alias* in `name`. Reading `name` reports every renamed
  dependency in the ecosystem as nonexistent — it was the single largest source
  of false positives during development, and there are a lot of them.
- **Name similarity between crates that both exist is deliberately NOT
  reported.** `h2` and `h3` are both official hyper crates; `wat` and `want` are
  unrelated real projects. Edit distance over published names is nearly pure
  noise, and a gate that cries wolf gets muted. Non-existence is the signal
  nobody can argue with.

Runtime is ~30s for ~1,200 crates across all lockfiles.

### 2. `check-cargo-audit-fail-closed.mjs` — strict posture, real granularity

`cargo audit --deny warnings` is the right posture: it escalates unmaintained
and yanked crates, not just vulnerabilities. But its only escape hatch is
`--ignore <RUSTSEC-id>`, and **a yanked crate has no advisory id** — cargo-audit
reports it with `advisory: null`.

So when `arrayref` was yanked with no upgrade path, the choices were:

1. drop `--deny warnings`, and stop failing on unmaintained advisories too, or
2. disable the job.

Both are losses of signal dressed up as a fix. The gate keeps the strict posture
and adds the missing granularity:

- every **vulnerability** fails, always — a policy acceptance can never silence
  one, enforced in the gate itself rather than trusted to validation elsewhere
- every **warning** fails, unless covered by a live acceptance
- **execution failures fail.** A database that will not load, a crash, or output
  that is not JSON all exit non-zero. "I could not check" must never render the
  same as "I checked and it is clean"

## Where acceptances live

| what | where | why |
| --- | --- | --- |
| RustSec advisories | `crates/openburnbar-iroh/deny.toml` `[advisories].ignore` | cargo-deny reads it directly; a second copy would drift |
| Yanked crates, phantom dependencies | `config/rust-supply-chain-policy.json` | they have no advisory id, so deny.toml has nowhere to put them |

`scripts/ci/check-advisory-ignore-single-source.sh` enforces the split: it fails
if a hardcoded `--ignore RUSTSEC-…` reappears in the workflow, **asserts the two
deny.toml readers extract an identical set**, and rejects a policy that is
malformed or carries an already-expired acceptance.

Every policy acceptance is **time-boxed and requires a substantive rationale**.
Past `expires` the gate goes red again and forces a re-decision — a suppression
cannot quietly rot into permanent blindness.

## Triage: a gate went red

### `[phantom] … declares a dependency on 'x', which does not exist`

**Do not resolve this by upgrading into the flagged version.** That is precisely
what the attack wants.

1. Read the flagged version's manifest on the registry. Does the dependency make
   sense for what the crate does? A slice-helper crate does not need a
   proc-macro.
2. Check the neighbour the gate names. One edit from something ubiquitous is a
   very strong signal.
3. Check the crate's release history. Sudden yanks around a new publish mean the
   registry is already responding.
4. If it is an attack: **stay pinned**, and report it to
   [RustSec](https://github.com/rustsec/advisory-db/issues) and crates.io
   support if no advisory exists yet.
5. If it is genuinely benign — a crate legitimately depending on something
   unpublished, e.g. a workspace member never released — time-box an acceptance
   with the evidence.

### `[warning/yanked] … : yanked`

1. Is there an unyanked version **in range** of what depends on it? If yes,
   upgrade; that is the real fix.
2. If not, check *why* it was yanked. A yank for a packaging mistake and a yank
   as part of a malware response are very different situations.
3. Remember what a lockfile pin means: `Cargo.lock` records a sha256, so we
   compile fixed, known bytes. **A yank changes what cargo would newly resolve,
   not what we build.** When the yanked version's own manifest is clean and
   there is nothing safe to move to, staying pinned is strictly safer than
   moving.
4. Only then, time-box an acceptance naming the blocker that makes it necessary.

## Adding an acceptance

```jsonc
{
  "kind": "yanked",              // yanked | phantom | typosquat | missing-pin
  "crate": "arrayref",
  "version": "0.3.9",            // optional; omit to cover any version
  "reason": "…",                 // substantive; a placeholder is rejected
  "url": "https://crates.io/crates/arrayref/versions",
  "expires": "2026-11-20"        // YYYY-MM-DD; the gate re-reds after this
}
```

Shorten an expiry the moment an upgrade path appears. Extend one only with fresh
evidence — never because it came up red again.

## Running the gates locally

```bash
node scripts/ci/check-cargo-dependency-confusion.mjs
node scripts/ci/check-cargo-audit-fail-closed.mjs crates/openburnbar-iroh
bash scripts/ci/check-advisory-ignore-single-source.sh
```

Self-tests (both are positive controls — they replay the real attack shape and
must fail on it):

```bash
node --test scripts/ci/check-cargo-dependency-confusion.test.mjs
node --test scripts/ci/check-cargo-audit-fail-closed.test.mjs
```

## Related

- [`docs/CI_RELEASE_RUNBOOK.md`](CI_RELEASE_RUNBOOK.md) — CI and release gates
- [`docs/LINT_RATIONALE.md`](LINT_RATIONALE.md) — suppression policy
- [`AGENTS.md`](../AGENTS.md) — repository agent contract
