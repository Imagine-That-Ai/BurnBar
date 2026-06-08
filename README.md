<div align="center">
  <img src="AgentLens/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="96" alt="OpenBurnBar" />

  # OpenBurnBar

  > A native macOS app that watches your AI coding agents so you don't have to wonder where all your money went.

  **Status:** Commercial launch candidate — macOS `1.0.2` is submitted to Mac App Store review and ships as a Developer ID notarized direct download; iOS `1.0` and the Hosted Quota Sync subscription are in Apple review with manual release enabled.

</div>

If you're the kind of person who has three AI agents running in parallel tabs and only checks the bill at the end of the month, this is for you. OpenBurnBar sits quietly in your menu bar, reads the local session logs your agents leave behind, and gives you a live view of tokens burned and dollars spent across the providers you actually use.

For the paranoid-and-proud crowd: analytics stay **local-first**. No API keys, no account, no cloud — unless you *want* cloud. OpenBurnBar also ships a **Cursor / VS Code extension** that talks to a small **local daemon** so your editor and your meter can be friends.

OpenBurnBar's macOS release ships through two channels: a sandboxed Mac App Store build and a Developer ID notarized DMG from GitHub Releases. For direct download, grab the latest macOS DMG, drag `OpenBurnBar.app` into `/Applications`, and launch it from your menu bar. If you want the latest tree or prefer local builds, `make install` remains the source fallback.

The macOS app ships as a packaged release artifact. The editor extension remains source-only for now; there is no public VS Marketplace / Open VSX listing or signed VSIX attached to releases yet.

OpenBurnBar's shipped product is AGPL-3.0-only. The Nous/Hermes gateway contribution path remains MIT-compatible and is guarded separately so BurnBar product-only AGPL/libsignal release artifacts do not leak into upstream Hermes Agent PRs.

## Architecture stance

OpenBurnBar is now explicitly **daemon-first** and **local-first**.

- Local SQLite plus daemon-owned local state are canonical.
- Firestore is an optional replication and collaboration plane.
- Raw iCloud session-file mirroring is disabled until a sealed archive format ships.
- Neither cloud path replaces local state as the source of truth.

The current architecture canon lives in [OPENBURNBAR_RELEASE_ARCHITECTURE.md](docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md).

### Support tiers (what we treat as first-class)

| Tier | Surfaces | Notes |
|------|----------|--------|
| **Core** | macOS app (`AgentLens/`), `OpenBurnBarCore`, local daemon (`OpenBurnBarDaemon/`), Cursor/VS Code extension (`extensions/openburnbar/`), `OpenBurnBarCLI` | Built and exercised in CI where configured; local-first + daemon RPC are the product spine. |
| **Experimental** | Optional Firestore sync, sealed cloud collaboration, Cursor connector + tunnel, future sealed iCloud archive support | Best-effort; opt-in; not canonical vs local SQLite/daemon state. Raw iCloud session-file mirroring is disabled in this tree. |
| **Adjacent tooling** | [`tools/openburnbar-mcp/`](tools/openburnbar-mcp/README.md) (local SQLite MCP helper, BurnBar Resume, plus opt-in hosted encrypted semantic search), [`tools/openburnbar-mcp-remote/`](tools/openburnbar-mcp-remote/) (BurnBar Pro hosted Remote MCP stdio shim) | Developer convenience; not required to run OpenBurnBar. |
| **Quarantined tests** | `AgentLensTests/Quarantine/` | Stale suites kept as migration reference only; **not compiled** in the active `OpenBurnBarTests` bundle until fixed and moved back to `Active/` — see [AgentLensTests/README.md](AgentLensTests/README.md) and [CONTRIBUTING.md](CONTRIBUTING.md). |

**Cursor deep dives** (for humans and agents):

- [Agent instructions (AGENTS.md)](AGENTS.md) — completion bar, tests, docs, scope for AI coding agents
- [Claude / agent mirror (CLAUDE.md)](CLAUDE.md) — same bar for tools that prioritize `CLAUDE.md`
- [OpenBurnBar Mission](docs/MISSION.md)
- [OpenBurnBar Direction](docs/DIRECTION.md)
- [BurnBar Resume](docs/BURNBAR_RESUME.md)
- [OpenBurnBar Roadmap](docs/ROADMAP.md)
- [OpenBurnBar + Cursor Agent Onboarding](docs/OPENBURNBAR_CURSOR_AGENT_ONBOARDING.md)
- [OpenBurnBar Current Release Architecture](docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md)
- [Threat Model and Permission Model](docs/THREAT_MODEL.md)
- [Governance and Maintainer Expectations](docs/GOVERNANCE.md)
- [Technical readiness & diligence scorecard](docs/TECHNICAL_READINESS.md)
- [Tech debt strategy & metrics](docs/TECH_DEBT_STRATEGY.md) · [live snapshot](docs/TECH_DEBT_METRICS.md)
- [Observability contract](docs/OBSERVABILITY.md) · [SLO runbook](docs/runbooks/slos.md)
- [Architecture ADRs](docs/ARCHITECTURE/README.md)

