# Remediation — committed Firebase/GCP security-evidence bundle (finding M-004)

`security/evidence/firebase-security-evidence-latest.json` was committed and is
**still tracked and present in git history**. It is a read-only artifact produced
by `scripts/ops/collect-firebase-security-evidence.mjs` and was only ever meant to
be a CI artifact — never committed.

It leaks a complete recon map of the production project (no secret *values*, but
everything an attacker needs to target it):

- the **project owner identity** — a `roles/owner` IAM binding tied to a personal
  email (`user:…@gmail.com`);
- the active `gcloud` account (verbatim in `authContext`);
- the **12-digit project number** (×204 in the file);
- the **service-account → role IAM inventory** (deploy SA, compute SA, every
  Google-managed service agent, the relay SA);
- the **Secret Manager name inventory** (Stripe, APNs, Android keystore,
  OpenRouter, MCP HMAC, webhook, and per-user `obb-<UID>-…` ids that leak Firebase
  UIDs);
- **KMS keyring/key paths** (e.g. the credential-encryption key path).

> This persists in history **regardless of whether the repo is public or private**.
> Anyone who has cloned, forked, or cached the repo already has it. Treat the
> identifiers as exposed and proceed accordingly.

This remediation has two halves:

1. **Additive (already landed in this change) — prevents recurrence:**
   - `.gitignore` now also names the specific file (the `security/evidence/*.json`
     glob already existed; the file predated it, which is *why* git still tracks it).
   - `scripts/ci/check-no-committed-evidence.sh` is a fail-closed gate that catches
     any tracked `security/evidence/*.json` and any re-introduced GCP-IAM-recon dump.
2. **Manual (steps below — a human must run these) — removes what already leaked:**
   `git rm --cached`, purge history, rotate identifiers, then wire the gate into CI.

The gate **deliberately fails right now** because the file is still tracked. That
is correct. Do not suppress it — make it pass by removing the file (Steps 1–3) and
only then make it a required check (Step 6).

---

## Step 0 — confirm the file is tracked (and find any siblings)

```bash
# Should print the path → confirms it is tracked.
git ls-files security/evidence/

# Confirm the gate currently fails on it (expected exit 1 until removed):
bash scripts/ci/check-no-committed-evidence.sh; echo "exit=$?"

# Catch any OTHER evidence bundles that may also have been committed over time:
git log --all --diff-filter=A --name-only --pretty=format: -- 'security/evidence/*.json' \
  | sort -u | sed '/^$/d'
```

Remediate every path the last command lists, not just `…-latest.json`.

## Step 1 — full backup (mandatory before any history rewrite)

```bash
# Mirror clone you can restore from if anything goes wrong.
git clone --mirror git@github.com:Imagine-That-Ai/BurnBar.git /tmp/burnbar-backup.git

# Note every long-lived ref and worktree — a rewrite must hit ALL of them, not just main.
git branch -a
git worktree list
```

## Step 2 — stop tracking the file (current tree), commit, push

This removes the file from the tree on a normal branch + PR. It does **not** touch
history (Step 4 does that), but it makes the gate pass and prevents new commits
from carrying the file.

```bash
git rm --cached security/evidence/firebase-security-evidence-latest.json
# …and any siblings Step 0 found, e.g.:
#   git rm --cached security/evidence/firestore-iam-inventory-2026-06-14.json

# The .gitignore rule is already in place; verify the path is now ignored:
git check-ignore -v security/evidence/firebase-security-evidence-latest.json

git commit -m "security(M-004): stop tracking Firebase security-evidence bundle (CI-artifact-only)"

# The gate should now pass on the current tree:
bash scripts/ci/check-no-committed-evidence.sh; echo "exit=$?"   # → exit=0
```

Open/merge this as a normal PR. The file is still in history after this — continue.

## Step 3 — purge the file from ALL of git history

Do this on a **fresh clone**, never your working repo. `git-filter-repo` is the
maintained replacement for `filter-branch`/BFG and is already installed here
(`git filter-repo --version`); a BFG alternative follows.

### Option A — git-filter-repo (preferred)

```bash
git clone git@github.com:Imagine-That-Ai/BurnBar.git /tmp/burnbar-rewrite
cd /tmp/burnbar-rewrite

# Remove the path(s) from every commit on every ref.
git filter-repo \
  --path security/evidence/firebase-security-evidence-latest.json \
  --invert-paths
# Add one --path per sibling Step 0 found. To purge the entire directory from
# history instead, use:  git filter-repo --path security/evidence/ --invert-paths

# Verify it is gone from history (must print nothing):
git log --all --oneline -- security/evidence/firebase-security-evidence-latest.json
```

> `filter-repo` intentionally drops the `origin` remote after rewriting — re-add it
> in Step 4.

#### Defense-in-depth: also scrub the leaked literals by content

Even after the path is gone, the owner email / project number may survive in other
blobs (e.g. an old log that quoted them). Purge the literals too:

```bash
cat > /tmp/recon-redactions.txt <<'EOF'
literal:alberto8793@gmail.com==>REDACTED-OWNER-EMAIL
literal:246956661961==>REDACTED-PROJECT-NUMBER
EOF
git filter-repo --replace-text /tmp/recon-redactions.txt
git grep -nI 'alberto8793@gmail.com\|246956661961' $(git rev-list --all) | head   # → sanity check
```

