# Functions break-glass deploy (emergency hotfix lane)

**When to use:** A production incident in Cloud Functions needs a forward fix
*now*, and the normal tag-driven `deploy-production.yml` lane is blocked — by
the legal release preflight (`requires_counsel_review`), a runtime-readiness
gate, or CI itself being down.

**When NOT to use:** Anything that can wait for a tag. The preflight gates are
deliberate controls; this lane exists so an outage never forces an *ad-hoc,
undocumented* bypass. Every break-glass use is logged, bounded, and reviewed
after the fact.

## Decision ladder (try in order)

1. **Rollback first.** If the incident was introduced by a recent deploy,
   prefer revision rollback — it needs no preflight:

   ```bash
   ./scripts/rollback-revision.sh   # Cloud Run service revision pin
   ./scripts/rollback.sh            # functions rollback helper
   ```

2. **Scoped health-functions deploy.** If the issue is limited to the health
   endpoints (e.g. the monitoring plane needs `sourceMetadata` parity):

   ```bash
   ./scripts/ops/deploy-health-functions.sh
   ```

3. **Full break-glass functions deploy** (the rest of this runbook).

## Preconditions

- [ ] A second person (or, if genuinely solo, a written incident note *before
      deploying*) has confirmed: incident is live, rollback is insufficient,
      and the fix commit is on `main` with green Fast Feedback + harness runs.
- [ ] The working tree is clean and on the exact commit to ship:
      `git status --porcelain` is empty; record `git rev-parse HEAD`.

## Procedure

```bash
# 1. Record the break-glass invocation BEFORE deploying.
COMMIT=$(git rev-parse HEAD)
gh issue create \
  --title "BREAK-GLASS functions deploy $(date -u +%Y-%m-%dT%H:%MZ)" \
  --label "P0 - Critical" --label "area: infra" \
  --body "Incident: <one line>. Commit: ${COMMIT}. Operator: $(git config user.name). Preflight bypassed: <which gate and why>."

# 2. Build + deploy functions only (no hosting, no rules).
npm ci --prefix functions && npm run build --prefix functions
npx firebase-tools deploy --only functions --project burnbar

# 3. Verify the deploy took.
curl -s https://us-central1-burnbar.cloudfunctions.net/healthReady | jq .version
gcloud functions describe <fixed-function> --project=burnbar \
  --format='value(updateTime)'   # must postdate the fix commit

# 4. Close the loop within 72h:
#    - the fix ships again through the NORMAL tag lane at the next release
#      (break-glass deploys are never the durable record), and
#    - the break-glass issue gets a postmortem comment and is closed.
```

## Invariants

- The break-glass issue is **opened before** the deploy, not after.
- Break-glass never ships anything that isn't already merged to `main` and
  green in CI — it bypasses *release ceremony*, never *code review or tests*.
- If the legal preflight (`requires_counsel_review`) is the blocker and the
  fix touches licensed surface (libsignal, vendored agent), counsel is
  notified in the same issue — the gate is being deferred, not waived.
- Two break-glass uses in 30 days means the normal lane is too slow — fix the
  lane (see `deploy-production.yml`), don't normalize the bypass.
