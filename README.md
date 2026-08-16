<div align="center">
  <img src="AgentLens/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="96" alt="BurnBar" />

  # BurnBar

  > A native macOS app that watches your AI coding agents so you don't have to wonder where all your money went.

</div>

If you're the kind of person who has three AI agents running in parallel tabs and only checks the bill at the end of the month, this is for you. BurnBar sits quietly in your menu bar, reads the local session logs your agents leave behind, and gives you a live view of tokens burned and dollars spent across the providers you actually use.

For the paranoid-and-proud crowd: analytics stay **local-first**. No API keys, no account, no cloud — unless you *want* cloud. BurnBar also ships a **Cursor / VS Code extension** that talks to a small **local daemon** so your editor and your meter can be friends.

**Cursor deep dives** (for humans and agents):

- [BurnBar Mission](docs/MISSION.md)
- [BurnBar Direction](docs/DIRECTION.md)
- [BurnBar Roadmap](docs/ROADMAP.md)
- [BurnBar + Cursor Agent Onboarding](docs/BURNBAR_CURSOR_AGENT_ONBOARDING.md)
- [BurnBar Current Release Architecture](docs/BURNBAR_RELEASE_ARCHITECTURE.md)

<!-- TODO: Add screenshot — ideally one popover, one dashboard, one "oh no" spend spike -->

---

## What it does

- **Lives in your menu bar** — no Dock icon, no windows stealing focus. Click when you're curious; forget it exists when you're not.
- **Reads local logs directly** — parses session files from Claude Code, Factory/Droid, Codex, Kimi, and friends. Your API keys never leave the providers you already trust; BurnBar just reads crumbs they dropped on disk.
- **Tracks cost and token volume** — today, this week, this month. Flip between "how many dollars" and "how many tokens" like the sophisticated chaos goblin you are.
- **Smart insights** — the InsightEngine notices patterns: spend up 40% vs yesterday, cache hits doing heavy lifting, first date with a shiny new model. Little cards, not a spreadsheet cosplaying as a product.
- **Per-provider breakdown** — see which agent is winning the "most expensive hobby" award and whether it's gaining on yesterday's champion.
- **Daily digest** — optional notification at a time you pick, because future-you deserves a single sentence of truth instead of a billing surprise.
- **Chat panel** — ask questions about *your* usage data inside the dashboard. Meta? A little. Useful? Also a little. Delightful? We think so.
- **Optional cloud sync** — sign in with **Google or Apple** (Firebase under the hood), and your totals can follow you across Macs. Fully opt-in; flip it off anytime and your local world keeps spinning.
- **Optional Cursor connector** — route selected **Z.ai** and **MiniMax** models through a local OpenAI-shaped router plus a tunnel, because Cursor is picky about BYOK targets. BurnBar logs those requests so you know where the bits actually went.

---

## Local-first retrieval architecture

BurnBar search is now backed by a derived local retrieval substrate. `GRDB/SQLite` remains the interactive authority; Firestore is replication/collaboration infrastructure for shared artifacts, not the serving search path.

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

- BurnBar materializes typed subsystem health in `retrieval_health` (parser/import, discovery, projection, lexical, semantic, rebuild, collaboration, insight rollups).
- Degraded states surfaced to consumers include: **Index stale**, **Semantic unavailable**, **Rebuild in progress**, and **Cloud/shared unavailable**.
- Rebuild/re-embed are durable queue jobs (`projection_jobs`) with retry/cancel semantics; lexical retrieval remains available when semantic indexing is degraded.

### Test and eval entrypoints

- `scripts/test-burnbar-swift.sh` — Swift package tests (`BurnBarCore`, `BurnBarDaemon`)
- `scripts/test-burnbar-retrieval-evals.sh` — retrieval + authoring replay/golden suites
- `scripts/test-burnbar-release-smoke.sh` — end-to-end release smoke (Swift + retrieval evals + extension tests + daemon health)

Implementation detail and rollout notes live in [`docs/BURNBAR_SEARCH_ARCHITECTURE_SPINE.md`](docs/BURNBAR_SEARCH_ARCHITECTURE_SPINE.md).

---

## Provider support

