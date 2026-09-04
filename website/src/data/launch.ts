export type LaunchChannel =
  | "github_release"
  | "hacker_news"
  | "reddit"
  | "indie_hackers"
  | "product_hunt"
  | "x_twitter"
  | "email"
  | "warm_dm";

export interface LaunchPost {
  channel: LaunchChannel;
  /** Optional subreddit / community label for Reddit-style posts. */
  community?: string;
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

export const WEEKEND_PUBLIC_BETA_POSITIONING =
  "Public beta of the free local Core: macOS menu-bar meter + iOS companion. We bug-watch with early users. Windows and Linux are not the launch story yet.";

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

/** Soft-launch / public-beta posts for a Mac + iOS Core weekend. */
export const WEEKEND_PUBLIC_BETA_POSTS: LaunchPost[] = [
  {
    channel: "github_release",
    headline: "OpenBurnBar public beta: free local AI cost meter for Mac (+ iOS)",
    body: `We're opening a public beta of the free local Core.

OpenBurnBar sits in your macOS menu bar, reads local Claude Code / Codex / Cursor / Factory logs, and shows tokens, spend, and quota headroom — no account required, no API keys leave your machine for local tracking.

iOS companion is on the App Store. Linux has an early ARM64 prerelease. Windows stays private until certification clears.

If you try it this weekend: please tell us whether the first-run number matches what you expect. Broken providers and confusing first-run moments are especially useful.

Download: https://burnbar.ai/download
Feedback: https://github.com/Imagine-That-Ai/BurnBar/discussions
Support: support@burnbar.ai`,
    cta: "Download the Mac DMG"
  },
  {
    channel: "hacker_news",
    headline: "Launch HN: OpenBurnBar – local cost/quota cockpit for AI coding agents (macOS)",
    body: `Hi HN — I built OpenBurnBar because my AI coding bill always arrived after the work was done.

It is a native macOS menu-bar app that reads local agent session logs (Claude Code, Codex, Cursor, Factory, etc.) and shows tokens, dollars, and quota headroom. Local tracking needs no account and does not send API keys off-device. There is also an iOS companion on the App Store.

This weekend is a public beta of the free local Core. Optional cloud sync / remote-control tiers exist, but they are not the launch story.

I am especially looking for feedback on:
1) Does first-run spend look right within ~10% of what you expect?
2) Which provider parsers are wrong or missing?
3) What confused you in the first five minutes?

Mac download: https://burnbar.ai/download
Source: https://github.com/Imagine-That-Ai/BurnBar`,
    cta: "Try the local Mac app"
  },
  {
    channel: "reddit",
    community: "r/LocalLLaMA",
    headline: "OpenBurnBar public beta: local-first cost/quota meter for AI coding agents (macOS)",
    body: `I open-sourced / opened a public beta for OpenBurnBar — a native macOS menu-bar tool that watches local AI coding agent logs and shows spend + quota without requiring an account for the local Core.

Useful if you run Claude Code / Codex / Cursor / similar and only notice the bill at month end.

Looking for beta feedback this weekend (especially wrong numbers + rough first-run). Windows is not public yet; Linux is ARM64 early beta only.

https://burnbar.ai/download`,
    cta: "Download + tell me what broke"
  },
  {
    channel: "reddit",
    community: "r/ClaudeAI",
    headline: "Public beta: menu-bar meter for Claude Code spend/quota (local, free Core)",
    body: `If you use Claude Code a lot and hate billing surprises: OpenBurnBar is a free local macOS menu-bar app that reads your local session logs and shows tokens/spend/quota headroom.

No account needed for local tracking. iOS companion is on the App Store. Public beta this weekend — I want bug reports more than praise.

https://burnbar.ai/download
Feedback: support@burnbar.ai or GitHub Discussions`,
    cta: "Try it and report mismatches"
  },
  {
    channel: "reddit",
    community: "r/cursor",
    headline: "Public beta: local Cursor/Claude/Codex spend meter for macOS",
    body: `Built a local-first menu-bar meter that reads Cursor + other agent logs and shows cost/quota without sending keys off-device for the free Core.

Public beta weekend — Mac DMG + iOS app. Looking for “this number is wrong” reports more than anything.

https://burnbar.ai/download`,
    cta: "Download for Mac"
  },
  {
    channel: "reddit",
    community: "r/programming",
    headline: "OpenBurnBar – local-first cost meter for AI coding agents (macOS public beta)",
    body: `OpenBurnBar is a native macOS app that parses local AI agent session logs and surfaces tokens, spend, and quota. Local Core is free and account-optional. Public beta this weekend; feedback welcome.

https://burnbar.ai/download
https://github.com/Imagine-That-Ai/BurnBar`,
    cta: "Read more / download"
  },
  {
    channel: "indie_hackers",
    headline: "Public beta: I launched a free local cost cockpit for AI coding agents",
    body: `I kept getting surprised by Claude/Cursor bills, so I built OpenBurnBar — a macOS menu-bar meter that reads local agent logs.

This weekend is a public beta of the free local Core (+ iOS companion). Not waiting for Windows/Linux parity. Goal is 25 installs and 10 honest bug reports, not virality.

If you run multiple agents, I’d love a cold-install test:
https://burnbar.ai/download`,
    cta: "See the launch notes"
  },
  {
    channel: "x_twitter",
    headline: "OpenBurnBar public beta thread",
    body: `1/ OpenBurnBar public beta is open.

Free local Mac menu-bar meter for AI coding agents — tokens, spend, quota. Reads local logs. No account required for the Core.

https://burnbar.ai/download

2/ iOS companion is on the App Store. Linux = early ARM64 only. Windows stays private until cert clears.

3/ If you try it this weekend, tell me one thing: does the first-run number match reality?

support@burnbar.ai · github.com/Imagine-That-Ai/BurnBar/discussions`,
    cta: "Download + reply with what broke"
  },
  {
    channel: "warm_dm",
    headline: "Personal ask (copy/paste)",
    body: `Hey — I’m opening a public beta of OpenBurnBar this weekend (free local Mac meter for Claude/Cursor/Codex spend + quota).

Would you be willing to cold-install it and tell me, brutally:
1) Did the first number look right?
2) What confused you in 5 minutes?

https://burnbar.ai/download

No pressure if you’re slammed — even a “install failed” note helps.`,
    cta: "Ask 20–30 warm contacts"
  },
  {
    channel: "product_hunt",
    headline: "OpenBurnBar - watch your AI coding agents (public beta)",
    body: `Track cost, quota, and agent activity from a native macOS menu bar app. Start free and local. Optional cloud sync / phone-to-Mac control only when you need it.

Public beta focus: Mac + iOS Core. Please report wrong numbers and rough first-run moments.`,
    cta: "Get OpenBurnBar"
  },
  {
    channel: "email",
    headline: "OpenBurnBar public beta is open (free local Core)",
    body: `The free local Mac app is the foundation this weekend: install, watch spend/quota, tell us what is wrong.

BurnBar Cloud / Cloud Pro remain optional for sync and supervised control. They are not required to try the beta.

Download: https://burnbar.ai/download
Feedback: support@burnbar.ai`,
    cta: "Try the free local Core"
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
