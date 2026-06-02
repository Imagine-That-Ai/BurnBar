# Swarm prompt — plan the burnbar.ai web surface for Personal Knowledge Memory

A copy-paste prompt set for a swarm of **planning** agents. Each lane returns an
implementation plan (not code) for one part of the burnbar.ai authenticated web
app — profile management, memory management, usage breakdowns, dashboards —
folded into the existing Remote MCP plumbing and the current BurnBar Pro cloud
subscription.

Paste the **brief** to every agent. Run **Lane 0** first (it is the keystone:
auth model, app shell, hosting target). Then fan out Lanes 1–6 in parallel.
Run **Synthesis** after the lanes return.

---

````markdown
# SWARM BRIEF — paste to every planning agent

ROLE: You are one planning agent in a swarm designing the burnbar.ai web app for "Personal
Knowledge Memory" — the per-user Cloud Pro feature where a member's own repo docs / notes sync
VERBATIM into a private memory namespace their coding agents query over MCP. You design the web
surface that lets a signed-in Pro member manage their profile, manage their memory, read their
usage breakdowns, see dashboards, manage their MCP clients, and manage their Pro subscription —
all under burnbar.ai.

Goal: Return the implementation plan for YOUR lane only, grounded in real files. Plan, do not build.

Ground truth — the stack we are designing against (query mem0 first, then open the files to confirm):
- `mcp__mem0-burnbar__search_memories` with `filters={"AND":[{"user_id":"burnbar"}]}` returns the
  exact wiki paragraph for any subsystem; each result's `metadata.source_path` names the full
  `droid-wiki/<path>` page. Query before reading whole files.
- WEB: `website/` is an Astro site. Hosting target `marketing` → `website/dist`, declared in
  `firebase.json`; deploy with `firebase deploy --only hosting:marketing`. Pages live in
  `website/src/pages/` (`index`, `pricing`, `mcp.astro`, `link.astro`, `hermes/connect.astro`,
  `router/daily/[date].astro`). Shared copy in `website/src/data/*.ts`, components in
  `website/src/components/`, styles in `website/src/styles/`, helpers in `website/src/lib/`.
- AUTH IS ALREADY ON THE WEB: `website/src/pages/link.astro` and `hermes/connect.astro` sign in
  with Google/Apple via Firebase Auth — their `firebase.json` CSP already allows
  `identitytoolkit.googleapis.com`, `securetoken.googleapis.com`, and `*.cloudfunctions.net`.
  Plan to reuse that auth + CSP pattern; name any new `connect-src` your lane needs.
- MCP (Cloud Pro, encrypted, per-user): `functions/src/callables/remoteMcp.ts`
  (`issueRemoteMcpGrant` / `revokeRemoteMcpClient` / `searchStreams` — validates Pro entitlement),
  `remoteMcpGrant.ts`, `remoteMcpOAuth.ts`. Hosted server `services/hosted-mcp/` at
  `https://mcp.burnbar.ai/mcp`. Local bridge `tools/openburnbar-mcp-remote/`. Docs:
  `docs/HOSTED_REMOTE_MCP.md`, `docs/REMOTE_MCP_RUNBOOK.md`.
- BILLING + ENTITLEMENT: `functions/src/callables/stripe.ts` (web), `appstore/` (Apple),
  `callables/googlePlayBillingPaths.ts` (Google), entitlement + allowance in
  `functions/src/cloudProAllowance.ts`.
- USAGE DATA: Firestore `users/{uid}/usage` (`UsageEventDoc`), `users/{uid}/usage_rollups/{today,
  7d,30d,90d,all_time}` (`UsageRollupDoc`, 5 docs merged client-side), `users/{uid}/quota_snapshots`
  (`QuotaSnapshotDoc`). Canonical schema in `functions/src/types.ts` (migrating to
  `tools/schema-sync/`). The memory store ships in the companion plan as `users/{uid}/chunks`
  (sealed titles + encrypted body pages) or a per-user mem0 namespace.
- BACKEND CONVENTIONS: new callables use `onCallProduction(name, options, handler)` from
  `functions/src/logging.ts`; wrap external HTTP with `functions/src/resilienceHelpers.ts`;
  enforce App Check. CI forbids raw `await fetch` in `functions/src`.

