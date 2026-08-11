# OpenBurnBar Windows Operations Runbook

**Owner:** OpenBurnBar release engineering

**Last verified:** 2026-08-11

**Applies to:** Windows x64 and ARM64 source, CI, staging, signing, physical certification, and Microsoft Store flights

This is the day-two runbook for the Windows port. It is intentionally simpler
than the implementation plans: an agent should be able to read this file,
identify the current finish line, and run the next release without rediscovering
the process.

## 1. The answer in plain English

There are two different finish lines. Never merge them into one percentage.

| Finish line | Meaning | Current rule |
| --- | --- | --- |
| Source parity | The Windows product code implements the approved macOS feature set and passes the x64 and ARM64 automated gates. | Report from `WINDOWS_PARITY_LEDGER.yml` and current CI. |
| Release certification | One exact signed package passes physical performance, accessibility, staging cloud, safety, and private Store/update tests. | Report from the exact candidate's validated evidence bundle. |

Source parity can be complete while a release is still `NO-GO`. A signed build
is also not a release by itself. The release becomes `GO` only when every
required evidence gate for that exact artifact is `PASS`.

### Measured source-parity checkpoint

This is an automated source checkpoint for one exact commit. It is not a
signed-release claim, and it is not by itself the current release candidate:

- Exact measured commit: `8b07625eebe9db0bf0084e6a884becd6d8bcc72e`
- Merge source: PR #2203, independently approved and merged on 2026-08-10
- Source parity: 51/51 `Real`, with zero substituted, deferred, blocked, or
  authored rows
- Clean local certification: 65/65 commands passed
- Windows Full: run `31358055958` passed x64, ARM64, and the aggregate gate
- Windows engine: run `31358056003` passed x64 and ARM64
- Candidate export/foundation: run `31358681287` imported 13,535/13,535 files
  with zero mismatches and passed all nine foundation commands
- Distribution/MSIX: run `31354131189` passed
- Staging preparation: dry run `31358681447` verified all 969 checksums and
  skipped deployment
- Shared domain-core: run `31354131316` passed the exact same SHA across all
  required consumers
- Intended Windows release version: `1.0.39`
- Protected release tag: not created; `windows-v1.0.39` does not exist
- Release verdict: `NO-GO`

That commit is where those numbers were measured. It is not a standing claim
about `origin/main`: this documentation change and every later commit land on
top of it, so `main` moves past it. Step 1 requires `CANDIDATE_SHA` to equal
`origin/main` and Step 2 requires each dispatched run's `headSha` to equal
`CANDIDATE_SHA`, so the run IDs above are evidence for that one commit and never
transfer to a later head. Before the next candidate is tagged, re-run at the new
`origin/main` head: the parity ledger verifier, the version-consistency gate,
`pr-windows-full.yml`, `pr-windows-fast.yml`, and the Windows engine,
candidate-export, distribution/MSIX, staging dry-run, and shared domain-core
gates.

Five open external receipt groups block the release: physical x64 performance,
accessibility/display, the signed-in OAuth/App Check/physical TPM/CloudVault
staging protocol, paired media/Computer Use safety, and Store/update lifecycle.
The staging deployment and infrastructure portion passed on 2026-08-11; the
person-and-device protocol did not run. Physical ARM64 is a sixth open group
but is not blocking. Section 7 and
[`ALBERTO_PARITY_CHECKLIST.md`](ALBERTO_PARITY_CHECKLIST.md) both allow shipping
it as an explicit, uncertified beta limitation, so never hold a release waiting
for ARM64 hardware; state the limitation instead. Historical signed artifacts do
not satisfy any of these gates for the current exact source.

### Exact staging infrastructure checkpoint

This is current staging-infrastructure proof, not signed Windows release
certification:

- Candidate: `0b8c208537bcf7786ff43370ffb28d0d4becb0f4`, retained on
  open, unmerged PR #2208