| Provider | Usage tracking | Source | Confidence | Quota reporting |
|---|---|---|---|---|
| Claude Code | Supported | `~/.claude/projects/*.jsonl` | Exact | Supported via Claude statusline bridge (5-hour / 7-day %) |
| Factory (Droid) | Supported | `~/.factory/sessions/*.jsonl` | Exact | Estimated via plan tier + BurnBar-tracked monthly Factory tokens |
| Codex (OpenAI) | Partial | `~/.codex/state_5.sqlite` + rollout JSONL | Estimated | Supported via the latest local Codex rollout/session rate-limit snapshot |
| Kimi (Moonshot) | Partial | `~/.kimi/sessions/*.jsonl` | Estimated | Unavailable |
| Z.ai | Partial | via Factory sessions | Estimated | Supported via official monitor quota endpoints |
| MiniMax | Partial | via Factory sessions | Estimated | Supported for Token Plan via official remains endpoint |
| Copilot | Planned | — | — | Unavailable |
| Aider | Planned | — | — | Unavailable |
| Cursor connector | Supported (optional) | Cursor BYOK + BurnBar local router | Exact | Unavailable |

**Exact** = the log format actually told us the numbers; we're not guessing.

**Estimated** = we applied math and hope — e.g. Codex may only give totals without an input/output split, so BurnBar shrugs and assumes 50/50. Costs everywhere use **public pricing tables**, not your invoice. Good for trends; bad for tax audits.

Quota reporting is separate from spend history. Codex quota comes from the latest local rollout/session snapshot, Claude Code quota comes from the local statusline bridge, MiniMax and Z.ai use official API responses, and Factory / Droid remaining is an explicit estimate from BurnBar-tracked raw monthly tokens rather than Factory billable tokens.

## Live Agent Fleet

BurnBar also exposes a local, read-only view of the agents active on this
machine. The daemon is the control plane: the app and external agents read
the daemon's versioned RPC or its atomically written snapshot file; they do
not crawl agent roots themselves. The fixed roster is:

```text
claude-code, factory-droid, codex, hermes, grok-bot,
grok-cli, pi, cursor, kimi, gemini-cli
```

Each row reports `running`, `idle`, `stale`, or `unknown` together with an
honest confidence tier (`exactProcess`, `activeSessionFile`, `logHeartbeat`,
`estimated`, or `unsupported`). Missing, malformed, or unsupported signals
remain typed rows instead of becoming fabricated liveness. Fleet serving is
local-only and does not use Firebase, Firestore, cloud relay, spawning, run
graphs, or cross-agent arbitration.

The default local paths are:

```text
socket:          ~/Library/Application Support/BurnBar/burnbar-daemon.sock
snapshot file:   ~/Library/Application Support/BurnBar/fleet-snapshot.json
state database:  ~/Library/Application Support/BurnBar/fleet.sqlite
```

`BURNBAR_DAEMON_SUPPORT_DIR` redirects the support directory and therefore the
default socket, snapshot, and database together. A non-empty
`BURNBAR_DAEMON_SOCKET_PATH` overrides only the socket; an empty value is
treated as unset by the daemon and documented readers. The daemon also
accepts `--socket-path PATH`, which wins over the environment override.
`BURNBAR_FLEET_ROOTS_DIR` points probes at hermetic fixture roots, and
`BURNBAR_FLEET_CADENCE_SECONDS` changes both the ticker and the reported
`cadenceSeconds` (the default is 15 seconds). Per-agent
`BURNBAR_FLEET_ROOT_<AGENT>` values override the base root when a fixture
needs a single-provider seam. `BURNBAR_FLEET_EVENT_RETENTION_SECONDS`
overrides the default 24-hour event history only for accelerated validation.
Probe roots are read-only and `~/.factory/artifacts/` is never traversed.

The versioned fleet methods are:

```text
daemon.fleet.snapshot             read latest completed snapshot
daemon.fleet.orchestrator.get    read daemon-owned designation
daemon.fleet.orchestrator.set    write an approved designation
daemon.fleet.directive.record    record an approved/dismissed/delivery outcome
```

The three write methods are control-plane operations, not general agent
permissions. They validate payloads, preserve typed outcomes, and serialize
daemon-owned state.

### Fleet smoke test

From the repository root, run this complete command block. It builds the
daemon, starts one hermetic instance with empty fixture roots, reads a
versioned snapshot over AF_UNIX, and checks the raw `fleet-snapshot.json`
file. The trap stops only the daemon started by this block and removes its
temporary directory.