### Option B — BFG (alternative; install `brew install bfg`)

```bash
git clone --mirror git@github.com:Imagine-That-Ai/BurnBar.git /tmp/burnbar-bfg.git
bfg --delete-files firebase-security-evidence-latest.json /tmp/burnbar-bfg.git
cd /tmp/burnbar-bfg.git
git reflog expire --expire=now --all && git gc --prune=now --aggressive
```

## Step 4 — force-push the rewritten history

`main` is protected with `enforce_admins: ON`, so a force-push is blocked until you
temporarily relax it.

1. GitHub → Settings → Branches → `main` rule → temporarily allow force pushes (or
   disable the rule). **Re-enable immediately after.**
2. Push every rewritten ref:
   ```bash
   cd /tmp/burnbar-rewrite                       # (or the BFG mirror)
   git remote add origin git@github.com:Imagine-That-Ai/BurnBar.git
   git push --force --all
   git push --force --tags
   ```
3. Re-enable branch protection (force-push off, required checks on).
4. **Tell every collaborator to re-clone.** Old clones still contain the purged
   file and will reintroduce it if pushed. Old local branches must be rebased onto
   the rewritten history or discarded.

See `docs/security/PUBLIC_REPO_HISTORY_PURGE_RUNBOOK.md` for the shared force-push /
fork / GitHub-Support-cache-purge procedure (Steps 4–5 there) — apply it verbatim
for forks and cached views.

## Step 5 — rotate the exposed GCP/Firebase identifiers

A history rewrite does **not** un-leak anything already cloned, forked, or indexed.
Treat the exposed identifiers as public and rotate / harden:

- **Owner email (`user:…@gmail.com`)** — assume it is a phishing target. Prefer to
  **stop using a personal Gmail as `roles/owner`**: create a dedicated
  org/workspace identity, grant it Owner, and remove the personal account's Owner
  binding. Enforce 2FA / hardware keys on whatever holds Owner.
- **Project number (`246956661961`)** — not a secret and not rotatable, but it is a
  pivot for App Check / API-key abuse. Confirm **App Check is ENFORCED** for
  Firestore and Storage (`scripts/ci/app-check-smoke.sh`) and that API keys are
  scoped/referrer-restricted.
- **Service accounts in the IAM dump** — review each for least privilege; rotate any
  SA key that is older than your rotation policy. The dump reveals the SA→role map,
  which makes any *separately* leaked SA key far more useful.
- **Secret Manager entries named in the file** — the *names* leaked, not the values.
  No automatic compromise, but if any value was *also* ever exposed elsewhere,
  rotate it (Stripe keys, APNs `.p8`, Android keystore, OpenRouter, MCP HMAC,
  webhook). Cross-check against `gitleaks` (Step 0 of the history-purge runbook).
- **KMS key path** — paths are not secrets; confirm key IAM grants decrypt only to
  the intended SAs.

## Step 6 — wire the gate into CI as a required check (AFTER the file is removed)

Do this **only after Steps 2–3** so the first CI run is green. Add a job to an
**existing** security/lint workflow (do not create a parallel workflow). Example
step:

```yaml
      - name: No committed security-evidence bundles (M-004)
        run: bash scripts/ci/check-no-committed-evidence.sh
```

Then mark that job as a **required status check** on `main` (GitHub → Settings →
Branches → branch protection → require status checks). From then on, any PR that
re-commits `security/evidence/*.json` or re-introduces a GCP-IAM-recon dump fails
closed before merge.

### Keep the collector's output a pure artifact

`scripts/ops/collect-firebase-security-evidence.mjs` and the `ops-plane-verify`
workflow should write the bundle to a path under `security/evidence/` (already
gitignored) and **upload it as a CI artifact only** — never `git add` it. Also
reconcile `docs/security/FIREBASE_SECURITY_EVIDENCE.md` (which claims sensitive
fields are redacted): the committed bundle proves IAM `members`/`email`, resource
`name`, and the `gcloud account` stdout are **not** redacted. Either extend the
collector's `redact()` to strip/hash those, or keep the bundle strictly as an
unpublished artifact — or both.

---

## Verify (end state)

```bash
# Tree: file untracked and ignored.
git ls-files security/evidence/                                   # → (nothing)
git check-ignore -v security/evidence/firebase-security-evidence-latest.json

# History: file and literals gone (run in the rewritten clone).
git log --all --oneline -- security/evidence/firebase-security-evidence-latest.json   # → (nothing)
git grep -nI 'alberto8793@gmail.com\|246956661961' $(git rev-list --all) | head       # → (nothing)

# Gate: now passes, and stays a required check.
bash scripts/ci/check-no-committed-evidence.sh; echo "exit=$?"    # → exit=0
```

| Half | Status |
| --- | --- |
| Prevent recurrence (gitignore + gate) | ✅ landed in this change (additive) |
| Stop tracking the leaked file (Step 2) | ☐ manual |
| Purge from history (Step 3–4) | ☐ manual |
| Rotate exposed identifiers (Step 5) | ☐ manual |
| Gate as required CI check (Step 6) | ☐ manual, **after** Steps 2–3 |
