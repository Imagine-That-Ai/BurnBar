/* Where OpenBurnBar shows up — macOS, iOS, daemon, CLI, etc. */

export type SurfaceStatus = "shipping" | "review" | "beta" | "source-only" | "planned";

export interface Surface {
  id: string;
  name: string;
  platform: string;
  status: SurfaceStatus;
  statusLabel: string;
  description: string;
  bullets: string[];
  cta?: { href: string; label: string; external?: boolean };
}

export const SURFACES: Surface[] = [
  {
    id: "macos",
    name: "macOS menu bar app",
    platform: "macOS 14+",
    status: "shipping",
    statusLabel: "Shipping",
    description:
      "The home base. Lives in the menu bar, reads local agent logs, surfaces cost, tokens, quota, sessions, and insights.",
    bullets: [
      "LSUIElement — no Dock icon, no windows stealing focus",
      "Dashboard, providers, models, sessions, projects, streams, search",
      "Hermes chat panel sits inside the dashboard",
      "Daily digest, smart insights, quota refresh, daemon-backed control plane",
      "Optional Firebase sync, optional iCloud session mirror, optional Sentry diagnostics"
    ],
    cta: { href: "/download", label: "Download for macOS" }
  },
  {
    id: "ios",
    name: "iPhone & iPad companion",
    platform: "iOS 17+",
    status: "review",
    statusLabel: "In App Store review",
    description:
      "Your whole burn picture, in your pocket. The Mac does the work; the phone and tablet show it — and reach back to it.",
    bullets: [
      "See spend the moment it happens — charts drawn from your own numbers",
      "Live on the lock screen and Dynamic Island, plus a “What's my burn today?” Siri shortcut",
      "Floo — see, steer, and unlock your Mac right from your phone",
      "Watch an agent work, or approve its moves, on the go",
      "Ask your Mac's assistant from anywhere — privately (paid)"
    ],
    cta: { href: "/download#ios", label: "iOS launch status" }
  },
  {
    id: "cursor",
    name: "Cursor & VS Code extension",
    platform: "Cursor / VS Code 1.95+",
    status: "source-only",
    statusLabel: "Source-only beta",
    description:
      "An activity-bar panel that hooks into the daemon over the local UNIX socket. Build locally and load unpacked — no marketplace listing yet.",
    bullets: [
      "Burn for the active workspace, scoped to the current Cursor agent run",
      "Quota panel pulled from the same daemon the menu bar reads",
      "Routed-provider gateway support — Z.ai, MiniMax, Ollama Cloud via Cloudflare tunnel",
      "Open VSX / VS Marketplace publication is on the roadmap, not shipped"
    ],
    cta: { href: "/download#editor", label: "Editor setup" }
  },
  {
    id: "daemon",
    name: "Local daemon",
    platform: "Embedded in macOS app",
    status: "shipping",
    statusLabel: "Shipping",
    description: "The control plane. A launchd-managed UNIX socket service every surface talks to.",
    bullets: [
      "Auth-token-gated JSON-RPC + HTTP gateway",
      "Owns provider routing, quota refresh, retrieval, mission control",
      "JSONL run journal — every agent invocation, every tool call, replayable",
      "Repairs itself when launched from a stale plist or moved app bundle"
    ]
  },
  {
    id: "cli",
    name: "Command-line interface",
    platform: "macOS",
    status: "shipping",
    statusLabel: "Shipping",
    description:
      "openburnbar — eight commands for scripting, agents, and operators. Same daemon, no extra account.",
    bullets: [
      "health · controller · questions · followups · missions",
      "mission-approve · simulator-runs · simulator-replay",
      "Pipes cleanly into git hooks, CI, and other agent scripts"
    ]
  },
  {
    id: "widgets",
    name: "Widgets & Live Activity",
    platform: "iOS / iPadOS",
    status: "shipping",
    statusLabel: "Shipping (with iOS app)",
    description:
      'Lock-screen quota, Dynamic Island countdown, home-screen cost sparkline. Siri shortcut: "What\'s my burn today?"',
    bullets: [
      "Hero small, cost sparkline medium, dashboard large",
      "Live Activity on iOS 16.1+ with top provider + tokens + cost",
      "App Intents for Spotlight + Siri"
    ]
  },
  {
    id: "smart-display",
    name: "Smart displays",
    platform: "Nest Hub · Pixel Clock · Chromecast",
    status: "shipping",
    statusLabel: "Shipping (per-device QA matrix)",
    description:
      'One-click "Make display work" — casts a live OpenBurnBar dashboard, with proof of acceptance before marking healthy.',
    bullets: [
      "Google Nest Hub via Cast V2 + Home Assistant blueprints",
      "ULANZI TC001 via AWTRIX HTTP or stock-firmware simulator",
      "Per-device QA matrix gates support claims — see docs/SMART_DISPLAY_DEVICE_QA.md"
    ],
    cta: { href: "/platforms#smart-displays", label: "See the live mockups" }
  },
  {
    id: "android",
    name: "Android companion",
    platform: "Android 8+",
    status: "beta",
    statusLabel: "Feature-complete · Play Store pending",
    description:
      "Everything the iPhone app does, now on Android — your burn, your sessions, the assistant, and Floo. Built and tested; not yet on the Play Store.",
    bullets: [
      "Full parity with the iPhone & iPad app, screen for screen",
      "Floo media and the assistant, same as on iOS",
      "Not yet distributed through the Play Store — that's the last step"
    ]
  },
  {
    id: "mcp",
    name: "MCP integration",
    platform: "Local stdio · Hosted Streamable HTTP · macOS + any OS",
    status: "shipping",
    statusLabel: "Shipping",
    description:
      "Three Model Context Protocol surfaces let Codex, Claude Code, Cursor, Droid, Kimi, Forge, and Hermes query your OpenBurnBar history as grounded evidence — local SQLite for free, encrypted hosted memory for Pro.",
    bullets: [
      "Local Python MCP — 26 tools over your OpenBurnBar SQLite, read-mostly by default",
      "Hosted Remote MCP — live at https://mcp.burnbar.ai/mcp, 8 tools, BurnBar Pro entitlement",
      "Local stdio shim — bridges stdio-only clients to the hosted endpoint, decrypts on-device",
      "Default privacy mode is local_decrypt_shim — public rollout stays gated until runtime-readiness evidence proves servers cannot read plaintext queries or bodies"
    ],
    cta: { href: "/mcp", label: "See the MCP page" }
  }
];

export function bySurfaceId(id: string): Surface | undefined {
  return SURFACES.find((s) => s.id === id);
}
