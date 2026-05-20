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
    status: "beta",
    statusLabel: "Public beta",
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
    name: "iOS & iPadOS companion",
    platform: "iOS 17+",
    status: "review",
    statusLabel: "In App Store review",
    description:
      "Quota Watch, Pulse, Streams, Hermes, Chart Studio. The Mac runs the data; the phone/tablet renders it natively.",
    bullets: [
      "Native Swift Charts via Chart Studio — 10 chart kinds plus sandboxed Mermaid",
      "Trend Atlas insights rotate across 9 rules",
      "Lock-screen Live Activity, Dynamic Island, Siri shortcut",
      "Adaptive split-view + sidebar nav on iPad, keyboard shortcuts ⌘1–4, ⌘R, ⌘H",
      "Hermes Realtime Relay reaches the Mac's local assistant remotely (paid feature)"
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
    status: "planned",
    statusLabel: "In development",
    description:
      "Read-only Firestore consumer — renders burn data other clients push to Firebase. Source under android/.",
    bullets: [
      "Material 3 + Jetpack Compose, edge-to-edge",
      "Full screen set: burn · streams · pulse · providers · hermes · chart studio · smart display · store · you",
      "No Play Store distribution path yet"
    ]
  }
];

export function bySurfaceId(id: string): Surface | undefined {
  return SURFACES.find((s) => s.id === id);
}
