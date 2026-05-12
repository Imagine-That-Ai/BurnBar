/* Headline features — each tied back to repo evidence */

export interface Feature {
  id: string;
  title: string;
  blurb: string;
  details?: string;
  evidence: string; // file:line reference for internal review
  category: "tracking" | "control" | "assistant" | "surface" | "honesty";
}

export const FEATURES: Feature[] = [
  {
    id: "menu-bar",
    title: "Lives in your menu bar",
    blurb:
      "No Dock icon, no windows stealing focus. Click once, see today's burn. Click again, dive in.",
    evidence: "AgentLens/Views/Popover/MenuBarPopoverView.swift; LSUIElement: README.md:342",
    category: "surface"
  },
  {
    id: "log-reader",
    title: "Reads logs, not API keys",
    blurb:
      "OpenBurnBar reads the JSONL crumbs Claude Code, Codex, Factory and friends drop on disk. Your API keys never leave the providers you already trust.",
    evidence: "AgentLens/Services/LogParser/; README.md:54-67",
    category: "tracking"
  },
  {
    id: "cost-token-rollups",
    title: "Cost and tokens — today, this week, this month, all-time",
    blurb:
      "Real numbers. Cost is exact where the vendor returns it, computed where they don't. Confidence is labeled on every row.",
    evidence: "AgentLens/Services/UsageAggregator.swift, LocalMetricsAggregator.swift",
    category: "tracking"
  },
  {
    id: "quota-windows",
    title: "Quota — distinct from spend",
    blurb:
      "Five-hour windows for Claude Code and Codex. Weekly for Kimi. Premium interactions for Copilot. Per-model for MiniMax. Plan-used USD for Cursor. Refresh on tap.",
    evidence: "AgentLens/Services/ProviderQuota/; docs/PROVIDERS.md",
    category: "tracking"
  },
  {
    id: "insight-engine",
    title: "Insights that learn your rhythm",
    blurb:
      "InsightEngine notices when spend spikes, a new model shows up, a cache lands, or a quota window is about to close. Daily digest at the time you choose.",
    evidence: "AgentLens/Services/InsightEngine.swift, DailyDigestManager.swift",
    category: "tracking"
  },
  {
    id: "hermes",
    title: "Hermes — chat over your own data",
    blurb:
      "An on-device assistant that knows your sessions, providers, models, and recent runs. Two modes — Local Index (stateless, CLI-backed) and Hermes Gateway (multi-turn, OpenAI-shaped, runs locally).",
    evidence: "AgentLens/Views/Chat/, DESIGN.md:150-187",
    category: "assistant"
  },
  {
    id: "conversation-atoms",
    title: "Conversation Atoms",
    blurb:
      "Every entity Hermes mentions — cost, session, provider, model, window, tool, project — becomes a tappable inline chip that opens the matching native detail view.",
    evidence: "docs/CONVERSATION_ATOMS.md; OpenBurnBarCore/.../Pretext/",
    category: "assistant"
  },
  {
    id: "chart-studio",
    title: "Chart Studio — answers as charts",
    blurb:
      "Hermes streams JSON envelopes that render to 10 native Swift Charts kinds and sandboxed Mermaid diagrams on iOS and iPadOS.",
    evidence: "docs/CHART_STUDIO.md; OpenBurnBarMobile/Views/ChartStudio/",
    category: "assistant"
  },
  {
    id: "daemon",
    title: "Daemon-first control plane",
    blurb:
      "A launchd-managed local daemon owns routing, quota, retrieval, projects, missions, and replay. Every surface — Mac, iOS, Cursor, CLI — talks to it.",
    evidence: "OpenBurnBarDaemon/; docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md",
    category: "control"
  },
  {
    id: "router",
    title: "Fire Hydrant — multi-provider router with automatic failover",
    blurb:
      "Cursor, Factory and OpenCode point at one local gateway. When a Z.ai or MiniMax account hits its quota — or a token expires — the router shifts traffic to the next healthy account, ranking by health then least-recently-used. No manual swaps. No failed calls landing in your IDE.",
    evidence:
      "OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/ProviderAccountTypes.swift:403-599; docs/ROUTED_CLIENT_GATEWAY.md",
    category: "control"
  },
  {
    id: "cli",
    title: "openburnbar — a real CLI",
    blurb:
      "health · controller · questions · followups · missions · mission-approve · simulator-runs · simulator-replay. Scriptable from any agent, git hook, or operator console.",
    evidence: "OpenBurnBarDaemon/Sources/OpenBurnBarCLI/; README.md:76-86",
    category: "control"
  },
  {
    id: "editor-extension",
    title: "Cursor & VS Code panel",
    blurb:
      "An activity-bar surface that shows the burn for your active workspace and routes provider traffic through the local gateway. Source-only today; build locally and load unpacked.",
    evidence: "extensions/openburnbar/",
    category: "surface"
  },
  {
    id: "ios-companion",
    title: "iPhone & iPad — the rest of your screens",
    blurb:
      "Quota Watch, Pulse, Streams, Hermes, Chart Studio. Live Activity on the lock screen. Siri shortcut: \"What's my burn today?\"",
    evidence: "OpenBurnBarMobile/; CHANGELOG.md:522-538",
    category: "surface"
  },
  {
    id: "smart-display",
    title: "Smart displays",
    blurb:
      "One-click cast to a Nest Hub or Pixel Clock. Only marks healthy after the display itself confirms acceptance.",
    evidence: "AgentLens/Services/Cast/, SmartHub/; docs/SMART_DISPLAY_DEVICE_QA.md",
    category: "surface"
  },
  {
    id: "honest-confidence",
    title: "Honest confidence labels",
    blurb:
      "Every provider row carries one of three labels — Exact, Estimated, Unavailable. We don't pretend to know what the vendor doesn't tell us.",
    evidence: "docs/PROVIDERS.md; AgentLens/Services/ProviderQuota/",
    category: "honesty"
  },
  {
    id: "local-first",
    title: "Local-first by design",
    blurb:
      "Local SQLite + the local daemon are canonical. Firestore is an optional replication plane — never the source of truth. The whole product works offline.",
    evidence: "docs/OPENBURNBAR_RELEASE_ARCHITECTURE.md:5-16; docs/THREAT_MODEL.md:188",
    category: "honesty"
  }
];

export const FEATURES_BY_CATEGORY = {
  tracking: FEATURES.filter((f) => f.category === "tracking"),
  control: FEATURES.filter((f) => f.category === "control"),
  assistant: FEATURES.filter((f) => f.category === "assistant"),
  surface: FEATURES.filter((f) => f.category === "surface"),
  honesty: FEATURES.filter((f) => f.category === "honesty")
};