---

## What it does

- **Lives in your menu bar** — no Dock icon, no windows stealing focus. Click when you're curious; forget it exists when you're not.
- **Reads local logs directly** — parses session files from Claude Code, Factory/Droid, Codex, Kimi, and friends. Your API keys never leave the providers you already trust; OpenBurnBar just reads crumbs they dropped on disk.
- **Tracks cost and token volume** — today, this week, this month. Flip between "how many dollars" and "how many tokens" like the sophisticated chaos goblin you are.
- **Smart insights** — the InsightEngine notices patterns: spend up 40% vs yesterday, cache hits doing heavy lifting, first date with a shiny new model. Little cards, not a spreadsheet cosplaying as a product.
- **Per-provider breakdown** — see which agent is winning the "most expensive hobby" award and whether it's gaining on yesterday's champion.
- **Daily digest** — optional notification at a time you pick, because future-you deserves a single sentence of truth instead of a billing surprise.
- **Chat panel** — ask questions about *your* usage data inside the dashboard. Meta? A little. Useful? Also a little. Delightful? We think so.
- **Optional cloud sync** — sign in with **Google or Apple** (Firebase under the hood), and selected OpenBurnBar data can follow you across devices. Usage/cost metadata remains server-readable where needed for sync; chat threads, CLI session mirrors/snapshots, rollback requests, mobile assistant chats, mission prompts/results, text snippets, approval-policy labels/paths, agent identity text, subscription topic labels, and conversation recall metadata are sealed on-device before Firestore receives them. Fully opt-in; flip it off anytime and your local world keeps spinning.
- **Hosted Remote MCP for BurnBar Pro** — paid users can connect coding agents to OpenBurnBar's hosted MCP endpoint for encrypted hosted session-memory search, with a local shim for stdio-only clients and device-side decrypt.
- **Optional routed-provider gateway** — route selected **Z.ai**, **MiniMax**, **Ollama Cloud**, and **Factory Droid** models through a local OpenAI-shaped router for Cursor, Factory, and OpenCode. Cursor gets a tunnel because it is picky about BYOK targets; local clients use the loopback gateway directly. OpenBurnBar logs those requests so you know where the bits actually went.
- **Daemon-backed controller runtime** — project registry, questions, followups, missions, scheduled reviews, simulator replay, mission provenance, and auto-takeover now live behind the local daemon instead of a UI-only mirror.
- **Operational tool plane** — OpenBurnBar exposes daemon-owned connector status/actions for GitHub, Slack, Linear, PostHog, Sentry, and Gmail, plus browser tooling status/actions for the system browser and daemon-side fetch/link extraction.

## CLI control plane

OpenBurnBar now ships a local CLI alongside the daemon:

```bash
swift run --package-path OpenBurnBarDaemon OpenBurnBarCLI -- help
```

Current commands:

- `health`
- `controller [projectSlug]`
- `questions [projectSlug]`
- `followups [projectSlug]`
- `missions [projectSlug]`
- `mission-approve <missionID> [note]`
- `simulator-runs [projectSlug]`
- `simulator-replay <runID>`

---

## Local-first retrieval architecture

OpenBurnBar search is now backed by a derived local retrieval substrate. `GRDB/SQLite` remains the interactive authority; Firestore is replication/collaboration infrastructure for shared artifacts, not the serving search path.

### Projection pipeline

```text
ConversationIndexer + ArtifactDiscovery + SharedArtifactSync
                        |
                        v
                 source rows in SQLite
      (conversations + source_artifacts + sync state)
                        |
                        v
                  projection_jobs queue
                        |
                        v
            ProjectionPipelineService.runSweep()
                        |
                        +--> search_documents + search_chunks + FTS
                        +--> chunk_embeddings + embedding_versions
                        +--> retrieval_health (projection/semantic/rebuild)
```

### Retrieval pipeline

```text
SearchService.retrieve(query)
        |
        +--> lexical candidates from search_chunks_fts (always on)
        +--> semantic candidates from vector index (optional)
                ANN -> exact fallback -> exact bounded rerank baseline
        |
        v
 candidate union -> bounded rerank -> source hydration -> RBAC/visibility filters
        |
        v
 chat/session/context consumers
```

