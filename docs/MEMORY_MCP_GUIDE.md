# Memory (Pensieve) — Quick Guide

BurnBar Memory quietly remembers what matters from your AI conversations —
decisions, fixes, preferences, project facts — and hands them back to any AI
tool you use. Everything is sealed with a key only your devices hold; our
servers store only scrambled data they cannot read.

The same tour ships inside the app as a guided walkthrough with spotlights:
**Settings › Cloud › Remote MCP › “How Memory works”** opens a five-page modal
(`AgentLens/Views/Settings/MemoryMCPWalkthroughView.swift`) whose copy is
pinned by `MemoryMCPWalkthroughTests`. Each spotlight page previews the real
control and offers a **Show me** button that takes you straight to it; the tour
is also reachable from **Help › How Memory Works…** (⇧⌘M), from **Settings
search** (“memory tour”, “pensieve tour”, “how memory works”), and from the
**Data & Privacy** landing.

Inside the tour, the voice is Pensieve — the memory basin itself — speaking in
plain language so a non-technical reader can finish in under a minute and still
remember where every control lives.

## The 60-second setup

1. **Sign in.** Open BurnBar › Settings › Cloud and sign in. Memory search
   rides on the Cloud Pro plan (trials count).
2. **Do nothing else.** Memory turns itself on. When a chat with your AI ends,
   BurnBar distills the useful facts, seals them with your vault key, and
   stores them. It never interrupts a conversation and never spends your AI
   credits.
3. **Connect your other AI tools (optional).** Settings › Cloud › Remote MCP
   shows the pieces. Tap **Link this Mac's CLI** and BurnBar configures
   supported tools for you. Doing it by hand? The endpoint is
   `https://mcp.burnbar.ai/mcp`, and the one-line connector for stdio-only
   clients is `openburnbar-mcp-remote mcp serve`. That connector is the
   Memory MCP.
4. **Ask for things back.** In any connected AI tool — or in the BurnBar app
   on iPhone, iPad, and Android — just ask in plain words. Your memory
   answers.

## Things worth asking

- “What do you remember about the auth refactor?”
- “Resume the conversation where we fixed the login bug.”
- “What did I decide about caching, and why?”
- “Which project used the MiniMax model last weekend?”
- “Summarize what we shipped this week.”

Behind the scenes your assistant searches your sealed memory, fetches the
exact conversation or fact, and decrypts it on your device — the cloud only
ever sees scrambled data.

## What gets remembered — and what never does

| Remembered | Never stored |
| --- | --- |
| Decisions and the reasons behind them | Secrets — API keys and passwords are blocked before they can be written |
| Fixes that worked (“how we solved X”) | Anything you delete or ask us to forget |
| Your preferences and conventions | Anything from a chat while Memory is off |
| Project facts and session summaries | Anything our servers could read — they only hold sealed data |

## You're in control

Open **Settings › Data & Privacy** — the control center for everything
BurnBar holds.

- **See it.** Every category of data with a live record count and a “% sealed”
  gauge.
- **Export it.** One click downloads everything as JSON, whenever you want.
- **Forget it.** Delete a single memory or a whole category; it's gone from
  your devices and the cloud.
- **Panic.** One button revokes all access immediately if a device is lost or
  something feels wrong.

## Troubleshooting

| What you see | What to do |
| --- | --- |
| A lock badge on Remote MCP | Memory search needs an active Cloud Pro plan — Settings › Cloud shows the options. |
| Recall comes back empty | Finish one full AI chat first. Memory is written when a session ends, not mid-conversation. |
| A tool can't connect | Run `openburnbar mcp doctor` in Terminal — it checks the link and tells you what to fix. |
| You changed your mind | Settings › Data & Privacy › delete the memory domain, or use Panic to revoke everything. |

## Five words we use

- **Pensieve** — the memory basin inside BurnBar.
- **Memory MCP** — the plug that lets any AI tool ask your memory questions.
- **Vault key** — the secret only your devices hold; it seals and unseals your
  memory.
- **Sealed** — encrypted so only you can read it. Not us, not anyone else.
- **Recall** — asking your memory a question and getting the answer back.

That's the whole thing. Sign in once, and your AI tools finally remember.

---

For the engineering contract behind this surface (tool registry, entitlement
gates, sealed recall), see
[`services/hosted-mcp/src/toolRegistry.ts`](../services/hosted-mcp/src/toolRegistry.ts)
and [`docs/MEMORY_STRATEGY_AUDIT.md`](MEMORY_STRATEGY_AUDIT.md).
