# Existing stable-tag dry-run recovery

Use this lane only when a stable `vX.Y.Z` tag was created before the two required
deploy dry-runs published their commit-status attestations. It repairs missing
evidence; it does not deploy, publish a GitHub Release, move a tag, or bypass the
normal release gates.

## Eligibility

Both `deploy-production.yml` and `deploy-cloud-run.yml` fail closed unless all
of these statements are true at dispatch time:

1. The event is `workflow_dispatch` and the selected ref is `main`.
2. The workflow dispatch SHA equals current `origin/main`.
3. The existing tag is stable SemVer, is an annotated tag object, peels to
   the full `candidate_sha`, and that tagged commit is reachable from current
   `origin/main`. The candidate may be an ancestor of current main because this
   recovery workflow itself lands after the immutable tag was created.
4. GitHub has no Release for the tag.
5. GitHub has no deployment for the exact tag, SHA, and `production`
   environment.
6. The current plane's exact status context is either absent or has exactly one
   legacy migration record:
   - `release-attestation/deploy-production/<tag>`
   - `release-attestation/deploy-cloud-run/<tag>`
   The one-time legacy exception must be a `success` created by
   `github-actions[bot]`, have a null `target_url`, and have the exact
   description `dry-run passed at <first 12 characters of candidate_sha>`.
   Multiple records, another creator, another description, a non-success state,
   or any non-null target URL are not replaceable.

The GitHub-state verifier is read-only. The dry-run resolver/build jobs do not
reference the `production` environment, production secrets, Google OIDC, or
provider credentials. The only write is the normal plane-specific commit status
after that plane's complete dry-run succeeds.

An unrelated proof or approval deployment at the same SHA does not disqualify
the candidate unless it is bound to the release tag and `production`
environment. A GitHub Release, matching production deployment, lightweight or
moved tag, prerelease tag, non-replaceable plane status, ambiguous API response,
or non-main dispatch is a hard stop. Do not delete evidence to make the lane
pass.

## Operator sequence

Inspect before dispatching:

```bash
tag=vX.Y.Z
main_sha="$(git ls-remote origin refs/heads/main | awk '{print $1}')"

git fetch origin "+refs/heads/main:refs/remotes/origin/main" --tags
test "$(git cat-file -t "refs/tags/$tag")" = tag
candidate_sha="$(git rev-parse "refs/tags/$tag^{commit}")"
git merge-base --is-ancestor "$candidate_sha" origin/main
test "$(git rev-parse origin/main)" = "$main_sha"
```

From the GitHub Actions UI, select **main** as the dispatch ref for each
workflow and supply:

```text
tag=vX.Y.Z
dry_run=true
candidate_sha=<full commit SHA peeled from the immutable existing tag>
```

Run only a plane whose exact status context is absent or is the single exact
legacy migration record described above. A failed run that never published its
status may be dispatched again after the failure is understood. After a
successful migration publishes the provenance-bound status, the legacy and new
records coexist, so the recovery gate will refuse every later overwrite.

Each published status targets the exact same-repository GitHub Actions run that
created it. Before any credentialed job, verification reads every raw status
page, evaluates only the newest record for each exact context, requires the
`github-actions[bot]` creator, and fetches the referenced run through the
Actions API. The run must bind the exact repository, plane workflow path,
`workflow_dispatch` event, `main` head branch, exact trusted control SHA,
completed-success conclusion, and deterministic run-name receipt containing the
exact plane, tag, candidate SHA, and control SHA. The status is read from the
exact candidate SHA; the recovery run itself executes from the newer main
commit that contains this lane. An older success cannot override a newer
failure, and a successful same-path run for another tag or candidate cannot be
reused.

After both exact contexts satisfy that provenance check, dispatch each real
retry from **main**, not from the immutable tag and not by rerunning the failed
tag-triggered run:

```text
tag=vX.Y.Z
dry_run=false
existing_tag_retry=true
candidate_sha=<full commit SHA peeled from the immutable existing tag>
```

The resolver first proves that the workflow SHA is exact current `origin/main`,
that the annotated tag still peels to `candidate_sha`, and that both dry-run
receipts were produced by successful same-path runs at that same trusted control
SHA. Only then does it check out or execute the immutable tag payload. The
resolver has no production environment, secrets, or OIDC permission.

For a Functions retry using `public-production-rollback`, protected
`domain-core-promotion` approval occurs only after the uncredentialed resolver
has verified current main, the immutable tag, both dry-run attestations, and the
candidate-bound release materials. The approval then gates the credentialed
`production` deploy; a rollback dry-run does not enter either protected
environment.

An existing-tag Functions retry cannot publish release evidence immediately:
eligibility requires that the GitHub Release does not exist, while
`domain-core-functions-release-evidence.yml` consumes that published Release
and its retained rollback assets. A successful retry therefore retains
`domain-core-functions-release-evidence-handoff-<tag>-<run>-<attempt>` with the
exact deploy coordinates. After the exact GitHub Release and retained rollback
assets are published, read those coordinates from the handoff artifact and
dispatch the evidence workflow from the immutable tag:

```bash
gh workflow run domain-core-functions-release-evidence.yml \
  --repo Imagine-That-Ai/BurnBar \
  --ref vX.Y.Z \
  --field deploy_run_id=<source deploy run ID> \
  --field deploy_run_attempt=<source deploy run attempt> \
  --field domain_core_profile=<public-production or public-production-rollback>
```

Do not dispatch this evidence workflow before the Release exists, and do not
substitute another deploy run, attempt, profile, tag, or commit.

For `v1.0.34`, never select the tag as the dispatch ref and never rerun the
original failed tag-triggered jobs. Those runs are permanently bound to the
older workflow/helper frozen in `v1.0.34`.

## HOLD conditions

Stop and investigate instead of changing history when any of these is true:

- the tag does not peel to `candidate_sha` or that commit is not reachable from
  current `origin/main`;
- the tag is lightweight, moved, deleted, recreated, or a prerelease;
- a GitHub Release or matching production deployment exists;
- either exact attestation context has any record other than the single exact
  replaceable legacy success, or has multiple records;
- current `main` moved after the dry-runs, so their trusted control SHA no
  longer matches the retry workflow SHA;
- GitHub cannot prove the release, deployment, or status absence;
- the workflow cannot be dispatched from `main`.

Never delete/recreate the tag, fabricate a status, remove a deployment, or
expose a production environment to make this recovery lane eligible.
