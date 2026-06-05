# Confidentiality Policy — what may live in the public repo

OpenBurnBar is open source: `github.com/Imagine-That-Ai/BurnBar` is **public**.
That is intentional and good — the code, architecture, threat models, and privacy
guarantees are meant to be inspectable. But "the code is open" is not the same as
"everything is open." Some material is sensitive even though it is not a secret:

- **Pricing & financials** — COGS, unit economics, margin targets, sensitivity tables.
- **Go-to-market strategy** — launch sequencing, kill-switch spend budgets, tier/SKU strategy.
- **Open-vuln working notes** — recon/remediation/audit evidence that maps
  *in-progress or unpatched* vulnerabilities. Publishing these before the fix
  ships is free reconnaissance for an attacker.

The secret scanners (gitleaks, trufflehog, detect-secrets) cannot catch any of
this — none of it is a credential. This policy and its guard fill that gap.

> TL;DR: secrets → secret scanners. **Sensitive-but-not-a-secret content → the
> confidentiality guard.** Both run on every PR.

## The line: public vs internal

| Keep **public** (transparency assets) | Keep **internal** (gitignored `internal/`, or private mirror) |
| --- | --- |
| Abstract threat models (`docs/THREAT_MODEL.md`, `docs/security/*_THREAT_MODEL.md`) | Pricing / COGS / margins (`docs/pricing/**`) |
| Privacy policy, `SECURITY.md`, supply-chain provenance | GTM master plan, launch budgets |
| Architecture & design docs, OSS migration specs | Leak/remediation/audit evidence for **open** holes |
| Customer-facing prices on the website | Detection-gap matrices, internal audit reports |
| Sanitized advisories **after** a fix ships | Agent working ledgers that reveal unshipped plans (review case-by-case) |

The rule of thumb for security docs: **publish the design, not the open hole.**
A threat model that says "we defend X against Y" is a transparency asset. A doc
that says "here is exactly where we currently leak and how" is internal until the
fix ships — then it becomes a sanitized advisory.

## How it is enforced (three points, one policy)

All three read the same declarative policy, so they cannot drift apart:

1. **Pre-commit** (`.pre-commit-config.yaml` → `confidentiality-guard`) — fast,
   staged-files only. Install once: `brew install pre-commit && pre-commit install`.
2. **CI** (`.github/workflows/confidentiality-guard.yml`) — full tracked tree on
   every PR and push to `main`. Require the `Confidentiality Guard / guard` check
   in branch protection.
3. **Release** (`scripts/security/scan-publishable-tree.sh`) — runs the guard
   next to the secret scans before a build is published.

| File | Role |
| --- | --- |
| `scripts/security/internal-content-policy.mjs` | **Policy** — rules, allowlist, banners (edit this) |
| `scripts/security/scan-internal-content.mjs` | **Engine** — classifies the tree (zero-dep) |
| `scripts/security/relocate-internal.mjs` | **Remediation** — moves flagged files into `internal/` |
| `scripts/security/__tests__/scan-internal-content.test.mjs` | **Tests** — `node --test …` |

Run it manually any time:

```bash
node scripts/security/scan-internal-content.mjs            # full tracked tree
node scripts/security/scan-internal-content.mjs --staged   # staged files (what pre-commit runs)
node scripts/security/scan-internal-content.mjs --json      # machine-readable
node scripts/security/relocate-internal.mjs                # preview a relocation
node scripts/security/relocate-internal.mjs --apply         # perform it
```

## Self-service: mark a doc internal without editing the policy

Any text file that carries this banner is blocked from the public tree, no policy
edit required:

```markdown
<!-- burnbar:confidential -->
> **BurnBar-Confidential: internal.** Do not publish to the public repo.
```

This is the preferred way to gate a *new* one-off internal doc. Use a policy rule
(below) for a whole category or directory.

## Extending the policy

Open `scripts/security/internal-content-policy.mjs`:

- **Block a new category** → add an entry to `INTERNAL_RULES` with `severity: "block"`,
  a `reason`, a `remediation`, and `paths: [/regex/]`.
- **Surface-but-don't-fail** → same, with `severity: "warn"` (the engine fails on
  warns only under `--strict`).
- **Keep something public that a rule would catch** → add it to `PUBLIC_ALLOWLIST`
  (the allowlist always wins, even over a self-declared banner).
- **New self-declared marker** → add to `SELF_DECLARE_MARKERS`.

Add a test in `scan-internal-content.test.mjs` for any new rule (positive +
a negative to prove no false positive), then run `node --test`.

## If the guard flags your commit

You have three correct moves — pick one:

1. **It really is internal** → `node scripts/security/relocate-internal.mjs --apply`
   (moves it under `internal/`), or move it by hand and `git rm --cached` the original.
2. **It is intentionally public** → add a `PUBLIC_ALLOWLIST` entry with a one-line
   reason, in the same PR, so the decision is reviewed.
3. **It is a brand-new internal one-off** → add the confidentiality banner.

## History is separate

The guard governs the **current tree**. Files already committed remain in git
history even after relocation. To scrub history and rotate any real secret that
was ever exposed, follow
[`PUBLIC_REPO_HISTORY_PURGE_RUNBOOK.md`](./PUBLIC_REPO_HISTORY_PURGE_RUNBOOK.md).