```sh
set -eu
TMPD="$(mktemp -d "${TMPDIR:-/tmp}/burnbar-readme.XXXXXX")"
DAEMON_PID=""
cleanup() {
  if [ -n "$DAEMON_PID" ]; then
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi
  rm -rf "$TMPD"
}
trap cleanup EXIT

for root in claude factory codex hermes grokbot grok pi cursor kimi gemini; do
  mkdir -p "$TMPD/roots/$root"
done

BIN="$(swift build --package-path BurnBarDaemon --show-bin-path)/BurnBarDaemon"
BURNBAR_DAEMON_SUPPORT_DIR="$TMPD/support" \
BURNBAR_FLEET_ROOTS_DIR="$TMPD/roots" \
BURNBAR_FLEET_CADENCE_SECONDS=1 \
"$BIN" --socket-path "$TMPD/burnbar-daemon.sock" >"$TMPD/daemon.log" 2>&1 &
DAEMON_PID=$!

export BURNBAR_DAEMON_SUPPORT_DIR="$TMPD/support"
export BURNBAR_DAEMON_SOCKET_PATH="$TMPD/burnbar-daemon.sock"
python3 - <<'PY'
import json
import os
import socket
import time

sock_path = os.environ["BURNBAR_DAEMON_SOCKET_PATH"]
request = b'{"id":"readme-fleet","method":"daemon.fleet.snapshot"}\n'
for _ in range(80):
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(2)
    try:
        client.connect(sock_path)
        client.sendall(request)
        response = json.loads(client.makefile("rb").read().decode())
    except (OSError, json.JSONDecodeError):
        response = {}
    finally:
        client.close()
    if response.get("protocolVersion") == 1 and "result" in response:
        snapshot = response["result"]["snapshot"]
        assert snapshot["schemaVersion"] == 1
        assert len(snapshot["agents"]) == 10
        print(
            "fleet smoke: protocol=1 schema=1 "
            f"agents={len(snapshot['agents'])} cadence={snapshot['cadenceSeconds']}"
        )
        break
    time.sleep(0.05)
else:
    raise SystemExit("fleet snapshot did not become ready")
PY

jq '{schemaVersion, generatedAt, cadenceSeconds, runningCount, persistenceHealth}' \
  "$BURNBAR_DAEMON_SUPPORT_DIR/fleet-snapshot.json"
```

For the complete schema, typed error matrix, read-only Python consumer,
orchestrator approval flow, Hermes delivery outcome, and restart/freshness
rules, see [`docs/fleet/BURNBAR_FLEET_API.md`](docs/fleet/BURNBAR_FLEET_API.md)
and the canonical signal inventory in
[`docs/fleet/BURNBAR_FLEET_SIGNALS.md`](docs/fleet/BURNBAR_FLEET_SIGNALS.md).

An app built against a newer fleet contract degrades honestly when paired
with an older daemon: `daemon.fleet.snapshot` may return a typed
method-not-found or protocol error, and Fleet shows an unavailable/mismatch
state rather than fabricated rows. The existing usage dashboard, provider
details, settings, and menu-bar surfaces remain independent. Multiple app
instances may read the same daemon snapshot safely; daemon-owned designation
and directive writes remain serialized and are never duplicated by reads.

The first-visit control path is deliberately human-approved: open Fleet,
designate BurnBar or a declared agent, switch the existing chat panel to
Orchestrator, inspect the proposal, approve or dismiss it, and treat Hermes
delivery as either a recorded delivered/failed outcome or an explicit typed
unsupported result. No step spawns agents, builds an execution graph, or
arbitrates work across agents.

### Cursor agent provider scope (narrower on purpose)

Routed Cursor traffic is a smaller club than the table above.

- **In:** `Z.ai`, `MiniMax`
- **Out (on purpose):** `Kimi`, `pony-alpha-2`, hidden/internal catalog models, browser tools
- **Public catalog examples for routing:** `glm-5-turbo`, `glm-5`, `minimax-m2.7-highspeed`

The sidebar today is honest about being a **shell**: health, catalog, workspace state, recovery copy — the full run-control red carpet is still rolling out.

---

## BurnBar in Cursor (and VS Code)

The extension is **local-first** and **daemon-backed**. Think of it as a polite sidecar, not a second brain.

You get:

- a BurnBar activity bar home with **Health**, **Runs**, and **Run Detail**
- **Reconnect**, **Refresh**, and **Repair Daemon** when the universe is misaligned
- workspace capability detection (local, remote, read-only, virtual, restricted) so the UI doesn't lie to you
- inline recovery prose for the usual failure modes — socket missing, timeout, protocol mismatch, "did you install the daemon?", etc.

