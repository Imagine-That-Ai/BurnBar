export type LaunchChannel =
  | "github_release"
  | "hacker_news"
  | "reddit"
  | "indie_hackers"
  | "product_hunt"
  | "email";

export interface LaunchPost {
  channel: LaunchChannel;
  headline: string;
  body: string;
  cta: string;
}

export interface UpsellTrigger {
  id: string;
  fromTier: "free" | "cloud";
  toTier: "cloud" | "cloud_pro";
  action: string;
  paywall: "BurnBar Cloud" | "BurnBar Cloud Pro";
  featureGroup: "Group A" | "Group B";
}

export const LAUNCH_POSITIONING =
  "OpenBurnBar is the cost meter and remote-control companion for the AI tools you already pay for - not another model subscription.";

export const FREE_TO_CLOUD_TRIGGERS: UpsellTrigger[] = [
  {
    id: "second-device-sign-in",
    fromTier: "free",
    toTier: "cloud",
    action: "second device sign-in",
    paywall: "BurnBar Cloud",
    featureGroup: "Group A"
  },
  {
    id: "hosted-quota-refresh",
    fromTier: "free",
    toTier: "cloud",
    action: "hosted quota refresh attempt",
    paywall: "BurnBar Cloud",
    featureGroup: "Group A"
  },
  {
    id: "cloud-search",
    fromTier: "free",
    toTier: "cloud",
    action: "cloud search attempt",
    paywall: "BurnBar Cloud",
    featureGroup: "Group A"
  },
  {
    id: "encrypted-backup",
    fromTier: "free",
    toTier: "cloud",
    action: "encrypted backup enable",
    paywall: "BurnBar Cloud",
    featureGroup: "Group A"
  },
  {
    id: "remote-mcp-grant",
    fromTier: "free",
    toTier: "cloud",
    action: "Hosted Remote MCP grant request",
    paywall: "BurnBar Cloud",
    featureGroup: "Group A"
  }
];

export const CLOUD_TO_CLOUD_PRO_TRIGGERS: UpsellTrigger[] = [
  {
    id: "floo-session-start",
    fromTier: "cloud",
    toTier: "cloud_pro",
    action: "Floo session start",
    paywall: "BurnBar Cloud Pro",
    featureGroup: "Group B"
  },
  {
    id: "agent-control-hosted-vision",
    fromTier: "cloud",
    toTier: "cloud_pro",
    action: "Agent Control hosted vision start",
    paywall: "BurnBar Cloud Pro",
    featureGroup: "Group B"
  },
  {
    id: "remote-mac-control",
    fromTier: "cloud",
    toTier: "cloud_pro",
    action: "remote Mac control attempt",
    paywall: "BurnBar Cloud Pro",
    featureGroup: "Group B"
  },
  {
    id: "audit-export-notarization",
    fromTier: "cloud",
    toTier: "cloud_pro",
    action: "audit export notarization prompt",
    paywall: "BurnBar Cloud Pro",
    featureGroup: "Group B"
  },
  {
    id: "hosted-action-balance-exhausted",
    fromTier: "cloud",
    toTier: "cloud_pro",
    action: "hosted-action balance exhausted",
    paywall: "BurnBar Cloud Pro",
    featureGroup: "Group B"
  }
];

export const LAUNCH_POSTS: LaunchPost[] = [
  {
    channel: "github_release",
    headline: "OpenBurnBar 1.0: local AI cost tracking, BurnBar Cloud, and Cloud Pro",
    body: "OpenBurnBar watches spend, quota, and agent activity across the AI tools developers already use. The core product stays local and free; BurnBar Cloud adds sync and encrypted history; Cloud Pro adds Floo and supervised Agent Control with prepaid hosted usage.",
    cta: "Download OpenBurnBar"
  },
  {
    channel: "hacker_news",
    headline: "Launch HN: OpenBurnBar - cost and quota cockpit for AI coding agents",
    body: "We built OpenBurnBar because the AI coding bill usually arrives after the work is done. It reads local agent logs, keeps the free tier local-first, and adds optional paid cloud sync and supervised remote-control workflows.",
    cta: "Try the local Mac app"
  },
  {
    channel: "reddit",
    headline: "OpenBurnBar: local-first AI agent spend and quota tracking",
    body: "OpenBurnBar helps developers see what their coding agents are doing, what they cost, and when quota is running out. The paid cloud tiers are optional and focused on sync, backup, and supervised control workflows.",
    cta: "Read the pricing page"
  },
  {
    channel: "indie_hackers",
    headline: "I launched a cost cockpit for developers running multiple AI agents",
    body: "OpenBurnBar started as a local meter for my own AI tool usage. It now has a free local product, BurnBar Cloud for sync and encrypted history, and Cloud Pro for phone-to-Mac workflows with explicit hosted-usage caps.",
    cta: "See the launch notes"
  },
  {
    channel: "product_hunt",
    headline: "OpenBurnBar - watch your AI coding agents",
    body: "Track cost, quota, sessions, and agent activity across your local developer tools. Start free and local, then add cloud sync or supervised phone-to-Mac control only when you need it.",
    cta: "Get OpenBurnBar"
  },
  {
    channel: "email",
    headline: "OpenBurnBar is ready for paid cloud workflows",
    body: "The free local app remains the foundation. BurnBar Cloud adds sync, backup, search, and agent memory across devices. BurnBar Cloud Pro adds Floo and Agent Control with included monthly allowance and prepaid top-ups.",
    cta: "Upgrade when you need sync or control"
  }
];

export const LAUNCH_UPSELL_TRIGGERS = [...FREE_TO_CLOUD_TRIGGERS, ...CLOUD_TO_CLOUD_PRO_TRIGGERS];