- Trusted dispatch head: `b5f927866ede91795fa2dadb1f1f915e42b98ab5`
- Successful run:
  [31439802683](https://github.com/Imagine-That-Ai/BurnBar/actions/runs/31439802683),
  completed `2026-08-11T02:13:37Z`
- Scope: `dry_run=false`, Functions on, Hosting off, and exactly four approved
  selectors
- Result: Firestore/Storage drift and all 12 TTL checks passed; exactly four
  candidate-bound Node 22 Functions became active and denied anonymous calls
- Isolation: non-target staging, production, Hosting, and Azure state matched
  their saved pre-deploy fingerprints

This proves the bounded cloud deployment path. It does not replace the
signed-in OAuth, App Check, physical TPM, CloudVault,
offline/revocation/sign-out, secret-scan, and fixture-restoration protocol on
the exact signed Windows candidate. Step 3 contains the detailed receipt and
the reusable procedure.

### Historical signed-candidate checkpoint

This checkpoint is history, not a substitute for live verification:

- Source candidate: `48837746490b6468efa4dc06a476f305d496039c`
- Protected release tag: `windows-v1.0.38`
- Windows x64 and ARM64 full CI: passed in run `29674350739`
- Staging deployment: passed in run `29675617068`
- Signed release workflow: run `29676266545`
- Physical x64 retry for `windows-v1.0.38`: validator-clean `NO-GO`. Exact package integrity, native hardware identity, clean checkout, 20/20 cold launches, 20/20 warm launches, uninstall/reinstall, 300-second idle capture, and a 30-minute/1,800-sample soak passed with no crash or hang. Accessibility/display, the remaining interactive performance measurements, staging fixtures, paired-device safety, and private Store lifecycle receipts remain incomplete.
- Physical retry evidence ZIP SHA-256: `bf10318474556b1ea3f69b05831fa09dfc4f8b36ac9470fb113092ec4f7ed876`.
- Physical ARM64 certification: explicit beta limitation until qualifying hardware exists. Hosted ARM64 CI and an ARM64 VM are useful functional evidence, but neither is physical certification.

Before repeating any of those facts, refresh them with GitHub and the live
systems below.

## 2. What this costs

Prices change. Confirm the linked vendor pages during the quarterly review.

| Service | Expected Windows-specific cost | Guardrail |
| --- | ---: | --- |
| Azure Artifact Signing Basic | `$9.99/account/month`, including 5,000 signatures; overage is `$0.005/signature` | Azure monthly alert at `$20`; an alert is not a hard cap. |
| Azure TPM verifier on App Service F1 | `$0` while it remains within the Free tier limits | Verify the plan still says `F1` before every release. |
| GitHub Actions | `$0` for standard GitHub-hosted runners while this repository remains public | Recheck if the repository becomes private or uses larger runners. |
| Microsoft Store company registration and Microsoft-hosted distribution | `$0` under the current company-registration program | Do not buy a second account for routine releases. |
| Firebase/GCP staging | Usually `$0` or pennies at beta volume; usage based, not guaranteed free | GCP monthly alert at `$5`; zero minimum instances; seven-day build-image cleanup. |

Current pricing sources:

- [Azure Artifact Signing SKU and overage](https://learn.microsoft.com/en-us/azure/artifact-signing/how-to-change-sku)
- [Azure App Service Windows pricing](https://azure.microsoft.com/en-us/pricing/details/app-service/windows/)
- [GitHub Actions billing](https://docs.github.com/en/billing/concepts/product-billing/github-actions)
- [Microsoft Store company registration](https://blogs.windows.com/windowsdeveloper/2026/05/07/publish-to-microsoft-store-as-a-company-now-with-free-registration-and-faster-onboarding/)
- [Firebase pricing plans](https://firebase.google.com/docs/projects/billing/firebase-pricing-plans), [Remote Config pricing](https://firebase.google.com/docs/remote-config/pricing), [Firestore pricing](https://cloud.google.com/firestore/pricing), [Artifact Registry pricing](https://cloud.google.com/artifact-registry/pricing), and [Cloud Run pricing](https://cloud.google.com/run/pricing)

Budget alerts notify; they do not stop spend. The standing budgets are:

- GCP project `burnbar-staging`, budget `OpenBurnBar staging monthly guardrail`, `$5/month`.
- Azure Windows resources, budget `OpenBurnBar-Windows-Monthly-Guardrail`, `$20/month`.

At current beta scale, the practical fixed Windows cost is about `$9.99/month`.
The rest should normally remain inside free tiers. Investigate any budget alert
rather than assuming it is harmless.

## 3. System map

| Surface | Source of truth | What proves it |
| --- | --- | --- |
| Product/source parity | `docs/windows-port/WINDOWS_PARITY_LEDGER.yml` | Ledger verifier plus x64 and ARM64 Windows CI |
| Signed package | `.github/workflows/openburnbar-release-windows.yml` | Protected `windows-vX.Y.Z` tag, Authenticode signer/timestamp, checksums, SBOM, OpenVEX, Sigstore bundle |
| Staging cloud | `burnbar-staging` | Exact deployed source SHA, four scoped Functions, rules/storage drift check, TTL, reviewed Remote Config baseline |
| TPM verifier | Azure app `openburnbar-tpm-verifier-staging` in `rg-openburnbar-staging` | F1 plan, `/healthz`, unauthenticated `/verify` denial, source/artifact binding |
| Physical x64 | HP ENVY x360 Intel laptop | Validator-clean physical evidence and supplemental receipts |
| ARM64 | Hosted CI plus optional functional VM evidence | Never label VM or hosted-runner results as physical ARM64 proof |
| Store/update | Partner Center private flight | Private install, upgrade, repair, rollback, activation, signed-feed, coexistence receipts |

## 4. Non-negotiable rules for agents

1. Query the BurnBar mem0 project for navigation, then verify every release,
   security, build, schema, and deployment fact in committed files or the live
   system.
2. Use a clean worktree. Preserve unrelated work and never certify a dirty
   candidate checkout.
3. Bind source commit, tag, workflow run, package hash, signer, and evidence to
   the same candidate. Any mismatch is `FAIL`.
4. Never convert `BLOCKED` or `NOT_RUN` into `PASS`. Never hand-author a receipt
   that the validator is designed to generate.
5. Hosted CI proves builds and automated behavior. A VM proves virtualized
   behavior. Only declared physical hardware proves a physical gate.
6. Do not open or operate a local VM without the operator's explicit approval.
7. Staging means `burnbar-staging`. Never point a certification session at the
   production `burnbar` project.
8. Never print or commit OAuth codes, tokens, TPM claims, App Check tokens,
   authorization headers, private keys, or verifier secrets.
9. A private Store flight requires explicit operator approval. Public Store,
   update-feed, winget, or production rollout requires a separate explicit
   decision.
10. One failed release candidate stays failed forever. Fix source, create a new
    version, sign a new artifact, and rerun the complete affected gates.

## 5. Secrets and public client configuration

Secret values belong in GitHub Environments, GCP Secret Manager, or Azure App
Service settings. This runbook names them but never stores their values.

GitHub `staging` Environment:

- `STAGING_GCP_WORKLOAD_IDENTITY_PROVIDER`
- `STAGING_GCP_DEPLOY_SERVICE_ACCOUNT`
- optional `STAGING_SENTRY_DSN_FUNCTIONS`
- environment variable `STAGING_ENABLED=true`

GitHub `windows-release` Environment:

- the existing `WINDOWS_CODESIGN_*` Artifact Signing settings
- `WINDOWS_UPDATE_SIGNING_KEY`

GCP staging Secret Manager:

- `WINDOWS_TPM_VERIFIER_TOKEN`
- `WINDOWS_GOOGLE_OAUTH_CLIENT_ID`

The signed Windows app receives only these approved public client settings in
the authorized staging test process:

- `OPENBURNBAR_FIREBASE_PROJECT_ID`
- `OPENBURNBAR_FIREBASE_WEB_API_KEY`
- `OPENBURNBAR_GOOGLE_OAUTH_CLIENT_ID`
- `OPENBURNBAR_APPCHECK_APP_ID`

Do not set ID tokens, App Check tokens, vault keys, or verifier tokens as child
process environment variables. See [Staging](../ops/STAGING.md),
[TPM App Check](WINDOWS_APP_CHECK_TPM_PRODUCTION.md), and
[remote safety config](WINDOWS_REMOTE_SAFETY_CONFIG.md).

## 6. Release procedure

Set these once per release. Replace the examples; do not blindly reuse an old
candidate identity.

```bash
export REPO=Imagine-That-Ai/BurnBar
export VERSION=1.0.39
export TAG="windows-v${VERSION}"
```

### Step 1: establish a clean candidate

```bash
git fetch origin main --tags
git switch --detach origin/main
test -z "$(git status --porcelain)"
export CANDIDATE_SHA="$(git rev-parse HEAD)"
git merge-base --is-ancestor "$CANDIDATE_SHA" origin/main
bash scripts/ci/verify-windows-parity-ledger.sh
OPENBURNBAR_EXPECTED_WINDOWS_VERSION="$VERSION" \
  OPENBURNBAR_REQUIRE_CURRENT_WINDOWS_VERSION=1 \
  bash scripts/verify-version-consistency.sh
```

Do not tag if the version is inconsistent, the candidate is not on `main`, or
the relevant fast/full Windows checks are not green.

### Step 2: verify Windows CI on both architectures

```bash
test "$(git rev-parse origin/main)" = "$CANDIDATE_SHA"
gh workflow run pr-windows-full.yml --repo "$REPO" --ref main
gh workflow run pr-windows-fast.yml --repo "$REPO" --ref main
gh run list --repo "$REPO" --workflow pr-windows-full.yml \
  --event workflow_dispatch --branch main --limit 5
gh run list --repo "$REPO" --workflow pr-windows-fast.yml \
  --event workflow_dispatch --branch main --limit 5
gh run view <RUN_ID> --repo "$REPO" --json headSha,status,conclusion,jobs,url
```

Record both new run IDs immediately. Required result: each run's `headSha`
equals `CANDIDATE_SHA`; the full suite's x64, ARM64, and aggregate gate and the
fast suite's x64 and aggregate gate are all `success`. If `main` moved before
dispatch, select a clean candidate branch at the exact SHA instead of treating
a newer run as evidence for the older candidate.

### Step 3: deploy and verify isolated staging

First run the safe dry run, then deploy the reviewed four-function Windows
surface. The `staging` Environment approval is intentional.

The current release campaign completed this infrastructure step in run
`31439802683` for candidate
`0b8c208537bcf7786ff43370ffb28d0d4becb0f4`. Trusted job `93656565440`
deployed Firestore indexes/rules, Storage rules, and exactly the four selectors
below with Hosting off. Post-deploy drift and all 12 TTL checks passed. Live
readback found
revisions `issuewindowsappcheckchallenge-00003-lix`,
`mintwindowsappchecktoken-00003-tol`,
`getwindowsruntimesafetyconfig-00003-mov`, and
`submitdomaincoreshadowsamples-00003-sax`; all were `ACTIVE`, candidate-bound,
had no configured minimum instance count, and returned `401` to anonymous
callable POSTs. Saved non-target staging, production, Hosting, TTL, and Azure
fingerprints stayed unchanged. The 92-index production JSON hashed to
`8bcfaac80d623481b061737aca15d3de1ef5c03430b63d8aa676deec01570873`
with its final newline and
`793a9e4a66211992218506c39962809b6e5250d6e9d0b227d424bb1740fa8ac0`
without it. Firestore Admin audit logs recorded zero production index changes
during the staging window. The earlier zero-step job `93622386842` was
cancelled after receiving no runner, and the pending production Firestore guard
remained at zero jobs.

Keep the procedure below for every later exact candidate. A past approval or
successful run never authorizes a future staging mutation.

**Stop after the dry run until the operator explicitly types
`approve staging deployment`.** Approval of a pull request, merge, CI run, or
release-preparation task is not staging-deployment approval. Neither is the
`staging` Environment reviewer prompt: that prompt appears only after the
mutating dispatch has already been fired, so it cannot stand in for the phrase.

The two dispatches are deliberately kept in separate blocks. Never merge them.

Dry run. This block is safe to run as a unit:

```bash
gh workflow run deploy-staging.yml --repo "$REPO" --ref main \
  -f dry_run=true -f deploy_functions=true \
  -f function_targets='functions:issueWindowsAppCheckChallenge,functions:mintWindowsAppCheckToken,functions:getWindowsRuntimeSafetyConfig,functions:submitDomainCoreShadowSamples'
```

Read the dry run's result, then stop. Ask for the phrase and wait for it.

**Post-approval only. This dispatch mutates `burnbar-staging`.** Run it as a
single standalone command once the operator has typed
`approve staging deployment` for this exact candidate:

```bash
gh workflow run deploy-staging.yml --repo "$REPO" --ref main \
  -f dry_run=false -f deploy_functions=true \
  -f function_targets='functions:issueWindowsAppCheckChallenge,functions:mintWindowsAppCheckToken,functions:getWindowsRuntimeSafetyConfig,functions:submitDomainCoreShadowSamples'
```

After approval, verify the selected run rather than trusting the dispatch:

```bash
gh run view <STAGING_RUN_ID> --repo "$REPO" \
  --json headSha,status,conclusion,jobs,url
gcloud functions list --v2 --project burnbar-staging \
  --regions us-central1 --format='table(name,state,environment)'
gcloud firestore fields ttls list --project burnbar-staging
```

Required live checks:

- source SHA equals `CANDIDATE_SHA` on all four Functions;
- all four are active, have no configured minimum instance count (effective
  `minInstances=0`), and unauthenticated calls return `401`;
- Firestore/Storage drift checks and TTL checks pass;
- Remote Config equals the reviewed baseline after any kill-switch drill;
- Azure verifier `/healthz` returns `200` and unauthenticated `/verify` returns
  `401`;
- no secret appears in logs or evidence.

Azure verifier checks:

```bash
az webapp show --resource-group rg-openburnbar-staging \
  --name openburnbar-tpm-verifier-staging \
  --query '{state:state,host:defaultHostName,httpsOnly:httpsOnly}'
az appservice plan show --resource-group rg-openburnbar-staging \
  --name asp-openburnbar-staging-windows --query '{tier:sku.tier,name:sku.name}'
curl --fail --silent --show-error \
  https://openburnbar-tpm-verifier-staging.azurewebsites.net/healthz
```

### Step 4: create the protected release tag

Confirm the local author identity before creating an annotated tag. Never move
or recreate a published release tag.

**Stop for explicit operator approval before pushing the tag.** The current
Windows workflow does more than build a private candidate: after signing and
verification succeed, it publishes a public GitHub Release containing the
signed Windows release bundle, update-feed files, and immutable domain-core
evidence. Under rule 9 above, pushing `windows-vX.Y.Z` is therefore a public
release action. If public GitHub release approval has not been given, keep the
verified candidate on `main` and do not create or push the tag.

Certification precedes publication. Signing and publication are separable only
if the publication job can be held, so hold it before the tag exists:

- Verified 2026-08-10: the `windows-release` GitHub Environment has no
  protection rules, so a single tag push runs signing and public publication
  end to end with no second approval.
- Before pushing, add a required reviewer to the repository's
  `windows-release` Environment. Both `build-sign` and the publishing
  `domain-core-windows-release-evidence` job declare that environment, so each
  then waits for its own approval.
- Approve `build-sign` only. It produces the signed candidate as a workflow
  artifact for Step 5 and creates no release.
- Leave `domain-core-windows-release-evidence` pending until Step 7 and Step 8
  pass. Step 9 approves it. Before starting Step 7, confirm with
  `gh run view <RELEASE_RUN_ID> --repo "$REPO" --json jobs` that this job is
  still waiting and that no release exists at
  `repos/$REPO/releases/tags/$TAG`. If either check fails, the candidate is
  already public and rule 9 was breached; report it rather than continuing
  quietly.
- GitHub cancels a run whose deployment stays pending beyond its approval
  window (30 days at the time of writing) and publishes nothing. Re-dispatch
  `openburnbar-release-windows.yml` from `refs/tags/${TAG}` when the gates
  finally pass.

If that reviewer is not added there is no private signing path, and the honest
consequence is that the tag itself is the public release: hold the tag until
every Step 7 and Step 8 gate is `PASS`. Never push the tag expecting to delete
the release afterwards.

```bash
git config user.name
git config user.email
test "$(git rev-parse HEAD)" = "$CANDIDATE_SHA"
git tag -a "$TAG" -m "OpenBurnBar Windows ${VERSION} candidate ${CANDIDATE_SHA}"
git push origin "refs/tags/${TAG}"
```

This triggers `.github/workflows/openburnbar-release-windows.yml`. With the
publication job held it stops at a pending deployment after signing and
supply-chain verification; without the hold it runs straight through and
publishes the public GitHub Release described above. Either way it does not
authorize Partner Center, winget, production staging, or any wider rollout;
those remain separate explicit decisions.

### Step 5: verify the signed build

```bash
gh run list --repo "$REPO" --workflow openburnbar-release-windows.yml \
  --branch "$TAG" --limit 5
gh run watch <RELEASE_RUN_ID> --repo "$REPO" --exit-status
gh run view <RELEASE_RUN_ID> --repo "$REPO" \
  --json headSha,headBranch,status,conclusion,jobs,url

mkdir -p "/tmp/openburnbar-windows-${VERSION}"
gh run download <RELEASE_RUN_ID> --repo "$REPO" \
  --name "windows-release-v${VERSION}" \
  --dir "/tmp/openburnbar-windows-${VERSION}/release"
gh run download <RELEASE_RUN_ID> --repo "$REPO" \
  --name "windows-provenance-v${VERSION}" \
  --dir "/tmp/openburnbar-windows-${VERSION}/provenance"
```

Required release evidence:

- workflow `headSha` equals `CANDIDATE_SHA` and tag resolves to it;
- x64 and ARM64 portable ZIP, direct MSIX, and Store MSIX are present;
- package hashes match `checksums-windows-v${VERSION}.txt`;
- Authenticode status is valid, signer is exactly Imagine That AI LLC, and an
  RFC 3161 timestamp is present;
- both Swift resource bundles exist and are manifest-hashed;
- x64 hosted install/launch/uninstall/reinstall is green;
- Ed25519 feed self-verification, SPDX SBOM, OpenVEX, and every Sigstore bundle
  verify against the exact artifact digest.

These downloads come from the workflow run, not from a GitHub Release, so every
gate from here to Step 8 runs against a private signed candidate. Keep
`domain-core-windows-release-evidence` pending throughout. With that job held,
`gh run watch` never returns; stop watching once `build-sign` and `supply-chain`
are `success` and the release artifacts are downloadable.

The GitHub artifact expires after seven days. Copy the verified release and
provenance to the candidate's content-addressed evidence directory promptly.

### Step 6: prepare a removable-drive handoff

Use a new versioned directory. Never overwrite an earlier candidate or its
evidence.

```text
BurnBar-cert/windows-vX.Y.Z-final-handoff/
  START-HERE.txt
  HANDOFF.md
  HP-CODEX-PROMPT.txt
  VERIFY-TRANSFER.ps1
  release-artifact/
  provenance/
  staging-receipts/
  SHA256SUMS
```

The transfer verifier must hash every file after the copy. Staging bootstrap
settings may be included only in the separately protected handoff area; never
put token material or the TPM verifier token on the drive or in evidence.

### Step 7: certify on the physical Intel x64 laptop

The baseline runner compiles the exact candidate's three Rust libraries before
it runs the managed suite. The machine therefore needs PowerShell 7, Node.js
22, the .NET 8 and 10 SDKs, Visual Studio 2022 C++/Windows build tools, NASM,
and Rust 1.94.0 plus 1.96.0 with the matching MSVC target installed. For the
Intel laptop, verify the pinned Rust setup before starting:

```powershell
rustup toolchain install 1.94.0 --profile minimal --target x86_64-pc-windows-msvc
rustup toolchain install 1.96.0 --profile minimal --target x86_64-pc-windows-msvc
rustup run 1.94.0 rustc --version
rustup run 1.96.0 rustc --version
nasm -v
node --version
dotnet --list-sdks
```

For a physical ARM64 campaign, install
`aarch64-pc-windows-msvc` on both pinned Rust toolchains instead. Missing or
wrong-architecture native libraries are certification failures, not skips.

Run from a normal signed-in PowerShell 7 desktop session, not a Codex sandbox,
service session, VM, or compatibility layer. Preserve any pre-existing package.

```powershell
$Repo = 'C:\BurnBar-cert\windows-vX.Y.Z\candidate'
$Harness = 'C:\BurnBar-cert\windows-vX.Y.Z\harness'
$Release = 'C:\BurnBar-cert\windows-vX.Y.Z\release'
$Evidence = 'C:\BurnBar-cert\windows-vX.Y.Z\physical-x64'

pwsh "$Harness\scripts\windows-port\new-physical-hardware-attestation.ps1" `
  -Operator Alberto -ExpectedArchitecture x64 `
  -OutputPath "$Evidence\hardware-attestation-x64.json"

pwsh "$Harness\scripts\windows-port\run-physical-release-certification.ps1" `
  -RepoRoot $Repo -OutputDir "$Evidence\baseline" -Platform x64 `
  -ArtifactManifestPath "$Release\signed-artifact-x64.json" `
  -HardwareAttestationPath "$Evidence\hardware-attestation-x64.json" `
  -PhysicalHardware

node "$Harness\scripts\windows-port\validate-release-certification-evidence.mjs" `
  "$Evidence\baseline" --write-sums `
  --expected-commit '<CANDIDATE_SHA>' `
  --expected-harness-commit '<HARNESS_SHA>'
```

Use `new-release-certification-supplemental-receipt.ps1 -Initialize` for each
gate, perform every assertion from
`scripts/windows-port/release-certification-protocols.json`, then finalize the
receipt only when every assertion genuinely passes. Rerun the baseline with
`-SupplementalReceiptDirectory` and validate the final bundle.

The physical x64 campaign must cover:

- install, uninstall, reinstall, cold and warm launch;
- dashboard content visible with native backdrops enabled;
- the permanent `640x720` route scenario with no clipping;
- named UI Automation controls, keyboard-only operation, Narrator, focus, high
  contrast, reduced motion/transparency, 100/150/200 percent DPI, and mixed-DPI
  monitors when available;
- cold/warm/surface latency, CPU, private memory, GPU, disk writes, frame
  pacing, sleep/wake, Explorer restart, and the mandatory 30-minute soak;
- signed-in staging OAuth PKCE, physical TPM App Check, invalid-token denial,
  CloudVault round trip/replay/conflict/sign-out cleanup;
- camera, microphone, screen share, transfer interruption, Mark of the Web,
  exact approval, protected-target denial, panic paths, watchdog, remote kill
  switches, phone authorization, and replay denial.

### Step 8: run a private Store/update flight

Only after the physical candidate is usable and the operator explicitly
authorizes a private flight:

1. Reserve/confirm the exact Partner Center product identity.
2. Upload the exact Store MSIX from the verified release bundle.
3. Restrict availability to the private test audience.
4. Install from the Store, upgrade from the prescribed predecessor, repair,
   uninstall/reinstall, and test launch/protocol/file/toast/startup activation.
5. Verify valid, tampered, downgrade, and offline update-feed behavior.
6. Verify Store and direct-download identity coexistence.
7. Finalize the `store-update-lifecycle` receipt and rerun the evidence
   validator.

Private-flight success is not permission for public submission.

### Step 9: publish the public GitHub Release

This is the last step, not part of Step 4. Run it only after Step 7 and Step 8
are `PASS` and the Section 7 table reads `GO` for this exact candidate.

1. Re-check every row of the Section 7 table against this candidate's validated
   evidence bundle. Physical ARM64 may be an explicit beta limitation; no other
   required gate may be `FAIL`, `BLOCKED`, or `NOT_RUN`.
2. Get the operator's explicit public-release approval. Tag approval, the
   `staging` Environment prompt, and private-flight authorization are each a
   different decision and none of them is this one.
3. Approve the pending `domain-core-windows-release-evidence` deployment. It
   publishes the non-prerelease `windows-vX.Y.Z` GitHub Release, created with
   `latest=false`, carrying the signed release bundle, update-feed files, and
   immutable domain-core evidence.
4. Confirm the published release tag resolves to `CANDIDATE_SHA` and the
   published asset digests match the checksums verified in Step 5.

Publishing this release still does not authorize Partner Center public
submission, winget, or production rollout.

## 7. Definition of done

A Windows release is `GO` only when this table is true for one exact candidate:

| Gate | Required release result |
| --- | --- |
| Source parity ledger | `46 Real / 0 Substituted / 0 DeferredApproved / 0 Blocked`, or the current stricter ledger contract |
| Windows automated checks | x64, ARM64, and aggregate `PASS` at the candidate SHA |
| Signed release | checksums, exact signer/timestamp, lifecycle, feed, SBOM, OpenVEX, and Sigstore `PASS` |
| Physical x64 performance | `PASS` |
| Accessibility/display | `PASS`; an unavailable physical setup remains `BLOCKED` and keeps the candidate `NO-GO`, never silently waived |
| Staging cloud | `PASS` for both the bounded deployment and the exact signed candidate's physical signed-in OAuth/App Check/TPM/CloudVault protocol |
| Media/Computer Use safety | `PASS` |
| Store/update lifecycle | `PASS` in an authorized private flight |
| Evidence validator | `PASS` with no identity or secret-leak error |
| Physical ARM64 | `PASS` when hardware exists; until then publish it as an explicit beta limitation, not as certified |

If any required non-waived gate is `FAIL`, `BLOCKED`, or `NOT_RUN`, the release
verdict is `NO-GO`.

The publication order is fixed by that verdict. A `windows-v*` tag may be signed
while the verdict is still `NO-GO`, because the physical and Store gates need a
signed artifact; the public GitHub Release is approved only once this table
reads `GO`. Physical ARM64 is the single waivable row, and waiving it means
stating the beta limitation in the release notes, never labelling it certified.

## 8. Rollback and incident response

For a suspected security or safety defect:

1. Set the staging or production Remote Config safety defaults to closed:
   `computer_use_kill_switch=true`, `media_kill_switch=true`, and privileged
   feature flags `false`.
2. Confirm active Computer Use stops within 60 seconds and new broker dispatch
   is denied after the maximum 90-second lease.
3. Halt the Store flight and any update-feed publication.
4. Preserve logs and content-addressed evidence after redaction. Do not delete
   the failed candidate's record.
5. Revert Functions or the Azure verifier to the last verified source-bound
   deployment if the incident is server-side.
6. Fix through a reviewed PR, create a new version, and repeat the affected
   release gates from the beginning.

For an unexpected bill:

1. Identify the service and project/resource group from the billing export.
2. Confirm Azure verifier still uses F1 and Functions still use zero minimum
   instances.
3. Confirm Artifact Registry `gcf-artifacts` still deletes images older than
   seven days.
4. Check for request abuse before disabling a security service.
5. Use the product kill switches first if spend is caused by an unsafe public
   workload; do not delete evidence or signing resources during triage.

## 9. Maintenance schedule

### Every PR touching Windows

- Update behavior tests and the parity ledger when the product surface changes.
- Run the cheapest affected suites locally.
- Require Windows fast/full CI according to the changed paths.
- Use the software-factory PR loop; do not bypass broken checks as routine.

### Every Windows release

- Follow Section 6 in order.
- Record exact commit, tag, workflow run, package hashes, signer/timestamp,
  staging deployment identities, device identity, and evidence ZIP hash.
- Restore staging Remote Config to the reviewed baseline after drills.
- Remove only the exact test package installed by the run.

### Monthly

- Review the GCP `$5` and Azure `$20` budget alerts and actual invoices.
- Confirm Azure verifier is running on F1 and `/healthz` is green.
- Confirm Functions have `minInstances=0`, TTL is active, and Artifact Registry
  cleanup is present.
- Verify no stale test OAuth credentials or staging packages remain on the HP.

### Quarterly and before a public launch

- Recheck vendor pricing and free-tier limits.
- Rotate/test deployment credentials without exposing their values.
- Review Windows, .NET, Swift, WebView2, WinAppSDK, Azure signing, Firebase, and
  Partner Center lifecycle changes.
- Perform a rollback drill and verify all kill paths.
- Obtain physical ARM64 hardware or keep the limitation explicit.

## 10. Lessons already paid for

Do not regress these fixes:

- A `coreclr.dll` illegal-instruction report was caused by omitted Swift
  resource bundles, not the CPU or .NET. Both Swift bundles must be staged,
  manifest-hashed, and exercised by the published-layout parser smoke test.
- A valid signature and successful installation did not make `v1.0.37` usable.
  WebView2/Win2D airspace covered the dashboard; native composition, routed
  screenshots, accessible names, and `640x720` layout are permanent gates.
- Firebase Remote Config may omit the concurrency ETag unless REST requests
  advertise gzip. The staging fixture publisher must send
  `Accept-Encoding: gzip` on GET and PUT, reuse the exact returned ETag, and
  must never fall back to `If-Match: *`.
- Portable and installed layouts must match their manifests exactly. A hash or
  size mismatch is a release failure.
- First-time staging deployments may require Google APIs and IAM setup, but
  scoped deployment must stay allowlisted and source-bound afterward.
- Runtime safety is fail-closed: missing/stale/malformed config, sign-out, app
  exit, or App Check loss must revoke the broker lease and stop privileged work.

## 11. Required agent status format

Every agent handoff must use this compact format:

```text
WINDOWS STATUS
Source parity: <percent/status and exact CI evidence>
Release certification: <percent/status and exact candidate>
Candidate: <tag, commit, workflow run, artifact SHA-256>
Passed: <short list>
Failed: <short list>
Blocked/not run: <short list>
Physical ARM64: <PASS or explicit beta limitation>
Production/public systems changed: <yes/no and authorization>
VM used: <yes/no; if yes, state approval and what it can prove>
Cost change: <monthly fixed and variable change>
Next action: <one concrete action and owner>
```

Suggested prompt for a fresh release agent:

```text
Read AGENTS.md and docs/windows-port/WINDOWS_PORT_OPERATIONS_RUNBOOK.md. Query
the BurnBar mem0 project for navigation, then verify every release fact in the
repo or live system. Work from a clean worktree. Continue the current Windows
release end to end through source-bound x64+ARM64 CI, isolated staging, signed
artifacts and provenance, removable-drive handoff, physical Intel x64 evidence,
authorized staging/safety protocols, and an explicitly authorized private Store
flight. Fail closed: never turn BLOCKED into PASS, never call VM evidence
physical, never expose secrets, never touch production or a public rollout
without explicit approval, and never open a VM without operator approval. Use
the required WINDOWS STATUS format at every handoff.
```