**Restricted workspaces** (Cursor/VS Code untrusted mode):

- **Allowed:** `read_file`, `search_workspace`, health, catalog state, projected run state
- **Gated until trusted:** `apply_patch`, `run_terminal`

**Fast start** (five steps, zero mysticism):

1. Run BurnBar on the same Mac as the editor.
2. Install or repair the daemon from BurnBar.
3. Add Z.ai / MiniMax keys if you want routed models.
4. Install the BurnBar extension from `extensions/burnbar` (build with `npm run build` in that folder, then load the unpacked extension in your editor of choice).
5. Open a folder or workspace, then open the BurnBar sidebar and say hi.

---

## Cursor provider routing (the tunnel plot twist)

BurnBar can wire supported models into Cursor without you hand-editing ghost JSON or running a sketchy proxy you found at 2am.

The play:

- Keys live in the **macOS Keychain** (where keys belong).
- You pick which model IDs Cursor should believe in.
- A local **OpenAI-compatible router** wakes up.
- A **public HTTPS tunnel** appears because Cursor blocks `localhost` and private IPs for BYOK — not our rule, just our problem to solve.
- BurnBar writes Cursor's custom-model BYOK settings for you.
- Routed usage shows up as **`BurnBar Cursor Connector`** so your dashboard and your conscience stay aligned.

**v1 scope:** `Z.ai`, `MiniMax`. **Tunnel flavor:** Cloudflare quick tunnel (bring `cloudflared`).

**Checklist:**

1. Install `cloudflared` (Homebrew is fine; the internet is full of opinions).
2. BurnBar → **Settings → Providers → Connect Cursor**
3. Paste keys, pick models, mash **Connect**
4. Leave BurnBar running while Cursor chats through the connector — it's doing real work under the hood.

---

## Repository map (yes, the folder is still named AgentLens)

The Mac app sources live under **`AgentLens/`** because renaming folders is a personality test Xcode sometimes fails. The product name is **BurnBar**; the bundle is **`com.burnbar.app`**. Roll with it.

| Area | What lives there |
|---|---|
| `AgentLens/` | SwiftUI app: menu bar, dashboard, settings, parsers, GRDB store |
| `BurnBarCore/` | Shared types and RPC contracts for app ↔ daemon |
| `BurnBarDaemon/` | Local JSON-RPC daemon + executable wrapper |
| `extensions/burnbar/` | TypeScript extension for Cursor / VS Code |
| `docs/` | Mission, direction, roadmap, architecture, onboarding, and other words we meant |

---

## Requirements

