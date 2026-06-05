# Runbook — purge internal files from public git history

The confidentiality guard cleans the **current tree**. Files already committed
stay in **history**: anyone can `git show <old-commit>:docs/pricing/...` on the
public repo. This runbook scrubs those paths from history and covers credential
rotation.

> **Read this first — set expectations honestly.**
> - History rewrite **breaks every commit SHA**, every open PR, and every clone/fork.
> - It does **not** un-leak anything already cloned, forked, or indexed. GitHub
>   keeps fork objects and cached views until you ask Support to purge them.
> - For **pricing/GTM/vuln-notes** (not credentials) this is therefore *optional
>   damage-limitation*, not a true secret-rotation emergency. The data is already
>   public; a purge mainly reduces future casual discoverability.
> - For the **open-vuln notes**, the higher-priority action is to **ship the fixes**;
>   purging the map second.
> - As of the last scan (`gitleaks detect`, 1207 commits), **no real credential was
>   ever committed** — every hit was a placeholder/test fixture. So there is
>   currently **nothing to rotate**. Re-run the scan (Step 0) before you trust that.

Decide deliberately. If you only want to stop *future* exposure, the relocation
+ guard (already done) is sufficient and non-destructive. Proceed below only if
you also want history scrubbed.

---

## Step 0 — confirm there's nothing to rotate (always do this)

```bash
gitleaks detect --source . --config .gitleaks.toml --redact --no-banner \
  --report-format json --report-path /tmp/gitleaks-history.json
node -e 'const f=require("/tmp/gitleaks-history.json");const by={};for(const x of f)by[x.RuleID]=(by[x.RuleID]||0)+1;console.log(by)'
```

Inspect every non-`generic-api-key` hit and any `generic-api-key` outside
`*test*`, `*.example`, `artifacts/`, `.asc/`, and lockfiles. **If any is a real
key**, treat it as compromised: rotate it (see Step 5) *before* or independent of
the history purge — purging is not a substitute for rotation.

## Step 1 — full backup (mandatory)

```bash
# Mirror clone you can restore from if anything goes wrong.
git clone --mirror git@github.com:Imagine-That-Ai/BurnBar.git /tmp/burnbar-backup.git
```

Also note all active branches and worktrees — a rewrite must be force-pushed to
**every** long-lived branch, not just `main`:

```bash
git branch -a
git worktree list
```

## Step 2 — verify the purge list

The list is generated from the relocation and tracked at
`scripts/security/internal-history-paths.txt` (83 paths). Review it:

```bash
wc -l scripts/security/internal-history-paths.txt
git log --oneline -- $(cat scripts/security/internal-history-paths.txt | head -1)   # sanity: a path has history
```

Add any extra paths you also want gone (e.g. older renamed locations).

## Step 3 — rewrite history (git-filter-repo)

`git-filter-repo` is the maintained replacement for `filter-branch`/BFG.
Install: `brew install git-filter-repo` (or `pip install git-filter-repo`).

Do this on a **fresh clone**, not your working repo:

```bash
git clone git@github.com:Imagine-That-Ai/BurnBar.git /tmp/burnbar-rewrite
cd /tmp/burnbar-rewrite

# Bring the path list into the fresh clone.
cp /path/to/BurnBar/scripts/security/internal-history-paths.txt ./purge-paths.txt

# Remove those paths from ALL of history, across all refs.
git filter-repo --invert-paths --paths-from-file purge-paths.txt

# Verify they are gone from history:
git log --all --oneline -- docs/pricing/ GTMMasterPlan.MD   # → no output
```

> `filter-repo` intentionally drops the `origin` remote after rewriting. Re-add it
> in Step 4. To purge by content pattern instead of path (e.g. a real leaked key),
> use `git filter-repo --replace-text <patterns.txt>` — one `literal:SECRET==>REMOVED`
> per line.

## Step 4 — force-push the rewritten history

`main` is protected with `enforce_admins: ON`, so a force-push is blocked until
you temporarily relax it.

1. GitHub → Settings → Branches → `main` rule → temporarily allow force pushes
   (or disable the rule). **Re-enable immediately after.**
2. Push every rewritten ref:
   ```bash
   cd /tmp/burnbar-rewrite
   git remote add origin git@github.com:Imagine-That-Ai/BurnBar.git
   git push --force --all
   git push --force --tags
   ```
3. Re-enable branch protection (force-push off, required checks on — including
   `Confidentiality Guard / guard`).
4. **Tell every collaborator to re-clone.** Their old clones still contain the
   purged content and will reintroduce it if they push. Old local branches must be
   rebased onto the rewritten history or discarded.

## Step 5 — purge GitHub's cached copies & forks, rotate any real secret

History rewrite alone leaves data reachable via:

- **Forks** — each fork keeps the old objects. Identify forks
  (`gh api repos/Imagine-That-Ai/BurnBar/forks`) and ask owners to delete/re-fork,
  or delete internal forks yourself.
- **Cached views / PR refs** — old commits stay viewable by SHA until purged.
  Open a GitHub Support request: "rewrote history to remove sensitive data, please
  garbage-collect cached views and stale PR refs for `Imagine-That-Ai/BurnBar`."
- **Third-party mirrors / archives** — search engines, `archive.org`, and any
  mirror may have snapshots. Request removal where it matters.
- **Rotate any real credential** found in Step 0 — assume it is compromised the
  moment it touched a public repo. For BurnBar that means: provider API keys,
  Stripe keys, Apple/Google service-account JSON, `FIREBASE_TOKEN`, relay bearer
  tokens. (Current scan: none found — but rotate on any future hit, no exceptions.)

## Step 6 — verify

```bash
# Fresh clone should be clean in both tree and history.
git clone git@github.com:Imagine-That-Ai/BurnBar.git /tmp/burnbar-verify
cd /tmp/burnbar-verify
node scripts/security/scan-internal-content.mjs                 # tree clean
git log --all --oneline -- docs/pricing/ GTMMasterPlan.MD       # history clean
gitleaks detect --source . --config .gitleaks.toml --redact --no-banner
```

---

### Decision summary

| Situation | Action |
| --- | --- |
| Stop *future* internal leakage | ✅ Done — relocation + guard (non-destructive). |
| A **real secret** is in history | Rotate immediately (Step 5), then purge (Steps 1–6). |
| Pricing/GTM/vuln-notes in history, no secret | Optional purge. Weigh fork/SHA breakage vs. limited benefit (data already public). Shipping the vuln fixes matters more. |
