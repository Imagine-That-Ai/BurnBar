<div align="center">
  <img src="AgentLens/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128.png" width="96" alt="BurnBar" />

  # BurnBar

  > A native macOS app that watches your AI coding agents so you don't have to wonder where all your money went.

</div>

If you're the kind of person who has three AI agents running in parallel tabs and only checks the bill at the end of the month, this is for you. BurnBar sits quietly in your menu bar, reads the local session logs your agents leave behind, and gives you a live view of tokens burned and dollars spent across every provider you use.

For analytics, it stays local-first: no API keys, no account, no cloud required. BurnBar also ships a Cursor extension shell backed by the local BurnBar daemon.

Cursor docs:

- [BurnBar + Cursor Agent Onboarding](docs/BURNBAR_CURSOR_AGENT_ONBOARDING.md)
- [BurnBar Current Release Architecture](docs/BURNBAR_RELEASE_ARCHITECTURE.md)

<!-- TODO: Add screenshot -->

---

## What it does

- **Lives in your menu bar** — no Dock icon, no windows stealing focus. Click the icon when you're curious, ignore it when you're not.
- **Reads local logs directly** — parses session files from Claude Code, Factory/Droid, Codex, Kimi, and more. No tokens or credentials needed.
- **Tracks cost and token volume** — today, this week, this month. Toggle between dollar view and raw token counts.
- **Smart insights** — the InsightEngine notices patterns: spend up 40% vs yesterday, cache hits covering most of your tokens, first session with a new model. Surfaced as brief cards, not a wall of charts.
- **Per-provider breakdown** — see exactly which agent is costing the most and how that shifts day over day.
- **Daily digest** — optional notification at a time you pick, summarizing the day's usage in a sentence or two.
- **Chat panel** — ask questions about your own usage data directly inside the dashboard.
- **Optional cloud sync** — Sign in with Apple and your totals follow you across machines. Firebase-backed, fully opt-in, and you can turn it off without losing anything local.
- **Optional Cursor connector** — bring selected Z.ai and MiniMax models into Cursor through a local router and public tunnel, with route logging so you can verify exactly where requests went.

---

## Provider Support

| Provider | Status | Log Location | Confidence |
|---|---|---|---|
| Claude Code | Supported | `~/.claude/projects/*.jsonl` | Exact |
| Factory (Droid) | Supported | `~/.factory/sessions/*.jsonl` | Exact |
| Codex (OpenAI) | Partial | `~/.codex/state_5.sqlite` | Estimated |
| Kimi (Moonshot) | Partial | `~/.kimi/sessions/*.jsonl` | Estimated |
| Zai | Partial | via Factory sessions | Estimated |
| MiniMax | Partial | via Factory sessions | Estimated |
| Copilot | Planned | — | — |
| Aider | Planned | — | — |
| Cursor connector | Supported (optional) | Cursor BYOK + BurnBar local router | Exact |

**Exact** means token counts come directly from the provider's log format.
**Estimated** means some heuristics are involved — for example, Codex stores total tokens without an input/output split, so BurnBar assumes 50/50. Costs are always calculated from public pricing tables, never from your billing account.

### Cursor Agent Provider Scope

Current routed Cursor scope is narrower than the analytics table above.

- Supported now: `Z.ai`, `MiniMax`
- Intentionally unsupported for routed Cursor use: `Kimi`, `pony-alpha-2`, hidden/internal catalog models
- Current public catalog models for routed Cursor use: `glm-5-turbo`, `glm-5`, `minimax-m2.7-highspeed`

The current Cursor sidebar is still a daemon/workspace shell. It shows health, catalog state, workspace state, and recovery guidance, but it does not yet expose full run controls from the sidebar.

---

## BurnBar In Cursor

The current BurnBar Cursor release is local-first and daemon-backed.

What you get today:

- a BurnBar activity bar entry with `Health`, `Runs`, and `Run Detail`
- reconnect, refresh, and daemon repair actions
- workspace capability detection for local, remote, read-only, virtual, and restricted modes
- inline recovery copy for common daemon and workspace failures

Restricted-mode behavior in the shipped extension:

- Available: `read_file`, `search_workspace`, health, catalog state, projected run state
- Gated: `apply_patch`, `run_terminal`

Fast start:

1. Open BurnBar on the same macOS machine as Cursor.
2. Install or repair the daemon in BurnBar.
3. Add Z.ai or MiniMax keys if you want routed Cursor models.
4. Install the BurnBar extension in Cursor.
5. Open a folder or workspace, then open the BurnBar sidebar.

---

## Cursor Provider Routing

BurnBar can also route supported provider models into Cursor without hand-editing Cursor state or running your own proxy.

What it does

- Stores your Z.ai and MiniMax API keys in the local macOS Keychain
- Lets you choose exactly which model IDs Cursor should see
- Starts a local OpenAI-compatible router
- Opens a public HTTPS tunnel because Cursor blocks `localhost` and private-IP BYOK targets
- Writes Cursor's custom-model BYOK settings for you
- Logs routed requests back into BurnBar as `BurnBar Cursor Connector` usage

v1 scope

- Supported providers: `Z.ai`, `MiniMax`
- Intentionally excluded: `Kimi`, `pony-alpha-2`
- Current tunnel path: Cloudflare quick tunnel for fastest setup

What you need

1. Install `cloudflared`
2. Open `Settings > Providers > Connect Cursor`
3. Paste keys, choose models, and press `Connect`
4. Keep BurnBar running while Cursor uses the connector

---

## Requirements

- macOS 14 Sonoma or later
- Xcode 16+
- Swift 5.10

---

## Build

```bash
git clone https://github.com/your-org/BurnBar.git
cd BurnBar
open BurnBar.xcodeproj
```

Hit `Cmd+R`. The app will appear in your menu bar.

If you prefer xcodegen:

```bash
brew install xcodegen
xcodegen generate
open BurnBar.xcodeproj
```

The app runs as `LSUIElement` — no Dock icon, no main window on launch. Everything is in the menu bar popover and the dashboard window that opens from it.

---

## Cloud Sync (optional)

BurnBar works completely offline out of the box. Cloud sync is an opt-in layer for people who want their totals to follow them across machines.

**How it works:**

- **Primary store:** GRDB SQLite — local, fast, always-on
- **Sync store:** Firestore under `users/{uid}/usage/{deviceId}_{usageId}`
- **Auth:** Sign in with Apple via Firebase Auth
- **Device identity:** A random UUID in Keychain that survives reinstalls

**Setup:**

1. Create a project in [Firebase Console](https://console.firebase.google.com) and add a macOS app with bundle ID `com.burnbar.app`.
2. Enable **Authentication > Sign-in method > Apple**.
3. Create a Firestore database (production mode) and deploy these security rules:

```
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    match /users/{userId}/usage/{doc} {
      allow read, write: if request.auth != null && request.auth.uid == userId;
    }
  }
}
```

4. Download `GoogleService-Info.plist` and place it at `AgentLens/Resources/GoogleService-Info.plist`. This file is gitignored — never commit it. See `GoogleService-Info.plist.example` for the expected shape.

5. Run `xcodegen generate` and rebuild.

**Privacy note:** Sync data includes project directory names and model names from your sessions. You can disable cloud sync at any time in **Settings > Account** without losing any local data.

---

## Limitations

Worth being upfront about:

- **Costs are estimates.** Calculated from public pricing tables, not your actual invoices. Good for patterns and relative comparison, not for reconciling your credit card statement.
- **Estimated providers use heuristics.** If a log format doesn't expose input vs. output token counts separately, BurnBar splits them proportionally. Zai and MiniMax are detected by model name inside Factory session logs.
- **Menu bar only by design.** There's no persistent main window — that's intentional. The dashboard opens on demand and closes when you're done.
- **Cloud totals cover the last 90 days** of uploaded data. Everything older stays local.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) for a full walkthrough of the project structure, how to add a new provider parser, coding conventions, and how to test changes.

The short version: parsers conform to `LogParser`, run in async contexts, must be `Sendable`, and should return an empty array gracefully when the log directory doesn't exist — never crash on missing data.

---

## License

<!-- TODO: Add license -->