### Shared/team collaboration flow

```text
Local shared artifact edit
        |
        v
CloudSyncService merge decision (local vs synced vs remote hash)
        |
        +--> Firestore shared artifact head + revision checks (optimistic concurrency)
        +--> local permission snapshot + audit events
        +--> projection reproject/purge jobs for local search parity
```

### Health, rebuild, and re-embed behavior

- OpenBurnBar materializes typed subsystem health in `retrieval_health` (parser/import, discovery, projection, lexical, semantic, rebuild, collaboration, insight rollups).
- Degraded states surfaced to consumers include: **Index stale**, **Semantic unavailable**, **Rebuild in progress**, and **Cloud/shared unavailable**.
- Rebuild/re-embed are durable queue jobs (`projection_jobs`) with retry/cancel semantics; lexical retrieval remains available when semantic indexing is degraded.

### Test and eval entrypoints

- `scripts/test-openburnbar-swift.sh` — Swift package tests (`OpenBurnBarCore`, `OpenBurnBarDaemon`)
- `scripts/test-openburnbar-app.sh` — Xcode `OpenBurnBarTests` only (compiled from `AgentLensTests/Active/**` + `AgentLensTests/Support/**`; `AgentLensTests/Quarantine/**` stays out of CI until revived)
- `scripts/test-openburnbar-retrieval-evals.sh` — retrieval + authoring replay/golden suites
- `scripts/test-openburnbar-release-smoke.sh` — end-to-end release smoke (Swift + retrieval evals + extension tests + authenticated daemon health)

Implementation detail and rollout notes live in [`docs/OPENBURNBAR_SEARCH_ARCHITECTURE_SPINE.md`](docs/OPENBURNBAR_SEARCH_ARCHITECTURE_SPINE.md).

The external launch settings that cannot be inferred from the working tree alone are tracked in [`docs/OSS_LAUNCH_CHECKLIST.md`](docs/OSS_LAUNCH_CHECKLIST.md). Re-check them immediately before making the repository public.

---

## Provider support

| Provider | Usage tracking | Source | Confidence | Quota reporting |
|---|---|---|---|---|
| Claude Code | Supported | `~/.claude/projects/*.jsonl` | Exact | Supported via Claude statusline bridge (5-hour / 7-day %) |
| Factory (Droid) | Supported | `~/.factory/sessions/*.jsonl` | Exact | Estimated via plan tier + OpenBurnBar-tracked monthly Factory tokens |
| Codex (OpenAI) | Partial | `~/.codex/state_5.sqlite` + rollout JSONL | Estimated | Supported via the latest local Codex rollout/session rate-limit snapshot |
| Kimi (Moonshot) | Partial | `~/.kimi/sessions/*.jsonl` | Estimated | Unavailable |
| Z.ai | Partial | via Factory sessions | Estimated | Supported via official monitor quota endpoints |
| MiniMax | Partial | via Factory sessions | Estimated | Supported for Token Plan via official remains endpoint |
| Copilot | Planned | — | — | Unavailable |
| Aider | Planned | — | — | Unavailable |
| Cursor connector | Supported (optional) | Cursor BYOK + OpenBurnBar local router | Exact | Unavailable |

**Exact** = the log format actually told us the numbers; we're not guessing.

**Estimated** = we applied math and hope — e.g. Codex may only give totals without an input/output split, so OpenBurnBar shrugs and assumes 50/50. Costs everywhere use **public pricing tables**, not your invoice. Good for trends; bad for tax audits.

Quota reporting is separate from spend history. Codex quota comes from the latest local rollout/session snapshot, Claude Code quota comes from the local statusline bridge, MiniMax and Z.ai use official API responses, Ollama reports local model inventory plus cloud-plan routing state, and Factory / Droid remaining is an explicit estimate from OpenBurnBar-tracked raw monthly tokens rather than Factory billable tokens.

Claude Code and Codex can also refresh quota remotely from iOS/iPadOS through on-demand quota sync. Codex supports hosted or self-hosted sync; Claude Code uses a self-hosted runner so provider auth stays in the user's own environment. See [Claude Code and Codex Remote Quota Sync](docs/HOSTED_QUOTA_SYNC.md).

Factory exact quota no longer reuses session state from other local apps in this source release. If you want OpenBurnBar to call the official Factory quota API, provide explicit `FACTORY_COOKIE_HEADER` and/or `FACTORY_BEARER_TOKEN` environment overrides; otherwise OpenBurnBar falls back to plan-tier estimation.

### Cursor agent provider scope (narrower on purpose)

Routed Cursor traffic is a smaller club than the table above.

