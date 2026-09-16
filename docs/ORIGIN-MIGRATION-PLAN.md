# Imagine That — GitHub → Cursor Origin migration plan

> **Status:** Plan only. No code, config, workflow, remote, or publication is changed by this document.
> **Requested:** Alberto, 2026-08-17 14:25 CT (ALL HANDS)
> **Written:** 2026-08-17, from live evidence gathered the same day
> **Scope:** `Imagine-That-Ai/BurnBar`, `Imagine-That-Ai/imaginethat-llc`, and the rest of the org
> **Seats available:** three Cursor Ultra subscriptions

---

## 0. Verdict first

**Origin cannot host the Imagine That ship pipeline today, and a hard cutover this week would take both live products off the air.** Origin launched in early beta *today* (2026-08-17). It is a real git host with real pull requests. It has **no CI, no releases, no artifact storage, no package registry, no static site hosting, no secret storage, and no public repository visibility.** `Imagine-That-Ai/BurnBar` is a public repo whose entire value chain is release artifacts, notarized DMGs, an npm package, and public download URLs. Every one of those depends on a capability Origin does not have.

**But the deeper finding is that GitHub was not the only thing that broke today.** The v1.0.35 release run failed on **two** jobs. One was GitHub's fault (an Actions artifact API returned `HTTP 503`). The other was ours: a brittle test in `functions/scripts/test-hermes.mjs` asserts on the literal source text of `firestore.rules`, and a refactor to a local alias broke the match. **That gate is still red right now, on `main`, and it will block the 1.0.35 cut on any host.** Migrating to Origin would not have shipped 1.0.35 today.

So the plan is deliberately ordered to put value before migration:

| Phase | What it buys | Migration content |
|---|---|---|
| **A. Unblock the two live ships** | 1.0.35 and CubeLove ship | none |
| **B. Cut GitHub out of the customer path** | An outage stops being a customer-visible event | none |
| **C. Reduce GitHub-API blast radius in CI** | An outage stops being a ship-blocking event | none |
| **D. Stand Origin up read-only** | Origin becomes real, reversibly | mirror only |
| **E. Prove Origin can carry a macOS release** | Go/no-go on cutover, with evidence | spike |
| **F. Cut over what Origin can actually carry** | Real migration, per repo | cutover |

Phases A–C are worth doing **even if Origin is never adopted**, and they are exactly the work that makes a later cutover safe. Only three packets in Phase A–D touch a live pointer, all of them intended ship actions and all ATC-gated (§8); **no Origin packet touches one at all**.

**One definition governs the whole plan** (§4.5): a lane counts as "off GitHub" only when it completes with `api.github.com` and `github.com` blocked at the network layer. Moving the repo is not migration, and Depot or Buildkite on Origin **still run the existing GitHub Actions** — so re-hosting a workflow that calls `api.github.com` changes the executor, not the dependency.

**Authoritative inventory:** §1.4 (BurnBar) and §1.5 (CubeLove) reproduce the CI Steward lists. Nothing is added to them. Two live CubeLove blockers are carried in §1.5 and must be respected before any CubeLove work: do not approve production-cutover on run `32051454244` att4, and do not merge `master` while that run is alive.

---

## 1. Evidence base

Everything below is either **FACT** (verified today, with the URL or command that proves it), **INFERENCE** (reasoning from facts, labelled), or **UNKNOWN** (say so and stop). Cursor Origin shipped hours ago; most third-party writing about it is stale by one day and describes a waitlist. Only `cursor.com/docs/origin/*` and the launch changelog are treated as authoritative here.

### 1.1 How to re-verify this document

These are read-only. None of them mutate anything.

```bash
# Origin surface
curl -s -o /dev/null -w '%{http_code}\n' https://cursor.com/docs/origin        # 200
curl -s -o /dev/null -w '%{http_code}\n' https://cursor.com/docs/api/origin.md # 404 (reference not published)
curl -s https://api.cursor.com/v1/origin/repos/example/example                 # 401, route exists

# GitHub incident
curl -s https://www.githubstatus.com/api/v2/status.json

# BurnBar live customer path
curl -s https://downloads.burnbar.ai/latest-macos.json
curl -s https://downloads.burnbar.ai/appcast.xml
curl -s https://registry.npmjs.org/openburnbar | python3 -c 'import json,sys;print(json.load(sys.stdin)["dist-tags"])'

# CubeLove live deploy pointer
curl -s https://cubelove.ai | grep -E 'release-sha|site-build-target|firestore-database'

# The red gate (run inside the repo)
rg -n 'relayLink' functions/scripts/test-hermes.mjs firestore.rules
```

### 1.2 The GitHub incident, 2026-08-17

**FACT** — Source: `githubstatus.com` Statuspage API v2, read at 19:28Z and again at 19:44Z.

- Incident **"Incident with GitHub.com"**, impact `critical`, opened **13:40:03Z**, **still unresolved** at the time of writing (~6 hours).
- Page status: indicator `major`, description **"Partial System Outage"**.
- Components attached: API Requests, Actions, Copilot, Git Operations, Issues, Pages, Pull Requests, Webhooks.
- Peak impact, quoted from the 14:04Z update: *"We are experiencing high error rates around 20% for web experiences and api traffic. Archive downloads and raw repository content downloads are experiencing an approximate 50% error rate. SAML and OIDC authentication, SCIM, and Team Sync are also impacted."*
- Git Operations degraded ~15:21–16:59Z, regressed 17:30–18:23Z. Latest update: *"continuing to investigate sporadic authentication failures."*

**Why the download detail matters:** "archive downloads and raw repository content downloads at ~50% error rate" is precisely the path our live macOS updater uses. See §3.2.

### 1.3 Org inventory — what we can actually see

**FACT** — `gh api orgs/Imagine-That-Ai/repos?per_page=100&type=all` returns exactly two repositories:

| Repo | Visibility | Role |
|---|---|---|
| `Imagine-That-Ai/BurnBar` | **public** | Flagship monorepo: Mac app, daemon, iOS, Android, Windows, Linux, Functions, website, extension |
| `Imagine-That-Ai/openburnbar-cursor-plugin` | **public** | Thin mirror repo; Cursor Marketplace reads this git URL to distribute the plugin |

**FACT** — `Imagine-That-Ai/imaginethat-llc` returns **HTTP 404** to this workspace's credential. `gh api installation/repositories` reports `total_count: 1` — the token is a GitHub App installation token scoped to `Imagine-That-Ai/BurnBar` only.

**Resolved by §1.5** — CI Steward confirms the CubeLove repository is **private** and factory-attested, which explains the 404: a single-repo installation token cannot see it. A 404 was never evidence of non-existence.

**Still UNKNOWN** — the repository's exact owner/name as addressable by a credential that can read it, and everything inside it. **Do not infer the slug**, and do not derive an Origin namespace from it (§2.1). See §10-U1.

**INFERENCE** — The org itself is small (two visible repos). The "what else in the org blocks a ship" question (§5.4) is therefore answered mostly by *non-repo* assets: DNS, Cloudflare R2, Firebase projects, npm, Apple, and Play. Those are the real single points of failure, and none of them are GitHub.

### 1.4 CI Steward inventory — BurnBar (authoritative)

Supplied by CI Steward on 2026-08-17 and **authoritative for this plan**. Nothing is added to these lists. Where an item was independently verified from this workspace, that is noted.

**FACT** — 84 workflow files (independently verified: `ls .github/workflows/*.yml | wc -l` → `84`).

**FACT** — `has_pages=false` (independently verified: `gh api repos/Imagine-That-Ai/BurnBar --jq .has_pages` → `false`). **The website is Firebase Hosting via `deploy-hosting.yml`, not GitHub Pages.** This corrects an assumption worth stating plainly: Origin's lack of a Pages equivalent costs BurnBar **nothing**, because BurnBar never used Pages. See §2.2.

**Must-ship workflows** — the set whose failure stops a ship:

| Workflow | Ships |
|---|---|
| `deploy-production.yml` | Cloud Functions (tag `v*` / trusted `main` retry) |
| `deploy-hosting.yml` | `burnbar.ai` + `app.burnbar.ai` |
| `deploy-firestore.yml` | Firestore rules and indexes |
| `deploy-cloud-run.yml` | Cloud Run services |
| `release.yml` | macOS DMG/ZIP, iOS, Android AAB, GitHub Release, R2 promote |
| `openburnbar-release-windows.yml` | Windows release |
| `linux-release.yml` + `linux-release-promote.yml` | Linux release and promotion |
| `publish-google-play.yml` | Google Play |
| `npm-publish-openburnbar.yml` | npm `openburnbar` |
| `public-macos-download-trust.yml` | Live macOS download trust verification |
| `public-linux-download-trust.yml` | Live Linux download trust verification |

**Native gates:** `pr-native-fast.yml`, `app-pr-gate.yml`, `daemon-pr-gate.yml`, `android-pr-gate.yml`, `linux-pr-gate.yml`, `burnbar-ci-gate.yml` (**polls `api.github.com`**), `fast-feedback.yml`.

