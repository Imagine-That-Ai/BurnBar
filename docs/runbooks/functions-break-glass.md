# Functions break-glass deploy (emergency hotfix lane)

**When to use:** A production incident in Cloud Functions needs a forward fix
*now*, and the normal tag-driven `deploy-production.yml` lane is blocked — by
the legal release preflight (`requires_counsel_review`), a runtime-readiness
gate, or CI itself being down.

**When NOT to use:** Anything that can wait for a tag. The preflight gates are
deliberate controls; this lane exists so an outage never forces an *ad-hoc,
undocumented* bypass. Every break-glass use is logged, bounded, and reviewed
after the fact.

## The deploy ancestor guard (Wave 0 — W0-4)

`prepare-functions-deploy` runs `scripts/ci/check-deploy-ancestor-guard.sh` before
anything is deployed: the **live deployed commit** (served by the healthLive
endpoint from the existing `functions/src/sourceMetadata.ts` GIT_SHA metadata)
must be an **ancestor** of the release commit, or a committed bootstrap receipt
must exist. This is the mechanical protection behind the #2195 postmortem
finding — production was once deployed from an uncommitted working tree with no
sha stamp, and deploying main afterwards silently **regressed live production
fixes**.

**The first tag deploy after the guard lands WILL trip it** — that is the
honest signal, not a bug. When it trips:

1. Land **human queue item 11**: a fresh, stamped deploy that re-anchors
   production (the guard then passes for every later release). This is the
   permanent fix.
2. Until that lands, deploy under the committed bootstrap receipt
   `config/deploy-regression-receipts/<date>.json` — a dated, signed,
   **expiring** acknowledgment that production is knowingly ahead of the
   stamped lineage (`2026-09-02.json` is the Wave-0 bootstrap; expires
   30 days out). Receipts are re-acknowledged by hand; an expired or malformed
   receipt fails closed, never waves through.
3. Break-glass exception: if production must move NOW and the guard blocks a
   legitimate hotfix, this lane's decision ladder above applies — and the
   receipt you then commit must say exactly which fix production carries that
   the release lineage lacks.

Self-test (offline, no GCP): `bash scripts/ci/check-deploy-ancestor-guard.sh --self-test`.

### Receipt schema and binding

`config/deploy-regression-receipts/<date>.json`:

```json
{
  "date": "2026-09-02",
  "kind": "allow-regression-bootstrap",
  "reason": "why production is knowingly ahead of the stamped lineage",
  "acknowledgedBy": "who",
  "liveSha": null,
  "releaseSha": "optional 40-hex release commit this receipt is limited to",
  "expiresOn": "2026-10-02"
}
```

A receipt authorizes exactly one transition. `liveSha: null` is the bootstrap
receipt: it authorizes a deploy **only while production reports no source
commit** (the #2195 condition), and it is checked before the unstamped refusal
so the first stamped deploy can ship. The moment production reports a source
commit, a bootstrap receipt authorizes nothing — including the copy embedded in
an older tag. A receipt with `liveSha: <sha>` authorizes deploys only while
production's live commit is exactly that sha (optionally only for `releaseSha`).
The deploy lane stages the guard script **and the receipts directory** from the
trusted current-main checkout before it resolves the release tag, so an
existing-tag retry of an older tag still runs the guard, and deleting a receipt
on main revokes it.

### Scoped deploys are prohibited

The guard proves ancestry for the fleet identity production reports through
`healthLive` (`source.commit`). A scoped deploy (`firebase deploy --only
functions:<name>`, `scripts/ops/deploy-health-functions.sh`,
`scripts/deploy-opentimestamps-verifier.sh`) replaces one function's identity
without moving that report, so a later retry could roll that function back while
the guard passes. Those scripts refuse the production project unless
`OPENBURNBAR_ACKNOWLEDGE_SCOPED_PROD_DEPLOY=1` is set, and any acknowledged scoped
deploy must be followed by a full stamped deploy to re-anchor the fleet.

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