- **In:** `Z.ai`, `MiniMax`, `Ollama Cloud`
- **Out (on purpose):** `Kimi`, `pony-alpha-2`, hidden/internal catalog models, browser tools
- **Public catalog examples for routing:** `glm-5-turbo`, `glm-5`, `minimax-m2.7-highspeed`, `deepseek-v4-flash`, `gpt-oss:120b`

The sidebar today is honest about being a **shell**: health, catalog, workspace state, recovery copy — the full run-control red carpet is still rolling out.

---

## OpenBurnBar in Cursor (and VS Code)

The extension is **local-first** and **daemon-backed**. Think of it as a polite sidecar, not a second brain.

You get:

- a OpenBurnBar activity bar home with **Health**, **Runs**, and **Run Detail**
- **Reconnect**, **Refresh**, and **Repair Daemon** when the universe is misaligned
- workspace capability detection (local, remote, read-only, virtual, restricted) so the UI doesn't lie to you
- workspace-root-bounded file and terminal access so the companion cannot wander outside the opened project roots
- inline recovery prose for the usual failure modes — socket missing, timeout, protocol mismatch, "did you install the daemon?", etc.

**Restricted workspaces** (Cursor/VS Code untrusted mode):

- **Allowed:** `read_file`, `search_workspace`, health, catalog state, projected run state
- **Gated until trusted:** `apply_patch`, `run_terminal`

Even in trusted workspaces, `apply_patch` and `run_terminal` pause for explicit approval before the companion dispatches them.

**Fast start** (five steps, zero mysticism):

1. Run OpenBurnBar on the same Mac as the editor.
2. Install or repair the daemon from OpenBurnBar.
3. Add Z.ai, MiniMax, and/or Ollama Cloud keys if you want routed models.
4. Install the OpenBurnBar extension from `extensions/openburnbar` (build with `npm run build` in that folder, then load the unpacked extension in your editor of choice).
5. Open a folder or workspace, then open the OpenBurnBar sidebar and say hi.

---

## Routed provider gateway

OpenBurnBar can wire supported models into Cursor, Droid/Factory, Forge, OpenCode, Codex CLI, and Claude Code without you hand-editing ghost JSON or running a sketchy proxy you found at 2am.

The play:

- Keys live in the **macOS Keychain** (where keys belong).
- You pick which model IDs routed clients should believe in.
- A local **OpenAI-compatible gateway** wakes up.
- Cursor gets a **public HTTPS tunnel** because Cursor blocks `localhost` and private IPs for BYOK — not our rule, just our problem to solve.
- Droid/Factory, Forge, OpenCode, Codex CLI, and Claude Code point directly at the local gateway.
- OpenBurnBar writes the client config for Cursor, Droid/Factory, Forge, OpenCode, Codex CLI, and Claude Code.
- OpenBurnBar temporarily swaps Cursor's local BYOK token field to a short-lived OpenBurnBar session token while the connector is active, then restores the saved value on disconnect.
- Routed provider API keys stay in Keychain; client config only receives the local gateway URL and gateway token.
- Gateway usage shows up as **`OpenBurnBar Gateway`**, and exhausted upstream plans fail over only when the next route proves the same canonical model ID instead of stranding the client on a dead account or silently changing models.
- The **Route log** button in Settings -> Agents -> CLIs shows each recent proxy request with the requested model, the model/provider/logo OpenBurnBar actually sent upstream, the provider-reported model, status, attempts, and usage metadata.

**v1 upstream provider scope:** `Z.ai`, `MiniMax`, `Ollama Cloud`, `OpenAI`, `Kimi`, `Anthropic`, and `Factory Droid` where configured. Exact model failover may change provider/account, but it will not change `gpt-5.4` into `gpt-5.4-mini`, `gpt-5.4-pro`, a broad family wrapper, or a same-capability-class substitute. Factory Standard exhaustion is treated as exact same-model failover, not silent Droid Core downgrade. **Client targets:** Cursor, Droid/Factory, Forge, OpenCode, Codex CLI, and Claude Code. **Cursor tunnel flavor:** Cloudflare quick tunnel (bring `cloudflared` only for Cursor).

**Checklist:**

1. Install `cloudflared` only if you want routed Cursor models.
2. OpenBurnBar -> **Settings -> Routing pools** and use **Use local defaults**.
3. Add provider keys/accounts in the matching pool.
4. Wire Codex, Droid/Factory, Forge, or Claude Code from the **Client apps** rows; use the older Cursor/OpenCode connector controls where those clients need them.
5. After a client sends traffic, click **Route log** in the proxy catalog panel to verify the exact slug/provider/model route.
6. Leave OpenBurnBar and the daemon running while clients chat through the gateway — it's doing real work under the hood.