**Blast radius if `api.github.com` dies — hard stop on:**

- New Actions runs
- Merge queue
- Required checks
- `burnbar-ci-gate`
- Deploy / Hosting / Release attestations
- Artifacts
- GitHub Release
- CubeLove Trusted Deploy
- Pages

**Already-live sites stay up.** That is the single most important line in the inventory, and it is the seam this plan exploits: serving survives, *shipping* does not. Phase B extends the same property to the macOS download path, which today does **not** have it (§3.3).

**FACT — Origin CI is not a failover today.** Depot and Buildkite on Origin **still run existing GitHub Actions**. Re-hosting the same workflows on a different executor is not independence from GitHub, and it is not a disaster-recovery path. Any plan that treats "Depot on Origin" as an outage answer is wrong. This constrains §5.2 and is the reason for the acceptance test in §4.5.

### 1.5 CI Steward inventory — CubeLove (authoritative)

**FACT** — `Imagine-That-Ai/imaginethat-llc` is **private** and **factory-attested**. Its `deploy.yml` contains **Trusted Deploy** and **Web Deploy**, and has **no `workflow_dispatch`**.

**Consequence, and it is a big one:** with no `workflow_dispatch`, CubeLove has **no manual re-trigger**. Deploys are event-driven only. Combined with the standing "do not rerun whole workflows" directive, a failed CubeLove deploy cannot simply be replayed — recovery requires a new qualifying event or an operator-side deploy outside Actions. This makes the break-glass path in §5.2 a requirement rather than a nicety.

**Live blockers, in force now:**

1. `deploy.yml`'s **CubeLove Pages step is missing three cutover env vars** (Claude review). The three variables are **UNKNOWN** to this workspace (§10-U11).
2. **Do not approve production-cutover on run `32051454244` attempt 4.**
3. **Do not merge `master` while that run is alive.**

**FACT** — run `32051454244` is not readable from this workspace: `gh api repos/Imagine-That-Ai/imaginethat-llc/actions/runs/32051454244` returns **HTTP 404**, consistent with §1.3. It is recorded here by id so the blocker is auditable, not so it can be inspected.

**INFERENCE (labelled, not asserted)** — BurnBar has `has_pages=false`, yet "Pages" appears in the `api.github.com` hard-stop list and CubeLove's `deploy.yml` has a Pages step. By elimination the org's Pages exposure is CubeLove's. Whether that step is GitHub Pages or a differently-named build step is **UNKNOWN** (§10-U12). **This matters because it can invert the per-repo recommendation:** if CubeLove genuinely publishes through GitHub Pages, then Origin — which has no Pages equivalent — cannot host CubeLove's publish step either, and CubeLove stops being the easy cutover candidate. Resolve before Phase F.

---

## 2. Question 1 — What Origin is today, and what it cannot do yet

Origin launched **today**. Every documentation page carries this banner:

> *"Origin is currently released in early beta. You can create repos, push and pull with git, mirror from GitHub, browse and search code, open and merge pull requests, and share with your Cursor team."*
> — [cursor.com/docs/origin](https://cursor.com/docs/origin)

### 2.1 What Origin has

| Capability | State | Evidence |
|---|---|---|
| **Git hosting** | Yes, HTTPS | `git clone https://origin.cursor.com/{owner}/{repo}.git` — [docs/origin/git](https://cursor.com/docs/origin/git) |
| **Web browse/search** | Yes | `cursor.com/codebase/{owner}/{repo}` — [docs/origin](https://cursor.com/docs/origin) |
| **Pull requests** | Yes | Tabs: Activity, Commits, Checks, Files Changed — [docs/origin/pull-requests](https://cursor.com/docs/origin/pull-requests) |
| **Review threads + approvals** | Yes | `origin pr review --approve`, threads with resolution state |
| **Auto-merge** | Yes | `origin pr merge --auto` |
| **Branch protection** | Partial | Settings → **Rules and Protections**; *"Available controls may expand during early beta"* — [docs/origin/settings](https://cursor.com/docs/origin/settings) |
| **Checks surface** | Yes (reporting only) | *"check runs and status for the branch"* |
| **REST API** | Yes, undocumented | `api.cursor.com/v1/origin`; `/repos/{owner}/{repo}` returns `401` unauth (verified) |
| **CLI** | Yes | `origin`, installed from `downloads.cursor.com/origin/install.sh` (verified `200`) |
| **GitHub mirroring** | Yes, bidirectional PRs | [docs/origin/mirror-github](https://cursor.com/docs/origin/mirror-github) |
| **Cloud agents + Automations** | Yes | Push and PR triggers — [docs/origin/integrations](https://cursor.com/docs/origin/integrations) |

**Slug semantics — do not guess.** The `{owner}` is a **codebase name your team claims**, not a mirror of the GitHub org:

> *"The codebase name is the namespace your repositories live under, the `{owner}` in `https://cursor.com/codebase/{owner}/{repo}`."*

`Imagine-That-Ai` on GitHub implies **nothing** about the Origin namespace. Until a human claims the name at `cursor.com/codebase`, the Origin owner slug is **UNKNOWN** and every Origin URL in this plan is written as `{owner}`.

### 2.2 What Origin cannot do yet — the blocking list

Each of these was verified as absent from the entire `cursor.com/docs/origin/*` tree, not merely "not found."

| Missing capability | Consequence for Imagine That | Severity |
|---|---|---|
| **No public visibility.** Only **Internal** and **Private**. | `BurnBar` is a public AGPL repo. Origin cannot host it as public. AGPL corresponding-source obligations and the open-source posture both assume anonymous read. | **Blocker** |
| **No CI.** No runners, no workflow format. CI is delegated to Depot or Buildkite apps. | 84 GitHub Actions workflows have no destination. | **Blocker** |
| **Depot and Buildkite work on Origin-hosted repos only, not mirrors.** *"Mirrored repos keep CI on GitHub."* ([docs/origin/settings](https://cursor.com/docs/origin/settings)) | You cannot mirror for safety *and* get Origin CI. It is one or the other. | **Blocker** |
| **Depot CI has no macOS.** *"Depot CI doesn't provide sandboxes for Arm, macOS, or Windows."* ([depot.dev/docs/ci/overview](https://depot.dev/docs/ci/overview)) | The entire release lane is `macos-26`: Xcode build, Developer ID signing, notarization, stapling. | **Blocker** |
| **No releases, no artifacts, no package registry.** Zero occurrences of `artifact`, `release asset`, `registry` in Origin docs. | No home for DMG, ZIP, SBOM, Sigstore bundles, checksums, appcast. No npm equivalent. | **Blocker** |
| **No static site hosting.** | No Pages equivalent. **For BurnBar this costs nothing** — `has_pages=false` and the website is Firebase Hosting via `deploy-hosting.yml` (§1.4). It may still block **CubeLove**, whose `deploy.yml` has a Pages step (§1.5, §10-U12). | **N/A for BurnBar; possible blocker for CubeLove** |
| **No secret storage.** Mirroring explicitly excludes *"GitHub Actions workflows and secrets."* | All 58 Actions secrets and 6 environments need a new home. | **Blocker** |
| **No Issues.** | Issue history is not migrated and has no destination. | Medium |
| **CODEOWNERS not documented.** | Review routing must be manual or rebuilt. | Medium |
| **API reference is a 404.** `cursor.com/docs/api/origin.md` returns HTTP 404 (verified) while three docs pages link to it. | Cannot design automation against Origin's API. Webhook events, scopes, and check-run reporting are all unspecified. | **High** |
| **Bugbot does not support Origin.** [docs/bugbot](https://cursor.com/docs/bugbot) lists GitHub, GitLab, Bitbucket only. | Loses one automated review lane. Automations on PR events are the substitute, not an equivalent. | Medium |
| **Documented UI churn.** *"The Permissions and Rules and Protections UIs are being redesigned."* ([docs/origin/settings](https://cursor.com/docs/origin/settings)) | Anything automated against them now is expected to break. | Medium |

**The pivotal unknown** is whether Origin exposes a check-run reporting API so an external macOS builder could post required status onto an Origin PR. That answer lives in the API reference, which is 404. Until it is published, **Origin cannot be a merge gate for a macOS product.** (§10-U2)

### 2.3 The one capability that is genuinely attractive today

Mirroring plus cloud agents. Origin gives agents first-class in-repo access with browse, search, PR review, and push, and Automations fire on push and PR events. That is real value and it is available **without** giving up GitHub, because a mirrored repo keeps GitHub as source of truth. That is the basis of Phase D.

---

## 3. What actually broke today — the honest version

Alberto's framing is that the outage blocked both publishes. That is **half right**, and the other half matters more.

### 3.1 The 1.0.35 macOS cut

**FACT** — `v1.0.35` is tagged at commit `3f127f7da2` ("chore(release): cut OpenBurnBar v1.0.35 (#2241)"). `release.yml` run `32047967821` started **16:56:06Z** and **failed**. There is **no GitHub Release for v1.0.35**; `gh release list` still shows **v1.0.29 (2026-07-06)** as Latest.

Two jobs failed, with two different causes:

**Failure 1 — ours. `Release Functions Gate`, 16:58:49Z. Not the outage.**

```
expected: /request\.resource\.data\.mode == "relayLink"/,
operator: 'match',
##[error]Process completed with exit code 1.
```

The assertion is `functions/scripts/test-hermes.mjs:112`:

```js
assert.match(rules, /request\.resource\.data\.mode == "relayLink"/);
```

`firestore.rules` **does** enforce that constraint, but now writes it through a local alias (`let d = request.resource.data;` … `d.mode == "relayLink"` at lines 1457 and 1603). The rule is correct; the test greps the rules file as **text** and the text moved. This is a reproducible red gate with no network dependency. It is red on `main` right now.

**Failure 2 — GitHub's. `Verify protected Shared Rust native release candidate`, 17:25:12Z.**

```
gh run download 31487272665 --repo failed: error downloading
domain-core-public-production-rollback-...-31487272665-1:
HTTP 503: No server is currently available to service your request.
(https://api.github.com/repos/Imagine-That-Ai/BurnBar/actions/artifacts/9099629577/zip)
```

The release gate reaches back through `api.github.com` to download a **previous run's** Actions artifact. During the incident that endpoint returned 503. This is a genuine outage casualty and a genuine architectural weakness: a release depends on the availability of another run's artifact storage.

Both failures caused `build-and-release` to be **skipped**, so no signing, no notarization, and no publication occurred.

**Conclusion:** the release lane needs **two** fixes, and only one of them is about GitHub. Fixing the host would not have shipped 1.0.35.

**FACT, and worth stating plainly** — `release.yml` has failed on `v1.0.30`, `v1.0.31`, `v1.0.33`, `v1.0.34`, and `v1.0.35`, and was cancelled on `v1.0.32`. The last successful public release was `v1.0.29` on 2026-07-06. **The release lane is chronically red. That is a larger risk to shipping than the choice of git host**, and no migration will improve it.

#### 3.1.1 The tag is already behind `main` — an ATC decision, not an engineering one

**FACT** — the annotated tag `v1.0.35` (`aaca10a11e…`) resolves to commit `3f127f7da2`. `origin/main` is `cf7aa2deab`, which is **exactly one commit ahead** (`git rev-list --left-right --count 'v1.0.35^{commit}'...origin/main` → `0 1`). The extra commit is `deps(deps-dev): bump the lockfile-updates group in /packages/signal-envelope-contracts (#2247)`.

`docs/RELEASE_MACOS.md` is explicit about this case:

> *"Before approving a promoted release, verify that the tag still points at the current `origin/main` tip. If `main` advances after the tag is cut, cancel the run before publication and cut a new patch tag from the newest main."*

So promoting `v1.0.35` as it stands would promote from a stale tag, against our own written rule. And **P1 makes this worse**, because fixing the red Functions gate adds a second commit to `main`.

This is a genuine fork and ATC owns it, because both branches have a real cost:

| Option | Cost |
|---|---|
| **A. Promote `v1.0.35` as-is** | Violates the stale-tag rule; ships a candidate that does not contain the P1 fix or `#2247`. The red gate that blocked it is still red in the shipped tree. |
| **B. Cut a new patch tag from post-P1 `main`** | Honors the rule and ships a tree whose gates are actually green — but it is a new version number, and Alberto said **Safari #2241 (1.0.35) is shipping**. |

**Recommendation: B, with the version question escalated rather than decided here.** The plan will not silently re-cut a tag Alberto named, and it will not silently promote a stale one. Naming the fork is the deliverable; ATC picks.

### 3.2 The npm publish

**FACT** — the npm registry serves `openburnbar@0.1.0` as `latest`. `tools/openburnbar-mcp-remote/package.json` is at **0.1.1**. `gh run list --workflow npm-publish-openburnbar.yml` returns **zero runs, ever**.

**INFERENCE** — the npm 0.1.1 publish was not failed by the outage; the `openburnbar-npm-v0.1.1` tag was never pushed, so the workflow never fired. The npm ship is blocked on a tag push, not on GitHub health. It is currently unblockable-by-migration and shippable today.

### 3.3 The customer-visible exposure nobody has named yet

This is the most important finding in the whole review, and it is independent of Origin.

**FACT** — the live update feeds are served from Cloudflare R2 at `downloads.burnbar.ai`, but the **bytes they point at are on GitHub**:

```json
// https://downloads.burnbar.ai/latest-macos.json  (live, version 1.0.29)
"downloadUrl": "https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/OpenBurnBar-1.0.29-macOS.dmg",
"appcastUrl":  "https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/appcast.xml"
```

```xml
<!-- https://downloads.burnbar.ai/appcast.xml (live) -->
<enclosure url="https://github.com/Imagine-That-Ai/BurnBar/releases/latest/download/OpenBurnBar-1.0.29-macOS.dmg" ... />
```

So during a GitHub incident that put **archive and raw content downloads at ~50% error rate**, every Sparkle update check and every DMG download had roughly a coin-flip chance of failing. The R2 host was up the whole time.

Three things make this worse:

1. **The bytes are already on R2.** `HEAD https://downloads.burnbar.ai/OpenBurnBar-1.0.29-macOS.dmg` returns `200`, and a range request serves real bytes (`206`, 1 MiB retrieved). The correct artifact is sitting on the resilient host and the feed points somewhere else.
2. **This violates our own written policy.** `docs/RELEASE_MACOS.md` states: *"Mutable GitHub `releases/latest/download` URLs are rejected for release handoffs."* The live feed uses exactly those URLs.
3. **`releases/latest/download` is mutable.** It re-points the moment any release is marked latest. The feed is not pinned to 1.0.29; it resolves to whatever "latest" is.

**This is the single highest-value fix available**, it takes GitHub out of the customer path entirely, and it has nothing to do with Origin. It is Phase B.

**Also FACT:** `https://downloads.burnbar.ai/OpenBurnBar-1.0.35-macOS.dmg` → `404`, and `https://downloads.burnbar.ai/latest-linux.json` → `404`. 1.0.35 has not been promoted, and the Linux feed has never been promoted.

---

## 4. Question 2 — Dual-remote vs hard cutover

**Recommendation: neither, in that framing.** The right model is **per-repo, per-capability, staged**, because "moving off GitHub" is not one decision — it is at least six independent ones (git hosting, code review, CI, artifacts, package registry, identity/OIDC), and Origin can only take the first two today.

### 4.1 Why a hard cutover fails on day one

A hard cutover — detach from GitHub, delete nothing but stop using it — breaks all of the following immediately:

| Breaks | Because |
|---|---|
| Public repo access | Origin has no public visibility. An AGPL project loses anonymous source access. |
| All 84 workflows | Origin has no CI. |
| macOS build/sign/notarize | No macOS runners reachable from an Origin-hosted repo (Depot excludes macOS; Buildkite unproven for Origin). |
| GitHub Releases URLs | Live `latest-macos.json`, `appcast.xml`, Linux updater, Windows updater, and the npm CLI's fallback host all resolve to `github.com` release assets. |
| npm publishing | Trusted publishing supports **GitHub Actions, GitLab CI/CD, and CircleCI cloud only** ([docs.npmjs.com/trusted-publishers](https://docs.npmjs.com/trusted-publishers)). Origin is not a supported provider. |
| npm provenance | Requires a **public** repository. Origin has none. |
| Sigstore release attestations | Bound to GitHub Actions OIDC identity. |
| Cursor Marketplace plugin | Marketplace reads `https://github.com/Imagine-That-Ai/openburnbar-cursor-plugin` as its distribution git URL. |
| Merge gating | `scripts/ci/await-burnbar-ci-gate.mjs` polls `api.github.com` for check-runs, commit status, and job state. |

### 4.2 Why naive dual-remote is a trap

Origin's mirror is **not** a symmetric second remote. From [docs/origin/mirror-github](https://cursor.com/docs/origin/mirror-github):

> *"pushes to a synced repo pass through to GitHub, which remains the source of truth."*

A mirror therefore provides **zero outage insulation** — a push to Origin still lands on GitHub, so a GitHub outage still blocks you. And mirroring **disqualifies the repo from Depot and Buildkite**, so you cannot mirror and build on Origin at the same time.

Origin does document a genuine dual-push remote for evaluation:

```bash
git remote set-url --add --push origin git@github.com:acme/checkout.git
git remote set-url --add --push origin https://origin.cursor.com/acme/checkout.git
```

That is a useful local pattern for a human evaluating Origin. It is **not** an availability strategy, because two independent write targets with no reconciliation will diverge the moment one push succeeds and the other fails.

### 4.3 The recommended model

**Four lanes, decided independently:**

| Lane | Today | Target | When |
|---|---|---|---|
| **1. Code custody** | GitHub | Origin mirror → later Origin-hosted where legal/visibility allows | Phase D, then per-repo |
| **2. Review + agents** | GitHub PRs + Bugbot/Codex | Origin PRs for internal repos; GitHub PRs stay for the public repo | Phase D–F |
| **3. CI + release** | GitHub Actions | **Stays on GitHub** until a macOS path on Origin is proven | Phase E gate |
| **4. Customer artifacts** | GitHub Releases (via R2 feeds) | **Cloudflare R2, first-party, immutable URLs** | **Phase B — now** |

The key insight: **lane 4 is where the customer pain actually was today, and lane 4 has nothing to do with Origin.** Moving artifacts to R2 removes GitHub from the customer path this week. Lanes 1–3 can then move at whatever pace Origin's maturity allows, with no ship risk.

**Public download URLs and live sites keep working on day one because Phase B moves them to a host we already own and already pay for, before anything migrates.**

### 4.4 Per-repo recommendation

| Repo | Recommendation | Reasoning |
|---|---|---|
| `Imagine-That-Ai/BurnBar` | **Mirror only. Do not detach.** | Public visibility, AGPL corresponding-source, macOS CI, GitHub Releases, npm trusted publishing, Sigstore OIDC. Five hard blockers. Revisit when Origin ships public repos and macOS CI. |
| `Imagine-That-Ai/openburnbar-cursor-plugin` | **Keep on GitHub.** | Cursor Marketplace reads the GitHub git URL. Moving it breaks plugin distribution. Ironic but true. |
| `Imagine-That-Ai/imaginethat-llc` (CubeLove) | **Leading cutover candidate, now conditional.** | Private, web-only, no Apple signing, no macOS runners, deploys to Firebase/Cloudflare rather than to release assets — all of which still favor it. **But three new conditions gate it:** its `deploy.yml` has a **Pages step** that Origin may be unable to host (§10-U12), it has **no `workflow_dispatch`** so it has no manual recovery path (§1.5), and it is **factory-attested**, so the attestation chain has to survive the move. **Do not promise this cutover until U11, U12, and U1 are closed.** |
| Any new internal repo | **Origin-hosted from day one.** | No migration cost, and it exercises Origin honestly. |

### 4.5 The acceptance test for the words "off GitHub"

Per CI Steward: *do not implement a hard cut that still calls `api.github.com` and call that "off GitHub."* That failure mode is easy to walk into, because moving the **repo** feels like moving the **dependency**, and Depot/Buildkite on Origin **still run existing GitHub Actions** (§1.4).

So this plan defines the term once, mechanically, and every packet inherits it:

> **A lane is "off GitHub" only when it completes successfully with both `api.github.com` and `github.com` blocked at the network layer for the duration of that lane.**
>
> Not "the repo moved." Not "CI runs somewhere else." Not "the workflow file lives in `.depot/workflows/`." The blocked-egress run is the only evidence accepted.

Three corollaries the team should be able to recite:

1. **Re-hosting a GitHub Actions workflow is not migration.** Depot and Buildkite execute the same workflows; anything inside them that calls `api.github.com` still calls `api.github.com`.
2. **A mirror is not a failover.** Pushes pass through to GitHub, which remains source of truth (§4.2).
3. **Partial credit does not exist.** A release lane that is 90% first-party and still fetches one cross-run artifact from `api.github.com` fails exactly the way it failed today (§3.1).

Every done-check in Phase B and Phase C is written as a blocked-egress test for this reason. Where a dependency genuinely cannot be severed — `burnbar-ci-gate` reading check status while CI lives on GitHub (§5.1) — the plan says so and marks it **accepted**, rather than quietly counting it as migrated.

---

## 5. Question 3 — Shipping without `api.github.com`

The goal is that neither ship depends on GitHub's API being healthy. Note that "without api.github.com" and "off GitHub" are different problems; the first is achievable now, the second is not.

### 5.1 OpenBurnBar Release — the three GitHub API dependencies to sever

**Dependency 1 — cross-run artifact download (the thing that 503'd).**
`domain-core-native-release-gate` calls `gh run download <run-id>` against `api.github.com/.../actions/artifacts/<id>/zip`.

*Fix:* have the producing run publish the domain-core evidence bundle to a content-addressed **R2** path (`s3://openburnbar-releases/domain-core/<commit>/<name>.tar.zst` + `.sha256`) and have the consuming gate fetch from `downloads.burnbar.ai`, with the Actions artifact retained only as a debug copy. Verification stays digest-based, so trust is unchanged. This removes GitHub from the release gate's critical path even while CI still runs on GitHub.
*Done-check:* re-run the gate with network egress to `api.github.com` blocked for that step; it must still pass.

**Dependency 2 — GitHub Releases as artifact store.**
`scripts/lib/domain-core-release-evidence.mjs` hard-codes `DOMAIN_CORE_REPOSITORY = "Imagine-That-Ai/BurnBar"`, and `publish-apple-android-release.mjs` drives the REST releases API.

*Fix:* invert the order. Publish the **immutable, versioned R2 object set first**, verify public bytes, and treat the GitHub Release as a **secondary mirror** for legacy clients. `docs/RELEASE_MACOS.md` already describes an R2-first compare-and-swap with public byte verification; the change is to stop treating the GitHub Release as the authoritative source the R2 uploader reads *from*.
*Done-check:* a release completes with the GitHub Release step disabled, and `downloads.burnbar.ai` serves a fully verified candidate.

**Dependency 3 — the merge gate polls the API.**
`scripts/ci/await-burnbar-ci-gate.mjs` polls `api.github.com/repos/{repo}/commits/{sha}/check-runs`, `/status`, and `/actions/jobs/{id}`.

*Fix:* this one is honestly **unfixable while CI lives on GitHub** — status must be read from wherever checks are reported. Treat it as an accepted dependency, and make it degrade well: on `5xx`, back off and keep waiting rather than failing the gate. Today a 503 storm can fail a merge gate that would otherwise have passed.
*Done-check:* fault-injection test — return `503` for N consecutive polls and confirm the gate waits instead of failing.

**What stays on GitHub regardless, and why:**

- **macOS signing and notarization** need macOS runners. Origin-hosted repos have no proven macOS path.
- **npm publish** needs a supported trusted-publishing provider. Origin is not one.
- **Sigstore attestations** are bound to GitHub Actions OIDC identity.

### 5.2 CubeLove Deploy

`deploy.yml` cannot be read from this workspace (§1.3). Its shape is supplied authoritatively by CI Steward (§1.5): **Trusted Deploy** and **Web Deploy**, **no `workflow_dispatch`**, private, factory-attested, with a **Pages step currently missing three cutover env vars**. What follows adds what the **live site proves**.

**Read §1.5 first.** Three blockers are in force right now and outrank everything in this subsection: do not approve production-cutover on run `32051454244` att4, do not merge `master` while that run is alive, and the missing env vars must be closed before any cutover.

**FACT** — `https://cubelove.ai` returns `200`, is fronted by Cloudflare (`2606:4700:…`), and self-describes in its HTML `<head>`:

```html
<meta name="release-sha" content="4e6e75f8fc13a286b6cb28783994c71369583a2f">
<meta name="site-build-target" content="cubelove">
<meta name="firestore-database" content="public">
```

**FACT** — `git cat-file -t 4e6e75f8…` fails in the BurnBar repo, so that commit belongs to a different repository. CubeLove is **not** built from this monorepo.

**FACT** — the CSP declares the backend surface: `*.googleapis.com`, `*.firebaseio.com`, `wss://*.firebaseio.com`, `*.cloudfunctions.net`, `*.a.run.app`, `api.amplitude.com`, `*.ingest.sentry.io`, and Google reCAPTCHA; `frame-src` includes `*.firebaseapp.com` and `*.web.app`.

**INFERENCE** — CubeLove is a static/SPA front end behind Cloudflare with a Firebase backend (Firestore, Cloud Functions, Cloud Run), Amplitude analytics, Sentry, and reCAPTCHA — most likely Firebase App Check. Its deploy is therefore a **Firebase/Cloud Run deploy**, not an artifact publication.

**Why this was the good news:** a Firebase deploy needs `firebase deploy` with a Google credential. It does **not** need GitHub Releases, macOS runners, notarization, or a package registry. On the backend side, CubeLove remains the one ship in the portfolio that can plausibly run entirely off GitHub.

**Two facts from §1.5 temper that, and both are new:**

- **The Pages step.** If CubeLove publishes through GitHub Pages, Origin cannot host that step at all, and CubeLove stops being the easy candidate. **UNKNOWN, and it gates the whole recommendation** (§10-U12).
- **No `workflow_dispatch`.** There is no manual re-trigger. Deploys are event-driven only, so a failed deploy cannot be replayed on demand — and "do not rerun whole workflows" is in force. **A non-Actions deploy path is therefore mandatory, not optional.**

Two paths, in preference order:

1. **Operator deploy with Workload Identity or a short-lived service-account token.** Fastest, no new vendor, works during any GitHub outage, and it is the **only** path that answers the no-`workflow_dispatch` recovery gap. Document it as break-glass regardless of whether CubeLove ever migrates. This is the one genuinely off-GitHub path here, and it must be proven against §4.5's blocked-egress test.
2. **Depot CI on an Origin-hosted repo.** Depot copies `.github/workflows/` into `.depot/workflows/` (`depot ci migrate workflows`) and imports secrets (`depot ci migrate secrets-and-vars`). Since CubeLove is Node/web, Depot's lack of macOS is irrelevant. **But per §1.4 this still runs existing GitHub Actions and is not a failover** — it changes who executes the workflow, not what the workflow calls. Treat it as an ergonomics and code-custody move, never as outage insulation, and never as satisfying §4.5 on its own.

**Done-check for either path:** deploy, then confirm the live `release-sha` meta tag changes to the new commit:

```bash
curl -s https://cubelove.ai | grep release-sha
```

That is a genuinely excellent property — **the site publishes its own deployed commit**, so deploy success is verifiable without touching GitHub at all.

### 5.3 The npm publish, specifically

`openburnbar` uses OIDC trusted publishing with no tokens. Per npm's docs, supported providers are **GitHub Actions, GitLab CI/CD, CircleCI cloud**; self-hosted runners are unsupported; and `repository.url` in `package.json` **must exactly match** the GitHub repository. `package.json` currently declares `git+https://github.com/Imagine-That-Ai/BurnBar.git`.

Therefore:

- Publishing from Origin CI is **impossible today**.
- Changing `repository.url` to an Origin URL **breaks trusted publishing** even from GitHub Actions.
- Reverting to a long-lived npm token to escape GitHub is a **security regression** and would drop provenance.
- Origin's lack of public visibility means npm provenance is lost regardless (provenance requires a public repo).

**Recommendation: npm publishing stays on GitHub Actions indefinitely.** Revisit only if npm adds a provider that Origin can satisfy. Record it as an accepted, named dependency rather than pretending it is migratable.

### 5.4 What else in the org blocks a ship if the GitHub API dies

Ranked by whether a ship actually stops:

| Asset | Owner | Blocks a ship without GitHub? | Note |
|---|---|---|---|
| **Cloudflare R2 + `burnbar.ai` DNS zone** | Cloudflare | **No** — and it is the escape hatch | Already serves the feeds and (partly) the bytes |
| **Firebase projects** (Hosting, Functions, Firestore, Cloud Run) | Google | **No** | `firebase deploy` needs no GitHub |
| **Stripe** | Stripe | **No** | Keys live in Functions params/Secret Manager (`functions/src/config.ts`), **not** Actions secrets — verified: no Stripe secret in any workflow |
| **Apple Developer ID + notary keys** | Apple | **No** for identity, **yes** in practice | Material is stored as Actions secrets; notarization needs a Mac |
| **Google Play service account** | Google | **No** for identity, **yes** in practice | `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` is an Actions secret |
| **npm registry** | npm | **Yes** | Trusted publishing binds to GitHub Actions |
| **Cursor Marketplace plugin** | Cursor | **Yes** | Distribution is a GitHub git URL |
| **`Vendor/libsignal` submodule** | `github.com/Ajnunezg/libsignal` | **Yes** for a clean build | Git Operations were degraded ~2.5h today |
| **SwiftPM `Package.resolved`** (30+ `github.com` packages) | GitHub | **Yes** for a cold build | Warm caches mitigate; a cold runner does not |
| **CI tool downloads** (SwiftLint, XcodeGen, gitleaks, actionlint, ktlint, bundletool) | GitHub Releases | **Yes** for a cold build | Every one is fetched from a GitHub release |

**The under-appreciated one is the last three.** Even a perfect Origin migration leaves the *build* dependent on GitHub, because our dependencies live there. Vendoring or mirroring SwiftPM pins, the libsignal submodule, and CI tool binaries into R2 or an internal cache buys more outage resilience than moving the repo does.

---

## 6. Question 4 — Secrets, signing, notarization, Firebase, Stripe, Play

**The governing fact:** Origin stores **no secrets**. Mirroring explicitly excludes *"GitHub Actions workflows and secrets."* Any secret that moves must move to a real secret store, not to Origin.

### 6.1 Current inventory

**FACT** — 58 distinct secret names across 84 workflow files in `.github/workflows/`, plus 6 GitHub Environments (`release`, `release-candidate`, `production`, `staging`, `domain-core-promotion`, `windows-release`).

| Group | Representative names | Recommendation |
|---|---|---|
| **Apple signing / notarization** | `APPLE_TEAM_ID`, `APPLE_SIGNING_IDENTITY`, `APPLE_CERTIFICATE_P12`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_NOTARY_KEY_ID`, `APPLE_NOTARY_ISSUER_ID`, `APPLE_NOTARY_API_KEY_P8`, `OPENBURNBAR_APP_PROFILE_BASE64`, `APP_STORE_ASC_*` | **Stay on GitHub.** Bound to the `release` environment with human approval. Do not copy Apple private keys into a second system to enable a migration that cannot complete. |
| **Sparkle update signing** | `OPENBURNBAR_SPARKLE_PRIVATE_KEY_BASE64` | **Stay.** The public key `SUPublicEDKey` is baked into shipped apps; rotating it strands installed clients. Highest-consequence key we hold. |
| **Android signing / Play** | `OPENBURNBAR_ANDROID_KEYSTORE_*`, `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | **Stay.** Play publishing is Actions-driven. |
| **Windows codesign** | `WINDOWS_CODESIGN_*` (Azure Trusted Signing), `WINDOWS_UPDATE_SIGNING_KEY` | **Stay.** Identity is Azure; the trigger is Actions. |
| **Linux signing** | `OPENBURNBAR_LINUX_ED25519_PRIVATE_KEY_PEM` | **Stay.** |
| **Firebase / GCP deploy** | `GCP_WORKLOAD_IDENTITY_PROVIDER`, `GCP_DEPLOY_SERVICE_ACCOUNT`, `GCP_HOSTING_DEPLOY_SERVICE_ACCOUNT`, `STAGING_GCP_*` | **Most portable.** These are **Workload Identity Federation** configs, not keys. WIF can trust a different OIDC issuer. **This is the one credential family that can follow CI to a new host without minting long-lived keys** — and it is what CubeLove needs. |
| **Firebase client config** | `FIREBASE_PLIST_BASE64`, `GOOGLE_SERVICES_JSON_BASE64`, `FIREBASE_APP_CHECK_DEBUG_TOKEN` | **Client configuration, not secrets.** Could move to any store, or a private config repo. Low risk either way. |
| **Cloudflare / R2** | `CLOUDFLARE_API_TOKEN`, `CLOUDFLARE_ACCOUNT_ID`, `OPENBURNBAR_R2_ZONE_ID` | **Becomes more important, not less.** Phase B increases R2's role. Scope the token to the `openburnbar-downloads` bucket and the `burnbar.ai` zone only. |
| **Sentry / analytics** | `OPENBURNBAR_SENTRY_DSN`, `SENTRY_DSN_FUNCTIONS`, `SENTRY_AUTH_TOKEN`, `SENTRY_ORG`, `ANDROID_SENTRY_DSN` | Portable. Low risk. |
| **Agent/automation keys** | `FACTORY_API_KEY`, `OPENAI_API_KEY`, `MEM0_BURNBAR_API_KEY` | Portable. |
| **Governance** | `DOMAIN_CORE_GOVERNANCE_READ_TOKEN`, `SECURITY_ADVISORY_TOKEN`, `SLACK_SECURITY_WEBHOOK`, `OPS_PAGING_SLACK_WEBHOOK` | Portable. |

### 6.2 Stripe — a clean answer

**FACT** — no Stripe secret appears in any workflow. `rg -i stripe .github/workflows/` returns only a staging lifecycle **test** invocation. Keys are defined through Firebase Functions params (`functions/src/config.ts`: `stripeSecretKey`, `stripeWebhookSecret`) and resolved from Google Secret Manager at runtime.

**Stripe is entirely unaffected by any git-host migration.** No action. Do not touch it.

### 6.3 The identity problem nobody can migrate around

Two credentials are **not** portable in the ordinary sense because they are *identities*, not stored values:

1. **Sigstore keyless attestation** binds to GitHub Actions OIDC. Building elsewhere produces attestations with a **different signing identity**. Anyone verifying our provenance against the documented identity will fail. Changing it is a public trust-chain change and needs a documented, announced rotation — not a side effect of a migration.
2. **npm trusted publishing** binds to `{org, repo, workflow filename}` on GitHub Actions. See §5.3.

**Principle for the whole migration: never split a signing identity across two hosts.** Either a lane is fully on GitHub or fully migrated, with an announced identity rotation. A half-migrated signing identity is how you ship an artifact users cannot verify.

---

## 7. Question 5 — Three Ultra seats: who codes, who ATC, who reviews

### 7.1 A blocker to resolve before assigning anyone

**FACT** — Origin's namespace is claimed and governed at the **Cursor team** level:

> *"A team admin claims the codebase name and enables Origin; non-admins can request access from the same page."* — [docs/origin/codebase-settings](https://cursor.com/docs/origin/codebase-settings)
> *"Team access follows your Cursor team / codebase access."* — [docs/origin/create-repository](https://cursor.com/docs/origin/create-repository)

**FACT** — Cursor Ultra is an **individual** plan. The business plans are **Teams** ($40/user/mo Standard, $120/user/mo Premium) and Enterprise. Teams is also where *"Agentic code reviews with Bugbot"*, *"Cloud agents and automations with shared team context"*, and SSO are listed.

**UNKNOWN, and it gates §7.2** — whether three **separate individual Ultra accounts** can share one Origin codebase. Origin's sharing model is described exclusively in terms of Cursor team membership, and three individual subscriptions are not a Cursor team.

**INFERENCE (high confidence, needs confirmation):** three individual Ultra seats will produce **three isolated Origin codebases with no shared repos**, which defeats the purpose. The likely requirement is a **Cursor Teams plan** (3 seats) for shared Origin access, either alongside or instead of the Ultra subscriptions.

**Action:** resolve this **before** claiming a codebase name, because the namespace is claimed once and the Permissions UI is explicitly being redesigned. Ask `hi@cursor.com` (the feedback address on every Origin docs page) directly. **Cost impact is real and should be priced before the migration is scheduled.** Until it is resolved, assign the roles below on GitHub, where they work today.

### 7.2 Role assignment

Three seats, three standing roles. **The ATC seat never builds.** The other two seats alternate builder and reviewer per packet, so no packet ever has two builders and no one ever reviews their own work.

| Seat | Standing role | Owns | Never does |
|---|---|---|---|
| **Seat 1 — Builder A** | Implementer | The packets marked *(Builder A)* in §8 | Review its own packet; touch a live pointer without ATC go |
| **Seat 2 — ATC** | Air traffic control | Sequencing, go/no-go on every live pointer, the ship calendar, the blocker register, incident comms, and the decision-only packets marked *(ATC)* | Write code on any packet it gates |
| **Seat 3 — Builder B** | Implementer | The packets marked *(Builder B)* in §8 | Review its own packet; touch a live pointer without ATC go |

Ownership is named inline on each packet in §8 rather than derived from a numbering rule, because dependency order — not parity — decides who should hold a given packet. The invariants are what matter and they hold regardless of assignment: **exactly one builder per packet, the reviewer is always the other builder, and ATC never builds a packet it gates.**

**Review rule:** Builder A reviews Builder B's packets; Builder B reviews Builder A's packets. ATC arbitrates disagreement and is the only seat that may declare a packet done. This preserves the existing contract in `AGENTS.md` — Codex remains the independent automated reviewer and approval gate, branch protection remains the mechanical merge gate — and adds a **named human owner** per packet so no packet is orphaned.

**Concurrency rule:** at most **two** packets in flight, one per builder, and **never two packets that touch the same live pointer.** The four pointers that must be serialized under ATC control:

1. `downloads.burnbar.ai` feed objects (`latest-macos.json`, `appcast.xml`)
2. The GitHub Release marked `latest`
3. `website/src/data/site.ts` (`SITE.macDownloadBaseUrl`, `macReleaseLatest`, `macReleaseFile`)
4. `cubelove.ai` — currently frozen by the §1.5 blockers, and separately gated by the "do not merge `master` while run `32051454244` is alive" hold

**ATC's standing veto:** no migration packet may merge while a ship packet is in flight for the same surface. Phase A and Phase B outrank all Origin work.

---

## 8. Question 6 — Ordered steps, each with a done-check

Numbered `P#` = packet. Each has exactly one builder. **Exactly three packets in Phase A–D change a live pointer** — P5 (promote the Mac release), P7 (ship CubeLove), and P8 (repoint the update feeds). All three are intended ship actions and all three are explicitly ATC-gated. Every other packet through Phase D is inert with respect to customers.

Two standing constraints apply to all of them: **do not rerun whole workflows**, and no packet may claim a lane is "off GitHub" without passing §4.5's blocked-egress test.

### Phase A — Unblock the two live ships (nothing migrates)

> **First, and deliberately: none of these steps touch Origin, remotes, or CI topology. Alberto's two in-flight ships are not frozen by this plan; they are the first thing it unblocks.**

**P1 — Fix the red Functions gate.** *(Builder A)*
Repair `functions/scripts/test-hermes.mjs:112`. The rule is correct; the assertion greps stale text. Make the assertion resilient to the `let d = request.resource.data` alias, or assert on behavior via the rules emulator rather than on source text. Sweep the sibling assertions in `test-hermes.mjs`, `test-pi-agent.mjs`, `test-hermes-gateway.mjs`, and `test-provider-account-device-links.mjs` for the same brittleness.
**Done-check:** `Release Functions Gate` passes locally and on a PR; `rg -n 'relayLink' firestore.rules` still shows the constraint is enforced (no rule weakened to satisfy a test).

**P2 — ATC decision: which tree ships as the Mac cut.** *(ATC; decision only, no build)*
Resolve §3.1.1. `v1.0.35` is one commit behind `origin/main` and P1 adds another. Choose Option A (promote the stale tag, accepting the documented violation in writing) or Option B (new patch tag from post-P1 `main`). Escalate the version-number question, since Alberto named 1.0.35.
**Done-check:** a dated decision recorded in this document, naming the exact tag and commit that will ship.

**P3 — Get the release lane green, without rerunning whole workflows.** *(Builder B; ATC go required)*
**Do not dispatch a full `release.yml` run.** Per `docs/RELEASE_MACOS.md`, "Re-run failed jobs" re-runs only the lane that failed, and the emergency retry lane (`run_release_validation_gates=false`) exists for a candidate that already passed its gates. Use the narrowest action that clears the two failures in §3.1: the Functions gate needs the P1 fix in the tree, and the domain-core native gate needs its cross-run artifact fetch to succeed (P11 fixes that permanently; until then it depends on `api.github.com` being healthy).
**Done-check:** both previously failing jobs report success for the tag chosen in P2; `build-and-release` is no longer skipped; live pointers unchanged.

**P4 — Publish the Mac release, non-latest.** *(Builder B; ATC go required)*
Publish assets explicitly non-latest, as the workflow already does by default. This does not repoint any customer.
**Done-check:** `gh release view <tag>` shows a published, non-latest release with the full asset set. `curl -s https://downloads.burnbar.ai/latest-macos.json` still reports `1.0.29`.

**P5 — Promote the Mac release.** *(Builder A; ATC go required; live pointer)*
Run the documented `promote=true` path with `expected_live_macos_version=1.0.29` and the current live commit. Ordering matters: **sequence this after P8** if P8 is ready, so the promoted feed is born first-party instead of being repointed afterward.
**Done-check:** `curl -s https://downloads.burnbar.ai/latest-macos.json` reports the shipped version; the versioned DMG returns `200` on R2; `bash scripts/ci/verify-public-macos-download-trust.sh` passes; `public-macos-download-trust.yml` is green.

**P6 — Ship npm `openburnbar@0.1.1`.** *(Builder B)*
Not outage-blocked; the tag was simply never pushed (§3.2). Dry-run via the workflow's `dry_run` input first, then push `openburnbar-npm-v0.1.1`. This is a tag push, not a workflow rerun.
**Done-check:** `curl -s https://registry.npmjs.org/openburnbar | python3 -c 'import json,sys;print(json.load(sys.stdin)["dist-tags"])'` shows `0.1.1`.

**P7 — Clear the CubeLove blockers, then ship.** *(Builder A; ATC go required; live pointer)*
Blockers first, in order, per §1.5: (a) do **not** approve production-cutover on run `32051454244` att4; (b) do **not** merge `master` while that run is alive; (c) supply the **three missing cutover env vars** in `deploy.yml`'s Pages step. Only then ship. Because `deploy.yml` has **no `workflow_dispatch`**, there is no manual re-trigger — so if the event-driven path cannot be re-armed cleanly, use the operator break-glass deploy from §5.2 path 1 rather than forcing a rerun.
**Done-check:** run `32051454244` is resolved or superseded (not approved); the three env vars are present in the Pages step; `curl -s https://cubelove.ai | grep release-sha` returns the intended commit SHA.

**P7a — Document the CubeLove break-glass deploy.** *(Builder A)*
Independent of migration. With no `workflow_dispatch` and a standing "no whole-workflow reruns" rule, CubeLove currently has no sanctioned manual recovery path. Write one: Workload Identity or short-lived service-account token, operator-run, with the exact command and the rollback.
**Done-check:** a documented procedure that a second person can execute, proven against a **staging** target, with `cubelove.ai` untouched.

### Phase B — Take GitHub out of the customer path (still nothing migrates)

**P8 — Repoint update feeds at first-party immutable R2 URLs.** *(Builder A; live pointer; the highest-value packet in this plan)*
Regenerate `latest-macos.json` and `appcast.xml` so `downloadUrl`, `appcastUrl`, `releaseNotesLink`, and the Sparkle `<enclosure url>` all resolve to **versioned** `https://downloads.burnbar.ai/...` paths — never `releases/latest/download`. This makes the live feed comply with the policy already written in `docs/RELEASE_MACOS.md`. Confirm `OPENBURNBAR_MAC_UPDATE_BASE_URL` is set to the R2 base before any tag.
**Done-check:** `curl -s https://downloads.burnbar.ai/appcast.xml | grep -c github.com` returns `0`; a real Sparkle update completes with `github.com` blocked at the network level.

**P9 — Mirror the remaining artifacts to R2.** *(Builder B)*
Publish Linux and Windows artifacts and `latest-linux.json` to R2 alongside macOS. `latest-linux.json` currently 404s.
**Done-check:** `curl -s -o /dev/null -w '%{http_code}' https://downloads.burnbar.ai/latest-linux.json` returns `200`; the Linux and Windows updaters resolve first-party URLs.

**P10 — Give the Mac prerelease channel a non-GitHub feed.** *(Builder A)*
`DirectDownloadUpdateService` queries `api.github.com/repos/Imagine-That-Ai/BurnBar/releases?per_page=10` for prereleases. Publish a `prerelease-macos.json` on R2 and use the API only as fallback.
**Done-check:** prerelease update check succeeds with `api.github.com` blocked.

### Phase C — Reduce GitHub-API blast radius in CI (still nothing migrates)

**P11 — Move the cross-run artifact handoff to R2.** *(Builder B)*
This is the exact 503 from §3.1. Publish domain-core evidence to content-addressed R2 with digest verification; keep the Actions artifact as a debug copy only.
**Done-check:** the gate passes with `api.github.com` blocked for that step.

**P12 — Make the merge gate outage-tolerant.** *(Builder A)*
`await-burnbar-ci-gate.mjs` must treat `5xx` as retry-with-backoff, not failure.
**Done-check:** fault-injection returning `503` for N polls makes the gate wait, not fail.

**P13 — Mirror build-time dependencies.** *(Builder B)*
Cache `Vendor/libsignal`, the SwiftPM pins in `Package.resolved`, and CI tool binaries (SwiftLint, XcodeGen, gitleaks, actionlint, ktlint, bundletool) into an internal mirror.
**Done-check:** a cold-runner build completes with `github.com` reachable only for the repo checkout.

### Phase D — Stand Origin up, read-only and reversible

**P14 — Resolve the seat/team question.** *(ATC)*
Close §10-U1's sibling, §7.1: can three individual Ultra accounts share one Origin codebase, or is a Cursor Teams plan required? Ask `hi@cursor.com`. Price it.
**Done-check:** a written answer, and a costed decision recorded in this document.

**P15 — Claim the codebase name.** *(ATC)*
One-time, irreversible-ish, and it defines every future Origin URL. ATC does it deliberately, after P14.
**Done-check:** `cursor.com/codebase/{owner}` resolves; `{owner}` is recorded here, replacing the placeholder.

**P16 — Mirror `BurnBar` into Origin.** *(Builder A)*
Use **Sync from GitHub**. Requires the Cursor GitHub app on the org and GitHub admin on the repo. **Do not detach.** GitHub remains source of truth; nothing about CI, releases, or downloads changes.
**Done-check:** Origin browse shows current `main`; `git log -1` matches GitHub; `release.yml` still runs on GitHub unchanged; downloads unchanged.

**P17 — Use Origin for review on one low-risk PR.** *(Builder B, reviewed by Builder A)*
Exercise Origin PRs, review threads, and approvals for real. Mirrored PRs sync bidirectionally.
**Done-check:** a PR is reviewed and merged through Origin, appears correctly on GitHub, and CI results are visible.

**P18 — Attach a cloud agent and one automation.** *(Builder A)*
Point a cloud agent at the Origin repo and create one PR-opened automation.
**Done-check:** the agent opens a PR on Origin; the automation fires on the event.

### Phase E — Prove or disprove Origin CI for a macOS product

**P19 — Buildkite macOS feasibility spike.** *(Builder B; timeboxed; draft only)*
The open question is whether an Origin-hosted repo can run a signed, notarized macOS build. Depot is out (no macOS). Buildkite has Apple-silicon hosted Mac agents with Xcode on Pro/Enterprise, but there is **no published Origin + macOS guide**. Test on a **throwaway Origin-hosted repo**, never on a mirror of BurnBar.
**Done-check:** a signed, notarized `.app` produced from an Origin-hosted repo, **and** the result reported back as a check on an Origin PR. Anything less is a **no-go** and Phase F stops at CubeLove.

**P20 — Get the Origin API reference.** *(ATC)*
`cursor.com/docs/api/origin.md` is 404 while three docs pages link to it. Without it, check-run reporting, webhook events, and scopes are unspecified. Ask `hi@cursor.com`.
**Done-check:** the reference is published, or a written answer confirming whether external CI can report checks onto Origin PRs.

**P21 — Get a public-visibility answer.** *(ATC)*
BurnBar is public and AGPL; Origin has only Internal and Private. Ask whether public repos are on the roadmap.
**Done-check:** a written answer recorded here. **Until public visibility exists, BurnBar cannot leave GitHub.**

### Phase F — Cut over only what Origin can carry

**P22 — Inventory CubeLove.** *(Builder A; blocked on §10-U1)*
Read `imaginethat-llc`: workflows, secrets, deploy targets, runner types, whether anything needs macOS.
**Done-check:** a written inventory in this document, with a per-secret destination.

**P23 — CubeLove cutover, if and only if P19/P22 justify it.** *(Builder B)*
Mirror → verify → Depot CI on an Origin-hosted copy → deploy to a **staging** Firebase target → compare → only then detach.
**Done-check:** a staging deploy driven entirely from Origin, with `release-sha` on the staging host matching the Origin commit, and **`cubelove.ai` untouched throughout**.

**P24 — Decide BurnBar's disposition.** *(ATC)*
Given P19/P20/P21, either schedule a cutover or record "mirror-only, revisit on <named Origin capability>". A written non-decision is a decision; an unwritten one is drift.
**Done-check:** a dated decision recorded in this document.

---

## 9. Question 7 — Risks that would cause another oops-our-fault fail

Ordered by expected damage. "Oops-our-fault" means a customer-visible failure we caused, not one we suffered.

**R1 — Shipping a feed that points at a host we are migrating away from.** *(Highest)*
Today's live `appcast.xml` points at `github.com/.../releases/latest/download/...`. That URL is **mutable**: it re-resolves the instant any release is marked latest. Repointing artifacts while that mutable URL is live can strand or mis-serve installed clients.
*Mitigation:* P8 makes every feed URL versioned and first-party **before** any host change. Never publish a feed whose enclosure URL can change meaning.

**R2 — Splitting a signing identity across hosts.**
Sparkle EdDSA, Sigstore/OIDC, and npm trusted publishing all bind to a specific identity. Half-migrating produces artifacts users cannot verify.
*Mitigation:* §6.3's principle — a lane is fully on one host or migrated with an announced rotation. Sparkle's key is the most dangerous: `SUPublicEDKey` is compiled into shipped apps, so rotating it strands every installed client.

**R3 — Believing the outage was the whole story.**
The 1.0.35 run had two failures and only one was GitHub's. If the team accepts "GitHub broke it," P1 never happens and the next tag fails identically on any host.
*Mitigation:* P1 is the **first** packet. Treat the chronic red release lane (§3.1: six consecutive failed or cancelled tags since v1.0.29) as the top engineering risk, above migration.

**R4 — Detaching from GitHub before Origin can carry the lane.**
**Detach from GitHub** is presented as a one-click Danger Zone action. Post-detach, pushes stop flowing to GitHub — silently, for anyone still pushing to the GitHub remote.
*Mitigation:* detach requires ATC sign-off and a completed Phase E. Never detach a repo whose CI still lives on GitHub. Never detach BurnBar while it must be public.

**R5 — Claiming the wrong codebase name.**
The `{owner}` slug is claimed once and appears in every Origin URL. Alberto explicitly warned against guessing slugs from GitHub coordinates.
*Mitigation:* P15, ATC-only, after P14.

**R6 — Mirroring and then expecting outage insulation.**
A mirror passes pushes through to GitHub, which stays source of truth. A mirror provides **zero** protection from a GitHub outage, and it also disqualifies the repo from Depot and Buildkite. Someone will assume otherwise.
*Mitigation:* stated explicitly in §4.2. Resilience comes from Phases B and C, not from mirroring.

**R7 — Building on an early-beta surface that is documented as changing.**
Cursor states the Permissions and Rules and Protections UIs are *"being redesigned"* and controls *"may expand during early beta."* The API reference is 404.
*Mitigation:* no automation against Origin's permissions or rules until P20 lands. Treat Phase D as evaluation, not as infrastructure.

**R8 — Losing the merge gate's teeth.**
Origin's branch protection is thin and undocumented, and Bugbot does not support Origin. GitHub currently enforces seven required contexts (`BurnBar CI Gate`, `Dependency Review (CVE check)`, `Firestore Security Rules Tests`, `Functions (security vitest)`, `OSV Scanner`, `Secret Detection (gitleaks)`, `Domain Core Trusted Deletion Guard`).
*Mitigation:* do not move merge gating to Origin until every one of those contexts can be reproduced and **required** there. A weaker gate that looks green is the definition of fake-green.

**R9 — Cold-build dependency on GitHub after "migrating off GitHub."**
`Vendor/libsignal`, 30+ SwiftPM packages, and every CI tool binary are fetched from GitHub. Git Operations were degraded ~2.5 hours today.
*Mitigation:* P13. Otherwise the migration produces a false sense of independence.

**R10 — Losing public source access for an AGPL product.**
BurnBar ships AGPL-covered binaries with a corresponding-source obligation, and releases include `OpenBurnBar-VERSION-corresponding-source.tar.gz`. Origin has no public visibility.
*Mitigation:* P21 gates any BurnBar cutover. This is a licensing exposure, not merely a convenience issue — it warrants counsel review before any move.

**R11 — Doing this while two ships are in flight.**
Alberto was explicit that cubelove.ai and the 1.0.35 cut stay in flight.
*Mitigation:* Phase A first; ATC's standing veto (§7.2); at most two packets in flight, never two on the same pointer.

**R12 — Paying for the wrong seats.**
Three individual Ultra subscriptions may not share an Origin codebase at all (§7.1).
*Mitigation:* P14 before P15, and before any migration is scheduled.

**R13 — Declaring victory on a lane that still calls `api.github.com`.** *(Named explicitly by CI Steward)*
This is the most likely way this migration produces an embarrassing failure: the repo moves, CI "runs on Origin" via Depot or Buildkite, the team says "we're off GitHub," and the next incident takes the ship down anyway — because Depot and Buildkite **still run the existing GitHub Actions** (§1.4) and the workflow body still calls the same API.
*Mitigation:* §4.5's acceptance test is the only accepted evidence, and every Phase B and C done-check is written as a blocked-egress run. Any lane that cannot pass it is labelled **accepted dependency**, never **migrated**.

**R14 — CubeLove has no manual recovery path.**
`deploy.yml` has **no `workflow_dispatch`** (§1.5), so deploys are event-driven only. With "do not rerun whole workflows" also in force, a failed or half-finished CubeLove deploy has no sanctioned replay. That is a live operational gap today, not a migration risk.
*Mitigation:* P7a, which is deliberately independent of migration. Do not let this gap get discovered during an incident.

**R15 — Promoting the Mac cut from a stale tag.**
`v1.0.35` is already one commit behind `origin/main`, and the P1 fix widens the gap (§3.1.1). `docs/RELEASE_MACOS.md` forbids promoting in that state. The tempting shortcut — promote the tag Alberto named and say nothing — ships a tree whose blocking gate is still red inside it.
*Mitigation:* P2 forces the choice into the open and records it. Neither silently re-cutting Alberto's named version nor silently promoting a stale tag is acceptable.

**R16 — Reading the "already-live sites stay up" line as reassurance.**
CI Steward's blast-radius list ends with *"Already-live sites stay up."* That is true and it is load-bearing — but it describes **serving**, not **shipping**, and it is **not yet true of the macOS download path**, whose live feed points at GitHub (§3.3). Someone will quote the reassuring half.
*Mitigation:* state both halves together every time. Phase B exists precisely to make the reassuring half true for downloads as well.

---

## 10. UNKNOWN register

Nothing below is guessed. Each item names what would close it.

| # | Unknown | Why it is unknown | How to close it |
|---|---|---|---|
| **U1** | Everything about `Imagine-That-Ai/imaginethat-llc`: existence under that slug, `deploy.yml`, its secrets, runners, and CI | This workspace's GitHub App installation token is scoped to `BurnBar` only (`installation/repositories` → `total_count: 1`); the repo returns 404 | Grant the installation access to the repo, or run the inventory from a credential that can read it. **Do not infer the slug from the org name.** |
| **U2** | Whether external CI can report check runs onto an Origin PR | `cursor.com/docs/api/origin.md` returns 404 | P20 — ask `hi@cursor.com`. **This single answer determines whether Origin can ever gate a macOS product.** |
| **U3** | Whether three individual Ultra accounts can share one Origin codebase | Origin sharing is documented only in terms of Cursor **team** membership; Ultra is an individual plan | P14 — ask `hi@cursor.com`; price a Cursor Teams plan as the fallback |
| **U4** | Whether Origin will support **public** repositories | Only Internal and Private are documented | P21 |
| **U5** | Whether Buildkite can run signed, notarized macOS builds for an Origin-hosted repo | Buildkite has hosted Apple-silicon agents, but no Origin + macOS documentation exists from either vendor | P19 spike on a throwaway repo |
| **U6** | Origin SSH remote URL format | Only HTTPS is documented, though the CLI manages SSH keys (`origin ssh-key add`) | Ask, or read the green **Code** button after P15. **Do not assume a format.** |
| **U7** | Origin storage quotas, repo/file size limits, LFS | Not documented | Relevant because release evidence and vendored frameworks are large. Ask before P16. |
| **U8** | Origin's own availability history and SLA | Launched today | No track record exists. Weigh accordingly against GitHub, which at least has a public status page and postmortems. |
| **U9** | Whether CubeLove's front end is served by Firebase Hosting, Cloud Run, or Cloudflare Pages | Cloudflare fronts the origin; the CSP proves a Firebase backend but not the static host | Closed by U1, or by asking the operator |
| **U10** | Root cause of today's GitHub incident | Still unresolved at the time of writing; no postmortem | Watch `githubstatus.com` for the incident report |
| **U11** | **Which three cutover env vars** are missing from `deploy.yml`'s CubeLove Pages step | Reported by Claude review via CI Steward (§1.5); the file is unreadable from here | Read `deploy.yml`, or have the reviewer name the three variables. **Blocks P7 and any CubeLove cutover.** |
| **U12** | Whether CubeLove's **Pages step is GitHub Pages** | BurnBar has `has_pages=false`, so the org's Pages exposure is CubeLove's by elimination — but "Pages" may name a build step rather than the GitHub product | Read `deploy.yml`, or check `has_pages` on the repo. **If it is GitHub Pages, Origin cannot host CubeLove's publish step and §4.4 flips** (§10-U4 becomes CubeLove's problem too). |
| **U13** | Current state of CubeLove run `32051454244` att4 | `gh api repos/Imagine-That-Ai/imaginethat-llc/actions/runs/32051454244` returns **404** from this workspace (verified) | Closed by U1. Until then the blocker stands on the steward's word: **do not approve, do not merge `master` while it is alive.** |

---

## 11. What this plan deliberately did not do

Per the HITL constraints on the request:

- **No merge.** This document is the only change on this branch.
- **No publish.** No release, no npm publish, no promotion, no pointer moved.
- **No `workflow_dispatch`.** No workflow was triggered. Every GitHub call made while researching this was read-only (`gh api`, `gh run view`, `gh release list`).
- **No workflow reruns**, whole or partial.
- **No approval on CubeLove run `32051454244`.** It was probed read-only and returned 404; nothing was approved, and no production-cutover was authorized.
- **`master` was not merged** anywhere. This branch targets `main` on BurnBar and touches one file.
- **No workflow inventory invented.** §1.4 and §1.5 reproduce the CI Steward lists exactly; the only additions are independent verifications of `has_pages`, the 84-file count, and the tag/`main` divergence, each labelled as such.
- **No GitHub remote deleted or modified.** `git remote -v` is unchanged.
- **No Origin slug guessed.** Every Origin URL is written as `{owner}` until a human claims the name (P15).
- **No fake-green.** The red Functions gate is reported as red, and this plan states that Origin would not have shipped 1.0.35 today.
- **No ads, no X.**
- **Safari #2241 (v1.0.35)** is treated as shipping; Phase A exists to unblock it.
- **Factory 1.0.34** remains on hold; nothing here touches `v1.0.34`, consistent with `docs/runbooks/existing-stable-tag-dry-run-recovery.md`.

---

## 12. One-paragraph answer for Alberto

Origin went early-beta today and it is a real git host with real pull requests, but it has no CI, no releases, no artifacts, no package registry, no secret storage, and no public repositories — so BurnBar, which is public, AGPL, notarized, and shipped through release assets and npm, cannot leave GitHub yet. CubeLove was the obvious first migration, and it still might be, but its `deploy.yml` has a Pages step and BurnBar has `has_pages=false`, which means the org's Pages exposure is CubeLove's — and Origin has no Pages. That question has to be answered before we promise anything. The thing worth doing this week has almost nothing to do with Origin: our live macOS update feed is hosted on Cloudflare but points its download URLs at GitHub, so today's outage gave every updating customer a coin-flip chance of failure while our own R2 copy of the DMG sat there working. Fix that and GitHub stops being a customer-visible dependency. Two honesty items to close on. The outage did not block 1.0.35 by itself — one of the two failing jobs was our own brittle test asserting on the text of `firestore.rules`, that gate is still red on `main`, and the `v1.0.35` tag is now a commit behind `main`, so somebody has to decide out loud whether we promote a stale tag or cut a new one. And when we do move something, "off GitHub" has to mean it passes with `api.github.com` blocked — Depot and Buildkite on Origin still run our existing GitHub Actions, so re-hosting the same workflow somewhere else and calling it a migration would be the exact failure we are trying to avoid.
