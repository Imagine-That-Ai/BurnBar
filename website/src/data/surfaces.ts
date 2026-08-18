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
    id: "linux",
    name: "Linux desktop app",
    platform: "Linux aarch64 (ARM64)",
    status: "shipping",
    statusLabel: "Available · 0.1.0",
    description:
      "Tauri desktop shell over the native OpenBurnBar daemon. First public Linux release — signed AppImage, deb, and rpm for ARM64.",
    bullets: [
      "AppImage, .deb (Debian/Ubuntu), and .rpm (Fedora/RHEL)",
      "Ed25519 detached signatures + keyless Sigstore/cosign attestations",
      "Talks to the OpenBurnBar daemon over a local AF_UNIX socket",
      "aarch64/ARM64 first — x86_64 lane is next"
    ],
    cta: { href: "/download#linux", label: "Download for Linux" }
  },
  {
    id: "ios",
    name: "iPhone & iPad companion",
    platform: "iOS 17+",
    status: "shipping",
    statusLabel: "On the App Store",
    description:
      "Your whole burn picture, in your pocket. The Mac does the work; the phone and tablet show it — and reach back to it.",
    bullets: [
      "See spend the moment it happens — charts drawn from your own numbers",
      "Live on the lock screen and Dynamic Island, plus a “What's my burn today?” Siri shortcut",
      "Floo — see, steer, and unlock your Mac right from your phone",
      "Watch an agent work, or approve its moves, on the go",
      "Ask your Mac's assistant from anywhere — privately (paid)"
    ],
    cta: { href: "/download#ios", label: "Get the iOS app" }
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
    id: "cursor-plugin",
    name: "Cursor Marketplace plugin",
    platform: "Cursor · desktop + Cloud Agents",
    status: "review",
    statusLabel: "Marketplace review pending",
    description:
      "A Cursor Marketplace candidate for hosted MCP over HTTP. Publication and live token setup are still pending; the HTTP-only package currently supports spend and capability diagnostics, while conversation and knowledge search require the optional local preprocessing/decrypt shim.",
    bullets: [
      "Hosted HTTP MCP at https://mcp.burnbar.ai/mcp, protocol 2025-11-25",
      "GitHub-style bearer variable OPENBURNBAR_MCP_ACCESS_TOKEN (short-lived, never committed)",
      "Marketplace publication and the attested /link token-copy path are pending",
      "Conversation and knowledge search need local preprocessing unavailable in the HTTP-only package",
      "Distinct from the source-only editor extension — the plugin is the candidate listing"
    ],
    cta: { href: "/mcp", label: "See the MCP page" }
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
      "openburnbar-cli — eight commands for scripting, agents, and operators. Same daemon, no extra account. (Distinct from the npm package `openburnbar`, which is the Node MCP / resume / memory CLI.)",
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
    statusLabel: "Remediation in progress · Play Store pending",
    description:
      "Android companion is in active mobile-parity remediation. Source coverage is broad; physical-device, store, and VoiceOver evidence is still blocked. See docs/mobile-parity/mobile-parity-ledger.md.",
    bullets: [
      "Parity is not claimed — productParityClaim stays false",
      "Pulse, Burn, Hermes, and Floo ship in source; store/physical rows stay blocked",
      "Not yet distributed through the Play Store"
    ]
  },
  {
    id: "mcp",
    name: "MCP integration",
    platform: "Local stdio · Hosted Streamable HTTP · macOS + any OS",
    status: "shipping",
    statusLabel: "Shipping",
    description:
      "The three non-plugin Model Context Protocol surfaces let Codex, Claude Code, Cursor, Droid, Kimi, Forge, and Hermes query your OpenBurnBar history as grounded evidence — local SQLite for free, encrypted hosted memory for Pro. (The Cursor Marketplace plugin is a separate surface.)",
    bullets: [
      "Local Python MCP — 26 tools over your OpenBurnBar SQLite, read-mostly by default",
      "Hosted Remote MCP — live at https://mcp.burnbar.ai/mcp, 10 tools, BurnBar Cloud entitlement",
      "Local stdio shim — bridges stdio-only clients to the hosted endpoint, decrypts on-device",
      "Default privacy mode is local_decrypt_shim — server never sees plaintext queries or bodies"
    ],
    cta: { href: "/mcp", label: "See the MCP page" }
  }
];

export function bySurfaceId(id: string): Surface | undefined {
  return SURFACES.find((s) => s.id === id);
}