More detail: [`docs/ROUTED_CLIENT_GATEWAY.md`](docs/ROUTED_CLIENT_GATEWAY.md).

---

## Repository map (yes, the folder is still named AgentLens)

The Mac app sources live under **`AgentLens/`** because renaming folders is a personality test Xcode sometimes fails. The product name is **OpenBurnBar**; the bundle is **`com.openburnbar.app`**. Roll with it.

| Area | What lives there |
|---|---|
| `AgentLens/` | SwiftUI app: menu bar, dashboard, settings, parsers, GRDB store |
| `OpenBurnBarCore/` | Shared types and RPC contracts for app ↔ daemon |
| `OpenBurnBarDaemon/` | Local JSON-RPC daemon + executable wrapper |
| `extensions/openburnbar/` | TypeScript extension for Cursor / VS Code |
| `docs/` | Mission, direction, roadmap, architecture, onboarding, and other words we meant |

---

## Requirements

- macOS 14 Sonoma or later
- Xcode 16+
- Swift 5.10
- Node + npm (only if you're hacking the editor extension)

---

## Install

### How your users install and open it

### 1. GitHub Release DMG (recommended)

This is the normal user path.

1. Open [GitHub Releases](https://github.com/Ajnunezg/BurnBar/releases)
2. Download the latest `OpenBurnBar-<version>-macOS.dmg`
3. Open the `.dmg`
4. Drag `OpenBurnBar.app` into `Applications`
5. Open `OpenBurnBar` from:
   - `Applications`
   - Spotlight: `Cmd+Space`, then type `OpenBurnBar`

If macOS blocks first launch:

- right-click `OpenBurnBar.app` → `Open` → `Open`
- or go to `System Settings` → `Privacy & Security` → `Open Anyway`

If the DMG is notarized, users should usually just double-click and launch.

### 2. Terminal source install (fallback)

```bash
git clone https://github.com/Ajnunezg/BurnBar.git
cd BurnBar
make install    # builds Release .app → /Applications
open -a OpenBurnBar
```

### 3. Xcode (contributor/dev path)

For developers only:

1. Open `OpenBurnBar.xcodeproj`
2. Select the `OpenBurnBar` scheme
3. Press Run
4. The app launches, then they can pin/use it from the menu bar

See [QUICKSTART.md](QUICKSTART.md) for the install matrix (DMG, source build, Xcode, and Homebrew tap status).

---

## Build (Mac app — development)

```bash
open OpenBurnBar.xcodeproj
```

Hit **⌘R**. The app shows up in your menu bar like a well-behaved utility.

The checked-in Xcode project is buildable as-is. Regenerate it with XcodeGen only if you change `project.yml`.

**Optional XcodeGen refresh:**

```bash
brew install xcodegen
xcodegen generate
open OpenBurnBar.xcodeproj
```

`LSUIElement` means: no Dock icon, no dramatic launch window — popover first, dashboard when you ask for it.

**Optional:** add your Apple **DEVELOPMENT_TEAM** in `project.yml` under the OpenBurnBar target if Keychain groups (Firebase / Google Sign-In) make Xcode grumpy about signing.

---

## Build (editor extension)

```bash
cd extensions/openburnbar
npm ci
npm run build
```

This repo does not currently publish a signed VSIX or marketplace listing. Build the extension locally, then load `extensions/openburnbar` through your editor's local development / unpacked-extension flow.

**Tests** (for the statistically responsible):

```bash
cd extensions/openburnbar
npm run test:ci   # unit + replay + extension-host
```

---

## Cloud sync (optional)

OpenBurnBar is a happy offline hermit by default. Cloud sync is for people who use more than one Mac and would like their totals to agree with each other.

**Pieces:**

- **Primary store:** GRDB + SQLite — fast, local, yours. **Optional at-rest encryption** uses SQLCipher (SPM `GRDB-SQLCipher`, pinned with the daemon); the encryption key lives in the Keychain. When encryption is on, the build must link SQLCipher — see [docs/THREAT_MODEL.md](docs/THREAT_MODEL.md) and [docs/RUNBOOK.md](docs/RUNBOOK.md). SQLCipher licensing: [Zetetic](https://www.zetetic.net/sqlcipher/license/).
- **Sync store:** Firestore under `users/{uid}/` — `usage` / quota / billing metadata remains server-readable; `chat_threads`, `conversations`, `text_snippets`, `mobile_assistant_chats`, `cli_sessions` plus snapshot labels/paths, `rollback_requests`, `approval_policies`, `agent_identities`, `subscription_topics`, `cli_agent_mission_requests`, and notification reply commands store private content only inside Cloud Vault sealed payloads. `session_logs` plus encrypted cloud search rows/postings are enabled separately. Hosted cloud backup writes for conversation metadata, chat content, session-log manifests/search metadata, and Hermes relay traffic require the server-written `burnbar_pro` entitlement or legacy `hosted_quota_sync`; metadata-only usage sync remains available without that paid entitlement.
- **Shared artifact sync:** Firestore under `workspaces/workspace-{uid}/teams/team-default/artifacts/{artifactID}` plus `versions/{revisionID}` for the current source-release collaboration head/history path
- **Auth:** Firebase Auth — **Google** and/or **Sign in with Apple**
- **App Check:** The app initializes App Check before Firebase; **production** Firebase projects must **enforce** App Check for **Cloud Firestore** in the console (Auth + rules are not enough). See [docs/FIREBASE_APP_CHECK_ENFORCEMENT.md](docs/FIREBASE_APP_CHECK_ENFORCEMENT.md).
- **Device identity:** random UUID stored in local app defaults and migrated from legacy OpenBurnBar/AgentLens defaults keys
- **iCloud mirror:** the legacy raw session-file mirror path is disabled and reports zero bytes to mirror. Sealed iCloud archive support must land before new session-log writes resume in iCloud.

**Current cloud behavior:** when cloud sync is enabled, OpenBurnBar uploads usage rows and operational sync metadata. Private chat/session surfaces are sealed before upload: chat-thread titles/previews/messages, mobile assistant chats, CLI session transcripts/tool pills, CLI snapshot file/path labels, rollback scopes/errors, mission prompts/results/events, text snippets, approval-policy display labels/project paths/file globs, agent persona text, subscription topic agent/topic labels, and conversation recall fields such as project/file/command labels live inside Cloud Vault payloads. Firestore rules reject the old plaintext field names on these collections. BurnBar Pro hosted session search stores encrypted bodies in Firebase Storage and sealed metadata plus opaque token/semantic hashes in Firestore; apps and explicitly configured MCP tools decrypt matches locally. See [docs/TEXT_EXPANSION.md](docs/TEXT_EXPANSION.md) for text expansion trigger, surface, and privacy details.

**Append-safe sync contract:** local SQLite/JSON insight stores remain authoritative and each enabled cloud target is treated as an append/merge replica. Firestore writes use stable document IDs plus merge semantics for usage, provider accounts, quota snapshots, sync status, and shared-artifact heads/revisions; retrying a sync is idempotent and adding new records does not delete sibling records. Local provider routing event trails persist full history even when callers request a limited display window. Remote device-local provider-account collisions are namespaced locally instead of overwriting the current Mac's Keychain-backed account, and remote download watermarks advance only after the full page has been durably persisted locally.

**Setup:**

1. Create a [Firebase](https://console.firebase.google.com) project and add a **macOS** app with bundle ID `com.openburnbar.app`.
2. Enable **Authentication** providers: **Google** and **Apple** (and whatever else you need for your own sanity).
3. Create a Firestore database (production mode) and deploy rules that cover **every** collection the app uses. In this source release that includes explicit per-user `users/{uid}/...` collections, first-class `provider_accounts`, the server-only `provider_account_secret_refs` collection used by Cloud Functions, and the current owner-scoped shared-artifact path under `workspaces/workspace-{uid}/teams/team-default/artifacts/...`. If rules allow only `usage`, enabling shared-artifact sync, **Back Up Session History**, provider-account quota refresh, or full session-log backup yields **“Missing or insufficient permissions.”** Deploy the checked-in [firestore.rules](firestore.rules), not a recursive `users/{uid}/{document=**}` shortcut:

   ```bash
   firebase deploy --only firestore:rules
   ```

   The checked-in rules intentionally keep the current shared-artifact path owner-scoped by default, reject plaintext-looking secret fields on client-writable sync documents, and deny all client access to provider credential reference documents. Broader multi-user team sharing will need a stricter project-specific policy later.

4. **App Check for Firestore (production):** After reviewing [App Check metrics](https://firebase.google.com/docs/app-check/monitor-metrics), **enforce** App Check for **Cloud Firestore** in the Firebase console. Register your [CI debug token](docs/RELEASE_MACOS.md) in App Check if you use `FIREBASE_APP_CHECK_DEBUG_TOKEN` / `FirebaseAppCheckDebugToken`. See [docs/FIREBASE_APP_CHECK_ENFORCEMENT.md](docs/FIREBASE_APP_CHECK_ENFORCEMENT.md).

5. Download `GoogleService-Info.plist` → `AgentLens/Resources/GoogleService-Info.plist` (gitignored; never commit). See `AgentLens/Resources/GoogleService-Info.plist.example` for the shape of the thing. In Xcode, use **File → Add Files to "OpenBurnBar"…**, select that plist, and check the **OpenBurnBar** target so it is copied into the app bundle.
6. Configure the **Google Sign-In** URL scheme / OAuth client as Firebase/Google Cloud demand (the app ships `OpenBurnBar-Info.plist` entries for the bundled client; yours will differ in a fork).
7. `xcodegen generate` and rebuild.

**Privacy:** Firestore can still see routing/count metadata such as provider/runtime identifiers, status, timestamps, device ids, token counts, cost estimates, opaque document ids, and sealed-envelope metadata. It cannot read sealed chat titles, previews, messages, CLI transcripts/snapshot paths, rollback scopes/errors, mission prompts/results, text snippets, approval-policy labels/paths, agent persona text, subscription topic labels, or conversation recall labels because those fields are encrypted on device with the Cloud Vault key. Full Markdown session-log bodies are encrypted before Firebase Storage upload and decrypted locally by trusted devices or explicitly configured MCP tools. You can disable sync in **Settings → Account** without sacrificing local history.

### iCloud session file mirror (disabled)

The legacy raw file-copy mirror is disabled. Existing users may still have old files in their personal iCloud Drive app container, but current builds do not create new raw `SessionMirror` copies.

- **Where old files may exist:** `Documents/OpenBurnBar/SessionMirror/<provider>/...` inside the app's iCloud container.
- **Current behavior:** the sync service reports the raw mirror as disabled, estimates zero bytes to mirror, and throws `rawMirrorDisabled` instead of exporting Hermes conversations to iCloud.
- **Cleanup:** run `scripts/privacy/scrub-icloud-session-mirror.sh` for a dry-run inventory, then `scripts/privacy/scrub-icloud-session-mirror.sh --apply` to remove legacy raw mirrored files from this Mac's iCloud Drive folder.
- **Apple Developer:** Enable **iCloud** for the macOS app ID `com.openburnbar.app` with **iCloud Documents** and container `iCloud.com.openburnbar.app`, matching [AgentLens/Resources/OpenBurnBar.entitlements](AgentLens/Resources/OpenBurnBar.entitlements).
- **Privacy:** sealed iCloud archive support must be implemented before this feature writes session logs again.
- **“Missing or insufficient permissions”:** if this appears during **Firestore** sync or dashboard refresh, update your Firestore security rules for the signed-in user, confirm **App Check enforcement** and a registered [debug token](docs/FIREBASE_APP_CHECK_ENFORCEMENT.md) for CI/local builds, and that the app bundle includes App Check (see [docs/FIREBASE_APP_CHECK_ENFORCEMENT.md](docs/FIREBASE_APP_CHECK_ENFORCEMENT.md)).

---

## What mobile shows you

`OpenBurnBarMobile` is a SwiftUI iOS 17+ companion that becomes useful immediately after sign-in. It mirrors the summaries and provider accounts your Mac publishes to Firestore, and it can add cloud-refreshable provider accounts directly when the provider supports backend refresh. Mac-local accounts stay visible as local-only snapshots, and encrypted credential transfer remains explicit.

After signing in with Apple or Google on the same Firebase account you use on Mac:

- **Dashboard** shows hero spend, period totals, top providers and models, and a sync-health pill. Empty until your Mac publishes — never tells you everything looks fine when it doesn't.
- **Quota Watch** lists urgency-sorted provider totals and account-level snapshots with provenance and a stale banner if quota data is older than the freshness threshold.
- **Activity** paginates the raw usage ledger, classifies errors into permission denied / App Check blocked / network / Firestore-unavailable rather than swallowing them.
- **Account → Devices** lets you approve this iPhone (after your Mac signs in and approves it from the new **Devices & Sync** tab in macOS Settings).
- **Account → Encrypted credential transfer** surfaces only the credentials your Mac has explicitly exported, decrypts them on this device with the iOS Keychain, and never reports success until provider readback confirms the credential works.

Provider account behavior is documented in [docs/PROVIDER_ACCOUNTS.md](docs/PROVIDER_ACCOUNTS.md). Architectural mobile details and screen-by-screen behavior live in [docs/IOS_APP_ARCHITECTURE.md](docs/IOS_APP_ARCHITECTURE.md). App Store submission steps, review-account seeding, and hosted quota subscription gates live in [docs/IOS_APP_STORE_RELEASE_RUNBOOK.md](docs/IOS_APP_STORE_RELEASE_RUNBOOK.md).

If mobile shows "No Mac data has been published yet" but the Mac is signed in, see Incidents 9–12 in the [Runbook](docs/RUNBOOK.md).

---

## Limitations (we're not going to surprise you)

- **Costs are estimates** from public price lists, not your accounting software. Great for vibes and trends; don't use them to fight finance.
- **Heuristics happen** wherever logs are shy about splits. Z.ai / MiniMax in analytics often arrive via Factory session fingerprints — clever, not clairvoyant.
- **Menu bar first** — no always-on main window by default. That's a feature for people who already have seventeen windows.
- **Cloud window:** uploaded totals emphasize roughly the **last 90 days**; ancient history stays local, like your old Xcode archives.
- **Paid-scale Firebase bar:** before onboarding paid users, deploy the incremental rollup counters, large-field index exemptions, stale-first quota refresh, and billing alert policies documented in [Paid-Scale Firebase Runbook](docs/PAID_SCALE_FIREBASE_RUNBOOK.md).

---

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) is the tour guide: folder layout, how to teach OpenBurnBar a new parser, `DesignSystem` discipline, and how to click "refresh" like a pro.

**TL;DR for parsers:** conform to `LogParser`, stay `Sendable`, return `[]` when folders ghost you — never throw a tantrum on missing files.

**Design tokens:** [DESIGN.md](DESIGN.md) — adaptive colors, SF Pro Rounded, and the botanical cream agenda.

**Where we're headed:** [docs/ROADMAP.md](docs/ROADMAP.md).

## Support

Support expectations live in [SUPPORT.md](SUPPORT.md).

---

## Security

### App Sandbox

OpenBurnBar intentionally runs **without macOS App Sandbox** (`com.apple.security.app-sandbox = false`). This is required because:

1. **Log file access**: The app monitors AI agent usage by reading log files from directories like `~/.claude/projects/`, `~/.factory/sessions/`, `~/.codex/`, `~/.kimi/sessions/`, and editor state under `~/Library/Application Support/` — none of which are accessible within a sandboxed app container.

2. **Daemon architecture**: The OpenBurnBarDaemon runs as a separate process that requires full filesystem access to scan and index conversation data across multiple locations.

3. **Firebase Auth + Keychain**: Firebase Authentication requires Keychain access which works more reliably without sandbox restrictions.

4. **Direct-download operational features**: the non-MAS build includes local routing, daemon, and developer-tool integrations that are not practical inside the Mac App Store sandbox. Raw iCloud session-file mirroring is disabled and is not a reason to accept plaintext cloud copies.

**Security implications**: Without sandboxing, if OpenBurnBar is compromised, the attacker has access to the user's home directory. However:

- Routed provider API keys and daemon-managed connector credentials use the macOS Keychain rather than plaintext files
- Hermes/OpenClaw bearer tokens and the controller Telegram bot token now live in the macOS Keychain instead of app preferences
- Network access is primarily to configured providers and optional user-enabled integrations; review connector, browser-tooling, and tunnel settings before enabling them
- The app does not silently download and execute third-party payloads, but optional assistant and daemon features can invoke locally installed developer tools and user-approved workspace commands

### Credential Storage

OpenBurnBar currently uses a **mix** of macOS Keychain and on-device app preferences.

- **Keychain-backed today:** routed provider API keys, Hermes/OpenClaw bearer tokens, the controller Telegram bot token, daemon-side provider secrets, daemon connector-plane credentials, and Cursor connector routed-provider secrets
- **Still stored in local app preferences today:** non-secret local settings such as gateway URLs, chat model overrides, and controller chat IDs

Keychain-backed secrets in this source release use a device-local accessibility class (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Cursor connector runtime state still writes a short-lived session token and non-secret route metadata into OpenBurnBar's private support directory while the bridge is active, but routed provider API keys are resolved from Keychain at runtime instead of being written to plaintext config.

### Reporting Vulnerabilities

See [SECURITY.md](SECURITY.md) for our vulnerability disclosure policy.

---

## License

Future OpenBurnBar releases are licensed under `AGPL-3.0-only`. See [LICENSE](LICENSE) for the full license text and [NOTICE](NOTICE) for project notices.

Historical snapshots published under MIT remain under the terms that applied to those releases; the preserved notice is in [LICENSES/MIT-legacy.txt](LICENSES/MIT-legacy.txt).

Third-party asset and branding notes live in [THIRD_PARTY.md](THIRD_PARTY.md). Dependency and libsignal notices live in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). AGPL corresponding-source policy lives in [docs/legal/agpl-compliance.md](docs/legal/agpl-compliance.md).