- macOS 14 Sonoma or later
- Xcode 16+
- Swift 5.10
- Node + npm (only if you're hacking the editor extension)

---

## Build (Mac app)

```bash
git clone https://github.com/Ajnunezg/BurnBar.git
cd BurnBar
open BurnBar.xcodeproj
```

Hit **⌘R**. The app shows up in your menu bar like a well-behaved utility.

**xcodegen** fans:

```bash
brew install xcodegen
xcodegen generate
open BurnBar.xcodeproj
```

`LSUIElement` means: no Dock icon, no dramatic launch window — popover first, dashboard when you ask for it.

**Optional:** add your Apple **DEVELOPMENT_TEAM** in `project.yml` under the BurnBar target if Keychain groups (Firebase / Google Sign-In) make Xcode grumpy about signing.

---

## Build (editor extension)

```bash
cd extensions/burnbar
npm install
npm run build
```

Load the `extensions/burnbar` folder as an unpacked extension in Cursor or VS Code.

**Tests** (for the statistically responsible):

```bash
cd extensions/burnbar
npm run test:ci   # unit + replay + extension-host
```

---

## Cloud sync (optional)

BurnBar is a happy offline hermit by default. Cloud sync is for people who use more than one Mac and would like their totals to agree with each other.

**Pieces:**

- **Primary store:** GRDB + SQLite — fast, local, yours
- **Sync store:** Firestore under `users/{uid}/` — `usage`, `conversations` (optional metadata backup), `session_logs` (+ `chunks` for full log backup when enabled)
- **Auth:** Firebase Auth — **Google** and/or **Sign in with Apple**
- **Device identity:** random UUID in Keychain (survives reinstalls, judges silently)
- **iCloud mirror (optional):** copies parsed session log files into your **personal** iCloud Drive folder for the app (`Documents/BurnBar/SessionMirror/...`). Independent of Firebase; see below.

**Setup:**

1. Create a [Firebase](https://console.firebase.google.com) project and add a **macOS** app with bundle ID `com.burnbar.app`.
2. Enable **Authentication** providers: **Google** and **Apple** (and whatever else you need for your own sanity).
3. Create a Firestore database (production mode) and deploy rules that cover **every** collection the app uses (not only `usage`). If rules allow only `usage`, enabling **Back Up Session History** or full session-log backup yields **“Missing or insufficient permissions.”** Use a single subtree rule (same as [firestore.rules](firestore.rules) in this repo):

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /users/{userId}/{document=**} {
      allow read, write: if request.auth != null && request.auth.uid == userId;
    }
  }
}
```

   Paste into **Firebase Console → Firestore → Rules** and publish, or add `firestore.rules` to your Firebase CLI project and run `firebase deploy --only firestore:rules`.

4. Download `GoogleService-Info.plist` → `AgentLens/Resources/GoogleService-Info.plist` (gitignored; never commit). See `AgentLens/Resources/GoogleService-Info.plist.example` for the shape of the thing.
5. Configure the **Google Sign-In** URL scheme / OAuth client as Firebase/Google Cloud demand (the app ships `BurnBar-Info.plist` entries for the bundled client; yours will differ in a fork).
6. `xcodegen generate` and rebuild.

**Privacy:** synced payloads can include **project directory names** and **model names** from sessions. You can disable sync in **Settings → Account** without sacrificing local history.

### iCloud session file mirror (optional)

Use this when you want session logs in **your** Apple ID’s iCloud storage instead of (or in addition to) Firestore metadata.

- **Where:** After each successful refresh, BurnBar incrementally copies files from each supported provider’s configured log path into the app’s iCloud container: `Documents/BurnBar/SessionMirror/<provider>/…` (same layout as on disk under that root).
- **UI:** **Settings → Account → iCloud session files** — toggle, status, **Set up guide** (iCloud sign-in check, privacy notes, size estimate, **Reveal in Finder**, **Mirror now**, and advanced Terminal examples for symlink-based relocation).
- **Apple Developer:** Enable **iCloud** for the macOS app ID `com.burnbar.app` with **iCloud Documents** and container `iCloud.com.burnbar.app`, matching [AgentLens/Resources/BurnBar.entitlements](AgentLens/Resources/BurnBar.entitlements).
- **Privacy:** mirrored files can contain paths, prompts, and code snippets. They are **not** uploaded to BurnBar-operated Firebase storage by this feature (they sync through Apple’s iCloud like any other document).
- **Conflicts:** editing the same mirrored file on two Macs can produce iCloud “conflict” copies; BurnBar does not merge those automatically.
- **“Missing or insufficient permissions”:** if this appears during **Firestore** sync or dashboard refresh, update your Firestore security rules for the signed-in user. If it appears only when **mirroring to iCloud**, the Mac build usually needs the **iCloud Documents** capability and matching **provisioning profile** for container `iCloud.com.burnbar.app` (see Apple Developer → Identifiers → your App ID).

---

## Limitations (we're not going to surprise you)

- **Costs are estimates** from public price lists, not your accounting software. Great for vibes and trends; don't use them to fight finance.
- **Heuristics happen** wherever logs are shy about splits. Z.ai / MiniMax in analytics often arrive via Factory session fingerprints — clever, not clairvoyant.
- **Menu bar first** — no always-on main window by default. That's a feature for people who already have seventeen windows.
- **Cloud window:** uploaded totals emphasize roughly the **last 90 days**; ancient history stays local, like your old Xcode archives.

---

## Contributing

[CONTRIBUTING.md](CONTRIBUTING.md) is the tour guide: folder layout, how to teach BurnBar a new parser, `DesignSystem` discipline, and how to click "refresh" like a pro.

**TL;DR for parsers:** conform to `LogParser`, stay `Sendable`, return `[]` when folders ghost you — never throw a tantrum on missing files.

**Design tokens:** [DESIGN.md](DESIGN.md) — adaptive colors, SF Pro Rounded, and the botanical cream agenda.

**Where we're headed:** [docs/ROADMAP.md](docs/ROADMAP.md).

---

## License

No root `LICENSE` file yet — we're in the awkward "figure out the legal bit" phase. The editor extension's `package.json` currently says `UNLICENSED`; treat that as a placeholder until we pick something human-readable.