First action: call `mcp__mem0-burnbar__search_memories` for your lane's topic, read the chunks it
returns, then open the named files. Extend what exists.

Success means your lane returns:
  - A 3-5 sentence design summary
  - The exact pages/islands/callables to create or edit (path + the change)
  - The data shapes / API signatures / Firestore reads/writes your lane introduces
  - A reuse map: which existing component (auth, callable, schema, style) each new piece extends
  - Open decisions for the user, each with a recommended default
  - Risks + the one test that would prove the lane works

Stop when: the plan is complete and every file path is real (you opened it or confirmed it exists).

Constraints:
  - Gate every memory/usage/profile read on Firebase Auth + the Pro entitlement check from
    `cloudProAllowance.ts`; the signed-in `uid` selects the namespace — a member sees only their own data.
  - Keep memory content VERBATIM (`infer:false` semantics) — plan to render it exactly as stored.
  - Stay additive and fail-open — extend the existing Astro site and hosting config; plan empty states
    for any data a callable cannot yet return.
  - Honor the copy policy: benefit-first, safety-forward, plain language; keep transport/protocol/codec
    jargon and internal codenames out of member-facing copy (public names live in
    `website/src/data/capabilities.ts`).
  - Note the build hazards in your plan: build on Node 22, firebase-deploy on Node 24; the
    `--container-narrow` token gotcha; re-verify edited files (concurrent-editor corruption).
  - Write plain-text plans. Lead every step with its action verb.
````

---

````markdown
# LANE 0 — Foundation & app shell  (PLAN FIRST — Lanes 1–6 depend on it)
Goal: Plan the signed-in app area and the shared primitives every other lane builds on.
Decide the runtime: extend `website/` with an authenticated `/app/*` route group, or add an `app`
hosting target (`app.burnbar.ai`) in `firebase.json` — recommend one and justify it on auth, CSP, and
deploy simplicity. Specify the Firebase Auth client (reuse the `link.astro` / `hermes/connect.astro`
pattern), an auth guard, an Astro-island callable client that attaches the ID token, the app shell/nav
(Dashboard, Memory, Usage, MCP, Account/Billing), and the `firebase.json` CSP `connect-src` additions
(`*.cloudfunctions.net`, `*.firebaseio.com`, `*.googleapis.com`, `https://mcp.burnbar.ai`).
Return: the route map, the shared `<AppShell>` / `<AuthGuard>` / callable-client module names, and the
hosting/CSP diff the other lanes inherit.

# LANE 1 — Profile & account management
Goal: Plan the Account area.
Specify the profile page: identity, linked sign-in providers (Google/Apple), session sign-out, linked
devices, data export, and a danger-zone account delete that triggers the memory-purge + Firestore cleanup
path. Name the Firebase Auth + profile-doc reads and any new profile callable.
Return: the `/app/account` plan — page + island + callable signatures + the delete/export flow.

# LANE 2 — Memory management  (core surface)
Goal: Plan the Personal Knowledge Memory manager.
Specify browse + search over the member's chunks (`users/{uid}/chunks` or the per-user mem0 namespace
from the companion plan), a chunk detail view rendering content + metadata (`source_path`, `page_title`,
`chunk_index`, `content_hash`), add/edit/delete memory, a knowledge-source manager (connected
repos/folders), manifest health, a "Sync now" action, and sync status + error surfacing. Plan to render
content verbatim. Call out the web-side decryption / key-handling decision explicitly (the device bridge
decrypts today; the browser has no device key) and recommend a default.
Return: the `/app/memory` plan — list, search, detail, sources — with the callable contracts it assumes.

# LANE 3 — Usage breakdowns
Goal: Plan the usage analytics surface.
Specify token + cost breakdowns by provider/model/time, provider-quota headroom bars, and rollup windows
(today / 7d / 30d / 90d / all-time) reading `users/{uid}/usage`, `usage_rollups` (merge the 5 docs
client-side), and `quota_snapshots` per `functions/src/types.ts`. Add a memory-query usage panel (MCP
search counts, top sources hit). Recommend a charting approach that fits the Astro-island model.
Return: the `/app/usage` plan — page + charts + the rollup-merge logic + the test that proves the merge.

# LANE 4 — Dashboards
Goal: Plan the signed-in landing overview.
Specify the at-a-glance dashboard composing Lanes 2 and 3: Pro status card, memory stats (chunk count,
sources, last sync), usage-at-a-glance, MCP client activity, recent agent queries. Reuse the Insights
"Editorial Observatory" visual language (`features/insights.md`) where it fits; keep each card a link
into its full lane surface.
Return: the `/app` (or `/app/dashboard`) composition plan — cards, data sources, empty states.

# LANE 5 — MCP integration + Pro subscription
Goal: Plan how the web app folds into Remote MCP and the Pro cloud sub.
MCP: specify grant/client management — list, issue (`issueRemoteMcpGrant`), revoke
(`revokeRemoteMcpClient`) per-client, scope selection, per-client activity, and a copy-ready connection
config snippet (`.mcp.json` for Claude Code / Cursor / Codex pointing at `https://mcp.burnbar.ai/mcp`).
Reuse `remoteMcp.ts`, `remoteMcpGrant.ts`, `remoteMcpOAuth.ts`.
Pro sub: specify plan status + entitlement (`cloudProAllowance.ts`), a Stripe customer-portal / checkout
entry (`callables/stripe.ts`), read-only surfaces + deep links for Apple/Google billing (`appstore/`,
`googlePlayBillingPaths.ts`), and invoices. Mirror the marketing tiers in `pricing.astro`.
Return: the `/app/mcp` + `/app/billing` plan — pages, callable signatures, the entitlement-gating points.

# LANE 6 — Backend callables + security
Goal: Plan the web-facing callables and prove the surface is safe.
Specify any new callable the lanes need that does not exist (web memory CRUD, knowledge-source
management, web usage aggregation, account export/delete), each via `onCallProduction` +
`wrapCallableHandler`, resilience-wrapped, App Check enforced, with the Firestore-rules changes. Run the
threat model: auth + Pro gating on every read, cross-tenant isolation (the `uid`/bearer `sub` selects the
namespace), web key-handling for encrypted bodies, CSP, App Check. Name `scripts/test-hosted-mcp-security.sh`
or a new web-security harness as the proof.
Return: the new-callable signatures + Firestore-rules deltas + the threat-model table + the security test list.

# SYNTHESIS — run after all lanes return
Goal: Merge the lane plans into one buildable implementation plan.
Read all lane outputs. Resolve conflicts (especially Lane 2's web-decryption decision, which Lanes 4/6
depend on, and Lane 0's hosting choice, which every lane inherits). Produce: one architecture summary, a
dependency-ordered phase list, the deduped file-change set, the consolidated open-decisions list (each with
a recommended default), a milestone-1 thin slice (proposed: read-only Dashboard + MCP connect + Pro status),
and the deploy runbook (Node 22 build / Node 24 deploy, hosting target, CSP `connect-src` additions,
`firebase deploy` target). Stop when the plan is internally consistent and every open decision has a default.
````

---

## Wiring notes

- **Lane 0 is the keystone** — its hosting choice (`/app/*` on the `marketing` target vs. a new
  `app.burnbar.ai` target) and its auth/callable client are inherited by every other lane. Plan it
  to completion and feed its output into the others before fanning out.
- **Lane 2's web-decryption question is the riskiest open decision.** Today the local stdio bridge
  decrypts sealed bodies with a device key; the browser has none. Options to weigh: render sealed
  metadata only on web, add an explicit web-readable opt-in grant mode, or a passphrase-derived web
  key. Surface this to Alberto early.
- **Companion dependency:** Lanes 2/3 read the memory store defined in the companion Personal
  Knowledge Memory plan. If that store is not designed yet, have Lane 2 state the callable contract
  it assumes so the two plans stay aligned.
- Scale the swarm by splitting Lane 5 into `5a` (MCP) and `5b` (billing), or Lane 6 into `6a`
  (callables) and `6b` (security), if you want one agent per concern.
